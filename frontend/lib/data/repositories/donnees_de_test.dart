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

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'cash_repository.dart';
import 'folio_repository.dart';
import 'guest_repository.dart';
import 'hotel_repository.dart';
import 'housekeeping_repository.dart';
import 'maintenance_repository.dart';
import 'order_repository.dart';
import 'outlet_repository.dart';
import 'reservation_repository.dart';
import 'stock_repository.dart';

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

/// Les ventes au comptoir du complement : rang du point de vente, lignes
/// (libelle, prix unitaire, quantite), moyen de paiement. Les points de
/// vente sont ceux de la tablette, pris dans l'ordre.
const _ventes = [
  (0, [('Poulet DG', 6500, 1), ('Bissap maison', 1000, 2)], PaymentMethod.CASH),
  (
    0,
    [('Brochettes de bœuf', 3000, 2), ('Bière locale', 1500, 3)],
    PaymentMethod.MOBILE_MONEY,
  ),
  (1, [('Bière locale', 1500, 4)], PaymentMethod.CASH),
  (1, [('Cocktail maison', 4500, 2)], PaymentMethod.CARD),
  (2, [('Bouteille de champagne', 45000, 1)], PaymentMethod.CARD),
  (
    2,
    [('Eau minérale', 1000, 3), ('Soda', 1000, 2)],
    PaymentMethod.MOBILE_MONEY,
  ),
  (0, [('Petit-déjeuner continental', 6000, 2)], PaymentMethod.CASH),
];

/// Les points de vente du jeu : code du jeu d'essai du serveur
/// (`backend/app/db/donnees_essai.py`), code et identifiant si on doit le
/// creer, libelle, horaires.
///
/// Deja descendu du serveur, le point de vente est repris tel quel. Sinon il
/// est cree sous un code a part et un identifiant fixe : un serveur qui a
/// deja son `BAR` refuserait un second point de vente au meme code (409), et
/// la file se bloquerait derriere ; le meme identifiant, renvoye par une
/// autre tablette, est reconnu comme un renvoi.
const _pointsDeVente = [
  (
    'BAR',
    'BAR_ESSAI',
    '01920000-0000-7000-9000-0000000e0001',
    'Bar / Lounge',
    '10:00',
    '23:59',
  ),
  (
    'RESTO',
    'RESTO_ESSAI',
    '01920000-0000-7000-9000-0000000e0002',
    'Restaurant',
    '06:30',
    '23:00',
  ),
];

/// Ce que les clients installes ont deja pris au comptoir : chambre, point
/// de vente, jours avant aujourd'hui, libelle, quantite, prix unitaire. Les
/// prix de la carte du jeu d'essai du serveur. Le 309 et le 401, arrives du
/// jour, n'ont encore rien pris : la fiche montre aussi ce cas.
const _ventesAuComptoir = [
  ('102', 'BAR', 1, 'Mutzig', 2, 1000),
  ('102', 'BAR', 1, 'Guinness', 1, 1200),
  ('102', 'BAR', 0, 'Top Ananas', 1, 600),
  ('102', 'RESTO', 1, 'Poulet DG', 1, 7500),
  ('201', 'BAR', 1, '33 Export', 2, 900),
  ('201', 'RESTO', 0, 'Ndolé crevettes et plantain', 1, 6500),
  ('201', 'RESTO', 0, 'Supermont 1,5 L', 1, 1000),
  ('501', 'BAR', 2, 'Mutzig', 3, 1000),
  ('501', 'BAR', 1, 'Guinness', 2, 1200),
  ('501', 'BAR', 0, 'Supermont 1,5 L', 1, 1000),
  ('402', 'RESTO', 1, 'Eru et water fufu', 1, 5000),
];

