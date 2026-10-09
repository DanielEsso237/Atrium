/// Des donnees de test sur la tablette, a la demande, en developpement.
///
/// L'ancien jeu de demonstration (retire le 30 septembre, voir
/// `purge_demo.dart`) ecrivait en base **sans** passer par la file d'envoi :
/// le serveur ne connaissait pas ces dossiers, et le premier depart
/// enregistre bloquait la file sur « reservation introuvable ».
///
/// Celui-ci fait l'inverse : il rejoue ce qu'un receptionniste ferait, avec
/// les memes depots (creer le client, reserver, faire l'arrivee, porter les
/// consommations, encaisser, faire le depart). Chaque ecriture part donc
/// aussi dans la file : un serveur les recevra comme n'importe quelle
/// saisie, et rien ne s'y bloquera.
///
/// Rien ne se charge tout seul : il faut le demander depuis le menu du
/// compte, qui ne le propose qu'en mode debug. Le serveur, lui, a son propre
/// jeu (`backend/app/db/seed_demo.py`).
library;

import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;

import '../../core/business_day.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'cash_repository.dart';
import 'folio_repository.dart';
import 'guest_repository.dart';
import 'hotel_repository.dart';
import 'maintenance_repository.dart';
import 'reservation_repository.dart';

/// Les clients : prenom, nom, nationalite, telephone.
const _clients = [
  ('Awa', 'Koné', 'CI', '+225 07 48 21 33 10'),
  ('Jean-Marc', 'Mballa', 'CM', '+237 6 77 41 20 18'),
  ('Fatou', 'Ndiaye', 'SN', '+221 77 512 40 08'),
  ('Paul', 'Essomba', 'CM', '+237 6 99 02 14 77'),
  ('Aminata', 'Traoré', 'ML', '+223 76 41 22 90'),
  ('Koffi', 'Yao', 'CI', '+225 05 66 10 72 41'),
  ('Mariam', 'Ouédraogo', 'BF', '+226 70 21 45 63'),
  ('Didier', 'Kouassi', 'CI', '+225 01 02 87 45 19'),
  ('Nadia', 'Bamba', 'CI', '+225 07 09 33 81 26'),
  ('Serge', 'Atangana', 'CM', '+237 6 70 88 13 52'),
  ('Clarisse', "N'Guessan", 'CI', '+225 05 44 70 12 08'),
  ('Ibrahim', 'Diallo', 'GN', '+224 622 18 47 90'),
];

enum _Etat { installe, parti, attendu, aVenir }

/// Les sejours : client, chambre, arrivee et depart en jours depuis
/// aujourd'hui, etat voulu. Les memes que le jeu du serveur.
const _sejours = [
  (1, '102', -2, 2, _Etat.installe),
  (2, '201', -1, 1, _Etat.installe),
  (7, '309', 0, 3, _Etat.installe),
  (8, '501', -3, 0, _Etat.installe),
  (5, '402', -1, 0, _Etat.installe),
  (9, '401', 0, 1, _Etat.installe),
  (0, '204', -2, 0, _Etat.parti),
  (11, '403', -1, 0, _Etat.parti),
  (3, '302', 0, 2, _Etat.attendu),
  (4, '103', 0, 3, _Etat.attendu),
  (10, '502', 0, 1, _Etat.attendu),
  (6, '510', 2, 5, _Etat.aVenir),
  (11, '567', 7, 9, _Etat.aVenir),
];

/// Ce que les clients ont consomme : sejour, categorie, libelle, quantite,
/// prix unitaire.
const _consommations = [
  (0, ChargeCategory.FNB, 'Dîner au restaurant', 2, 8500),
  (0, ChargeCategory.MINIBAR, 'Minibar : bière locale', 2, 1500),
  (2, ChargeCategory.FNB, 'Petit-déjeuner', 1, 6000),
  (3, ChargeCategory.LAUNDRY, 'Blanchisserie', 1, 4000),
  (3, ChargeCategory.FNB, 'Room service', 1, 12500),
  (6, ChargeCategory.MINIBAR, 'Minibar : eau minérale', 3, 1000),
  (7, ChargeCategory.FNB, 'Dîner au restaurant', 1, 9500),
];

