/// Envoyer les ecritures d'un agent absent, sur le code d'un responsable
/// (correction 8).
///
/// Chacun ne remonte que ses ecritures : celles d'un agent qui ne repassait
/// pas restaient pour toujours sur la tablette.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/core/widgets/atrium_puces.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/auth_api.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/envoi_pour_autrui.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outbox.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/sync/envoi_pour_un_absent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Le serveur des ecritures : il note les clients recus.
class _Serveur extends ApiClient {
  _Serveur() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final recus = <String>[];
  final refuses = <String>{};

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final nom = (body as Map)['last_name'] as String;
    if (refuses.contains(nom)) {
      throw const ApiException(ApiFailure.conflict, 'Fiche en double');
    }
    recus.add(nom);
    return {};
  }
}

/// Le serveur d'authentification : il delivre le jeton, ou refuse.
class _Auth extends AuthApi {
  _Auth()
    : super(
        ApiClient(baseUrl: 'http://localhost', tokens: const TokenStore()),
        const TokenStore(),
      );

  ApiException? echec;
  Map<String, Object?>? demande;

  @override
  Future<Map<String, dynamic>> deleguer({
    required String auteurId,
    required String employeeCode,
    required String secret,
    required String motif,
    String? tablette,
  }) async {
    demande = {
      'author_id': auteurId,
      'employee_code': employeeCode,
      'reason': motif,
      'device_id': tablette,
    };
    if (echec != null) throw echec!;
    return {
      'access_token': 'jeton-delegue',
      'expires_in': 600,
      'approver': {'first_name': 'Awa', 'last_name': 'Chef'},
    };
  }
}

void main() {
  group('le depot', () {
    late AtriumDatabase db;
    late GuestRepository clients;
    late _Serveur serveur;
    late _Auth auth;
    late String recep;
    late String menage;
    late EnvoiPourAutrui envoi;
    String? jetonVu;

    setUp(() async {
      db = AtriumDatabase.memory();
      await seedDemoData(db);
      await seedAccounts(db);
      clients = GuestRepository(db);
      serveur = _Serveur();
      auth = _Auth();
      jetonVu = null;
      Future<String> id(String code) async => (await (db.select(
        db.users,
      )..where((u) => u.employeeCode.equals(code))).getSingle()).id;
      recep = await id('RECEP01');
      menage = await id('MENAGE01');
      envoi = EnvoiPourAutrui(
        db: db,
        auth: auth,
        baseUrl: 'http://localhost',
        moteur: (jetons) {
          // Le jeton delegue, pas la session de qui tient la tablette.
          jetons.readAccess().then((j) => jetonVu = j);
          return OutboxSender(db: db, api: serveur);
        },
      );

      // Le receptionniste a saisi, puis le menage a pris la tablette.
      await db.declarerAuteur(recep);
      await clients.create(firstName: 'Ali', lastName: 'Kone');
      await db.declarerAuteur(menage);
      await clients.create(firstName: 'Ida', lastName: 'Sow');
    });

    tearDown(() => db.close());

    Future<OutboxStatus> statutDe(String auteur) async => (await (db.select(
      db.outboxEntries,
    )..where((o) => o.authorId.equals(auteur))).getSingle()).status;

    test('les ecritures de l absent partent, et elles seules', () async {
      final r = await envoi.envoyer(
        auteurId: recep,
        code: 'admin01',
        secret: '123456',
        motif: 'Parti sans se reconnecter',
      );

      expect(serveur.recus, ['Kone']);
      expect(jetonVu, 'jeton-delegue');
      expect(await statutDe(recep), OutboxStatus.ACKED);
      expect(await statutDe(menage), OutboxStatus.PENDING);
      expect(r.envoyees, 1);
      expect(r.responsable, 'Awa Chef');
      expect(r.refus, isNull);
      expect(auth.demande!['author_id'], recep);
      expect(auth.demande!['reason'], 'Parti sans se reconnecter');
      expect(auth.demande!['device_id'], isNotNull);
      expect(await db.watchEnvoisDAutrui().first, isEmpty);
    });

    test('un code refuse : rien ne part, le message du serveur', () async {
      auth.echec = const ApiException(
        ApiFailure.forbidden,
        'Code du responsable incorrect.',
      );

      await expectLater(
        envoi.envoyer(
          auteurId: recep,
          code: 'ADMIN01',
          secret: '000000',
          motif: 'Parti',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Code du responsable incorrect.',
          ),
        ),
      );
      expect(serveur.recus, isEmpty);
      expect(await statutDe(recep), OutboxStatus.PENDING);
    });

    test('hors ligne : il faut le serveur', () async {
      auth.echec = const ApiException(ApiFailure.offline, 'injoignable');

      await expectLater(
        envoi.envoyer(
          auteurId: recep,
          code: 'ADMIN01',
          secret: '123456',
          motif: 'Parti',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('en ligne'),
          ),
        ),
      );
    });

    test('un refus du serveur se dit, et l ecriture reste', () async {
      serveur.refuses.add('Kone');

      final r = await envoi.envoyer(
        auteurId: recep,
        code: 'ADMIN01',
        secret: '123456',
        motif: 'Parti',
      );

      expect(r.envoyees, 0);
      expect(r.refus, 'Fiche en double');
      expect(await statutDe(recep), OutboxStatus.FAILED);
      expect(
        messageEnvoiDelegue('RECEP01', r),
        'Aucune écriture de RECEP01 envoyée, autorisé par Awa Chef. '
        '1 écriture reste : Fiche en double',
      );
    });
  });

  test('le message apres un envoi', () {
    expect(
      messageEnvoiDelegue(
        'RECEP01',
        const EnvoiDelegue(responsable: 'Awa Chef', envoyees: 3, restantes: 0),
      ),
      '3 écritures de RECEP01 envoyées, autorisé par Awa Chef.',
    );
  });

  testWidgets('la pastille du collegue propose l envoi', (tester) async {
    AtriumPalette.current = AtriumPalette.light;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
          envoisDAutruiProvider.overrideWith(
            (ref) => Stream.value(const [
              (id: 'recep', agent: 'RECEP01', n: 2),
            ]),
          ),
        ],
        child: MaterialApp(
          theme: themeAtrium(),
          home: const Scaffold(body: Center(child: PuceEcritures())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('2 · RECEP01'));
    await tester.pumpAndSettle();

    expect(find.text('Envoyer à la place de RECEP01'), findsOneWidget);
    expect(find.textContaining('2 écritures de RECEP01'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Envoyer'), findsOneWidget);
  });
}
