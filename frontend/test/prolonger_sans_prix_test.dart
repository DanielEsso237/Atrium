/// « Prolonger » sur la fiche d'une chambre occupee (essai du 24 octobre).
///
/// Sans prix de l'heure supplementaire, le bouton refusait, alors que
/// l'administration annoncait « La prolongation n'est pas facturee ». Un
/// depart tardif gratuit n'a rien a prolonger : le bouton n'est pas propose.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/rooms_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/data/repositories/settings_repository.dart';
import 'package:atrium/features/rooms/room_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (prix, propose) in [(0, false), (2000, true)]) {
    testWidgets(
      'prix de l heure a $prix : Prolonger ${propose ? '' : 'non '}propose',
      (tester) async {
        final db = AtriumDatabase.memory();
        final chambre = await tester.runAsync(() async {
          await seedDemoData(db);
          await SettingsRepository(
            db,
          ).setStayRules(StayRules(checkoutHour: 12, extraHourPrice: prix));
          final client = await GuestRepository(
            db,
          ).create(firstName: 'Paul', lastName: 'Mbarga');
          final room = await (db.select(
            db.rooms,
          )..where((r) => r.number.equals('101'))).getSingle();
          await ReservationRepository(db).arriveeDirecte(
            guestId: client.id,
            roomId: room.id,
            unite: UniteSejour.NIGHTS,
            duree: 1,
            prix: 20000,
            by: '00000000-0000-0000-0000-0000000000a1',
          );
          final plan = await db.watchRoomBoard().first;
          return plan.firstWhere((c) => c.roomId == room.id);
        });
        tester.view.physicalSize = const Size(1366, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
            ],
            child: MaterialApp(
              theme: themeAtrium(),
              home: Builder(
                builder: (c) => TextButton(
                  onPressed: () => afficherFicheChambre(c, chambre!),
                  child: const Text('ouvrir'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('ouvrir'));
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(find.text('Check-out'), findsOneWidget);
        expect(find.text('Prolonger'), propose ? findsOneWidget : findsNothing);
        await tester.runAsync(db.close);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