/// Charge le jeu et dit ce qui a ete fait, en une phrase pour l'ecran.
///
/// Une seule fois par tablette : si les clients du jeu sont deja la, on ne
/// recree rien -- deux fois les memes clients, ce serait deux fiches au
/// serveur.
///
/// L'hotel (coordonnees et logo) se regle aussi sur une tablette qui a deja
/// les sejours, et seulement pour un agent qui a le droit de le modifier :
/// le serveur refuserait la modification a tout autre, et la file d'envoi
/// se bloquerait derriere.
Future<String> chargerDonneesDeTest(
  AtriumDatabase db, {
  required String agentId,
  bool peutModifierHotel = false,
  Uint8List? logo,
}) async {
  final sejours = await _clientsEtSejours(db, agentId: agentId);
  if (!peutModifierHotel) return sejours;
  final hotel = await _hotelDeTest(db, agentId: agentId, logo: logo);
  return '$sejours $hotel';
}

/// Des coordonnees et le logo d'Edge Hotel, pour voir l'en-tete des
/// factures. Rien n'est remplace : un hotel deja renseigne garde les siens.
Future<String> _hotelDeTest(
  AtriumDatabase db, {
  required String agentId,
  Uint8List? logo,
}) async {
  final depot = HotelRepository(db);
  final hotel = await depot.lire();
  if (hotel == null) return '';
  final faits = <String>[];
  if (hotel.address == null && hotel.phone == null) {
    await depot.modifierIdentite(
      nom: hotel.name,
      raisonSociale: 'Edge Hospitality SARL',
      adresse: 'Boulevard de la République, Plateau',
      ville: 'Abidjan',
      pays: "Côte d'Ivoire",
      telephone: '+225 27 20 30 40 50',
      email: 'reception@edgehotel.ci',
      numeroFiscal: 'CI-ABJ-2026-B-1234',
      by: agentId,
    );
    faits.add('coordonnées');
  }
  if (logo != null && hotel.logoData == null && hotel.logoVersion == null) {
    await depot.importerLogo(logo, by: agentId);
    faits.add('logo');
  }
  return faits.isEmpty
      ? "L'hôtel avait déjà son logo et ses coordonnées."
      : "Hôtel : ${faits.join(' et ')} ajoutés.";
}

