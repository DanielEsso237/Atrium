/// La commande en chambre sur la tablette (F2.6, reunion du 18 octobre).
///
/// Le client appelle la reception depuis la 101 ; elle commande deux bieres
/// au bar, qui les prend en charge et les monte. Ce qui compte : chaque geste
/// s'ecrit ici et part dans la file vers la bonne route ; ce que le serveur
/// refuserait est refuse ici d'abord (sinon la file se bloque) ; la livraison
/// pose sur l'ardoise les memes lignes que le serveur ; et le client ne part
/// pas avec un plateau en route.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/descente.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/data/repositories/room_order_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

const _hotel = FolioRepository.defaultHotelId;
const _biere = '01920000-0000-7000-8000-0000000c0001';
const _jus = '01920000-0000-7000-8000-0000000c0002';
const _plat = '01920000-0000-7000-8000-0000000c0003';

/// Un serveur qui accepte tout, rend un numero de commande et note les
/// routes appelees.
class _ServeurQuiNote extends ApiClient {
  _ServeurQuiNote()
    : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final routes = <String>[];
  final corps = <Object?>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    routes.add(path);
    corps.add(body);
    return {'number': 'ORD-000042'};
  }
}

void main() {
  late AtriumDatabase db;
  late OutletRow bar;
  late RoomOrderRepository commandes;
  late String client;
  late String ardoise;

  Future<void> article(
    String id,
    String categorie,
    String libelle,
    int prix, {
    bool disponible = true,
  }) => db
      .into(db.menuItems)
      .insert(
        MenuItemsCompanion.insert(
          id: id,
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
          hotelId: _hotel,
          code: libelle.substring(0, 3).toUpperCase(),
          label: libelle,
          menuCategoryId: categorie,
          price: Value(prix),
          taxRate: const Value(18),
          isAvailable: Value(disponible),
        ),
      );

  Future<void> categorie(String id, String? outletId) => db
      .into(db.menuCategories)
      .insert(
        MenuCategoriesCompanion.insert(
          id: id,
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
          hotelId: _hotel,
          label: 'Carte $id',
          outletId: Value(outletId),
        ),
      );

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    final restaurant = await OutletRepository(
      db,
    ).create(code: 'RESTO2', label: 'Grill');
    await categorie('01920000-0000-7000-8000-0000000c0101', bar.id);
    await categorie('01920000-0000-7000-8000-0000000c0102', restaurant.id);
    await article(
      _biere,
      '01920000-0000-7000-8000-0000000c0101',
      'Bière',
      1500,
    );
    await article(
      _jus,
      '01920000-0000-7000-8000-0000000c0101',
      'Jus',
      1000,
      disponible: false,
    );
    await article(
      _plat,
      '01920000-0000-7000-8000-0000000c0102',
      'Brochettes',
      4000,
    );
    commandes = RoomOrderRepository(db);

    // Awa Diallo en 101.
    client = (await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo')).id;
    final chambre = await (db.select(
      db.rooms,
    )..where((r) => r.number.equals('101'))).getSingle();
    final reservations = ReservationRepository(db);
    final dossier = await reservations.create(
      guestId: client,
      roomTypeId: chambre.roomTypeId,
      arrival: DateTime.now().subtract(const Duration(days: 1)),
      departure: DateTime.now().add(const Duration(days: 2)),
      nightlyRate: 25000,
      roomId: chambre.id,
    );
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((l) => l.reservationId.equals(dossier))).getSingle();
    await reservations.checkIn(lineId: ligne.id);
    ardoise = (await (db.select(
      db.folios,
    )..where((f) => f.reservationRoomId.equals(ligne.id))).getSingle()).id;
  });

  tearDown(() => db.close());

  Future<void> ouvrirLeBar() => CashRepository(
    db,
  ).open(userId: utilisateurDemo, openingFloat: 0, outletId: bar.id);

  Future<void> viderLaFile() => db.delete(db.outboxEntries).go();

  Future<List<Map<String, dynamic>>> file() async => [
    for (final e
        in await (db.select(db.outboxEntries)
              ..where((o) => o.entityTable.equals('orders'))
              ..orderBy([(o) => OrderingTerm.asc(o.id)]))
            .get())
      jsonDecode(e.payload) as Map<String, dynamic>,
  ];

  Future<String> deuxBieres({String? overrideBy}) => commandes.commander(
    outletId: bar.id,
    folioId: ardoise,
    lignes: [(menuItemId: _biere, quantite: 2, notes: 'bien fraîches')],
    by: utilisateurDemo,
    overrideBy: overrideBy,
  );

  Future<OrderRow> commande(String id) =>
      (db.select(db.orders)..where((o) => o.id.equals(id))).getSingle();

  Future<FolioRow> folio() =>
      (db.select(db.folios)..where((f) => f.id.equals(ardoise))).getSingle();

  test('la reception commande : la commande, ses lignes, et une entree de '
      'file vers POST /room-orders', () async {
    await ouvrirLeBar();
    await viderLaFile();
    final avant = (await folio()).balance;

    final id = await deuxBieres();

    final c = await commande(id);
    expect(c.type, OrderType.ROOM_SERVICE);
    expect(c.status, OrderStatus.SENT);
    expect(c.folioId, ardoise);
    expect(c.guestId, client);
    expect(c.orderedBy, utilisateurDemo);
    expect(c.total, 3000);
    // Les prix sont TTC : la taxe en est une part, pas un supplement.
    expect(c.taxTotal, 3000 * 18 ~/ 100);
    final lignes = await (db.select(
      db.orderItems,
    )..where((i) => i.orderId.equals(id))).get();
    expect(lignes.single.labelSnapshot, 'Bière');
    expect(lignes.single.unitPrice, 1500);
    expect(lignes.single.amount, 3000);

    // Rien sur l'ardoise tant que ce n'est pas livre.
    expect((await folio()).balance, avant);

    final p = (await file()).single;
    expect(p['action'], 'CREATE');
    expect(p['outlet_id'], bar.id);
    expect(p['folio_id'], ardoise);
    final items = (p['items'] as List).cast<Map<String, dynamic>>();
    expect(items.single['id'], lignes.single.id);
    expect(items.single['menu_item_id'], _biere);
    expect(items.single['quantity'], 2);
    expect(items.single['notes'], 'bien fraîches');
  });

  group('les refus du serveur, ici d\'abord, sans rien ecrire', () {
    Future<void> refuse(Future<void> Function() geste, String message) async {
      await viderLaFile();
      await expectLater(
        geste(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(message),
          ),
        ),
      );
      expect(await file(), isEmpty);
      expect(
        await (db.select(
          db.orders,
        )..where((o) => o.type.equalsValue(OrderType.ROOM_SERVICE))).get(),
        isEmpty,
      );
    }

    test('le bar est ferme : aucun tiroir ouvert sur lui', () async {
      await refuse(deuxBieres, 'fermé');
    });

    test('un point de vente qui ne porte pas sur la chambre', () async {
      await ouvrirLeBar();
      await (db.update(db.outlets)..where((o) => o.id.equals(bar.id))).write(
        const OutletsCompanion(allowsRoomCharge: Value(false)),
      );
      await refuse(deuxBieres, 'ne porte pas sur la chambre');
    });

    test('un article d\'une autre carte, ou plus disponible', () async {
      await ouvrirLeBar();
      await refuse(
        () => commandes.commander(
          outletId: bar.id,
          folioId: ardoise,
          lignes: [(menuItemId: _plat, quantite: 1, notes: null)],
          by: utilisateurDemo,
        ),
        'absent de la carte',
      );
      await refuse(
        () => commandes.commander(
          outletId: bar.id,
          folioId: ardoise,
          lignes: [(menuItemId: _jus, quantite: 1, notes: null)],
          by: utilisateurDemo,
        ),
        'Plus disponible : Jus',
      );
    });

    test('une ardoise close : le client est parti', () async {
      await ouvrirLeBar();
      await (db.update(db.folios)..where((f) => f.id.equals(ardoise))).write(
        const FoliosCompanion(status: Value(FolioStatus.CLOSED)),
      );
      await refuse(deuxBieres, 'le client est parti');
    });
  });

  test('le plafond compte les commandes deja en route', () async {
    await ouvrirLeBar();
    final dejaDu = (await folio()).balance;
    // Le client peut encore devoir 4 000 : une commande de 3 000 passe,
    // une seconde ne passe plus, alors que l'ardoise n'a encore rien.
    await (db.update(db.guests)..where((g) => g.id.equals(client))).write(
      GuestsCompanion(creditLimit: Value(dejaDu + 4000)),
    );
    await deuxBieres();
    await expectLater(deuxBieres(), throwsA(isA<StateError>()));
    // Un responsable l'autorise : elle passe, et son nom part avec.
    final id = await deuxBieres(overrideBy: utilisateurDemo);
    expect((await commande(id)).overrideBy, utilisateurDemo);
    expect((await file()).last['override_by'], utilisateurDemo);
  });

  test('le bar prend en charge, puis livre : les lignes passent sur '
      'l\'ardoise au nom du bar', () async {
    await ouvrirLeBar();
    final id = await deuxBieres();
    final avant = (await folio()).balance;

    await commandes.prendreEnCharge(orderId: id, by: utilisateurDemo);
    expect((await commande(id)).status, OrderStatus.IN_PREP);
    expect((await commande(id)).takenBy, utilisateurDemo);

    await commandes.livrer(orderId: id, by: utilisateurDemo);
    final c = await commande(id);
    expect(c.status, OrderStatus.SERVED);
    expect(c.deliveredBy, utilisateurDemo);

    // La ligne d'ardoise prend l'id de la ligne de commande, comme sur le
    // serveur : la descente la recouvrira sans la doubler.
    final ligneCommande = await (db.select(
      db.orderItems,
    )..where((i) => i.orderId.equals(id))).getSingle();
    final surArdoise = await (db.select(
      db.folioItems,
    )..where((i) => i.id.equals(ligneCommande.id))).getSingle();
    expect(surArdoise.folioId, ardoise);
    expect(surArdoise.category, ChargeCategory.FNB);
    expect(surArdoise.amount, 3000);
    expect(surArdoise.sourceTable, 'outlets');
    expect(surArdoise.sourceId, bar.id);
    expect(surArdoise.businessDate, c.businessDate);
    expect((await folio()).balance, avant + 3000);

    // Deux gestes, deux entrees ; la livraison n'enfile pas de charge : le
    // serveur ecrit lui-meme les lignes a la livraison.
    expect(
      [for (final p in await file()) p['action']],
      ['CREATE', 'ACCEPT', 'DELIVER'],
    );
    final charges = await (db.select(
      db.outboxEntries,
    )..where((o) => o.entityTable.equals('folio_items'))).get();
    expect(charges.where((e) => e.entityId == ligneCommande.id), isEmpty);

    // Livrer deux fois ne double rien.
    await commandes.livrer(orderId: id, by: utilisateurDemo);
    expect((await folio()).balance, avant + 3000);
  });

  test('le client paie a la livraison : sur l\'ardoise et solde, le total '
      'dans le tiroir de celui qui livre', () async {
    await ouvrirLeBar();
    final id = await deuxBieres();
    final avant = await folio();
    final tiroir = await CashRepository(
      db,
    ).openSessionId(utilisateurDemo, outletId: bar.id);

    await commandes.livrer(
      orderId: id,
      by: utilisateurDemo,
      payeMaintenant: PaymentMethod.MOBILE_MONEY,
    );

    final apres = await folio();
    expect(apres.chargesTotal, avant.chargesTotal + 3000);
    expect(apres.paymentsTotal, avant.paymentsTotal + 3000);
    expect(apres.balance, avant.balance);
    final paiement = await (db.select(
      db.payments,
    )..where((x) => x.folioId.equals(ardoise))).getSingle();
    expect(paiement.amount, 3000);
    expect(paiement.method, PaymentMethod.MOBILE_MONEY);
    expect(paiement.cashSessionId, tiroir);
    // Il remonte avec la livraison, pas a part.
    final p = (await file()).last;
    expect(p['action'], 'DELIVER');
    expect(p['payment'], {
      'id': paiement.id,
      'method': 'MOBILE_MONEY',
      'amount': 3000,
    });
    final apart = await (db.select(
      db.outboxEntries,
    )..where((o) => o.entityTable.equals('payments'))).get();
    expect(apart, isEmpty);
  });

  test(
    'livrer exige le tiroir de celui qui livre, sur ce point de vente',
    () async {
      await ouvrirLeBar();
      final id = await deuxBieres();
      final tiroir = await CashRepository(
        db,
      ).openSessionId(utilisateurDemo, outletId: bar.id);
      await (db.update(
        db.cashSessions,
      )..where((s) => s.id.equals(tiroir!))).write(
        const CashSessionsCompanion(status: Value(CashSessionStatus.CLOSED)),
      );

      await expectLater(
        commandes.livrer(orderId: id, by: utilisateurDemo),
        throwsA(
          isA<CaisseFermee>()
              .having(
                (e) => e.message,
                'message',
                contains('Ouvrez la caisse de ${bar.label}'),
              )
              .having((e) => e.libelle, 'libelle', 'de ${bar.label}'),
        ),
      );
      expect((await commande(id)).status, OrderStatus.SENT);
    },
  );

  test('un agent rattache a un autre point de vente ne touche pas a la '
      'commande', () async {
    await ouvrirLeBar();
    final id = await deuxBieres();
    final autre = await OutletRepository(
      db,
    ).create(code: 'PISC', label: 'Piscine');
    await db
        .into(db.userOutlets)
        .insert(
          UserOutletsCompanion.insert(
            userId: utilisateurDemo,
            outletId: autre.id,
          ),
        );
    await expectLater(
      commandes.prendreEnCharge(orderId: id, by: utilisateurDemo),
      throwsA(isA<StateError>()),
    );
  });

  test('annuler : avec un motif, jamais une commande livree', () async {
    await ouvrirLeBar();
    final id = await deuxBieres();
    await expectLater(
      commandes.annuler(orderId: id, motif: '  ', by: utilisateurDemo),
      throwsA(isA<StateError>()),
    );
    await commandes.annuler(
      orderId: id,
      motif: 'Le client s’est ravisé',
      by: utilisateurDemo,
    );
    final c = await commande(id);
    expect(c.status, OrderStatus.CANCELLED);
    expect(c.cancelReason, 'Le client s’est ravisé');
    expect((await file()).last, {
      'action': 'CANCEL',
      'id': id,
      'reason': 'Le client s’est ravisé',
    });

    final livree = await deuxBieres();
    await commandes.livrer(orderId: livree, by: utilisateurDemo);
    await expectLater(
      commandes.annuler(
        orderId: livree,
        motif: 'Trop tard',
        by: utilisateurDemo,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('déjà livrée'),
        ),
      ),
    );
  });

  test('le client ne part pas avec un plateau en route', () async {
    await ouvrirLeBar();
    final id = await deuxBieres();
    final ligne = (await (db.select(
      db.folios,
    )..where((f) => f.id.equals(ardoise))).getSingle()).reservationRoomId!;
    final reservations = ReservationRepository(db);

    await expectLater(
      reservations.checkOut(lineId: ligne),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('le départ'),
        ),
      ),
    );
    await expectLater(
      reservations.annulerArrivee(
        lineId: ligne,
        approuvePar: utilisateurDemo,
        motif: 'Erreur',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('pas encore livrée'),
        ),
      ),
    );

    // Livree, plus rien ne retient le client.
    await commandes.livrer(orderId: id, by: utilisateurDemo);
    await RoomOrderRepository.verifierAucuneEnRoute(db, ardoise, 'le départ');
  });

  test('la file part vers les routes du contrat, et le numero du serveur '
      'remplace le numero provisoire', () async {
    await ouvrirLeBar();
    await viderLaFile();
    final id = await deuxBieres();
    await commandes.prendreEnCharge(orderId: id, by: utilisateurDemo);
    await commandes.livrer(orderId: id, by: utilisateurDemo);
    final annulee = await deuxBieres();
    await commandes.annuler(
      orderId: annulee,
      motif: 'Erreur',
      by: utilisateurDemo,
    );
    // Les autres ecritures (caisse, stock) ne nous regardent pas ici.
    await (db.delete(
      db.outboxEntries,
    )..where((o) => o.entityTable.equals('orders').not())).go();

    final serveur = _ServeurQuiNote();
    await OutboxSender(db: db, api: serveur).drain();

    expect(serveur.routes, [
      '/room-orders',
      '/room-orders/$id/accept',
      '/room-orders/$id/deliver',
      '/room-orders',
      '/room-orders/$annulee/cancel',
    ]);
    // Livree sur l'ardoise : pas de paiement dans le corps.
    expect(serveur.corps[2], <String, Object?>{});
    final creation = serveur.corps.first as Map;
    expect(creation.containsKey('override_by'), isFalse);
    expect(serveur.corps.last, {'reason': 'Erreur'});
    expect((await commande(id)).number, 'ORD-000042');
    expect((await commande(id)).syncState, SyncState.synced);
  });

  group('la descente', () {
    RemoteRoomOrder duServeur(String id, String statut, {String? folioId}) =>
        RemoteRoomOrder(
          id: id,
          number: 'ORD-000007',
          outletId: bar.id,
          status: statut,
          total: 1500,
          taxTotal: 270,
          folioId: folioId ?? ardoise,
          guestId: client,
          businessDate: '2026-10-18',
          items: [
            RemoteRoomOrderLine(
              id: id.replaceRange(30, 36, 'aaaaaa'),
              label: 'Bière',
              quantity: 1,
              unitPrice: 1500,
              taxRate: 18,
              amount: 1500,
              status: statut,
              menuItemId: _biere,
            ),
          ],
        );

    Future<void> descendre(List<RemoteRoomOrder> c) async {
      final api = FakeCatalogApi(roomOrders: c);
      await Descente(db, api, SyncRepository(db, api)).pull();
    }

    test('le bar recoit la commande, et l\'en-tete de l\'ardoise qu\'il ne '
        'lit pas', () async {
      const id = '01920000-0000-7000-8000-0000000c0201';
      const ailleurs = '01920000-0000-7000-8000-0000000c0299';
      await descendre([duServeur(id, 'SENT', folioId: ailleurs)]);

      final c = await commande(id);
      expect(c.status, OrderStatus.SENT);
      expect(c.number, 'ORD-000007');
      final enRoute = await commandes.watchEnRoutePour(bar.id).first;
      expect(enRoute.map((e) => e.id), [id]);
      expect(enRoute.single.lignes.single.libelle, 'Bière');
      // L'ardoise inconnue a son en-tete : la livraison y posera ses lignes.
      final entete = await (db.select(
        db.folios,
      )..where((f) => f.id.equals(ailleurs))).getSingle();
      expect(entete.status, FolioStatus.OPEN);
    });

    test(
      'une commande avec un geste en attente ici n\'est pas ecrasee',
      () async {
        await ouvrirLeBar();
        final id = await deuxBieres();
        await commandes.prendreEnCharge(orderId: id, by: utilisateurDemo);

        // Le serveur ne sait pas encore la prise en charge.
        await descendre([duServeur(id, 'SENT')]);

        expect((await commande(id)).status, OrderStatus.IN_PREP);
        expect((await commande(id)).total, 3000);
      },
    );
  });
}
