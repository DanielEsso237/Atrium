/// Les ardoises du comptoir, sur la tablette et hors ligne.
///
/// Decision du 12 octobre : au bar, un client prend une biere, puis un jus,
/// et demande sa note en partant. Ce qui compte : chaque geste s'ecrit ici et
/// part dans la file vers la bonne route ; ce que le serveur refuserait est
/// refuse ici d'abord ; et le plafond du client compte son ardoise du bar.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/outlet_tab_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

/// Un serveur qui accepte tout et note les routes appelees.
class _ServeurQuiNote extends ApiClient {
  _ServeurQuiNote()
    : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final routes = <String>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    routes.add(path);
    return {};
  }

  final patchs = <(String, Object?)>[];

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    patchs.add((path, body));
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late OutletRow bar;
  late OutletTabRepository ardoises;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    ardoises = OutletTabRepository(db);
  });

  tearDown(() => db.close());

  Future<void> ouvrirCaisse() => CashRepository(
    db,
  ).open(userId: utilisateurDemo, openingFloat: 0, outletId: bar.id);

  Future<void> servir(String ardoise, int prix, [String libelle = 'Biere']) =>
      ardoises.servir(
        pointDeVente: bar,
        ardoiseId: ardoise,
        libelle: libelle,
        prixUnitaire: prix,
        by: utilisateurDemo,
        categorie: ChargeCategory.FNB,
      );

  Future<FolioRow> folio(String id) =>
      (db.select(db.folios)..where((f) => f.id.equals(id))).getSingle();

  Future<List<Map>> file() async => [
    for (final e in await (db.select(db.outboxEntries)
          ..where((o) => o.entityTable.equals('folios')))
        .get())
      jsonDecode(e.payload) as Map,
  ];

  /// Awa Diallo en 101, plafond [plafond] ; rend (client, ardoise du sejour).
  Future<(String, String)> awaEn101({int plafond = 0}) async {
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    await (db.update(db.guests)..where((g) => g.id.equals(client.id))).write(
      GuestsCompanion(creditLimit: Value(plafond)),
    );
    final chambre = await (db.select(
      db.rooms,
    )..where((r) => r.number.equals('101'))).getSingle();
    final reservations = ReservationRepository(db);
    final dossier = await reservations.create(
      guestId: client.id,
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
    final ardoise = await (db.select(
      db.folios,
    )..where((f) => f.reservationRoomId.equals(ligne.id))).getSingle();
    return (client.id, ardoise.id);
  }

  test('sans caisse ouverte, pas d\'ardoise', () async {
    expect(
      () => ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo),
      throwsStateError,
    );
  });

  test('les passages se numerotent, et l\'ardoise part dans la file', () async {
    await ouvrirCaisse();

    final premiere = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
    final seconde = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);

    expect((await folio(premiere)).tabNumber, 1);
    expect((await folio(seconde)).tabNumber, 2);
    expect((await folio(seconde)).outletId, bar.id);
    final liste = await ardoises.watchArdoises(bar.id).first;
    expect(liste.map((a) => a.titre), containsAll(['Client divers n°1', 'Client divers n°2']));
    expect((await file()).where((p) => p['action'] == 'TAB_OPEN'), hasLength(2));
  });

  test('une biere, un jus, puis la note : payee et close', () async {
    await ouvrirCaisse();
    final id = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
    await servir(id, 1500);
    await servir(id, 800, 'Jus');

    var a = (await ardoises.watchArdoises(bar.id).first).single;
    expect(a.etat, EtatArdoise.aPayer);
    expect(a.reste, 2300);

    await ardoises.payer(
      pointDeVente: bar,
      ardoiseId: id,
      moyen: PaymentMethod.CASH,
      by: utilisateurDemo,
    );

    a = (await ardoises.watchArdoises(bar.id).first).single;
    expect(a.etat, EtatArdoise.payee);
    expect(a.reste, 0);
    final reglement = (await file()).singleWhere((p) => p['action'] == 'TAB_SETTLE');
    expect((reglement['payment'] as Map)['amount'], 2300);
    // Close : on n'y sert plus.
    expect(() => servir(id, 500), throwsStateError);
  });

  test('portee a la chambre, les lignes gardent leur point de vente', () async {
    final (client, chambre) = await awaEn101();
    await ouvrirCaisse();
    final id = await ardoises.ouvrir(
      pointDeVente: bar,
      by: utilisateurDemo,
      guestId: client,
    );
    await servir(id, 1500);
    await servir(id, 1000, 'Jus');

    await ardoises.porterALaChambre(
      pointDeVente: bar,
      ardoiseId: id,
      ardoiseChambreId: chambre,
    );

    final a = (await ardoises.watchArdoises(bar.id).first).single;
    expect(a.etat, EtatArdoise.enChambre);
    expect(a.titre, '101 · Awa Diallo');
    final lignes = await (db.select(
      db.folioItems,
    )..where((i) => i.folioId.equals(chambre))).get();
    final duBar = lignes.where((i) => i.sourceId == bar.id);
    expect(duBar.map((i) => i.label).toSet(), {'Biere', 'Jus'});
    expect((await folio(chambre)).balance, greaterThanOrEqualTo(2500));
    final report = (await file()).singleWhere((p) => p['action'] == 'TAB_TO_ROOM');
    expect(report['room_folio_id'], chambre);
  });

  test('le client loge retrouve son ardoise ouverte au lieu d\'en avoir deux', () async {
    final (client, _) = await awaEn101();
    await ouvrirCaisse();

    final premiere = await ardoises.ouvrir(
      pointDeVente: bar,
      by: utilisateurDemo,
      guestId: client,
    );
    final seconde = await ardoises.ouvrir(
      pointDeVente: bar,
      by: utilisateurDemo,
      guestId: client,
    );

    expect(seconde, premiere);
  });

  test('le plafond compte l\'ardoise du bar avec celle de la chambre', () async {
    final (client, chambre) = await awaEn101();
    // Ce que la chambre doit deja (la nuitee), plus 6 000 de marge.
    final du = (await folio(chambre)).balance;
    await (db.update(db.guests)..where((g) => g.id.equals(client))).write(
      GuestsCompanion(creditLimit: Value(du + 6000)),
    );
    await ouvrirCaisse();
    final id = await ardoises.ouvrir(
      pointDeVente: bar,
      by: utilisateurDemo,
      guestId: client,
    );
    await servir(id, 4000);

    // La chambre + 4 000 au bar + 3 000 : au-dela de la marge de 6 000.
    expect(() => servir(id, 3000, 'Whisky'), throwsStateError);
    // Le seuil exact passe.
    await servir(id, 2000, 'Jus');
  });

  test('parti sans payer : annulee avec motif, plus rien a payer', () async {
    await ouvrirCaisse();
    final id = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
    await servir(id, 1500);

    await ardoises.annuler(
      ardoiseId: id,
      motif: 'Parti sans payer',
      by: utilisateurDemo,
    );

    final a = (await ardoises.watchArdoises(bar.id).first).single;
    expect(a.etat, EtatArdoise.annulee);
    expect(a.reste, 0);
    final ligne = (await ardoises.watchLignes(id).first).single;
    expect(ligne.annulee, isTrue);
    expect((await file()).singleWhere((p) => p['action'] == 'TAB_CANCEL')['reason'],
        'Parti sans payer');
  });

  test('le versement sait combien d\'ardoises restent a payer', () async {
    await ouvrirCaisse();
    final une = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
    final deux = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
    await servir(une, 1500);
    await servir(deux, 6000);
    await ardoises.payer(
      pointDeVente: bar,
      ardoiseId: une,
      moyen: PaymentMethod.CASH,
      by: utilisateurDemo,
    );

    expect(await ardoises.nonPayees(bar.id), (1, 6000));
  });

  test('la file envoie chaque geste a sa route, dans l\'ordre', () async {
    await ouvrirCaisse();
    final id = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
    await servir(id, 1500);
    await ardoises.payer(
      pointDeVente: bar,
      ardoiseId: id,
      moyen: PaymentMethod.CASH,
      by: utilisateurDemo,
    );
    final serveur = _ServeurQuiNote();

    await OutboxSender(db: db, api: serveur).drain();

    expect(
      serveur.routes.where((r) => r.contains(id)).toList(),
      ['/folios/$id/items', '/outlet-tabs/$id/settle'],
    );
    expect(serveur.routes, contains('/outlet-tabs'));
    expect(
      serveur.routes.indexOf('/outlet-tabs'),
      lessThan(serveur.routes.indexOf('/folios/$id/items')),
    );
  });

  group('nommer une ardoise (14 octobre)', () {
    test('le nom remplace « Client divers n°1 », le numero reste', () async {
      await ouvrirCaisse();
      final id = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);

      await ardoises.renommer(ardoiseId: id, nom: '  Table 4 ');

      final f = await folio(id);
      expect(f.tabLabel, 'Table 4');
      expect(f.tabNumber, 1);
      expect(f.syncState, SyncState.pending);
      final a = (await ardoises.watchArdoises(bar.id).first).single;
      expect(a.titre, 'Table 4');
      expect(a.numeroSousLeNom, 'Client divers n°1');
      expect(
        (await file()).where((p) => p['action'] == 'TAB_RENAME').single['label'],
        'Table 4',
      );
    });

    test('un nom vide remet le nom par defaut', () async {
      await ouvrirCaisse();
      final id = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
      await ardoises.renommer(ardoiseId: id, nom: 'Table 4');
      await ardoises.renommer(ardoiseId: id, nom: '   ');

      expect((await folio(id)).tabLabel, isNull);
      final a = (await ardoises.watchArdoises(bar.id).first).single;
      expect(a.titre, 'Client divers n°1');
      expect(a.numeroSousLeNom, isNull);
      final renommages = (await file()).where(
        (p) => p['action'] == 'TAB_RENAME',
      );
      expect(renommages.last['label'], isNull);
    });

    test('plus de 60 caracteres, ou une ardoise close : refuse', () async {
      await ouvrirCaisse();
      final id = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
      await expectLater(
        ardoises.renommer(ardoiseId: id, nom: 'x' * 61),
        throwsStateError,
      );
      await ardoises.renommer(ardoiseId: id, nom: 'Table 4');
      await servir(id, 1000);
      await ardoises.payer(
        pointDeVente: bar,
        ardoiseId: id,
        moyen: PaymentMethod.CASH,
        by: utilisateurDemo,
      );
      await expectLater(
        ardoises.renommer(ardoiseId: id, nom: 'Table 5'),
        throwsStateError,
      );
      // Redonner le nom qu'elle porte ne change rien : pas de refus.
      await ardoises.renommer(ardoiseId: id, nom: 'Table 4');
    });

    test('le renommage part en PATCH /outlet-tabs/{id}', () async {
      await ouvrirCaisse();
      final id = await ardoises.ouvrir(pointDeVente: bar, by: utilisateurDemo);
      await ardoises.renommer(ardoiseId: id, nom: 'Table 4');
      final serveur = _ServeurQuiNote();

      await OutboxSender(db: db, api: serveur).drain();

      expect(serveur.patchs.single.$1, '/outlet-tabs/$id');
      expect(serveur.patchs.single.$2, {'label': 'Table 4'});
    });
  });

  // Essai du 24 octobre : yann Emane part avec son ardoise du Restaurant
  // impayee, sans que le depart le dise ; puis on lui sert encore a boire.
  group('le depart et les ardoises du comptoir', () {
    test('le depart les trouve, et les porte sur la chambre', () async {
      await ouvrirCaisse();
      final (client, chambre) = await awaEn101();
      final ligne = (await folio(chambre)).reservationRoomId!;
      final ardoise = await ardoises.ouvrir(
        pointDeVente: bar,
        by: utilisateurDemo,
        guestId: client,
      );
      await servir(ardoise, 1500);

      final ouvertes = await ardoises.ouvertesAuDepart(ligne);
      expect(ouvertes.single.pointDeVente, 'Bar');
      expect(ouvertes.single.reste, 1500);
      expect(ouvertes.single.portable, isTrue);

      final avant = (await folio(chambre)).balance;
      expect(await ardoises.porterAuDepart(ligne), 1);
      expect((await folio(chambre)).balance, avant + 1500);
      expect((await folio(ardoise)).status, FolioStatus.CLOSED);
      expect(await ardoises.ouvertesAuDepart(ligne), isEmpty);
    });

    test('client parti : son ardoise se paie, elle ne recoit plus rien',
        () async {
      await ouvrirCaisse();
      final (client, chambre) = await awaEn101();
      final ligne = (await folio(chambre)).reservationRoomId!;
      final ardoise = await ardoises.ouvrir(
        pointDeVente: bar,
        by: utilisateurDemo,
        guestId: client,
      );
      await servir(ardoise, 1500);
      expect(await ardoises.clientParti(ardoise), isNull);

      await ReservationRepository(db).checkOut(lineId: ligne);

      expect(await ardoises.clientParti(ardoise), 'Awa Diallo');
      await expectLater(servir(ardoise, 2000), throwsStateError);
      expect((await folio(ardoise)).chargesTotal, 1500);
      // Payer reste possible : il repasse regler.
      await ardoises.payer(
        pointDeVente: bar,
        ardoiseId: ardoise,
        moyen: PaymentMethod.CASH,
        by: utilisateurDemo,
      );
      expect((await folio(ardoise)).status, FolioStatus.CLOSED);
    });

    test('une ardoise sans client n est jamais tenue pour partie', () async {
      await ouvrirCaisse();
      final ardoise = await ardoises.ouvrir(
        pointDeVente: bar,
        by: utilisateurDemo,
      );
      expect(await ardoises.clientParti(ardoise), isNull);
    });
  });
}
