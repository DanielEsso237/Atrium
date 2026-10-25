import 'package:atrium/core/brand/atrium_logo.dart';
import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/features/auth/login_screen.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestSession extends SessionNotifier {
  final attempts = <({String code, String secret, bool parPin})>[];

  @override
  SessionState build() => const SessionState();

  @override
  Future<bool> connecter({
    required String codeAgent,
    required String secret,
    bool parPin = false,
  }) async {
    attempts.add((code: codeAgent, secret: secret, parPin: parPin));
    return true;
  }

  /// L'ancien code de RECEP01, tel que la tablette le connaitrait.
  @override
  Future<bool> estAncienCode(String codeAgent, String pin) async =>
      codeAgent == 'RECEP01' && pin == '2580';
}

Future<_TestSession> _open(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  bool dark = false,
  bool reducedMotion = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  AtriumPalette.current = dark ? AtriumPalette.dark : AtriumPalette.light;
  addTearDown(() => AtriumPalette.current = AtriumPalette.light);
  final session = _TestSession();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWith(() => session)],
      child: MaterialApp(
        theme: themeAtrium(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reducedMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: const LoginScreen(),
      ),
    ),
  );
  if (reducedMotion) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(seconds: 1));
  }
  return session;
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    // Les métriques des polices embarquées sont celles de l'application.
    for (final family in {
      'Roboto': [
        for (final weight in [400, 500, 600, 700, 800])
          'assets/fonts/roboto/Roboto-$weight.ttf',
      ],
    }.entries) {
      final loader = FontLoader(family.key);
      for (final asset in family.value) {
        loader.addFont(rootBundle.load(asset));
      }
      await loader.load();
    }
  });

  for (final scenario in [
    (name: 'ordinateur', size: const Size(1280, 800), scale: 1.0, dark: false),
    (
      name: 'petit écran paysage',
      size: const Size(900, 375),
      scale: 1.0,
      dark: false,
    ),
    (name: 'téléphone', size: const Size(375, 667), scale: 1.0, dark: false),
    (name: 'tablette', size: const Size(768, 1024), scale: 1.0, dark: false),
    (
      name: 'texte agrandi',
      size: const Size(375, 667),
      scale: 2.0,
      dark: false,
    ),
    (name: 'mode sombre', size: const Size(1280, 800), scale: 1.0, dark: true),
  ]) {
    testWidgets('Connexion accessible sans débordement : ${scenario.name}', (
      tester,
    ) async {
      await _open(
        tester,
        size: scenario.size,
        textScale: scenario.scale,
        dark: scenario.dark,
      );
      expect(find.byType(EdgeHotelLogo), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Le formulaire reste utilisable même si le bandeau ou le clavier
      // dépassent la hauteur de la fenêtre.
      await tester.ensureVisible(find.text('Mot de passe'));
      await tester.tap(find.text('Mot de passe'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Se connecter'));
      expect(find.text('Se connecter').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  }

  testWidgets('Le sixième chiffre soumet le PIN et le code agent', (
    tester,
  ) async {
    final session = await _open(tester, size: const Size(1280, 800));
    await tester.enterText(find.byType(TextField), 'RECEP01');
    for (final chiffre in ['1', '2', '3', '4', '5']) {
      await tester.tap(find.text(chiffre));
      await tester.pumpAndSettle();
    }
    expect(session.attempts, isEmpty);
    await tester.tap(find.text('6'));
    await tester.pumpAndSettle();
    expect(session.attempts, [
      (code: 'RECEP01', secret: '123456', parPin: true),
    ]);
    await _close(tester);
  });

  // Decision du 25 octobre : le PIN passe a 6 chiffres. Un ancien code de 4
  // reconnu part tout seul au quatrieme chiffre, comme avant ; sinon l'agent
  // continue jusqu'a six.
  testWidgets('Un ancien code reconnu part tout seul au quatrième chiffre', (
    tester,
  ) async {
    final session = await _open(tester, size: const Size(1280, 800));
    await tester.enterText(find.byType(TextField), 'RECEP01');
    for (final chiffre in ['2', '5', '8', '0']) {
      await tester.tap(find.text(chiffre));
      await tester.pumpAndSettle();
    }
    expect(session.attempts, [(code: 'RECEP01', secret: '2580', parPin: true)]);
    await _close(tester);
  });

  testWidgets('Quatre chiffres non reconnus attendent le sixième', (
    tester,
  ) async {
    final session = await _open(tester, size: const Size(1280, 800));
    await tester.enterText(find.byType(TextField), 'RECEP01');
    for (final chiffre in ['4', '3', '2', '1']) {
      await tester.tap(find.text(chiffre));
      await tester.pumpAndSettle();
    }
    expect(session.attempts, isEmpty);
    for (final chiffre in ['5', '6']) {
      await tester.tap(find.text(chiffre));
      await tester.pumpAndSettle();
    }
    expect(session.attempts, [
      (code: 'RECEP01', secret: '432156', parPin: true),
    ]);
    await _close(tester);
  });

  testWidgets('Le code agent n’est pas pré-rempli, et rien ne part sans lui', (
    tester,
  ) async {
    final session = await _open(tester, size: const Size(1280, 800));
    final champ = tester.widget<TextField>(find.byType(TextField));
    expect(champ.controller!.text, isEmpty);
    expect(find.text('ADMIN01'), findsNothing);
    for (final chiffre in ['1', '2', '3', '4']) {
      await tester.tap(find.text(chiffre));
      await tester.pumpAndSettle();
    }
    expect(session.attempts, isEmpty);
    await _close(tester);
  });

  testWidgets('La transition animée reste utilisable après redimensionnement', (
    tester,
  ) async {
    await _open(tester, size: const Size(1280, 800), reducedMotion: false);
    await tester.tap(find.text('Mot de passe'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Se connecter'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(375, 667);
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.text('Se connecter'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Se connecter').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('Le mot de passe se saisit et se soumet sur téléphone', (
    tester,
  ) async {
    final session = await _open(tester, size: const Size(375, 667));
    await tester.ensureVisible(find.text('Mot de passe'));
    await tester.tap(find.text('Mot de passe'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'RECEP01');
    await tester.enterText(find.byType(TextField).last, 'mon-secret');
    await tester.ensureVisible(find.text('Se connecter'));
    await tester.tap(find.text('Se connecter'));
    await tester.pumpAndSettle();
    expect(session.attempts, [
      (code: 'RECEP01', secret: 'mon-secret', parPin: false),
    ]);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });
}
