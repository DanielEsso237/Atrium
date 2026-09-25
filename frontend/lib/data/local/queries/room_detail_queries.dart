/// La fiche qui s'ouvre au clic sur une chambre du plan (paragraphe 5.2).
///
/// Le cahier des charges liste ce qu'elle doit montrer : numero, type, prix,
/// client actuel, dates d'arrivee et de depart, consommations, etat,
/// historique. Tout vient de la base locale, donc l'ouverture est instantanee
/// et fonctionne hors ligne.
library;

import 'package:drift/drift.dart';

import '../database.dart';
import '../enums.dart';

/// Le sejour en cours dans une chambre, s'il y en a un.
class CurrentStay {
  const CurrentStay({
    required this.lineId,
    required this.folioId,
    required this.guestName,
    required this.arrival,
    required this.departure,
    required this.adultes,
    required this.enfants,
    required this.nightlyRate,
    required this.balance,
  });

  final String lineId;
  final String? folioId;
  final String guestName;
  final String arrival;
  final String departure;
  final int adultes;
  final int enfants;
  final int nightlyRate;

  /// Solde de l'ardoise, en francs CFA entiers.
  final int balance;
}

/// Une ligne de consommation portee a l'ardoise.
class Charge {
  const Charge({
    required this.libelle,
    required this.categorie,
    required this.montant,
    required this.journee,
  });

  final String libelle;
  final ChargeCategory categorie;
  final int montant;
  final String journee;
}

/// Un sejour passe dans cette chambre.
class PastStay {
  const PastStay({
    required this.guestName,
    required this.arrival,
    required this.departure,
  });

  final String guestName;
  final String arrival;
  final String departure;
}

/// Tout ce que la fiche affiche, en un seul objet.
class RoomDetail {
  const RoomDetail({
    required this.sejour,
    required this.expected,
    required this.consommations,
    required this.historique,
  });

  final CurrentStay? sejour;

  /// Le sejour attribue a cette chambre mais pas encore pris en charge.
  ///
  /// C'est ce qui permet de faire le check-in depuis le plan : la reception
  /// clique sur la chambre du client qui se presente, sans passer par la
  /// liste des reservations.
  final CurrentStay? expected;
  final List<Charge> consommations;
  final List<PastStay> historique;

  bool get estOccupee => sejour != null;
  bool get attendUneArrivee => sejour == null && expected != null;
}

extension RoomDetailQueries on AtriumDatabase {
  /// La fiche complete d'une chambre, en flux continu.
  ///
  /// Trois lectures plutot qu'une : elles n'ont pas la meme forme (un sejour,
  /// des lignes d'ardoise, des sejours passes) et les joindre produirait un
  /// produit cartesien qu'il faudrait defaire en Dart.
  Stream<RoomDetail> watchRoomDetail(String roomId) async* {
    await for (final _ in _declencheur(roomId)) {
      final sejour = await _sejourEnCours(roomId);
      yield RoomDetail(
        sejour: sejour,
        expected: sejour != null ? null : await _sejourAttendu(roomId),
        consommations: sejour?.folioId == null
            ? const []
            : await _consommations(sejour!.folioId!),
        historique: await _historique(roomId),
      );
    }
  }

  /// Emet a chaque fois qu'une des tables de la fiche bouge.
  Stream<void> _declencheur(String roomId) => customSelect(
    'SELECT 1',
    readsFrom: {reservationRooms, folios, folioItems, guests},
  ).watch();

