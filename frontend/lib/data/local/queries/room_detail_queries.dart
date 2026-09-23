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
class SejourEnCours {
  const SejourEnCours({
    required this.ligneId,
    required this.folioId,
    required this.clientNom,
    required this.arrivee,
    required this.depart,
    required this.adultes,
    required this.enfants,
    required this.tarifNuit,
    required this.soldeArdoise,
  });

  final String ligneId;
  final String? folioId;
  final String clientNom;
  final String arrivee;
  final String depart;
  final int adultes;
  final int enfants;
  final int tarifNuit;

  /// Solde de l'ardoise, en francs CFA entiers.
  final int soldeArdoise;
}

/// Une ligne de consommation portee a l'ardoise.
class Consommation {
  const Consommation({
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
class SejourPasse {
  const SejourPasse({
    required this.clientNom,
    required this.arrivee,
    required this.depart,
  });

  final String clientNom;
  final String arrivee;
  final String depart;
}

/// Tout ce que la fiche affiche, en un seul objet.
class FicheChambre {
  const FicheChambre({
    required this.sejour,
    required this.consommations,
    required this.historique,
  });

  final SejourEnCours? sejour;
  final List<Consommation> consommations;
  final List<SejourPasse> historique;

  bool get estOccupee => sejour != null;
}

extension RoomDetailQueries on AtriumDatabase {
  /// La fiche complete d'une chambre, en flux continu.
  ///
  /// Trois lectures plutot qu'une : elles n'ont pas la meme forme (un sejour,
  /// des lignes d'ardoise, des sejours passes) et les joindre produirait un
  /// produit cartesien qu'il faudrait defaire en Dart.
  Stream<FicheChambre> watchFicheChambre(String roomId) async* {
    await for (final _ in _declencheur(roomId)) {
      final sejour = await _sejourEnCours(roomId);
      yield FicheChambre(
        sejour: sejour,
        consommations:
            sejour?.folioId == null ? const [] : await _consommations(sejour!.folioId!),
        historique: await _historique(roomId),
      );
    }
  }

  /// Emet a chaque fois qu'une des tables de la fiche bouge.
  Stream<void> _declencheur(String roomId) => customSelect(
        'SELECT 1',
        readsFrom: {reservationRooms, folios, folioItems, guests},
      ).watch();

  Future<SejourEnCours?> _sejourEnCours(String roomId) async {
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

    return SejourEnCours(
      ligneId: r.read<String>('id'),
      folioId: r.read<String?>('folio_id'),
      clientNom: '${r.read<String>('first_name')} ${r.read<String>('last_name')}',
      arrivee: r.read<String>('arrival_date'),
      depart: r.read<String>('departure_date'),
      adultes: r.read<int>('adults'),
      enfants: r.read<int>('children'),
      tarifNuit: r.read<int>('nightly_rate'),
      soldeArdoise: r.read<int?>('balance') ?? 0,
    );
  }

  Future<List<Consommation>> _consommations(String folioId) async {
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
          (r) => Consommation(
            libelle: r.read<String>('label'),
            categorie: ChargeCategory.values.byName(r.read<String>('category')),
            montant: r.read<int>('amount'),
            journee: r.read<String>('business_date'),
          ),
        )
        .toList();
  }

  Future<List<SejourPasse>> _historique(String roomId) async {
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
          (r) => SejourPasse(
            clientNom:
                '${r.read<String>('first_name')} ${r.read<String>('last_name')}',
            arrivee: r.read<String>('arrival_date'),
            depart: r.read<String>('departure_date'),
          ),
        )
        .toList();
  }
}
