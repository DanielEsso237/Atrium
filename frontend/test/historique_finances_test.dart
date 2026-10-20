/// L'historique des finances (18 octobre).
///
/// Ce qui compte : chaque mouvement d'argent dit qui, quoi, comment ; un
/// remboursement retranche ; une depense annulee reste sans rien retrancher ;
/// une caisse fermee avec un ecart le dit ; le comptoir n'ouvre pas
/// l'historique de l'argent de l'hotel.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/formats.dart';
import 'package:atrium/core/ids.dart';
import 'package:atrium/core/router.dart' show permissionPour;
import 'package:atrium/core/shell/app_shell.dart' show destinationsPour;
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/finances_historique_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/expense_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/finances/finances_presentation.dart';
import 'package:atrium/features/finances/historique_finances_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';

class _TestSession extends SessionNotifier {
  _TestSession(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  late AtriumDatabase db;
  late UserRow admin;
  late GuestRow client;
  late String encaissement;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    admin = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    final now = DateTime.now().toUtc();
    final guest = newId();
    await db.into(db.guests).insert(
      GuestsCompanion.insert(
        id: guest, createdAt: now, updatedAt: now, hotelId: _hotel,
        code: 'CLI-T1', firstName: 'Awa', lastName: 'Mbarga',
      ),
    );
    client = await (db.select(
      db.guests,
    )..where((g) => g.id.equals(guest))).getSingle();

    final folio = newId();
    await db.into(db.folios).insert(
      FoliosCompanion.insert(
        id: folio, createdAt: now, updatedAt: now, hotelId: _hotel,
        number: 'FOL-T1', guestId: Value(client.id),
      ),
    );
    encaissement = newId();
    for (final (id, montant, rembourse) in [
      (encaissement, 45000, false),
      (newId(), 5000, true),
    ]) {
      await db.into(db.payments).insert(
        PaymentsCompanion.insert(
          id: id, createdAt: now, updatedAt: now, hotelId: _hotel,
          method: PaymentMethod.MOBILE_MONEY, amount: montant,
          folioId: Value(folio), receivedBy: Value(admin.id),
          receivedAt: Value(now.subtract(Duration(hours: rembourse ? 1 : 3))),
          isRefund: Value(rembourse),
          reference: Value(rembourse ? null : 'MM-778'),
          reversesPaymentId: Value(rembourse ? encaissement : null),
          businessDate: Value(businessDateNow()),
        ),
      );
    }

    final depenses = ExpenseRepository(db);
    SaisieDepense saisie(int montant) => SaisieDepense(
      businessDate: businessDateNow(),
      category: ExpenseCategory.ELECTRICITY,
      label: 'Facture ENEO',
      amount: montant,
    );
    await depenses.create(saisie(80000));
    final doublon = await depenses.create(saisie(80000));
    await depenses.annuler(doublon, motif: 'Saisie en double');

    await db.into(db.cashSessions).insert(
      CashSessionsCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
        userId: admin.id, status: const Value(CashSessionStatus.CLOSED),
        openedAt: Value(now.subtract(const Duration(hours: 9))),
        closedAt: Value(now.subtract(const Duration(hours: 2))),
        openingFloat: const Value(20000),
        countedAmount: const Value(63000),
        expectedAmount: const Value(65000),
        variance: const Value(-2000),
      ),
    );
    await db.into(db.invoices).insert(
      InvoicesCompanion.insert(
        id: newId(), createdAt: now, updatedAt: now, hotelId: _hotel,
        folioId: folio, number: const Value('F-0042'),
        status: const Value(InvoiceStatus.ISSUED),
        issuedAt: Value(now.subtract(const Duration(hours: 2))),
        total: const Value(45000),
      ),
    );
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  test('un encaissement dit qui, comment, et son remboursement retranche',
      () async {
    final lignes = await db.watchEncaissementsHistorique().first;
    expect(lignes, hasLength(2));
    final e = lignes.firstWhere((x) => x.id == encaissement);
    expect(e.client, '${client.firstName} ${client.lastName}'.trim());
    expect(e.reference, 'MM-778');
    expect(e.agent, isNotNull);
    final r = lignes.firstWhere((x) => x.remboursement);
    expect(r.annule, encaissement);
    final (entree, genre) = ligneDEncaissement(r);
    expect(genre, GenreArgent.remboursement);
    expect(entree.titre, 'Encaissement annulé');
    expect(entree.negatif, isTrue);
  });

  test('une depense annulee reste, sans rien retrancher', () async {
    final depenses = await db.watchDepensesHistorique().first;
    expect(depenses, hasLength(2));
    final annulee = depenses.singleWhere((d) => d.annulee);
    final (entree, _) = ligneDeDepense(annulee);
    expect(entree.etat, 'Annulée');
    expect(entree.negatif, isFalse);
    expect(entree.detail, contains('Saisie en double'));
  });

  test('une caisse fermee avec un ecart le dit', () async {
    final caisses = await db.watchCaissesHistorique().first;
    final lignes = lignesDeCaisse(caisses.single);
    expect(lignes, hasLength(2), reason: 'ouverte, puis fermee');
    final fermee = lignes.last.$1;
    expect(fermee.etat, 'Écart');
    expect(fermee.detail, contains('écart −${formatAmount(2000)}'));
  });

  test('les factures emises se lisent avec leur numero', () async {
    final factures = await db.watchFacturesHistorique().first;
    expect(factures.single.numero, 'F-0042');
    expect(lignesDeFacture(factures.single).single.$1.titre,
        'Facture F-0042 émise');
  });

  test("le comptoir n'ouvre pas l'historique de l'argent de l'hotel", () {
    expect(permissionPour('/finances/historique'), 'folio.read|accounting.read');
    expect(permissionPour('/finances'), contains('cash.session'));
    final comptoir = destinationsPour(
      const SessionState(
        acces: AccessProfile(permissions: {'order.read', 'cash.session'}),
      ),
    );
    expect(
      comptoir.map((d) => d.route),
      isNot(contains('/finances/historique')),
    );
  });

  for (final taille in [const Size(1280, 900), const Size(390, 844)]) {
    testWidgets("l'historique des finances s affiche sans debordement : $taille",
        (tester) async {
      tester.view.physicalSize = taille;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final acces =
          (await tester.runAsync(() => accessProfileFor(db, admin.id)))!;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            sessionProvider.overrideWith(
              () => _TestSession(SessionState(agent: admin, acces: acces)),
            ),
            pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
          ],
          child: MaterialApp(
            theme: themeAtrium(),
            home: const HistoriqueFinancesScreen(),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Historique des finances'), findsOneWidget);
      if (taille.width > 600) {
        expect(find.text('Encaissement'), findsOneWidget);
        expect(find.text('Facture ENEO'), findsNWidgets(2));
      }

      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(db.close);
    });
  }
}
