/// La reception est la caisse centrale : le versement du soir.
///
/// Chaque point de vente tient son tiroir pendant le service. Le soir, son
/// agent declare ce qu'il remet -- c'est la fermeture de sa caisse -- et la
/// reception confirme ce qu'elle recoit. Trois chiffres restent : l'attendu,
/// le declare et le recu.
library;

import 'package:atrium/core/business_day.dart';
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
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

/// Le barman : un agent de point de vente, sans la caisse centrale.
const _barman = '01920000-0000-7000-8000-00000000b001';

/// La reception : celle qui recoit les versements.
const _reception = '01920000-0000-7000-8000-000000050002';

class _Appel {
  const _Appel(this.chemin, this.corps);
  final String chemin;
  final Map<String, Object?> corps;
}

/// Un serveur de papier : il note ce qu'on lui envoie, et repond a une
/// ouverture de caisse par l'identifiant qu'on lui a dit de retenir.
class _FauxApi extends ApiClient {
  _FauxApi({this.caisseRetenue})
    : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final String? caisseRetenue;
  final appels = <_Appel>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final corps = (body as Map?)?.cast<String, Object?>() ?? {};
    appels.add(_Appel(path, corps));
    if (path == '/cash-sessions') {
      return {'id': caisseRetenue ?? corps['id']};
    }
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late CashRepository caisse;
  late OrderRepository commandes;
  late OutletRow bar;

