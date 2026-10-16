/// La nouvelle arrivee (16 octobre) : le formulaire de la reservation, avec
/// la duree en nuits ou en heures, et la piece d'identite obligatoire.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/reservations/arrivee_directe_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  testWidgets('les etapes, le recapitulatif, et ce qui manque', (
    tester,
  ) async {
    final db = AtriumDatabase.memory();
    late UserRow agent;
    late AccessProfile acces;
    await tester.runAsync(() async {
      await seedDemoData(db);
      await seedAccounts(db);
      agent = await (db.select(
        db.users,
      )..where((u) => u.employeeCode.equals('RECEP01'))).getSingle();
      acces = (await accessProfileFor(db, agent.id))!;
    });
    AtriumPalette.current = AtriumPalette.light;
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
          sessionProvider.overrideWith(
            () => _Session(SessionState(agent: agent, acces: acces)),
          ),
        ],
        child: MaterialApp(
          theme: themeAtrium(),
          home: const ArriveeDirecteScreen(),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
    }

    expect(tester.takeException(), isNull);
    expect(find.text('Nouvelle arrivée'), findsOneWidget);
    // Les etapes de la reservation ; la piece n'apparait qu'avec le client.
    expect(find.text('Le client'), findsOneWidget);
    expect(find.text('La durée'), findsOneWidget);
    expect(find.text('La chambre'), findsOneWidget);
    expect(find.text('Le prix'), findsOneWidget);
    expect(find.text('En heures'), findsOneWidget);
    expect(find.text('Récapitulatif'), findsOneWidget);
    expect(find.text('Il manque un client, une chambre.'), findsOneWidget);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });
}
