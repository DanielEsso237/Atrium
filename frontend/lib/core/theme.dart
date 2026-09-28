/// Theme tactile d'Atrium (cahier des charges, paragraphe 6.4).
///
/// Trois contraintes gouvernent tout ce fichier :
///
/// - **Ecrans de 10 a 13 pouces**, tenus a bout de bras ou poses au comptoir.
/// - **Doigts, pas souris** : aucune cible cliquable en dessous de 48 dp, la
///   taille qu'un index adulte atteint sans viser.
/// - **Lumiere d'accueil et de couloir** : contrastes eleves, car un ecran
///   tactile lu en biais perd beaucoup plus qu'un ecran de bureau.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Cote minimal d'une cible tactile, en pixels logiques.
const double cibleTactile = 48;

/// Rayon des cartes et des gros boutons du tableau de bord.
const double rayonCarte = 16;

/// Couleurs des cinq etats de chambre du paragraphe 5.2.
///
/// Elles vivent ici et nulle part ailleurs : la pastille du plan, la legende
/// et la fiche de chambre doivent etre d'accord, sinon l'ecran ment.
abstract final class CouleursEtat {
  static const disponible = Color(0xFF2E7D32); // vert
  static const occupee = Color(0xFFC62828); // rouge
  static const reservee = Color(0xFFF9A825); // jaune
  static const nettoyage = Color(0xFF1565C0); // bleu
  static const maintenance = Color(0xFF424242); // gris fonce
}

const _graine = Color(0xFF00695C);

ThemeData themeAtrium() {
  final schema = ColorScheme.fromSeed(
    seedColor: _graine,
    brightness: Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: schema,
    scaffoldBackgroundColor: const Color(0xFFF4F6F8),
    visualDensity: VisualDensity.comfortable,

    // Material reduit par defaut les cibles a 40 dp sur certaines plateformes.
    // Sur une tablette de reception, c'est deux fois trop petit.
    materialTapTargetSize: MaterialTapTargetSize.padded,

    // 16 est le plancher de lisibilite a bout de bras ; le corps de texte monte
    // a 17 parce que l'essentiel de ce que lit un receptionniste est du texte
    // dense (noms, numeros de chambre, montants).
    textTheme: const TextTheme(
      displaySmall: TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
      headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
      headlineSmall: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 17),
      bodyMedium: TextStyle(fontSize: 16),
      labelLarge: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
    ),

    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rayonCarte),
        side: BorderSide(color: schema.outlineVariant),
      ),
      margin: EdgeInsets.zero,
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(cibleTactile * 2, cibleTactile + 8),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(cibleTactile * 2, cibleTactile + 8),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: schema.outline),
      ),
      labelStyle: const TextStyle(fontSize: 17),
    ),

    appBarTheme: AppBarTheme(
      backgroundColor: schema.surface,
      foregroundColor: schema.onSurface,
      elevation: 0,
      centerTitle: false,
      toolbarHeight: 72,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: schema.onSurface,
      ),
    ),

    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      contentTextStyle: TextStyle(fontSize: 17),
    ),
  );
}

/// Le theme de la nouvelle charte (violet profond, menthe, anthracite).
///
/// Il vit a cote de `themeAtrium()` le temps de la refonte : les ecrans
/// refondus l'appliquent a leur sous-arbre, les autres gardent l'ancien. Un
/// basculement global aurait repeint d'un coup des ecrans dont la mise en page
/// n'a pas ete revue pour ces couleurs. Quand le dernier ecran sera passe,
/// `main.dart` l'adoptera et `themeAtrium()` disparaitra.
ThemeData atriumBrandTheme() {
  final schema =
      ColorScheme.fromSeed(
        seedColor: AtriumColors.purple,
        brightness: Brightness.light,
      ).copyWith(
        primary: AtriumColors.purple,
        onPrimary: AtriumColors.white,
        secondary: AtriumColors.mintStrong,
        onSecondary: AtriumColors.ink,
        surface: AtriumColors.surface,
        onSurface: AtriumColors.textPrimary,
        onSurfaceVariant: AtriumColors.textSecondary,
        outline: AtriumColors.border,
        outlineVariant: AtriumColors.border,
        error: AtriumColors.error,
        onError: AtriumColors.white,
      );

  const texte = AtriumColors.textPrimary;

  return ThemeData(
    useMaterial3: true,
    colorScheme: schema,
    fontFamily: atriumFontFamily,
    scaffoldBackgroundColor: AtriumColors.background,
    visualDensity: VisualDensity.comfortable,
    materialTapTargetSize: MaterialTapTargetSize.padded,

    // Meme plancher que l'ancien theme (16 a bout de bras) pour le corps de
    // texte ; les titres tiennent par le poids plus que par la taille.
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w600,
        height: 1.1,
        color: AtriumColors.white,
      ),
      headlineSmall: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: texte,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: texte,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: texte,
      ),
      bodyLarge: TextStyle(fontSize: 17, height: 1.45, color: texte),
      bodyMedium: TextStyle(fontSize: 16, height: 1.45, color: texte),
      bodySmall: TextStyle(
        fontSize: 14,
        height: 1.4,
        color: AtriumColors.textSecondary,
      ),
      labelLarge: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      labelMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: texte,
      ),
    ),

    cardTheme: CardThemeData(
      elevation: 0,
      color: AtriumColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AtriumRadii.xl),
        side: const BorderSide(color: AtriumColors.border),
      ),
      margin: EdgeInsets.zero,
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(cibleTactile * 2, cibleTactile + 8),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: AtriumSpacing.xl),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AtriumRadii.md),
          ),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStateProperty.resolveWith((etats) {
          if (etats.contains(WidgetState.disabled)) {
            return AtriumColors.textDisabled;
          }
          if (etats.contains(WidgetState.pressed)) {
            return AtriumColors.purpleDeep;
          }
          return AtriumColors.purple;
        }),
        foregroundColor: const WidgetStatePropertyAll(AtriumColors.white),
        overlayColor: WidgetStateProperty.resolveWith(
          (etats) =>
              etats.contains(WidgetState.hovered) ||
                  etats.contains(WidgetState.focused)
              ? AtriumColors.mint.withValues(alpha: 0.10)
              : null,
        ),
      ),
    ),

    iconTheme: const IconThemeData(color: AtriumColors.textSecondary),

    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AtriumColors.purple,
      contentTextStyle: TextStyle(
        fontFamily: atriumFontFamily,
        fontSize: 16,
        color: AtriumColors.white,
      ),
    ),

    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AtriumColors.purple,
      selectionColor: AtriumColors.mintStrong.withValues(alpha: 0.35),
      selectionHandleColor: AtriumColors.purple,
    ),
  );
}
