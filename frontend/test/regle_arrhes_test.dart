/// La regle des arrhes, fixee depuis l'administration.
///
/// Le format est celui du serveur (`services/deposit.py`) ; une regle mal
/// formee y serait lue, en silence, comme « pas d'arrhes ».
library;

import 'dart:convert';

import 'package:atrium/core/formats.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/settings_repository.dart';
import 'package:atrium/features/administration/deposit_section.dart';
import 'package:flutter_test/flutter_test.dart';

class _FauxApi extends ApiClient {
  _FauxApi() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final appels = <(String, String, Object?)>[];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    appels.add(('PUT', path, body));
    return {};
  }

  @override
  Future<Map<String, dynamic>> delete(String path) async {
    appels.add(('DELETE', path, null));
    return {};
  }
}

void main() {
  group('le calcul, recopie du serveur', () {
    test('un pourcentage se calcule en entiers, arrondi en dessous', () {
      expect(const DepositRule.percent(3000).depositFor(25000), 7500);
      expect(const DepositRule.percent(3333).depositFor(10000), 3333);
      expect(const DepositRule.percent(1250).depositFor(9999), 1249);
    });

    test('jamais plus que le sejour', () {
      expect(const DepositRule.fixed(20000).depositFor(15000), 15000);
      expect(const DepositRule.fixed(20000).depositFor(25000), 20000);
    });

    test('une regle mal formee se lit comme aucune regle', () {
      expect(DepositRule.fromJson({'mode': 'FIXED'}), isNull);
      expect(DepositRule.fromJson({'mode': 'PERCENT', 'rate_bp': 20000}), isNull);
      expect(DepositRule.fromJson({'mode': 'AUTRE', 'amount': 5}), isNull);
      expect(
        DepositRule.fromJson({'mode': 'PERCENT', 'rate_bp': 3000}),
        const DepositRule.percent(3000),
      );
    });

    test('le format ecrit est exactement celui du serveur', () {
      expect(const DepositRule.fixed(20000).toJson(), {
        'mode': 'FIXED',
        'amount': 20000,
      });
      expect(const DepositRule.percent(3000).toJson(), {
        'mode': 'PERCENT',
        'rate_bp': 3000,
      });
    });
  });

  group('la saisie et l\'exemple', () {
    test('pourcentages lus sans decimal', () {
      expect(parseRateBp('30'), 3000);
      expect(parseRateBp('12,5'), 1250);
      expect(parseRateBp('12.05'), 1205);
      expect(parseRateBp('100'), 10000);
      expect(parseRateBp('0'), isNull);
      expect(parseRateBp('101'), isNull);
      expect(parseRateBp('trente'), isNull);
    });

    test('l\'exemple dit la somme en francs', () {
      expect(
        describeRule(const DepositRule.percent(3000), 25000),
        '30 % — soit ${formatAmount(7500)} sur une chambre à '
        '${formatAmount(25000)} la nuit.',
      );
      expect(formatRate(1250), '12,5 %');
    });
  });

  group('l\'enregistrement', () {
    late AtriumDatabase db;
    late SettingsRepository reglages;

    setUp(() async {
      db = AtriumDatabase.memory();
      await seedDemoData(db);
      reglages = SettingsRepository(db);
    });

    tearDown(() => db.close());

    test('la regle se relit et remonte en PUT', () async {
      await reglages.setDepositRule(const DepositRule.percent(3000));

      expect(await reglages.depositRule(), const DepositRule.percent(3000));
      final api = _FauxApi();
      await OutboxSender(db: db, api: api).drain();
      final (methode, chemin, corps) = api.appels.single;
      expect(methode, 'PUT');
      expect(chemin, '/settings/deposit-rule');
      expect(corps, {'mode': 'PERCENT', 'rate_bp': 3000});
    });

    test('changer la regle ne cree pas un second reglage', () async {
      await reglages.setDepositRule(const DepositRule.percent(3000));
      await reglages.setDepositRule(const DepositRule.fixed(20000));

      expect(await db.select(db.settings).get(), hasLength(1));
      expect(await reglages.depositRule(), const DepositRule.fixed(20000));
    });

    test('retirer la regle remonte en DELETE', () async {
      await reglages.setDepositRule(const DepositRule.fixed(20000));
      await reglages.setDepositRule(null);

      expect(await reglages.depositRule(), isNull);
      final api = _FauxApi();
      await OutboxSender(db: db, api: api).drain();
      expect(api.appels.last.$1, 'DELETE');
      final payloads = (await db.select(db.outboxEntries).get())
          .map((e) => jsonDecode(e.payload) as Map)
          .toList();
      expect(payloads.last['value'], isNull);
    });
  });
}
