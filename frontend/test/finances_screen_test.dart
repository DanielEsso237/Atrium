/// Le tableau de bord des finances (16 octobre, refait le 18) : l'argent de
/// l'hotel pour la direction, sa caisse et ses factures pour le comptoir.
library;

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/formats.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/repositories/expense_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/finances/finances_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  setUpAll(() async {
    final roboto = FontLoader('Roboto');
    for (final graisse in [400, 500, 600, 700, 800]) {
      roboto.addFont(
        rootBundle.load('assets/fonts/roboto/Roboto-$graisse.ttf'),
      );
    }
    await roboto.load();
  });

  Future<void> ouvrir(
    WidgetTester tester, {
    required Size taille,
    AccessProfile? acces,
    Future<void> Function(AtriumDatabase db)? avant,
  }) async {
    final db = AtriumDatabase.memory();
    late UserRow admin;
    late AccessProfile droits;
    await tester.runAsync(() async {
      await seedDemoData(db);
      await seedAccounts(db);
      admin = await (db.select(
        db.users,
      )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
      droits = acces ?? await accessProfileFor(db, admin.id);
      await avant?.call(db);
    });
    AtriumPalette.current = AtriumPalette.light;
    tester.view.physicalSize = taille;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
          sessionProvider.overrideWith(
            () => _Session(SessionState(agent: admin, acces: droits)),
          ),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const FinancesScreen()),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  Future<void> fermer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final taille in [const Size(1280, 800), const Size(400, 900)]) {
    testWidgets('la direction voit le tableau de bord (${taille.width} px)', (
      tester,
    ) async {
      await ouvrir(tester, taille: taille);
      expect(tester.takeException(), isNull);
      // Le chiffre qui compte, en tete : le chiffre d'affaires du mois.
      expect(find.text('Chiffre d’affaires, ce mois'), findsOneWidget);
      for (final titre in [
        'Par moyen de paiement',
        'Du chiffre d’affaires au bénéfice',
        'Dépenses par rubrique',
        'Caisses',
        'À encaisser',
        'Derniers mouvements d’argent',
      ]) {
        await tester.scrollUntilVisible(
          find.text(titre),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(titre), findsOneWidget, reason: titre);
      }
      // L'argent de l'hotel : pas la caisse du comptoir.
      expect(find.text('Ma caisse'), findsNothing);
      expect(tester.takeException(), isNull);
      await fermer(tester);
    });
  }

  testWidgets('le comptoir ne voit que sa caisse et ses factures', (
    tester,
  ) async {
    await ouvrir(
      tester,
      taille: const Size(1280, 800),
      acces: const AccessProfile(permissions: {'order.read', 'cash.session'}),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Ma caisse'), findsOneWidget);
    expect(find.text('Mes factures'), findsOneWidget);
    expect(find.text('Aucune caisse ouverte.'), findsOneWidget);
    for (final cache in [
      'Chiffre d’affaires, ce mois',
      'Caisse du jour',
      'Dépenses',
      'Comptabilité',
      'Rapports',
      'Historique',
    ]) {
      expect(find.text(cache), findsNothing, reason: cache);
    }
    await fermer(tester);
  });

  testWidgets('une depense annulee ne compte pas dans le mois', (tester) async {
    await ouvrir(
      tester,
      taille: const Size(1280, 1600),
      avant: (db) async {
        final depenses = ExpenseRepository(db);
        SaisieDepense saisie(int montant) => SaisieDepense(
          businessDate: businessDateNow(),
          category: ExpenseCategory.values.first,
          label: 'Facture d’essai',
          amount: montant,
        );
        await depenses.create(saisie(12000));
        final erreur = await depenses.create(saisie(50000));
        await depenses.annuler(erreur, motif: 'Saisie en double');
      },
    );
    expect(tester.takeException(), isNull);
    // Le bandeau et les rubriques ne comptent que la depense gardee.
    expect(find.text(formatAmount(12000)), findsWidgets);
    expect(find.text(formatAmount(62000)), findsNothing);
    await fermer(tester);
  });
}
