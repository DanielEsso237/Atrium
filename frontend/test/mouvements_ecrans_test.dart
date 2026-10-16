/// Les ecrans du 16 octobre s'affichent, sur tablette comme sur telephone :
/// Mouvements, Historique (ses deux vues) et Entretien.
///
/// Mme Diallo est arrivee en 101 et a paye 20 000 : de quoi remplir la
/// chronologie, la liste des clients deja venus et son parcours.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/mouvements_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/entretien/entretien_screen.dart';
import 'package:atrium/features/mouvements/historique_screen.dart';
import 'package:atrium/features/mouvements/mouvements_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late String clientId;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    await seedAccounts(db);
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    clientId = client.id;
    final chambre = await db
        .customSelect("SELECT id FROM rooms WHERE number = '101'")
        .getSingle();
    final reservations = ReservationRepository(db);
    final id = await reservations.create(
      guestId: client.id,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 3),
      nightlyRate: 25000,
      roomId: chambre.read<String>('id'),
    );
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(id))).getSingle();
    await reservations.checkIn(lineId: ligne.id, by: utilisateurDemo);
    await CashRepository(db).open(userId: utilisateurDemo, openingFloat: 0);
    final ardoise = (await FolioRepository(db).openFolioForStay(ligne.id))!;
    await FolioRepository(db).addPayment(
      folioId: ardoise.id,
      method: PaymentMethod.CASH,
      amount: 20000,
      receivedBy: utilisateurDemo,
    );
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  test('la chronologie et les clients deja venus', () async {
    final mouvements = await db.watchMouvements().first;
    expect(
      mouvements.map((m) => m.genre),
      containsAll([
        GenreMouvement.reservation,
        GenreMouvement.arrivee,
        GenreMouvement.encaissement,
      ]),
    );
    final arrivee = mouvements.firstWhere(
      (m) => m.genre == GenreMouvement.arrivee,
    );
    expect(arrivee.annulable, isTrue);
    expect(arrivee.client, 'Awa Diallo');

    final clients = await db.watchClientsVenus().first;
    expect(clients.single.nom, 'Awa Diallo');
    expect(clients.single.nuits, 2);
    expect(clients.single.consomme, 50000);
    expect(clients.single.paye, 20000);
    expect(clients.single.enCeMoment, isTrue);

    final parcours = await db.watchParcoursClient(clientId).first;
    expect(parcours.single.lignes, hasLength(2));
    expect(parcours.single.paiements.single.montant, 20000);
    expect(parcours.single.solde, 30000);
  });

  test('les mouvements d un client et l encaissement annule', () async {
    final siens = await db.watchMouvements(guestId: clientId).first;
    expect(siens, isNotEmpty);
    expect(siens.every((m) => m.guestId == clientId), isTrue);
    expect(await db.watchMouvements(guestId: 'personne').first, isEmpty);

    final caisse = CashRepository(db);
    final jour = businessDateNow();
    final avant = (await caisse.watchDayPayments(jour).first).single;
    expect(avant.annulable, isTrue);
    expect(avant.annule, isFalse);

    await FolioRepository(db).annulerEncaissement(
      paymentId: avant.id,
      approuvePar: utilisateurDemo,
      motif: 'Erreur de saisie',
      by: utilisateurDemo,
    );
    final apres = await caisse.watchDayPayments(jour).first;
    final origine = apres.firstWhere((x) => x.id == avant.id);
    expect(origine.annule, isTrue);
    expect(origine.annulable, isFalse);
    final rendu = apres.firstWhere((x) => x.id != avant.id);
    expect(rendu.amount, -20000);
    expect(rendu.annulable, isFalse);
  });

  for (final largeur in [1280.0, 400.0]) {
    for (final (nom, ecran) in [
      ('Mouvements', const MouvementsScreen()),
      ('Historique', const HistoriqueScreen()),
      ('Entretien', const EntretienScreen()),
    ]) {
      testWidgets('$nom s affiche sans debordement ($largeur px)', (
        tester,
      ) async {
        AtriumPalette.current = AtriumPalette.light;
        tester.view.physicalSize = Size(largeur, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final agent = await tester.runAsync(
          () => (db.select(
            db.users,
          )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle(),
        );
        final acces = (await tester.runAsync(
          () => accessProfileFor(db, agent!.id),
        ))!;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              sessionProvider.overrideWith(
                () => _TestSession(SessionState(agent: agent, acces: acces)),
              ),
              pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
            ],
            child: MaterialApp(theme: themeAtrium(), home: ecran),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(nom), findsWidgets);

        if (nom == 'Historique') {
          await tester.tap(find.text('Clients'));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 150)),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Awa Diallo'), findsWidgets);
          await tester.tap(find.text('Awa Diallo').first);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 150)),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.textContaining('Séjour'), findsWidgets);
        }

        await tester.runAsync(db.close);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
