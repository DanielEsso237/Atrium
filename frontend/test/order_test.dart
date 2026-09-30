/// Porter une consommation depuis un point de vente.
///
/// Le parcours que le patron a decrit : Jean consomme au restaurant, puis a
/// la boite de nuit, et tout finit sur sa facture de sejour. Ce qui compte
/// ici, c'est que l'argent atterrisse sur la **bonne** ardoise et qu'on sache
/// d'ou il vient.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late OrderRepository commandes;
  late ReservationRepository reservations;

  const hotel = '01920000-0000-7000-8000-000000000001';
  const clientId = '01920000-0000-7000-8000-00000000f001';
  const barId = '01920000-0000-7000-8000-00000000f101';
  const boutiqueId = '01920000-0000-7000-8000-00000000f102';

  // La carte : une categorie commune, une propre au bar, une propre a la
  // boutique.
  const catCommuneId = '01920000-0000-7000-8000-00000000f201';
  const catBarId = '01920000-0000-7000-8000-00000000f202';
  const catBoutiqueId = '01920000-0000-7000-8000-00000000f203';
  const pouletId = '01920000-0000-7000-8000-00000000f301';
  const biereId = '01920000-0000-7000-8000-00000000f302';
  const teeShirtId = '01920000-0000-7000-8000-00000000f303';
  const saumonId = '01920000-0000-7000-8000-00000000f304';

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    commandes = OrderRepository(db);
    reservations = ReservationRepository(db);

    final now = DateTime.now().toUtc();
    await db.into(db.guests).insert(
          GuestsCompanion.insert(
            id: clientId,
            createdAt: now,
            updatedAt: now,
            hotelId: hotel,
            code: 'CLI-00001',
            firstName: 'Jean',
            lastName: 'Bamba',
          ),
        );

    for (final (id, code, label, chambre, rang) in [
      (barId, 'BAR', 'Bar', true, 1),
      (boutiqueId, 'BOUTIQUE', 'Boutique', false, 2),
    ]) {
      await db.into(db.outlets).insert(
            OutletsCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotel,
              code: code,
              label: label,
              allowsRoomCharge: Value(chambre),
              sortOrder: Value(rang),
            ),
          );
    }
  });

  tearDown(() => db.close());

  Future<OutletRow> pointDeVente(String id) =>
      (db.select(db.outlets)..where((o) => o.id.equals(id))).getSingle();

  /// Installe un client en chambre, ardoise ouverte.
  Future<ChargeableRoom> installer() async {
    final chambre = await db
        .customSelect('SELECT id FROM rooms ORDER BY number LIMIT 1')
        .getSingle();
    final roomId = chambre.read<String>('id');

    await reservations.create(
      guestId: clientId,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime.utc(2026, 9, 24),
      departure: DateTime.utc(2026, 9, 26),
      nightlyRate: 25000,
      roomId: roomId,
    );
    final ligne = await db
        .customSelect('SELECT id FROM reservation_rooms LIMIT 1')
        .getSingle();
    await reservations.checkIn(lineId: ligne.read<String>('id'));

    final dispo = await commandes.watchChargeableRooms().first;
    return dispo.single;
  }

  /// Une carte minimale, comme la descente la deposerait dans la base.
  Future<void> garnirLaCarte() async {
    final now = DateTime.now().toUtc();

    for (final (id, outlet, label, rang) in [
      (catCommuneId, null, 'Plats', 1),
      (catBarId, barId, 'Boissons', 2),
      (catBoutiqueId, boutiqueId, 'Souvenirs', 3),
    ]) {
      await db.into(db.menuCategories).insert(
            MenuCategoriesCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotel,
              label: label,
              outletId: Value(outlet),
              sortOrder: Value(rang),
            ),
          );
    }

    for (final (id, code, label, categorie, prix, dispo) in [
      (pouletId, 'PLAT1', 'Poulet DG', catCommuneId, 5000, true),
      (biereId, 'BOIS1', 'Biere', catBarId, 2000, true),
      (teeShirtId, 'SOUV1', 'Tee-shirt', catBoutiqueId, 5000, true),
      (saumonId, 'PLAT2', 'Saumon', catCommuneId, 8000, false),
    ]) {
      await db.into(db.menuItems).insert(
            MenuItemsCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotel,
              code: code,
              label: label,
              menuCategoryId: categorie,
              price: Value(prix),
              isAvailable: Value(dispo),
            ),
          );
    }
  }

  test('seules les chambres occupees avec ardoise sont proposees', () async {
    expect(await commandes.watchChargeableRooms().first, isEmpty);

    final chambre = await installer();

    expect(chambre.guestName, 'Jean Bamba');
    expect(chambre.roomNumber, isNotEmpty);
    // Le solde est affiche avant de valider : c'est ce qui rendra le seuil
    // comprehensible plutot qu'un refus sec.
    expect(chambre.balance, greaterThan(0));
  });

  test('une consommation au bar arrive sur la bonne ardoise', () async {
    final chambre = await installer();
    final avant = chambre.balance;

    await commandes.charge(
      outlet: await pointDeVente(barId),
      folioId: chambre.folioId,
      label: 'Biere',
      unitPrice: 2000,
      quantity: 2,
    );

    final apres = await commandes.watchChargeableRooms().first;
    expect(apres.single.balance, avant + 4000);
  });

  test('la ligne garde le point de vente d ou elle vient', () async {
    // Ce qui permettra de ventiler le chiffre d'affaires par point de vente
    // sans ajouter de colonne.
    final chambre = await installer();
    await commandes.charge(
      outlet: await pointDeVente(barId),
      folioId: chambre.folioId,
      label: 'Biere',
      unitPrice: 2000,
    );

    final ligne = await db
        .customSelect(
          "SELECT source_table AS t, source_id AS i, category AS c "
          "FROM folio_items WHERE label = 'Biere'",
        )
        .getSingle();
    expect(ligne.read<String>('t'), 'outlets');
    expect(ligne.read<String>('i'), barId);
    expect(ligne.read<String>('c'), 'FNB');
  });

  test('un point de vente qui ne facture pas la chambre est refuse', () async {
    final chambre = await installer();

    await expectLater(
      commandes.charge(
        outlet: await pointDeVente(boutiqueId),
        folioId: chambre.folioId,
        label: 'Tee-shirt',
        unitPrice: 5000,
      ),
      throwsA(isA<StateError>()),
    );

    final n = await db
        .customSelect("SELECT COUNT(*) AS n FROM folio_items WHERE label = 'Tee-shirt'")
        .getSingle();
    expect(n.read<int>('n'), 0);
  });

  test('un montant nul ou un libelle vide est refuse', () async {
    final chambre = await installer();
    final bar = await pointDeVente(barId);

    await expectLater(
      commandes.charge(
        outlet: bar,
        folioId: chambre.folioId,
        label: '   ',
        unitPrice: 2000,
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      commandes.charge(
        outlet: bar,
        folioId: chambre.folioId,
        label: 'Biere',
        unitPrice: 0,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('la consommation part dans la file d envoi', () async {
    final chambre = await installer();
    await commandes.charge(
      outlet: await pointDeVente(barId),
      folioId: chambre.folioId,
      label: 'Biere',
      unitPrice: 2000,
    );

    final r = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM outbox_entries "
          "WHERE entity_table = 'folio_items'",
        )
        .getSingle();
    // La nuitee du check-in, plus la biere.
    expect(r.read<int>('n'), greaterThanOrEqualTo(2));
  });

  test('les onglets suivent l ordre du referentiel', () async {
    final onglets = await commandes.watchOutlets().first;
    expect(onglets.map((o) => o.code), ['BAR', 'BOUTIQUE']);
  });

  test('un point de vente desactive disparait des onglets', () async {
    await db.customStatement(
      "UPDATE outlets SET is_active = 0 WHERE id = ?",
      [boutiqueId],
    );

    final onglets = await commandes.watchOutlets().first;
    expect(onglets.map((o) => o.code), ['BAR']);
  });

  // --- La carte du restaurant -------------------------------------------------

  group('la carte', () {
    test('un point de vente ne voit que ses categories et les communes',
        () async {
      await garnirLaCarte();

      final carteBar = await commandes.watchMenu(barId).first;
      final libelles = carteBar.map((e) => e.label).toList();

      // Categorie commune + categorie du bar, pas celle de la boutique.
      expect(libelles, containsAll(['Poulet DG', 'Biere']));
      expect(libelles, isNot(contains('Tee-shirt')));

      final carteBoutique = await commandes.watchMenu(boutiqueId).first;
      final libellesBoutique = carteBoutique.map((e) => e.label).toList();
      expect(libellesBoutique, containsAll(['Poulet DG', 'Tee-shirt']));
      expect(libellesBoutique, isNot(contains('Biere')));
    });

    test('un article en rupture reste dans la carte, marque indisponible',
        () async {
      await garnirLaCarte();

      final carte = await commandes.watchMenu(barId).first;
      final saumon = carte.firstWhere((e) => e.label == 'Saumon');

      expect(saumon.isAvailable, isFalse);
      expect(carte.firstWhere((e) => e.label == 'Poulet DG').isAvailable,
          isTrue);
    });

    test('choisir un article porte le bon prix sur l ardoise', () async {
      await garnirLaCarte();
      final chambre = await installer();
      final avant = chambre.balance;

      // Ce que fait l'ecran au tap : l'article remplit libelle et prix, puis
      // la fenetre rend (libelle, prix, quantite) a `charge`.
      final carte = await commandes.watchMenu(barId).first;
      final poulet = carte.firstWhere((e) => e.label == 'Poulet DG');
      expect(poulet.price, 5000);

      await commandes.charge(
        outlet: await pointDeVente(barId),
        folioId: chambre.folioId,
        label: poulet.label,
        unitPrice: poulet.price,
      );

      final ligne = await db
          .customSelect(
            "SELECT unit_price AS p, amount AS a, quantity AS q "
            "FROM folio_items WHERE label = 'Poulet DG'",
          )
          .getSingle();
      expect(ligne.read<int>('p'), 5000);
      expect(ligne.read<int>('a'), 5000);
      expect(ligne.read<int>('q'), 1);

      final apres = await commandes.watchChargeableRooms().first;
      expect(apres.single.balance, avant + 5000);
    });

    test('la saisie libre fonctionne toujours', () async {
      // Meme parcours, sans passer par la carte : un plat du jour ou un
      // service hors carte doit rester possible. Protege l'ancien
      // comportement contre une regression.
      await garnirLaCarte();
      final chambre = await installer();
      final avant = chambre.balance;

      await commandes.charge(
        outlet: await pointDeVente(barId),
        folioId: chambre.folioId,
        label: 'Plat du jour',
        unitPrice: 5000,
      );

      final ligne = await db
          .customSelect(
            "SELECT unit_price AS p, amount AS a FROM folio_items "
            "WHERE label = 'Plat du jour'",
          )
          .getSingle();
      expect(ligne.read<int>('p'), 5000);
      expect(ligne.read<int>('a'), 5000);

      final apres = await commandes.watchChargeableRooms().first;
      expect(apres.single.balance, avant + 5000);
    });
  });
}