/// Charge le jeu, ses ventes au comptoir et son complement pour les
/// rapports (ventes, stock, caisse, menage, pannes), et dit ce qui a ete
/// fait, en une phrase pour l'ecran.
///
/// Une seule fois par tablette : si les clients du jeu sont deja la, on ne
/// recree rien -- deux fois les memes clients, ce serait deux fiches au
/// serveur. Les ventes au comptoir, venues apres, se chargent quand meme
/// sur une tablette qui a deja le premier jeu.
///
/// `peut` : les droits de l'agent. Creer un point de vente demande
/// `restaurant.write` au serveur ; sans lui, on ne cree rien qu'il
/// refuserait.
///
/// L'hotel (coordonnees et logo) se regle aussi sur une tablette qui a deja
/// les sejours, et seulement pour un agent qui a `hotel.write` : le
/// serveur refuserait la modification a tout autre, et la file d'envoi
/// se bloquerait derriere.
Future<String> chargerDonneesDeTest(
  AtriumDatabase db, {
  required String agentId,
  bool Function(String permission)? peut,
  Uint8List? logo,
}) async {
  final sejours = await _clientsEtSejours(db, agentId: agentId, peut: peut);
  final complement = await _complement(db, agentId: agentId);
  if (!(peut?.call('hotel.write') ?? false)) return '$sejours $complement';
  final hotel = await _hotelDeTest(db, agentId: agentId, logo: logo);
  return '$sejours $complement $hotel';
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

/// Le premier jeu : clients, sejours, consommations, une panne.
Future<String> _clientsEtSejours(
  AtriumDatabase db, {
  required String agentId,
  bool Function(String permission)? peut,
}) async {
  final deja = await db
      .customSelect(
        "SELECT 1 FROM guests WHERE first_name = 'Jean-Marc' "
        "AND last_name = 'Mballa' AND deleted_at IS NULL LIMIT 1",
      )
      .getSingleOrNull();
  if (deja != null) {
    return await _chargerVentesAuComptoir(
          db,
          agentId: agentId,
          peut: peut ?? (_) => false,
        ) ??
        'Les données de test sont déjà sur cette tablette.';
  }

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

  final comptoir = await _chargerVentesAuComptoir(
    db,
    agentId: agentId,
    peut: peut ?? (_) => false,
  );
  return '${clients.length} clients et $sejours séjours ajoutés.'
      '${comptoir == null ? '' : ' $comptoir'}';
}

/// Le bar et le restaurant, et ce que les clients installes y ont pris :
/// de quoi ouvrir une chambre au point de vente et voir son historique.
///
/// `null` quand c'est deja fait.
Future<String?> _chargerVentesAuComptoir(
  AtriumDatabase db, {
  required String agentId,
  required bool Function(String permission) peut,
}) async {
  final points = <String, OutletRow>{};
  for (final (code, codeEssai, id, libelle, ouvre, ferme) in _pointsDeVente) {
    final existant = await (db.select(db.outlets)
          ..where(
            (o) =>
                (o.code.equals(code) | o.id.equals(id)) &
                o.deletedAt.isNull() &
                o.isActive.equals(true) &
                o.allowsRoomCharge.equals(true),
          ))
        .get();
    if (existant.isNotEmpty) {
      points[code] = existant.first;
    } else if (peut('restaurant.write')) {
      points[code] = await OutletRepository(db).create(
        id: id,
        code: codeEssai,
        label: libelle,
        opensAt: ouvre,
        closesAt: ferme,
      );
    }
  }
  if (points.isEmpty) {
    return 'Aucun point de vente : chargez les données avec un compte qui '
        'gère les points de vente (ADMIN01).';
  }

  final chambres = {
    for (final c in await OrderRepository(db).watchChargeableRooms().first)
      c.roomNumber: c,
  };
  final aujourdhui = businessDayFor(DateTime.now());
  final ardoises = FolioRepository(db);
  var ventes = 0;
  var dejaPortees = 0;
  for (final (numero, code, ilYa, libelle, quantite, prix)
      in _ventesAuComptoir) {
    final chambre = chambres[numero];
    final point = points[code];
    if (chambre == null || point == null) continue;
    // Deja portee lors d'un chargement precedent : on ne la double pas.
    final deja = await db
        .customSelect(
          "SELECT 1 FROM folio_items WHERE source_table = 'outlets' "
          'AND folio_id = ?1 AND source_id = ?2 AND label = ?3 '
          'AND deleted_at IS NULL LIMIT 1',
          variables: [
            Variable.withString(chambre.folioId),
            Variable.withString(point.id),
            Variable.withString(libelle),
          ],
        )
        .getSingleOrNull();
    if (deja != null) {
      dejaPortees++;
      continue;
    }
    await ardoises.addCharge(
      folioId: chambre.folioId,
      category: ChargeCategory.FNB,
      label: libelle,
      quantity: quantite,
      unitPrice: prix,
      postedBy: agentId,
      // D'ou vient la ligne : c'est ce qui la fait apparaitre dans
      // l'historique du point de vente.
      sourceTable: 'outlets',
      sourceId: point.id,
      businessDate: ilYa == 0
          ? null
          : formatIsoDate(
              DateTime.utc(
                aujourdhui.year,
                aujourdhui.month,
                aujourdhui.day - ilYa,
              ),
            ),
    );
    ventes++;
  }
  if (ventes == 0 && dejaPortees > 0) return null;
  return ventes == 0
      ? 'Aucun client installé à qui porter : chargez d’abord le jeu.'
      : '$ventes consommations au bar et au restaurant.';
}

/// De quoi remplir les rapports et declencher les alertes : ventes aux
/// points de vente, livraison en stock, une caisse close avec un ecart, une
/// chambre faite, une panne reglee et une panne urgente.
///
/// Tout passe par les depots, donc par la file d'envoi. Les ventes et les
/// encaissements tombent sur la journee en cours : un depot ne date pas une
/// saisie dans le passe.
Future<String> _complement(
  AtriumDatabase db, {
  required String agentId,
}) async {
  final deja = await db
      .customSelect(
        "SELECT 1 FROM folio_items WHERE label = 'Bissap maison' "
        'AND deleted_at IS NULL LIMIT 1',
      )
      .getSingleOrNull();
  if (deja != null) {
    return 'Le complément pour les rapports est déjà là.';
  }

  final faits = <String>[];
  final caisse = CashRepository(db);
  await caisse.open(userId: agentId, openingFloat: 50000, by: agentId);

  // Le stock d'abord : les ventes d'articles relies a un produit l'entament.
  try {
    final produits = await (db.select(db.products)
          ..where((p) => p.deletedAt.isNull() & p.isActive.equals(true))
          ..orderBy([(p) => OrderingTerm(expression: p.label)])
          ..limit(5))
        .get();
    final magasins = await (db.select(db.stockLocations)
          ..where((l) => l.deletedAt.isNull())
          ..orderBy([(l) => OrderingTerm(expression: l.sortOrder)]))
        .get();
    if (produits.isNotEmpty && magasins.isNotEmpty) {
      final central = magasins.firstWhere(
        (l) => l.isCentral,
        orElse: () => magasins.first,
      );
      for (final p in produits) {
        await StockRepository(db).receive(
          placeId: central.id,
          productId: p.id,
          quantity: 24,
          unitCost: p.purchasePrice,
          reason: 'Livraison fournisseur',
          by: agentId,
        );
      }
      faits.add('${produits.length} livraisons en stock');
    }
  } catch (e) {
    debugPrint('[Donnees de test] stock ecarte : $e');
  }

  // Les ventes au comptoir, reparties sur les points de vente connus.
  final points = await (db.select(db.outlets)
        ..where((o) => o.deletedAt.isNull())
        ..orderBy([(o) => OrderingTerm(expression: o.sortOrder)]))
      .get();
  if (points.isEmpty) {
    faits.add('aucune vente : pas de point de vente sur cette tablette');
  } else {
    final commandes = OrderRepository(db);
    var ventes = 0;
    for (final (rang, lignes, moyen) in _ventes) {
      final point = points[rang % points.length];
      final articles = <(String, int, int, String?)>[];
      for (final (libelle, prix, quantite) in lignes) {
        // L'article de la carte du meme nom, s'il existe : la vente fait
        // alors sortir son produit du stock, et la marge se calcule.
        final article = await db
            .customSelect(
              '''
              SELECT mi.id AS id FROM menu_items mi
                JOIN menu_categories mc ON mc.id = mi.menu_category_id
               WHERE mi.label = ?1 AND mi.deleted_at IS NULL
                 AND (mc.outlet_id IS NULL OR mc.outlet_id = ?2)
               LIMIT 1
              ''',
              variables: [
                Variable.withString(libelle),
                Variable.withString(point.id),
              ],
            )
            .getSingleOrNull();
        articles.add((libelle, prix, quantite, article?.read<String>('id')));
      }
      // Chaque point de vente a son tiroir : on l'ouvre avant d'y vendre.
      await caisse.open(
        userId: agentId,
        openingFloat: 0,
        by: agentId,
        outletId: point.id,
      );
      await commandes.sellWalkIn(
        outlet: point,
        lines: articles,
        method: moyen,
        by: agentId,
      );
      ventes++;
    }
    faits.add('$ventes ventes au comptoir');
  }

  // Une caisse close avec 500 FCFA de moins que prevu, puis une nouvelle
  // ouverte : l'agent peut continuer d'encaisser.
  final session = await caisse.openSessionId(agentId);
  if (session != null) {
    final attendu = (await db
            .customSelect(
              '''
              SELECT s.opening_float + COALESCE((
                SELECT SUM(CASE WHEN p.is_refund = 1 THEN -p.amount
                                ELSE p.amount END)
                  FROM payments p
                 WHERE p.cash_session_id = s.id
                   AND p.method = 'CASH'
                   AND p.deleted_at IS NULL), 0) AS attendu
                FROM cash_sessions s WHERE s.id = ?1
              ''',
              variables: [Variable.withString(session)],
            )
            .getSingle())
        .read<int>('attendu');
    await caisse.close(
      sessionId: session,
      countedAmount: attendu > 500 ? attendu - 500 : attendu,
      by: agentId,
    );
    await caisse.open(userId: agentId, openingFloat: 50000, by: agentId);
    faits.add('une caisse close avec un écart');
  }

  // Une chambre faite : la premiere a faire.
  try {
    final tache = await (db.select(db.housekeepingTasks)
          ..where(
            (t) => t.deletedAt.isNull() & t.status.equalsValue(TaskStatus.PENDING),
          )
          ..limit(1))
        .getSingleOrNull();
    if (tache != null) {
      final menage = HousekeepingRepository(db);
      await menage.start(tache.id, by: agentId);
      await menage.finish(tache.id, by: agentId);
      faits.add('une chambre faite');
    }
  } catch (e) {
    debugPrint('[Donnees de test] menage ecarte : $e');
  }

  // Une panne reglee, pour les delais ; une panne urgente, pour l'alerte.
  try {
    final pannes = MaintenanceRepository(db);
    final ampoule = await pannes.create(
      title: 'Ampoule grillée dans le couloir',
      location: 'Couloir du 2e étage',
      by: agentId,
    );
    await pannes.take(ampoule, by: agentId);
    await pannes.resolve(
      ampoule,
      resolution: 'Ampoule remplacée',
      by: agentId,
    );
    final chambre = (await db
            .customSelect(
              "SELECT id FROM rooms WHERE number = '105' "
              'AND deleted_at IS NULL LIMIT 1',
            )
            .getSingleOrNull())
        ?.read<String>('id');
    await pannes.create(
      title: "Fuite d'eau dans la salle de bain",
      description: "L'eau coule sous la porte, le client attend à la réception.",
      roomId: chambre,
      location: chambre == null ? 'Chambre 105' : null,
      priority: Priority.URGENT,
      blocksRoom: chambre != null,
      by: agentId,
    );
    faits.add('deux pannes, dont une urgente');
  } catch (e) {
    debugPrint('[Donnees de test] pannes ecartees : $e');
  }

  return 'Complément : ${faits.join(', ')}.';
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
