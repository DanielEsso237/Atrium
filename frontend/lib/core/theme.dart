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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
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
