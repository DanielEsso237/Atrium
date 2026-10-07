/// Theme tactile d'Atrium (cahier des charges, paragraphe 6.4), charte
/// **Livree** (bleu royal et blanc, reprise de ChronoFS), en clair et en
/// sombre.
///
/// Trois contraintes gouvernent tout ce fichier :
///
/// - **Ecrans de 10 a 13 pouces**, tenus a bout de bras ou poses au comptoir,
///   mais aussi telephone, PC et navigateur.
/// - **Doigts, pas souris** : aucune cible cliquable en dessous de 48 dp.
/// - **Lumiere d'accueil et de couloir** : contrastes eleves, car un ecran
///   tactile lu en biais perd beaucoup plus qu'un ecran de bureau.
///
/// Un seul theme pour toute l'application, construit depuis une palette
/// (`AtriumPalette.light` / `.dark`). Les composants Material des ecrans plus
/// anciens (boutons, champs, dialogues, onglets) prennent ainsi la charte
/// sans qu'on ait a les reecrire.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Cote minimal d'une cible tactile, en pixels logiques.
const double cibleTactile = 48;

/// Rayon des cartes et des gros boutons.
const double rayonCarte = 16;

/// Couleurs des cinq etats de chambre du paragraphe 5.2.
///
/// Elles vivent ici et nulle part ailleurs : la pastille du plan, la legende
/// et la fiche de chambre doivent etre d'accord, sinon l'ecran ment.
///
/// Elles pointent vers `AtriumRoomColors`, la palette de la charte : les
/// ecrans pas encore refondus (le menage) parlent ainsi deja comme le plan.
abstract final class CouleursEtat {
  static const disponible = AtriumRoomColors.available;
  static const occupee = AtriumRoomColors.occupied;
  static const reservee = AtriumRoomColors.reserved;
  static const nettoyage = AtriumRoomColors.cleaning;
  static const maintenance = AtriumRoomColors.outOfOrder;
}

/// Le theme en vigueur, construit depuis la palette courante.
///
/// Garde pour les appels existants ; `atriumTheme(palette)` est la forme
/// explicite.
ThemeData themeAtrium() => atriumTheme(AtriumPalette.current);

/// Meme theme : la refonte a reuni l'ancien theme et celui de la connexion.
ThemeData atriumBrandTheme() => atriumTheme(AtriumPalette.current);