  Future<CurrentStay?> _sejourEnCours(String roomId) async {
    final lignes = await customSelect(
      '''
      SELECT rr.id, rr.arrival_date, rr.departure_date, rr.adults, rr.children,
             rr.nightly_rate,
             g.first_name, g.last_name,
             f.id AS folio_id, f.balance
        FROM reservation_rooms rr
        JOIN reservations res ON res.id = rr.reservation_id
        JOIN guests g         ON g.id  = res.guest_id
        LEFT JOIN folios f    ON f.reservation_room_id = rr.id
                             AND f.status = 'OPEN'
                             AND f.deleted_at IS NULL
       WHERE rr.room_id = ?1
         AND rr.deleted_at IS NULL
         AND rr.status = 'CHECKED_IN'
       LIMIT 1
      ''',
      variables: [Variable.withString(roomId)],
      readsFrom: {reservationRooms, reservations, guests, folios},
    ).get();

    if (lignes.isEmpty) return null;
    final r = lignes.first;

    return CurrentStay(
      lineId: r.read<String>('id'),
      folioId: r.read<String?>('folio_id'),
      guestName:
          '${r.read<String>('first_name')} ${r.read<String>('last_name')}',
      arrival: r.read<String>('arrival_date'),
      departure: r.read<String>('departure_date'),
      adultes: r.read<int>('adults'),
      enfants: r.read<int>('children'),
      nightlyRate: r.read<int>('nightly_rate'),
      balance: r.read<int?>('balance') ?? 0,
    );
  }

  /// Le sejour attribue a cette chambre et pas encore arrive.
  Future<CurrentStay?> _sejourAttendu(String roomId) async {
    final lignes = await customSelect(
      '''
      SELECT rr.id, rr.arrival_date, rr.departure_date, rr.adults, rr.children,
             rr.nightly_rate,
             g.first_name, g.last_name
        FROM reservation_rooms rr
        JOIN reservations res ON res.id = rr.reservation_id
        JOIN guests g         ON g.id  = res.guest_id
       WHERE rr.room_id = ?1
         AND rr.deleted_at IS NULL
         AND rr.status IN ('PENDING','CONFIRMED')
       ORDER BY rr.arrival_date
       LIMIT 1
      ''',
      variables: [Variable.withString(roomId)],
      readsFrom: {reservationRooms, reservations, guests},
    ).get();

    if (lignes.isEmpty) return null;
    final r = lignes.first;

    return CurrentStay(
      lineId: r.read<String>('id'),
      folioId: null,
      guestName:
          '${r.read<String>('first_name')} ${r.read<String>('last_name')}',
      arrival: r.read<String>('arrival_date'),
      departure: r.read<String>('departure_date'),
      adultes: r.read<int>('adults'),
      enfants: r.read<int>('children'),
      nightlyRate: r.read<int>('nightly_rate'),
      balance: 0,
    );
  }

  Future<List<Charge>> _consommations(String folioId) async {
    final lignes = await customSelect(
      '''
      SELECT label, category, amount, business_date
        FROM folio_items
       WHERE folio_id = ?1 AND deleted_at IS NULL
       ORDER BY business_date DESC, created_at DESC
       LIMIT 20
      ''',
      variables: [Variable.withString(folioId)],
      readsFrom: {folioItems},
    ).get();

    return lignes
        .map(
          (r) => Charge(
            libelle: r.read<String>('label'),
            categorie: ChargeCategory.values.byName(r.read<String>('category')),
            montant: r.read<int>('amount'),
            journee: r.read<String>('business_date'),
          ),
        )
        .toList();
  }

  Future<List<PastStay>> _historique(String roomId) async {
    final lignes = await customSelect(
      '''
      SELECT g.first_name, g.last_name, rr.arrival_date, rr.departure_date
        FROM reservation_rooms rr
        JOIN reservations res ON res.id = rr.reservation_id
        JOIN guests g         ON g.id  = res.guest_id
       WHERE rr.room_id = ?1
         AND rr.deleted_at IS NULL
         AND rr.status = 'CHECKED_OUT'
       ORDER BY rr.departure_date DESC
       LIMIT 10
      ''',
      variables: [Variable.withString(roomId)],
      readsFrom: {reservationRooms, reservations, guests},
    ).get();

    return lignes
        .map(
          (r) => PastStay(
            guestName:
                '${r.read<String>('first_name')} ${r.read<String>('last_name')}',
            arrival: r.read<String>('arrival_date'),
            departure: r.read<String>('departure_date'),
          ),
        )
        .toList();
  }
}