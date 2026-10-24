/// Trois articles differents touches dans la carte : trois lignes vendues.
///
/// Signale le 23 octobre au bar : Supermont, Castel et 33 Export touches,
/// et seule la Supermont arrivait sur la facture, en double. Reproduit le
/// 24 octobre par la recherche, sur un ecran de moins de 600 px de petit
/// cote : la liste restait ouverte sur « Ajouter une ligne », et une ligne
/// melangeait les articles sous un seul compteur, dont « − » retirait le
/// dernier. Desormais une ligne par article, dans la recherche comme dans le
/// tableau.
library;

import 'package:atrium/core/ids.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/outlet_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/orders/orders_screen.dart';
import 'package:atrium/features/orders/tableau_carte.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  late UserRow agent;

  // La vraie police : celle des tests, plus large, fait deborder la fiche.
  setUpAll(() async {
    final roboto = FontLoader('Roboto');
    for (final graisse in [400, 500, 600, 700, 800]) {
      roboto.addFont(
        rootBundle.load('assets/fonts/roboto/Roboto-$graisse.ttf'),
      );
    }
    await roboto.load();
  });

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    agent = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    final bar = await OutletRepository(db).create(code: 'BAR', label: 'Bar');
    // Rien ne se sert sans le tiroir ouvert du point de vente.
    await CashRepository(
      db,
    ).open(userId: agent.id, openingFloat: 0, outletId: bar.id);
    final now = DateTime.now().toUtc();
    final categorie = newId();
    await db
        .into(db.menuCategories)
        .insert(
          MenuCategoriesCompanion.insert(
            id: categorie,
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            label: 'Boissons',
            outletId: Value(bar.id),
          ),
        );
    for (final (code, label, prix) in [
      ('SUPERMONT', 'Supermont', 900),
      ('CASTEL', 'Castel', 1000),
      ('EXPORT', '33 Export', 500),
    ]) {
      await db
          .into(db.menuItems)
          .insert(
            MenuItemsCompanion.insert(
              id: newId(),
              createdAt: now,
              updatedAt: now,
              hotelId: _hotel,
              code: code,
              label: label,
              menuCategoryId: categorie,
              price: Value(prix),
            ),
          );
    }
    AtriumPalette.current = AtriumPalette.light;
  });

  tearDown(() => db.close().timeout(const Duration(seconds: 5)));

  for (final payer in [false, true]) {
    testWidgets('trois articles touches a droite partent tous les trois'
        '${payer ? ' (payes sur place)' : ''}', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final acces = (await tester.runAsync(
        () => accessProfileFor(db, agent.id),
      ))!;

      // Pas de `pumpAndSettle` : un indicateur qui tourne ne se pose jamais.
      Future<void> attendre() async {
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            sessionProvider.overrideWith(
              () => _TestSession(SessionState(agent: agent, acces: acces)),
            ),
            pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
          ],
          child: MaterialApp(theme: themeAtrium(), home: const OrdersScreen()),
        ),
      );
      await attendre();
      await tester.tap(find.text('Nouveau client'));
      await attendre();

      for (final article in ['Supermont', 'Castel', '33 Export']) {
        await tester.tap(
          find.descendant(
            of: find.byType(TableauCarte),
            matching: find.text(article),
          ),
        );
        await attendre();
      }
      expect(find.text('Consommation 3'), findsOneWidget);

      if (payer) {
        await tester.tap(find.text('Payer maintenant'));
        await attendre();
        await tester.tap(find.text('Encaisser'));
      } else {
        await tester.tap(find.text('Ouvrir une ardoise'));
      }
      // La vente s'ecrit dans le temps du test : on la laisse finir, sinon sa
      // transaction tient la base et la lecture ci-dessous attend pour rien.
      for (var i = 0; i < 20; i++) {
        await attendre();
      }

      final lignes = await tester.runAsync(
        () => db.select(db.folioItems).get(),
      );
      expect(
        {for (final l in lignes!) l.label: (l.quantity, l.unitPrice)},
        {'Supermont': (1, 900), 'Castel': (1, 1000), '33 Export': (1, 500)},
      );

      // L'ecran d'abord : ses flux tiendraient la base ouverte.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('par la recherche : une ligne par article, et la liste se ferme',
      (tester) async {
    // Petit cote sous 600 px : la fiche s'ouvre en feuille, avec la
    // recherche et sans tableau.
    tester.view.physicalSize = const Size(1366, 592);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final acces = (await tester.runAsync(
      () => accessProfileFor(db, agent.id),
    ))!;
    Future<void> attendre() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionProvider.overrideWith(
            () => _TestSession(SessionState(agent: agent, acces: acces)),
          ),
          pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp(theme: themeAtrium(), home: const OrdersScreen()),
      ),
    );
    await attendre();
    await tester.ensureVisible(find.text('Nouveau client'));
    await tester.tap(find.text('Nouveau client'));
    await attendre();
    expect(find.byType(TableauCarte), findsNothing);

    Future<void> chercher(String texte, String article) async {
      // Le champ Consommation de la premiere ligne : apres la recherche de
      // l'ecran, derriere la feuille.
      final champ = find.byType(TextField).at(1);
      await tester.tap(champ);
      await attendre();
      await tester.enterText(champ, texte);
      await attendre();
      await tester.tap(find.text(article).last);
      await attendre();
    }

    await chercher('super', 'Supermont');
    // La liste fermee : rien ne couvre plus « Ajouter une ligne ».
    expect(find.text('Castel'), findsNothing);
    // Un autre article, cherche sur la meme ligne : il prend la sienne.
    await chercher('cast', 'Castel');
    expect(find.text('Consommation 2'), findsOneWidget);

    await tester.tap(find.text('Ouvrir une ardoise'));
    for (var i = 0; i < 20; i++) {
      await attendre();
    }
    final lignes = await tester.runAsync(
      () => db.select(db.folioItems).get(),
    );
    expect(
      {for (final l in lignes!) l.label: (l.quantity, l.unitPrice)},
      {'Supermont': (1, 900), 'Castel': (1, 1000)},
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
