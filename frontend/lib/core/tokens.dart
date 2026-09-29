/// Les jetons de la charte Atrium : **Nuit & mangue**.
///
/// Un bleu-nuit profond pour la structure, une mangue eclatante pour tout ce
/// qui se touche, un vert palmier pour ce qui est libre. Pense pour un hall
/// d'hotel ou la lumiere change toute la journee : clair le jour, sombre le
/// soir, selon le reglage de l'appareil.
///
/// Chaque couleur de l'interface vient d'ici. Les noms historiques
/// (`purple`, `mint`...) sont gardes pour ne pas toucher aux ecrans qui les
/// emploient ; ils designent un **role**, plus une teinte :
///
/// - `purple`      la couleur d'action principale (nuit le jour, mangue la nuit)
/// - `mint*`       l'accent mangue et ses fonds pales
/// - `white`       le papier : carte, champ, texte pose sur l'action principale
/// - `onNight`     le texte pose sur les bandeaux de nuit, clair dans les deux modes
///
/// Les valeurs se lisent dans `AtriumPalette.current`, que la racine de
/// l'application positionne selon la luminosite de l'appareil.
library;

import 'package:flutter/material.dart';

/// Une palette complete. Deux instances : `light` et `dark`.
@immutable
class AtriumPalette {
  const AtriumPalette({
    required this.brightness,
    required this.primary,
    required this.primaryPressed,
    required this.paper,
    required this.onNight,
    required this.onNightSoft,
    required this.night,
    required this.nightRaised,
    required this.nightBright,
    required this.photoTint,
    required this.accentFill,
    required this.accent,
    required this.accentBorder,
    required this.accentSoft,
    required this.accentTint,
    required this.background,
    required this.surface,
    required this.surfaceMuted,
    required this.border,
    required this.text,
    required this.textSecondary,
    required this.textOnMuted,
    required this.placeholder,
    required this.textDisabled,
    required this.success,
    required this.error,
    required this.errorTint,
    required this.warning,
    required this.tileMango,
    required this.tileMangoInk,
    required this.tilePalm,
    required this.tilePalmInk,
    required this.tileSky,
    required this.tileSkyInk,
    required this.grid,
    required this.shadow,
  });

  final Brightness brightness;
  final Color primary;
  final Color primaryPressed;
  final Color paper;
  final Color onNight;
  final Color onNightSoft;
  final Color night;
  final Color nightRaised;
  final Color nightBright;
  final Color photoTint;
  final Color accentFill;
  final Color accent;
  final Color accentBorder;
  final Color accentSoft;
  final Color accentTint;
  final Color background;
  final Color surface;
  final Color surfaceMuted;
  final Color border;
  final Color text;
  final Color textSecondary;
  final Color textOnMuted;
  final Color placeholder;
  final Color textDisabled;
  final Color success;
  final Color error;
  final Color errorTint;
  final Color warning;
  final Color tileMango;
  final Color tileMangoInk;
  final Color tilePalm;
  final Color tilePalmInk;
  final Color tileSky;
  final Color tileSkyInk;
  final Color grid;

  /// Teinte des ombres : la nuit le jour, un noir franc la nuit (une ombre
  /// bleutee sur fond bleu-nuit ne detache rien).
  final Color shadow;

  bool get isDark => brightness == Brightness.dark;

  // --- Blocs forts ---------------------------------------------------------
  //
  // Les cartes qui portent le chiffre de l'ecran (occupation, total, ticket,
  // en-tete de fiche). La nuit, un bleu-nuit plus clair que le fond ; le
  // jour, la mangue : pas de bloc bleu-nuit sur une page claire.

  /// L'encre posee sur la mangue : un brun tres sombre, chaud, jamais bleu.
  static const _encreMangue = Color(0xFF2B1B04);