  final jour = businessDateNow();

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    caisse = CashRepository(db);
    commandes = OrderRepository(db);
    bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
  });

  tearDown(() => db.close());

  Future<void> vendre(int montant, {PaymentMethod moyen = PaymentMethod.CASH}) =>
      commandes.sellWalkIn(
        outlet: bar,
        lines: [('Biere', montant, 1, null)],
        method: moyen,
        by: _barman,
      );

  /// Le bar ouvre a 5 000, vend 12 000 en especes et 4 000 en mobile.
  Future<String> soireeDuBar() async {
    final id = await caisse.open(
      userId: _barman,
      openingFloat: 5000,
      outletId: bar.id,
    );
    await vendre(7000);
    await vendre(5000);
    await vendre(4000, moyen: PaymentMethod.MOBILE_MONEY);
    return id;
  }

  Future<CashSessionRow> ligne(String id) => (db.select(
    db.cashSessions,
  )..where((c) => c.id.equals(id))).getSingle();

  group('la caisse d un point de vente', () {
    test('porte son point de vente, la caisse centrale non', () async {
      final duBar = await caisse.open(
        userId: _barman,
        openingFloat: 0,
        outletId: bar.id,
      );
      final centrale = await caisse.open(userId: _reception, openingFloat: 0);

      expect(
        (await caisse.watchCurrent(_barman, outletId: bar.id).first)!.ofOutlet,
        isTrue,
      );
      expect((await ligne(duBar)).outletId, bar.id);
      expect((await caisse.watchCurrent(_reception).first)!.ofOutlet, isFalse);
      expect((await ligne(centrale)).outletId, isNull);
    });

    test('verser ferme la caisse et constate l ecart', () async {
      final id = await soireeDuBar();

      // Attendu : 5 000 de fond et 12 000 d'especes. Le mobile ne passe pas
      // par le tiroir. Il manque 1 000.
      final ecart = await caisse.close(sessionId: id, countedAmount: 16000);

      expect(ecart, -1000);
      final s = await ligne(id);
      expect(s.status, CashSessionStatus.CLOSED);
      expect(s.expectedAmount, 17000);
      expect(s.countedAmount, 16000);
      expect(s.receivedAmount, isNull);
      expect(await caisse.watchCurrent(_barman).first, isNull);
    });
  });

  group('la reception confirme', () {
    test('ce qu elle recoit, et les trois chiffres restent', () async {
      final id = await soireeDuBar();
      await caisse.close(sessionId: id, countedAmount: 17000);
      final centrale = await caisse.open(userId: _reception, openingFloat: 0);

      final ecart = await caisse.confirmRemittance(
        sessionId: id,
        receivedAmount: 16500,
        by: _reception,
      );

      expect(ecart, -500);
      final s = await ligne(id);
      expect(s.expectedAmount, 17000);
      expect(s.countedAmount, 17000);
      expect(s.receivedAmount, 16500);
      expect(s.receivedBy, _reception);
      expect(s.receivedSessionId, centrale);
    });

    test('le versement recu entre dans la caisse centrale', () async {
      final id = await soireeDuBar();
      await caisse.close(sessionId: id, countedAmount: 17000);
      final centrale = await caisse.open(
        userId: _reception,
        openingFloat: 10000,
      );
      await caisse.confirmRemittance(
        sessionId: id,
        receivedAmount: 17000,
        by: _reception,
      );

      // Sans cela, la reception constaterait 17 000 de trop a chaque soir.
      expect((await caisse.watchCurrent(_reception).first)!.expected, 27000);
      expect(
        await caisse.close(sessionId: centrale, countedAmount: 27000),
        0,
      );
    });

    test('pas avant que le point de vente ait declare', () async {
      final id = await soireeDuBar();
      await caisse.open(userId: _reception, openingFloat: 0);

      await expectLater(
        caisse.confirmRemittance(
          sessionId: id,
          receivedAmount: 17000,
          by: _reception,
        ),
        throwsStateError,
      );
    });

    test('pas sans caisse ou mettre l argent', () async {
      final id = await soireeDuBar();
      await caisse.close(sessionId: id, countedAmount: 17000);

      await expectLater(
        caisse.confirmRemittance(
          sessionId: id,
          receivedAmount: 17000,
          by: _reception,
        ),
        throwsStateError,
      );
      expect((await ligne(id)).receivedAmount, isNull);
    });

    test('pas deux fois', () async {
      final id = await soireeDuBar();
      await caisse.close(sessionId: id, countedAmount: 17000);
      await caisse.open(userId: _reception, openingFloat: 0);
      await caisse.confirmRemittance(
        sessionId: id,
        receivedAmount: 17000,
        by: _reception,
      );

      await expectLater(
        caisse.confirmRemittance(
          sessionId: id,
          receivedAmount: 99000,
          by: _reception,
        ),
        throwsStateError,
      );
      expect((await ligne(id)).receivedAmount, 17000);
    });

    test('pas la caisse centrale elle-meme', () async {
      final centrale = await caisse.open(userId: _reception, openingFloat: 0);
      await caisse.close(sessionId: centrale, countedAmount: 0);
      await caisse.open(userId: utilisateurDemo, openingFloat: 0);

      await expectLater(
        caisse.confirmRemittance(
          sessionId: centrale,
          receivedAmount: 0,
          by: utilisateurDemo,
        ),
        throwsStateError,
      );
    });
  });

  group('le rapport du soir', () {
    test('dit ce que chaque point de vente doit tant qu il n a rien verse',
        () async {
      await soireeDuBar();

      final rapport = await caisse.watchEveningReport(jour).first;

      final point = rapport.outlets.single;
      expect(point.outletLabel, 'Bar');
      expect(point.takings, 16000);
      expect(point.cashTakings, 12000);
      expect(point.remittances.single.status, RemittanceStatus.pending);
      expect(rapport.expected, 17000);
      expect(rapport.pending, 17000);
      expect(rapport.paid, 0);
      expect(rapport.variance, 0);
    });

    test('suit le versement : declare, puis recu, avec l ecart', () async {
      final id = await soireeDuBar();
      await caisse.close(sessionId: id, countedAmount: 16000);

      var rapport = await caisse.watchEveningReport(jour).first;
      expect(rapport.outlets.single.remittances.single.status,
          RemittanceStatus.declared);
      expect(rapport.toConfirm, 1);
      expect(rapport.pending, 0);
      expect(rapport.paid, 16000);
      expect(rapport.variance, -1000);

      await caisse.open(userId: _reception, openingFloat: 0);
      await caisse.confirmRemittance(
        sessionId: id,
        receivedAmount: 15500,
        by: _reception,
      );

      rapport = await caisse.watchEveningReport(jour).first;
      final versement = rapport.outlets.single.remittances.single;
      expect(versement.status, RemittanceStatus.received);
      expect(versement.declared, 16000);
      expect(versement.received, 15500);
      expect(rapport.toConfirm, 0);
      expect(rapport.paid, 15500);
      expect(rapport.variance, -1500);
    });

    test('la reception qui vend au bar remplit le tiroir du bar', () async {
      // Un tiroir par point de vente, quel que soit l'agent (decision du 11
      // octobre) : ce que la reception vend au bar est la recette du bar,
      // pas celle de la caisse centrale.
      await soireeDuBar();
      final centrale = await caisse.open(userId: _reception, openingFloat: 0);
      final tiroirDuBar = await caisse.open(
        userId: _reception,
        openingFloat: 0,
        outletId: bar.id,
      );
      expect(tiroirDuBar, isNot(centrale));
      await commandes.sellWalkIn(
        outlet: bar,
        lines: [('Eau', 1000, 1, null)],
        method: PaymentMethod.CASH,
        by: _reception,
      );

      final rapport = await caisse.watchEveningReport(jour).first;

      expect(rapport.centralTakings, 0);
      expect(rapport.outlets.single.takings, 17000);
      expect(
        (await caisse.watchCurrent(_reception, outletId: bar.id).first)!
            .cashCollected,
        1000,
      );
      expect((await caisse.watchCurrent(_reception).first)!.cashCollected, 0);
    });
  });

  group('la remontee', () {
    test('l ouverture porte son identifiant et son point de vente', () async {
      final id = await caisse.open(
        userId: _barman,
        openingFloat: 5000,
        outletId: bar.id,
      );
      await caisse.close(sessionId: id, countedAmount: 5000);
      final api = _FauxApi();

      await OutboxSender(db: db, api: api).drain();

      final ouverture = api.appels.firstWhere(
        (a) => a.chemin == '/cash-sessions',
      );
      // Sans l'identifiant, la caisse naissait sous un autre sur le serveur
      // et la fermeture ne la retrouvait pas : 404, et la file bloquee.
      expect(ouverture.corps['id'], id);
      expect(ouverture.corps['outlet_id'], bar.id);
      expect(ouverture.corps['opening_float'], 5000);
      expect(api.appels.last.chemin, '/cash-sessions/$id/close');
      expect((await ligne(id)).syncState, SyncState.synced);
    });

    test('la confirmation part par sa propre route', () async {
      final id = await soireeDuBar();
      await caisse.close(sessionId: id, countedAmount: 17000);
      await caisse.open(userId: _reception, openingFloat: 0);
      await caisse.confirmRemittance(
        sessionId: id,
        receivedAmount: 16500,
        by: _reception,
      );
      final api = _FauxApi();

      final rapport = await OutboxSender(db: db, api: api).drain();

      expect(rapport.arret, DrainStop.termine);
      final recu = api.appels.last;
      expect(recu.chemin, '/cash-sessions/$id/receive');
      expect(recu.corps, {'received_amount': 16500});
      // Le versement est declare au serveur avant d'y etre confirme.
      final chemins = [for (final a in api.appels) a.chemin];
      expect(
        chemins.indexOf('/cash-sessions/$id/close'),
        lessThan(chemins.indexOf('/cash-sessions/$id/receive')),
      );
    });

    test('la caisse deja ouverte sur le serveur est adoptee', () async {
      const duServeur = '01920000-0000-7000-8000-00000000c001';
      final locale = await soireeDuBar();
      await caisse.close(sessionId: locale, countedAmount: 17000);
      final api = _FauxApi(caisseRetenue: duServeur);

      final rapport = await OutboxSender(db: db, api: api).drain();

      // L'agent n'a qu'une caisse : la tablette prend celle du serveur, et
      // la fermeture qui attendait la vise.
      expect(rapport.arret, DrainStop.termine);
      expect(api.appels.last.chemin, '/cash-sessions/$duServeur/close');
      final caisses = await db.select(db.cashSessions).get();
      expect(caisses.single.id, duServeur);
      expect(caisses.single.status, CashSessionStatus.CLOSED);
      expect(caisses.single.syncState, SyncState.synced);
      final paiements = await db.select(db.payments).get();
      expect(paiements.map((p) => p.cashSessionId).toSet(), {duServeur});
    });
  });

  group('la descente', () {
    RemoteCashSession duBar({
      String id = '01920000-0000-7000-8000-00000000c002',
      String statut = 'CLOSED',
      int? verse = 17000,
    }) => RemoteCashSession(
      id: id,
      userId: _barman,
      status: statut,
      openedAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
      openingFloat: 5000,
      closedAt: statut == 'CLOSED' ? DateTime.now().toUtc() : null,
      expectedAmount: 17000,
      countedAmount: verse,
      outletId: bar.id,
    );

    Future<PullReport> descendre(List<RemoteCashSession> caisses) {
      final api = FakeCatalogApi(cashSessions: caisses);
      return Descente(db, api, SyncRepository(db, api)).pull();
    }

    test('la reception voit le versement declare sur un autre poste',
        () async {
      await descendre([duBar()]);

      final rapport = await caisse.watchEveningReport(jour).first;
      final versement = rapport.outlets.single.remittances.single;
      expect(versement.status, RemittanceStatus.declared);
      expect(versement.declared, 17000);
      expect(versement.expected, 17000);
    });

    test('une confirmation pas encore remontee n est pas ecrasee', () async {
      final versement = duBar();
      await descendre([versement]);
      await caisse.open(userId: _reception, openingFloat: 0);
      await caisse.confirmRemittance(
        sessionId: versement.id,
        receivedAmount: 17000,
        by: _reception,
      );

      // Le serveur ne sait pas encore que la reception a confirme.
      final rapport = await descendre([versement]);

      expect(rapport.skipped, greaterThan(0));
      expect((await ligne(versement.id)).receivedAmount, 17000);
    });

    test('ne fait pas deux caisses ouvertes pour un meme agent', () async {
      // Une caisse ouverte ici, deja remontee, mais nee sous un autre
      // identifiant sur le serveur.
      final locale = await caisse.open(
        userId: _barman,
        openingFloat: 5000,
        outletId: bar.id,
      );
      await vendre(7000);
      await OutboxSender(db: db, api: _FauxApi()).drain();
      final duServeur = duBar(statut: 'OPEN', verse: null);

      await descendre([duServeur]);

      final ouvertes = await (db.select(db.cashSessions)
            ..where((c) => c.status.equalsValue(CashSessionStatus.OPEN)))
          .get();
      expect(ouvertes.single.id, duServeur.id);
      expect(ouvertes.single.id, isNot(locale));
      expect(
        await caisse.openSessionId(_barman, outletId: bar.id),
        duServeur.id,
      );
      expect(
        (await caisse.watchCurrent(_barman, outletId: bar.id).first)!
            .cashCollected,
        7000,
      );
    });
  });
}