/// Le premier jeu : clients, sejours, consommations, une panne. Une seule
/// fois par tablette.
Future<String> _clientsEtSejours(
  AtriumDatabase db, {
  required String agentId,
}) async {
  final deja = await db
      .customSelect(
        "SELECT 1 FROM guests WHERE first_name = 'Jean-Marc' "
        "AND last_name = 'Mballa' AND deleted_at IS NULL LIMIT 1",
      )
      .getSingleOrNull();
  if (deja != null) return 'Les données de test sont déjà sur cette tablette.';

  final chambres = {
    for (final r in await db.customSelect('''
      SELECT r.id, r.number, r.room_type_id, rt.default_rate
        FROM rooms r
        JOIN room_types rt ON rt.id = r.room_type_id
       WHERE r.deleted_at IS NULL AND r.is_active = 1
    ''').get())
      r.read<String>('number'): (
        id: r.read<String>('id'),
        type: r.read<String>('room_type_id'),
        tarif: r.read<int>('default_rate'),
      ),
  };

  final aujourdhui = businessDayFor(DateTime.now());
  DateTime jour(int decalage) => DateTime.utc(
    aujourdhui.year,
    aujourdhui.month,
    aujourdhui.day + decalage,
  );

  final reservations = ReservationRepository(db);
  final ardoises = FolioRepository(db);

  // Encaisser suppose une caisse ouverte : sans elle, l'encaissement serait
  // refuse ici comme au serveur.
  await CashRepository(
    db,
  ).open(userId: agentId, openingFloat: 50000, by: agentId);

  final clients = <String>[];
  for (final (prenom, nom, pays, telephone) in _clients) {
    final client = await GuestRepository(db).create(
      firstName: prenom,
      lastName: nom,
      nationality: pays,
      phone: telephone,
      documentType: IdDocumentType.ID_CARD,
      createdBy: agentId,
    );
    clients.add(client.id);
  }

  var sejours = 0;
  for (var rang = 0; rang < _sejours.length; rang++) {
    final (client, numero, arrivee, depart, etat) = _sejours[rang];
    final chambre = chambres[numero];
    if (chambre == null) continue;

    final ligne = await _ligneDe(
      db,
      await reservations.create(
        guestId: clients[client],
        roomTypeId: chambre.type,
        arrival: jour(arrivee),
        departure: jour(depart),
        nightlyRate: chambre.tarif,
        adults: rang % 3 == 0 ? 2 : 1,
        // Une reservation a venir n'a pas encore de chambre : l'attribuer
        // des maintenant la ferait apparaitre sur le plan avant l'heure.
        roomId: etat == _Etat.aVenir ? null : chambre.id,
        createdBy: agentId,
        depositCollected: numero == '502' ? chambre.tarif ~/ 2 : null,
        depositMethod: numero == '502' ? PaymentMethod.MOBILE_MONEY : null,
      ),
    );
    sejours++;
    if (etat == _Etat.attendu || etat == _Etat.aVenir) continue;

    // L'arrivee porte les nuits passees sur l'ardoise, comme a la reception.
    await reservations.checkIn(lineId: ligne, by: agentId);
    final ardoise = (await ardoises.openFolioForStay(ligne))!.id;

    for (final (sejour, categorie, libelle, quantite, prix) in _consommations) {
      if (sejour != rang) continue;
      await ardoises.addCharge(
        folioId: ardoise,
        category: categorie,
        label: libelle,
        quantity: quantite,
        unitPrice: prix,
        postedBy: agentId,
      );
    }

    if (etat == _Etat.parti) {
      // Le depart se fait note reglee : on encaisse, on clot, puis la
      // chambre part au menage.
      final solde = await _solde(db, ardoise);
      if (solde > 0) {
        await ardoises.addPayment(
          folioId: ardoise,
          method: PaymentMethod.CASH,
          amount: solde,
          receivedBy: agentId,
        );
      }
      await ardoises.close(ardoise, by: agentId);
      await reservations.checkOut(lineId: ligne, by: agentId);
    } else if (rang == 0 || rang == 2) {
      // Deux clients installes ont deja regle une partie de leur note.
      final acompte = _min(await _solde(db, ardoise), chambre.tarif);
      if (acompte > 0) {
        await ardoises.addPayment(
          folioId: ardoise,
          method: rang == 0 ? PaymentMethod.CARD : PaymentMethod.MOBILE_MONEY,
          amount: acompte,
          reference: rang == 0 ? null : 'MOMO-77120',
          receivedBy: agentId,
        );
      }
    }
  }

  final enPanne = chambres['203'];
  if (enPanne != null) {
    // Le ticket bloquant sort la chambre de la vente, comme au serveur.
    await MaintenanceRepository(db).create(
      title: 'Climatisation en panne',
      description: 'Le client précédent signale un bruit puis un arrêt.',
      roomId: enPanne.id,
      priority: Priority.HIGH,
      blocksRoom: true,
      by: agentId,
    );
  }

  return '${clients.length} clients et $sejours séjours ajoutés.';
}

Future<String> _ligneDe(AtriumDatabase db, String reservationId) async =>
    (await db
            .customSelect(
              'SELECT id FROM reservation_rooms WHERE reservation_id = ?',
              variables: [Variable.withString(reservationId)],
            )
            .getSingle())
        .read<String>('id');

Future<int> _solde(AtriumDatabase db, String ardoise) async =>
    (await db
            .customSelect(
              'SELECT balance FROM folios WHERE id = ?',
              variables: [Variable.withString(ardoise)],
            )
            .getSingle())
        .read<int>('balance');

int _min(int a, int b) => a < b ? a : b;