  Color get hero => isDark ? nightRaised : const Color(0xFFFFB020);
  Color get heroTop => isDark ? nightBright : const Color(0xFFFFCB5C);
  Color get onHero => isDark ? onNight : _encreMangue;
  Color get onHeroSoft =>
      isDark ? onNightSoft : _encreMangue.withValues(alpha: 0.72);

  /// Le chiffre mis en avant sur un bloc fort : mangue la nuit, encre le
  /// jour (de la mangue sur de la mangue ne se lirait pas).
  Color get heroAccent => isDark ? accent : _encreMangue;

  /// Le texte et les icones poses sur un aplat mangue.
  Color get onAccent => isDark ? night : _encreMangue;

  /// L'aplat d'un choix retenu (filtre, bascule, periode).
  Color get selected => isDark ? nightBright : const Color(0xFFFFB020);
  Color get onSelected => isDark ? onNight : _encreMangue;

  /// Le jour : papier froid legerement bleute, structure bleu-nuit, mangue
  /// assombrie d'un cran pour garder 3:1 sur blanc.
  static const light = AtriumPalette(
    brightness: Brightness.light,
    // Le jour, l'action est mangue, comme la nuit : pas de bleu-nuit en aplat.
    primary: Color(0xFFFFB020),
    primaryPressed: Color(0xFFF08A00),
    paper: Color(0xFFFFFFFF),
    onNight: Color(0xFFFBF6EC),
    onNightSoft: Color(0xFFC9CEE6),
    night: Color(0xFF0A0F2E),
    nightRaised: Color(0xFF141B47),
    nightBright: Color(0xFF263178),
    photoTint: Color(0xFFD7DBF3),
    accentFill: Color(0xFFFFD98A),
    // Assez sombre pour se lire sur blanc (contraste ~4,5:1) : la mangue
    // franche reste pour les aplats (`hero`), pas pour le texte.
    accent: Color(0xFFB45F00),
    accentBorder: Color(0xFFF5CF84),
    accentSoft: Color(0xFFFFE6B3),
    accentTint: Color(0xFFFFF6E2),
    background: Color(0xFFEEF0F7),
    surface: Color(0xFFF8F9FC),
    surfaceMuted: Color(0xFFE6E9F3),
    border: Color(0xFFD7DCEB),
    text: Color(0xFF0D1330),
    textSecondary: Color(0xFF4F587A),
    textOnMuted: Color(0xFF283052),
    placeholder: Color(0xFFA3AAC4),
    textDisabled: Color(0xFF8D94AF),
    success: Color(0xFF0B8A5F),
    error: Color(0xFFD93A33),
    errorTint: Color(0xFFFDECEA),
    warning: Color(0xFFB86E00),
    tileMango: Color(0xFFFFEBC4),
    tileMangoInk: Color(0xFF9A5A00),
    tilePalm: Color(0xFFD3F4E4),
    tilePalmInk: Color(0xFF0B7650),
    tileSky: Color(0xFFDCE5FF),
    tileSkyInk: Color(0xFF2B4DC4),
    grid: Color(0xFFE2E6F1),
    shadow: Color(0xFF0D1330),
  );