ThemeData atriumTheme(AtriumPalette p) {
  // Du blanc sur le bleu, dans les deux modes : le bleu de nuit est assez
  // sature pour le porter (5:1).
  const onPrimary = Colors.white;
  final schema = ColorScheme(
    brightness: p.brightness,
    primary: p.primary,
    onPrimary: onPrimary,
    primaryContainer: p.accentSoft,
    onPrimaryContainer: p.text,
    secondary: p.accent,
    onSecondary: p.isDark ? p.night : p.text,
    secondaryContainer: p.accentTint,
    onSecondaryContainer: p.text,
    tertiary: p.success,
    onTertiary: p.paper,
    error: p.error,
    onError: p.isDark ? p.night : Colors.white,
    errorContainer: p.errorTint,
    onErrorContainer: p.error,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.textSecondary,
    surfaceContainerLowest: p.paper,
    surfaceContainerLow: p.paper,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surfaceMuted,
    surfaceContainerHighest: p.surfaceMuted,
    outline: p.border,
    outlineVariant: p.border,
    shadow: p.shadow,
    scrim: p.night,
    inverseSurface: p.isDark ? p.onNight : p.night,
    onInverseSurface: p.isDark ? p.night : p.onNight,
    inversePrimary: p.accent,
  );

  final texte = p.text;
  final radius12 = BorderRadius.circular(AtriumRadii.md);
  const formeBouton = WidgetStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(AtriumRadii.md)),
    ),
  );

  TextStyle ts(double size, FontWeight w, {Color? color, double? height}) =>
      TextStyle(
        fontFamily: atriumFontFamily,
        fontSize: size,
        fontWeight: w,
        height: height,
        color: color ?? texte,
      );

  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: schema,
    fontFamily: atriumFontFamily,
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    visualDensity: VisualDensity.comfortable,

    // Material reduit par defaut les cibles a 40 dp sur certaines plateformes.
    // Sur une tablette de reception, c'est deux fois trop petit.
    materialTapTargetSize: MaterialTapTargetSize.padded,
    splashFactory: InkSparkle.splashFactory,

    // 16 est le plancher de lisibilite a bout de bras ; le corps de texte monte
    // a 17 parce que l'essentiel de ce que lit un receptionniste est du texte
    // dense (noms, numeros de chambre, montants). Les titres tiennent par le
    // poids et un interlettrage serre, pas par la taille.
    textTheme: TextTheme(
      displaySmall: ts(
        36,
        FontWeight.w700,
        height: 1.1,
      ).copyWith(letterSpacing: -0.8),
      headlineMedium: ts(
        28,
        FontWeight.w700,
        height: 1.15,
      ).copyWith(letterSpacing: -0.6),
      headlineSmall: ts(
        22,
        FontWeight.w700,
        height: 1.2,
      ).copyWith(letterSpacing: -0.3),
      titleLarge: ts(20, FontWeight.w700).copyWith(letterSpacing: -0.2),
      titleMedium: ts(17, FontWeight.w600),
      titleSmall: ts(15, FontWeight.w600),
      bodyLarge: ts(17, FontWeight.w400, height: 1.45),
      bodyMedium: ts(16, FontWeight.w400, height: 1.45),
      bodySmall: ts(14, FontWeight.w400, height: 1.4, color: p.textSecondary),
      labelLarge: ts(17, FontWeight.w600),
      labelMedium: ts(15, FontWeight.w700),
      labelSmall: ts(13, FontWeight.w600, color: p.textSecondary),
    ),

    iconTheme: IconThemeData(color: p.textSecondary),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),

    cardTheme: CardThemeData(
      elevation: 0,
      color: p.paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AtriumRadii.lg),
        side: BorderSide(color: p.border),
      ),
      margin: EdgeInsets.zero,
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(cibleTactile * 2, cibleTactile + 4),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: AtriumSpacing.lg),
        ),
        shape: formeBouton,
        textStyle: WidgetStatePropertyAll(ts(16, FontWeight.w600)),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStateProperty.resolveWith((etats) {
          if (etats.contains(WidgetState.disabled)) return p.surfaceMuted;
          if (etats.contains(WidgetState.pressed)) return p.primaryPressed;
          return p.primary;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
          (etats) =>
              etats.contains(WidgetState.disabled) ? p.textDisabled : onPrimary,
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (etats) =>
              etats.contains(WidgetState.hovered) ||
                  etats.contains(WidgetState.focused)
              ? Colors.white.withValues(alpha: 0.10)
              : null,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(cibleTactile * 2, cibleTactile + 4),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: AtriumSpacing.lg),
        ),
        shape: formeBouton,
        textStyle: WidgetStatePropertyAll(ts(16, FontWeight.w600)),
        foregroundColor: WidgetStatePropertyAll(p.text),
        backgroundColor: WidgetStatePropertyAll(p.paper),
        side: WidgetStateProperty.resolveWith(
          (etats) => BorderSide(
            color:
                etats.contains(WidgetState.focused) ||
                    etats.contains(WidgetState.hovered)
                ? p.accent.withValues(alpha: 0.5)
                : p.border,
            width: 1,
          ),
        ),
        overlayColor: WidgetStatePropertyAll(p.accent.withValues(alpha: 0.06)),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(cibleTactile, cibleTactile),
        ),
        textStyle: WidgetStatePropertyAll(ts(15.5, FontWeight.w600)),
        foregroundColor: WidgetStatePropertyAll(p.accent),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: AtriumSpacing.sm),
        ),
        shape: formeBouton,
        overlayColor: WidgetStatePropertyAll(p.accent.withValues(alpha: 0.08)),
      ),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.primary,
      foregroundColor: onPrimary,
      elevation: 1,
      highlightElevation: 2,
      extendedTextStyle: ts(16, FontWeight.w600, color: onPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AtriumRadii.lg),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.paper,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      labelStyle: ts(16, FontWeight.w500, color: p.textSecondary),
      floatingLabelStyle: ts(15, FontWeight.w600, color: p.accent),
      hintStyle: ts(16, FontWeight.w400, color: p.placeholder),
      prefixIconColor: p.textSecondary,
      suffixIconColor: p.textSecondary,
      border: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.accent, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.error, width: 1.6),
      ),
    ),

    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 72,
      titleTextStyle: ts(20, FontWeight.w700).copyWith(letterSpacing: -0.2),
      iconTheme: IconThemeData(color: p.text),
    ),

    tabBarTheme: TabBarThemeData(
      labelColor: p.text,
      unselectedLabelColor: p.textSecondary,
      labelStyle: ts(16, FontWeight.w600),
      unselectedLabelStyle: ts(16, FontWeight.w500),
      indicatorColor: p.accent,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: p.border,
      overlayColor: WidgetStatePropertyAll(p.accent.withValues(alpha: 0.10)),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: p.paper,
      selectedColor: p.selected,
      disabledColor: p.surfaceMuted,
      side: BorderSide(color: p.border),
      labelStyle: ts(15, FontWeight.w600),
      secondaryLabelStyle: ts(15, FontWeight.w700),
      checkmarkColor: p.onSelected,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AtriumRadii.md - 2),
      ),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, cibleTactile)),
        textStyle: WidgetStatePropertyAll(ts(15, FontWeight.w600)),
        shape: formeBouton,
        backgroundColor: WidgetStateProperty.resolveWith(
          (etats) =>
              etats.contains(WidgetState.selected) ? p.selected : p.paper,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (etats) => etats.contains(WidgetState.selected) ? onPrimary : p.text,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: p.border)),
      ),
    ),

    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.night,
      indicatorColor: p.nightBright,
      selectedIconTheme: IconThemeData(color: p.onNight),
      unselectedIconTheme: IconThemeData(color: p.onNightSoft),
      selectedLabelTextStyle: ts(13, FontWeight.w700, color: p.onNight),
      unselectedLabelTextStyle: ts(13, FontWeight.w500, color: p.onNightSoft),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.night,
      indicatorColor: p.nightBright,
      height: 72,
      iconTheme: WidgetStateProperty.resolveWith(
        (etats) => IconThemeData(
          color: etats.contains(WidgetState.selected)
              ? p.onNight
              : p.onNightSoft,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (etats) => ts(
          12,
          etats.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: etats.contains(WidgetState.selected)
              ? p.onNight
              : p.onNightSoft,
        ),
      ),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: p.textSecondary,
      textColor: p.text,
      titleTextStyle: ts(16, FontWeight.w600),
      subtitleTextStyle: ts(14, FontWeight.w400, color: p.textSecondary),
      selectedColor: p.text,
      selectedTileColor: p.accentTint,
      shape: RoundedRectangleBorder(borderRadius: radius12),
      minVerticalPadding: 12,
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shadowColor: p.shadow.withValues(alpha: p.isDark ? 0.6 : 0.14),
      barrierColor: p.isDark
          ? Colors.black.withValues(alpha: 0.6)
          : const Color(0xFF0B1636).withValues(alpha: 0.38),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AtriumRadii.xl),
        side: BorderSide(
          color: p.isDark
              ? Colors.white.withValues(alpha: 0.08)
              : p.border.withValues(alpha: 0.6),
        ),
      ),
      titleTextStyle: ts(20, FontWeight.w700).copyWith(letterSpacing: -0.2),
      contentTextStyle: ts(16, FontWeight.w400, height: 1.45),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.border,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: p.paper,
      surfaceTintColor: Colors.transparent,
      textStyle: ts(16, FontWeight.w500),
      shape: RoundedRectangleBorder(
        borderRadius: radius12,
        side: BorderSide(color: p.border),
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.isDark ? p.onNight : p.text,
        borderRadius: BorderRadius.circular(AtriumRadii.sm),
      ),
      textStyle: ts(13, FontWeight.w600, color: p.isDark ? p.night : p.paper),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.isDark ? p.onNight : p.text,
      contentTextStyle: ts(
        16,
        FontWeight.w500,
        color: p.isDark ? p.night : p.paper,
      ),
      // Le bleu royal ne se lit pas sur l'encre de la barre : un bleu pale.
      actionTextColor: p.isDark ? p.nightBright : const Color(0xFFA9BEFF),
      shape: RoundedRectangleBorder(borderRadius: radius12),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.surfaceMuted,
      circularTrackColor: Colors.transparent,
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (etats) => etats.contains(WidgetState.selected) ? p.onAccent : p.paper,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (etats) =>
            etats.contains(WidgetState.selected) ? p.accent : p.surfaceMuted,
      ),
      trackOutlineColor: WidgetStatePropertyAll(p.border),
    ),

    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (etats) => etats.contains(WidgetState.selected) ? p.accent : null,
      ),
      checkColor: WidgetStatePropertyAll(p.onAccent),
      side: BorderSide(color: p.textSecondary, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),

    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (etats) =>
            etats.contains(WidgetState.selected) ? p.accent : p.textSecondary,
      ),
    ),

    datePickerTheme: DatePickerThemeData(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: p.hero,
      headerForegroundColor: p.onHero,
      todayBorder: BorderSide(color: p.accent, width: 1.5),
      rangeSelectionBackgroundColor: p.accentSoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AtriumRadii.xl),
      ),
    ),

    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: 0.22),
      selectionHandleColor: p.accent,
    ),

    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(
        p.textSecondary.withValues(alpha: 0.35),
      ),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(6),
    ),

    // Transitions de page : un fondu remonte court, identique sur toutes les
    // plateformes. Une tablette de comptoir ne doit pas donner le mal de mer.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
