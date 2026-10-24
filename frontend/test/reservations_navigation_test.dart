import 'package:atrium/core/business_day.dart';
import 'package:atrium/core/formats.dart';
import 'package:atrium/core/shell/app_shell.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/dashboard_queries.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/dashboard/dashboard_screen.dart';
import 'package:atrium/features/reservations/reservations_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _TestSession extends SessionNotifier {
  _TestSession(this.access);
  final AccessProfile access;

  @override
  SessionState build() => SessionState(acces: access, online: true);
}

class _Reservations extends ReservationRepository {
  _Reservations(super.db, this.rows);
  final List<ReservationSummary> rows;

  @override
  Stream<List<ReservationSummary>> watchReservations({
    Set<ReservationStatus>? statuses,
  }) => Stream.value([
    for (final row in rows)
      if (statuses == null || statuses.contains(row.status)) row,
  ]);
}

void main() {
  late AtriumDatabase db;
  late ProviderContainer container;
  late GoRouter router;
  late List<ReservationSummary> rows;

  setUpAll(() async {
    for (final family in {
      'Roboto': [
        for (final weight in [400, 500, 600, 700, 800])
          'assets/fonts/roboto/Roboto-$weight.ttf',
      ],
      'PhosphorLight': ['assets/fonts/phosphor/Phosphor-Light.ttf'],
      'PhosphorFill': ['assets/fonts/phosphor/Phosphor-Fill.ttf'],
    }.entries) {
      final loader = FontLoader(family.key);
      for (final asset in family.value) {
        loader.addFont(rootBundle.load(asset));
      }
      await loader.load();
    }
  });

  setUp(() {
    db = AtriumDatabase.memory();
    AtriumPalette.current = AtriumPalette.light;
    final today = businessDayFor(DateTime.now());
    final yesterday = today.subtract(const Duration(days: 1));
    final tomorrow = today.add(const Duration(days: 1));
    ReservationSummary row(
      String name,
      ReservationStatus status,
      DateTime arrival,
      DateTime departure,
    ) => ReservationSummary(
      id: name,
      lineId: name,
      reference: 'R-${name.hashCode.abs()}',
      guestName: name,
      guestId: 'client-${name.hashCode.abs()}',
      arrival: formatIsoDate(arrival),
      departure: formatIsoDate(departure),
      status: status,
      nightlyRate: 25000,
      roomTypeId: 'standard',
      roomTypeLabel: 'Standard',
      roomNumber: '101',
    );
    rows = [
      row('Client arrivée', ReservationStatus.CONFIRMED, today, tomorrow),
      row('Client demain', ReservationStatus.CONFIRMED, tomorrow, tomorrow),
      row('Client départ', ReservationStatus.CHECKED_IN, yesterday, today),
      row(
        'Client en retard',
        ReservationStatus.CHECKED_IN,
        yesterday,
        yesterday,
      ),
    ];
  });
  tearDown(() => db.close());

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    double textScale = 1,
    bool allowed = true,
    bool dark = false,
    Set<String> autres = const {},
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AtriumPalette.current = dark ? AtriumPalette.dark : AtriumPalette.light;
    addTearDown(() => AtriumPalette.current = AtriumPalette.light);
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _TestSession(
            AccessProfile(
              permissions: {if (allowed) 'reservation.read', ...autres},
            ),
          ),
        ),
        reservationRepositoryProvider.overrideWithValue(
          _Reservations(db, rows),
        ),
        pendingWritesProvider.overrideWith((ref) => Stream.value(0)),
        dashboardProvider.overrideWith(
          (ref) => Stream.value(
            const DashboardSummary(
              chambresTotal: 10,
              chambresOccupees: 2,
              reservationsActives: 4,
              arriveesDuJour: 1,
              arriveesRestantes: 1,
              departsDuJour: 2,
              departsRestants: 2,
              caDuJour: 0,
              chambresANettoyer: 0,
            ),
          ),
        ),
      ],
    );
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/clients/:id',
          builder: (_, state) =>
              Scaffold(body: Text('Fiche ${state.pathParameters['id']}')),
        ),
        ShellRoute(
          builder: (context, state, child) =>
              AppShell(location: state.matchedLocation, child: child),
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('Accueil test')),
            ),
            GoRoute(
              path: '/statistiques',
              builder: (_, _) =>
                  const Scaffold(body: Text('Statistiques test')),
            ),
            GoRoute(
              path: '/mouvements',
              builder: (_, _) => const Scaffold(body: Text('Tableau test')),
            ),
            GoRoute(
              path: '/reservations',
              builder: (_, _) => const ReservationsScreen(),
            ),
            GoRoute(
              path: '/chambres',
              builder: (_, _) => const Scaffold(body: Text('Chambres test')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: themeAtrium(),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Finder selected(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.selected == true,
    ),
  );

  /// La feuille qui s'ouvre sur un parent, dans le rail et sur telephone.
  Finder dansLaFeuille(String label) =>
      find.descendant(of: find.byType(BottomSheet), matching: find.text(label));

  testWidgets('Le sous-menu se déplie et se replie sans changer de page', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Arrivées'), findsNothing);
    expect(find.text('Départs'), findsNothing);
    await tester.tap(find.byTooltip('Déplier réception'));
    await tester.pumpAndSettle();
    expect(find.text('Arrivées'), findsOneWidget);
    expect(find.text('Départs'), findsOneWidget);
    expect(find.text('Historique'), findsOneWidget);
    expect(find.text('Accueil test'), findsOneWidget);
    await tester.tap(find.byTooltip('Replier réception'));
    await tester.pumpAndSettle();
    expect(find.text('Arrivées'), findsNothing);
    expect(find.text('Accueil test'), findsOneWidget);
    await close(tester);
  });

  testWidgets('Réception ouvre son tableau de bord et deplie ses vues', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Réception'));
    await tester.pumpAndSettle();
    expect(find.text('Tableau test'), findsOneWidget);
    expect(selected('Réception'), findsOneWidget);
    expect(find.text('Arrivées'), findsOneWidget);
    await close(tester);
  });

  testWidgets('Les deux liens filtrent les clients et marquent la vue active', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Réception'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arrivées'));
    await tester.pumpAndSettle();
    expect(find.text('Client arrivée'), findsOneWidget);
    expect(find.text('Client départ'), findsNothing);
    expect(find.text('Client demain'), findsNothing);
    expect(selected('Arrivées'), findsOneWidget);
    await tester.tap(find.text('Départs'));
    await tester.pumpAndSettle();
    expect(find.text('Client arrivée'), findsNothing);
    expect(find.text('Client départ'), findsOneWidget);
    expect(find.text('Client en retard'), findsOneWidget);
    expect(selected('Départs'), findsOneWidget);
    await tester.tap(find.text('Réservations').first);
    await tester.pumpAndSettle();
    expect(container.read(reservationFilterProvider), ReservationFilter.all);
    expect(find.text('Client demain'), findsOneWidget);
    expect(selected('Réservations'), findsOneWidget);
    await close(tester);
  });

  testWidgets(
    'Les filtres de la page et les accès externes ouvrent la bonne vue',
    (tester) async {
      await open(tester);
      container
          .read(reservationFilterProvider.notifier)
          .select(ReservationFilter.arrivalsToday);
      router.go('/reservations');
      await tester.pumpAndSettle();
      expect(find.text('Arrivées'), findsOneWidget);
      expect(selected('Arrivées'), findsOneWidget);
      await tester.ensureVisible(find.text('Départs du jour'));
      await tester.tap(find.text('Départs du jour'));
      await tester.pumpAndSettle();
      expect(selected('Départs'), findsOneWidget);
      await tester.tap(find.byTooltip('Replier réception'));
      await tester.pumpAndSettle();
      expect(find.text('Départs'), findsNothing);
      expect(selected('Réception'), findsOneWidget);
      expect(
        container.read(reservationFilterProvider),
        ReservationFilter.departuresToday,
      );
      await close(tester);
    },
  );

  for (final size in [const Size(375, 667), const Size(800, 600)]) {
    testWidgets('Le menu compact ouvre les arrivées et les départs : $size', (
      tester,
    ) async {
      await open(tester, size: size);
      const label = 'Réception';
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(dansLaFeuille('Tableau de bord'), findsOneWidget);
      await tester.tap(dansLaFeuille('Arrivées'));
      await tester.pumpAndSettle();
      expect(find.text('Client arrivée'), findsOneWidget);
      expect(find.text('Client demain'), findsNothing);
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(selected('Arrivées'), findsOneWidget);
      await tester.tap(dansLaFeuille('Départs'));
      await tester.pumpAndSettle();
      expect(find.text('Client départ'), findsOneWidget);
      expect(find.text('Client arrivée'), findsNothing);
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      await tester.tap(dansLaFeuille('Réservations'));
      await tester.pumpAndSettle();
      expect(container.read(reservationFilterProvider), ReservationFilter.all);
      await close(tester);
    });
  }

  testWidgets('Le sous-menu reste masqué sans le droit de réservation', (
    tester,
  ) async {
    await open(tester, allowed: false);
    expect(find.text('Réception'), findsNothing);
    expect(find.text('Arrivées'), findsNothing);
    expect(find.byTooltip('Déplier réception'), findsNothing);
    await close(tester);
  });

  testWidgets('Le menu sur téléphone accepte le texte agrandi en mode sombre', (
    tester,
  ) async {
    await open(tester, size: const Size(375, 667), textScale: 2, dark: true);
    await tester.tap(find.text('Réception'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(dansLaFeuille('Départs'));
    expect(dansLaFeuille('Départs').hitTestable(), findsOneWidget);
    await close(tester);
  });

  // 16 octobre, sur la tablette : un sejour de dix nuits debordait de 12 px
  // de la colonne des dates sur celle de la chambre.
  for (final size in [const Size(1280, 800), const Size(1024, 768)]) {
    testWidgets('Un long séjour tient dans sa colonne : $size', (tester) async {
      final today = businessDayFor(DateTime.now());
      rows.add(
        ReservationSummary(
          id: 'long',
          lineId: 'long',
          reference: 'R-LONG',
          guestName: 'Client longue durée',
          arrival: formatIsoDate(today),
          departure: formatIsoDate(today.add(const Duration(days: 12))),
          status: ReservationStatus.CONFIRMED,
          nightlyRate: 125000,
          roomTypeId: 'suite',
          roomTypeLabel: 'Suite présidentielle',
          roomNumber: '204',
        ),
      );
      await open(tester, size: size);
      container
          .read(reservationFilterProvider.notifier)
          .select(ReservationFilter.all);
      router.go('/reservations');
      await tester.pumpAndSettle();
      expect(find.text('Client longue durée'), findsOneWidget);
      expect(find.text('12 nuits'), findsOneWidget);
      await close(tester);
    });
  }

  testWidgets('toucher le client ouvre sa fiche', (tester) async {
    // Retour du 23 octobre : « pouvoir voir directement la fiche du client
    // sur cet ecran ».
    await open(tester, autres: {'guests.read'});
    router.go('/reservations');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Toutes').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Client demain'));
    await tester.pumpAndSettle();

    expect(find.text('Fiche client-${'Client demain'.hashCode.abs()}'),
        findsOneWidget);
    await close(tester);
  });

  testWidgets('sans le droit de lire les fiches, le nom reste un nom', (
    tester,
  ) async {
    await open(tester);
    router.go('/reservations');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Toutes').first);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Voir la fiche de Client demain'), findsNothing);
    await close(tester);
  });
}