  /// La nuit : bleu-nuit profond, la mangue devient la couleur d'action et
  /// le papier devient une carte a peine plus claire que le fond.
  static const dark = AtriumPalette(
    brightness: Brightness.dark,
    primary: Color(0xFFFFB020),
    primaryPressed: Color(0xFFF08A00),
    paper: Color(0xFF141B3E),
    onNight: Color(0xFFFBF6EC),
    onNightSoft: Color(0xFFB5BCDC),
    night: Color(0xFF05081A),
    nightRaised: Color(0xFF0E1433),
    nightBright: Color(0xFF232C6B),
    photoTint: Color(0xFF7F88C0),
    accentFill: Color(0xFF3D2D0B),
    accent: Color(0xFFFFB020),
    accentBorder: Color(0xFF7A5610),
    accentSoft: Color(0xFF45320C),
    accentTint: Color(0xFF221B0E),
    background: Color(0xFF080C20),
    surface: Color(0xFF0E1433),
    surfaceMuted: Color(0xFF1A2250),
    border: Color(0xFF263064),
    text: Color(0xFFF3EEE4),
    textSecondary: Color(0xFFA6AECD),
    textOnMuted: Color(0xFFD6DAEE),
    placeholder: Color(0xFF5E6892),
    textDisabled: Color(0xFF5E6892),
    success: Color(0xFF3DDC97),
    error: Color(0xFFFF6B63),
    errorTint: Color(0xFF3A1719),
    warning: Color(0xFFFFB020),
    tileMango: Color(0xFF3A2A0B),
    tileMangoInk: Color(0xFFFFC65A),
    tilePalm: Color(0xFF0E3326),
    tilePalmInk: Color(0xFF52E3A6),
    tileSky: Color(0xFF16245A),
    tileSkyInk: Color(0xFF93B0FF),
    grid: Color(0xFF1D2552),
    shadow: Color(0xFF000000),
  );

  /// La palette en vigueur, positionnee par la racine de l'application.
  static AtriumPalette current = light;
}

AtriumPalette get _p => AtriumPalette.current;

abstract final class AtriumColors {
  static Color get purple => _p.primary;
  static Color get mint => _p.accentFill;
  static Color get ink => _p.text;
  static Color get white => _p.paper;

  /// Texte pose sur un bandeau de nuit : clair dans les deux modes.
  static Color get onNight => _p.onNight;

  static Color get purpleNight => _p.night;
  static Color get purpleDeep => _p.primaryPressed;
  static Color get purpleBright => _p.nightBright;
  static Color get photoTint => _p.photoTint;
  static Color get onPurpleSoft => _p.onNightSoft;

  static Color get mintStrong => _p.accent;
  static Color get mintBorder => _p.accentBorder;
  static Color get mintSoft => _p.accentSoft;
  static Color get mintTint => _p.accentTint;

  static Color get background => _p.background;
  static Color get surface => _p.surface;
  static Color get surfaceMuted => _p.surfaceMuted;
  static Color get border => _p.border;
  static Color get textPrimary => _p.text;
  static Color get textSecondary => _p.textSecondary;
  static Color get textOnMuted => _p.textOnMuted;
  static Color get placeholder => _p.placeholder;
  static Color get textDisabled => _p.textDisabled;

  static Color get success => _p.success;
  static Color get error => _p.error;
  static Color get errorTint => _p.errorTint;
  static Color get warning => _p.warning;
}

/// Les couleurs du tableau de bord. La barre laterale reste de nuit dans les
/// deux modes : c'est le repere fixe de l'application.
abstract final class AtriumDashColors {
  static Color get sidebar => _p.night;
  static Color get sidebarRaised => _p.nightRaised;
  static Color get sidebarText => _p.onNight;
  static Color get sidebarMuted => _p.onNightSoft;
  static const sidebarDivider = Color(0x1FFFFFFF);

  /// L'entree active : une pastille de nuit claire, cerclee de mangue.
  static Color get activeStart => _p.nightBright;
  static Color get activeEnd => _p.nightRaised;
  static const activeBorder = Color(0xFFFFB020);

  static Color get title => _p.text;
  static Color get page => _p.background;
  static Color get headerLight => _p.surface;
  static Color get card => _p.paper;
  static Color get cardBorder => _p.border;
  static Color get control => _p.surfaceMuted;

  static Color get tileMint => _p.tileMango;
  static Color get tileMintInk => _p.tileMangoInk;
  static Color get tileLavender => _p.tilePalm;
  static Color get tileLavenderInk => _p.tilePalmInk;
  static Color get tileBlue => _p.tileSky;
  static Color get tileBlueInk => _p.tileSkyInk;

  static Color get chipMint => _p.tilePalm;
  static Color get chipMintInk => _p.tilePalmInk;

  static Color get grid => _p.grid;
  static const wave = Color(0xFFFFB020);
}

/// Les couleurs des graphiques, lisibles sur les deux fonds et distinctes
/// pour les trois formes de daltonisme (mangue / bleu / palmier / rose).
abstract final class AtriumChartColors {
  static const current = Color(0xFFF2A20C);
  static const previous = Color(0xFF7D88D6);
  static const arrivals = Color(0xFF10B981);
  static const departures = Color(0xFF5B7CFA);
  static const types = [
    Color(0xFFF2A20C),
    Color(0xFF10B981),
    Color(0xFF5B7CFA),
    Color(0xFFE0557A),
  ];
  static const other = Color(0xFF8A92AE);
}

abstract final class AtriumRadii {
  static const double sm = 8;
  static const double md = 14;
  static const double lg = 16;
  static const double xl = 24;
}

/// L'echelle d'espacement, par pas de 4.
abstract final class AtriumSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Les ombres, teintees de bleu-nuit plutot que de gris neutre : sur un fond
/// pale, une ombre grise salit la surface au lieu de la detacher.
abstract final class AtriumShadows {
  /// La carte de connexion : large et diffuse, elle flotte sur le bandeau.
  static const card = [
    BoxShadow(color: Color(0x0F0D1330), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x1F0D1330),
      blurRadius: 48,
      spreadRadius: -8,
      offset: Offset(0, 20),
    ),
  ];

  /// Touche du pave, case du PIN : un relief de bouton physique, a peine.
  static const key = [
    BoxShadow(color: Color(0x0D0D1330), blurRadius: 1, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x140D1330),
      blurRadius: 10,
      spreadRadius: -2,
      offset: Offset(0, 4),
    ),
  ];

  /// L'embleme sur le bandeau sombre.
  static const emblem = [
    BoxShadow(
      color: Color(0x6605081A),
      blurRadius: 24,
      spreadRadius: -4,
      offset: Offset(0, 10),
    ),
  ];

  /// Carte du tableau de bord : un voile a peine perceptible, la bordure
  /// fait le travail.
  static const soft = [
    BoxShadow(color: Color(0x080D1330), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x0D0D1330),
      blurRadius: 24,
      spreadRadius: -6,
      offset: Offset(0, 10),
    ),
  ];

  /// Halo autour d'un element actif (case courante, option retenue).
  static List<BoxShadow> glow(Color couleur, {double force = 0.45}) => [
    BoxShadow(
      color: couleur.withValues(alpha: force),
      blurRadius: 12,
      spreadRadius: 1,
    ),
  ];

  /// Halo de focus autour d'un champ.
  static List<BoxShadow> focusRing(Color couleur) => [
    BoxShadow(color: couleur.withValues(alpha: 0.28), spreadRadius: 4),
  ];
}

/// Les durees et courbes des animations.
///
/// Toutes repondent a un geste, sauf l'entree de la page de connexion. Et
/// toutes tombent a zero quand le systeme demande de reduire les animations.
abstract final class AtriumMotion {
  /// Retour d'une touche pressee : doit suivre le doigt.
  static const fast = Duration(milliseconds: 120);

  /// Changement d'etat d'un controle (selecteur, focus).
  static const base = Duration(milliseconds: 240);

  /// Changement de contenu (PIN vers mot de passe).
  static const slow = Duration(milliseconds: 320);

  static const standard = Curves.easeOutCubic;

  /// Duree effective, nulle si l'utilisateur a coupe les animations.
  static Duration of(BuildContext context, Duration duree) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duree;
}

/// La police de la refonte, embarquee dans `assets/fonts/jakarta`.
const atriumFontFamily = 'PlusJakartaSans';

/// Chiffres a chasse fixe : un code ou un montant ne doit pas bouger
/// horizontalement pendant qu'on le tape.
const tabularFigures = [FontFeature.tabularFigures()];
