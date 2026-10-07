/// Les jetons de la charte Atrium : **Livree**, reprise de ChronoFS.
///
/// Le bleu royal d'une livree d'hotel pour la structure et l'action, le
/// blanc du linge pour les surfaces, une seule touche de laiton -- comme un
/// bouton d'uniforme -- pour ce qui doit accrocher l'oeil (le montant du, le
/// logo). Clair le jour, sombre le soir, selon le reglage de l'appareil.
///
/// Chaque couleur de l'interface vient d'ici. Les noms historiques
/// (`purple`, `mint`...) sont gardes pour ne pas toucher aux ecrans qui les
/// emploient ; ils designent un **role**, plus une teinte :
///
/// - `purple`      la couleur d'action principale (bleu royal)
/// - `mint*`       l'accent bleu et ses fonds pales
/// - `white`       le papier : carte, champ, texte pose sur l'action principale
/// - `onNight`     le texte pose sur un aplat bleu, clair dans les deux modes
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
  // en-tete de fiche) : un aplat bleu royal, le texte en blanc. La nuit, un
  // bleu plus sourd, pour ne pas eblouir dans un hall eteint.

  /// Le laiton : la seule couleur chaude de la charte, rare par principe.
  static const brass = Color(0xFFC8A15A);

  /// Le laiton eclairci, lisible sur le bleu royal (6,6:1).
  static const brassOnBlue = Color(0xFFE8CB8E);

  Color get hero => isDark ? const Color(0xFF16224A) : primary;
  Color get heroTop =>
      isDark ? const Color(0xFF1C2B5C) : const Color(0xFF1E45A0);
  Color get onHero => const Color(0xFFFFFFFF);
  Color get onHeroSoft =>
      isDark ? const Color(0xFFB4C2EA) : const Color(0xFFC3CFEF);

  /// Le chiffre mis en avant sur un bloc fort -- ce qui reste a encaisser,
  /// le total a payer : en laiton, la seule touche chaude de l'ecran.
  Color get heroAccent => brassOnBlue;

  /// Le texte et les icones poses sur un aplat d'accent.
  Color get onAccent => isDark ? night : const Color(0xFFFFFFFF);

  /// L'aplat d'un choix retenu (filtre, bascule, periode).
  Color get selected => isDark ? const Color(0xFF2A4BB0) : primary;
  Color get onSelected => const Color(0xFFFFFFFF);

  /// Le jour : papier blanc sur un fond gris-bleu tres pale, structure et
  /// action en bleu royal.
  static const light = AtriumPalette(
    brightness: Brightness.light,
    primary: Color(0xFF143894),
    primaryPressed: Color(0xFF0F2C78),
    paper: Color(0xFFFFFFFF),
    onNight: Color(0xFFFFFFFF),
    onNightSoft: Color(0xFFC3CFEF),
    night: Color(0xFF102A73),
    nightRaised: Color(0xFF1A3C9A),
    nightBright: Color(0xFF2A4BB0),
    photoTint: Color(0xFFDCE4F8),
    accentFill: Color(0xFFDCE7FF),
    // Le bleu royal lui-meme : 10:1 sur blanc, il sert aussi bien au texte
    // qu'aux aplats.
    accent: Color(0xFF143894),
    accentBorder: Color(0xFFC9D6F2),
    accentSoft: Color(0xFFE3EAFA),
    accentTint: Color(0xFFF2F5FE),
    background: Color(0xFFF4F6FB),
    surface: Color(0xFFF9FAFD),
    surfaceMuted: Color(0xFFEDF0F7),
    border: Color(0xFFE1E6F0),
    text: Color(0xFF1C2333),
    textSecondary: Color(0xFF5E6880),
    textOnMuted: Color(0xFF2E3750),
    placeholder: Color(0xFF98A1B5),
    textDisabled: Color(0xFF8F98AD),
    success: Color(0xFF0B7F57),
    error: Color(0xFFD2423B),
    errorTint: Color(0xFFFDEDEC),
    warning: Color(0xFFA0650C),
    tileMango: Color(0xFFE8EEFC),
    tileMangoInk: Color(0xFF143894),
    tilePalm: Color(0xFFDFF3EB),
    tilePalmInk: Color(0xFF0B7650),
    tileSky: Color(0xFFF6EEDD),
    tileSkyInk: Color(0xFF7D5F27),
    grid: Color(0xFFE7EBF3),
    shadow: Color(0xFF14244F),
  );

  /// La nuit : un bleu d'encre, l'action en bleu vif, le papier devient une
  /// carte a peine plus claire que le fond.
  static const dark = AtriumPalette(
    brightness: Brightness.dark,
    primary: Color(0xFF3F66DB),
    primaryPressed: Color(0xFF3457C2),
    paper: Color(0xFF141B31),
    onNight: Color(0xFFF3F6FF),
    onNightSoft: Color(0xFFA9B6DA),
    night: Color(0xFF0A1028),
    nightRaised: Color(0xFF121A3A),
    nightBright: Color(0xFF22356F),
    photoTint: Color(0xFF7F8FC4),
    accentFill: Color(0xFF1E2E5E),
    accent: Color(0xFF8FA8FF),
    accentBorder: Color(0xFF34477F),
    accentSoft: Color(0xFF1D2A55),
    accentTint: Color(0xFF151F40),
    background: Color(0xFF0A0E1C),
    surface: Color(0xFF0F1528),
    surfaceMuted: Color(0xFF19213B),
    border: Color(0xFF252F4D),
    text: Color(0xFFE9EDF7),
    textSecondary: Color(0xFFA0AAC2),
    textOnMuted: Color(0xFFD3D9EA),
    placeholder: Color(0xFF5F6A8A),
    textDisabled: Color(0xFF5F6A8A),
    success: Color(0xFF3DD598),
    error: Color(0xFFFF6B63),
    errorTint: Color(0xFF3A1719),
    warning: Color(0xFFF0B44C),
    tileMango: Color(0xFF1C2A57),
    tileMangoInk: Color(0xFF9DB4FF),
    tilePalm: Color(0xFF0E3326),
    tilePalmInk: Color(0xFF52E3A6),
    tileSky: Color(0xFF33290F),
    tileSkyInk: Color(0xFFE8CB8E),
    grid: Color(0xFF1B2340),
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

/// Les couleurs du tableau de bord. La barre laterale reste bleue dans les
/// deux modes : c'est le repere fixe de l'application.
abstract final class AtriumDashColors {
  static Color get sidebar => _p.night;
  static Color get sidebarRaised => _p.nightRaised;
  static Color get sidebarText => _p.onNight;
  static Color get sidebarMuted => _p.onNightSoft;
  static const sidebarDivider = Color(0x1FFFFFFF);

  /// L'entree active : une pastille bleue claire, cerclee de laiton.
  static Color get activeStart => _p.nightBright;
  static Color get activeEnd => _p.nightRaised;
  static const activeBorder = AtriumPalette.brass;

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
  static Color get wave => _p.primary;
}

/// Les cinq etats d'une chambre (cahier des charges, paragraphe 5.2) : libre
/// en vert, occupee en rouge, reservee en jaune, en nettoyage en bleu, hors
/// service en gris.
///
/// Les teintes du cahier des charges, raffinees pour la charte et passees au
/// validateur dataviz. Le vert tire vers l'eau : c'est ce qui le garde
/// distinct du rouge pour un lecteur daltonien (ecart de 12 contre 5 pour un
/// vert franc). La couleur n'est
/// jamais seule : chaque etat porte aussi son libelle et son icone.
///
/// Trois nuances par etat : la couleur pleine (le voyant, les barres), un
/// fond pale (les pastilles) et une encre lisible sur ce fond (le libelle).
abstract final class AtriumRoomColors {
  static const available = Color(0xFF0FA3A0);
  static const availableTint = Color(0xFFE0F5F4);
  static const availableInk = Color(0xFF0A6664);

  static const occupied = Color(0xFFE5484D);
  static const occupiedTint = Color(0xFFFDEBEC);
  static const occupiedInk = Color(0xFFB0252B);

  static const reserved = Color(0xFFE0A00E);
  static const reservedTint = Color(0xFFFDF3DB);
  static const reservedInk = Color(0xFF7D5500);

  static const cleaning = Color(0xFF4F6FF0);
  static const cleaningTint = Color(0xFFE7ECFE);
  static const cleaningInk = Color(0xFF2B45BF);

  static const outOfOrder = Color(0xFF5A6072);
  static const outOfOrderTint = Color(0xFFECEEF2);
  static const outOfOrderInk = Color(0xFF3E4454);

  // Les memes etats poses sur un fond sombre (la fiche, les cartes la nuit,
  // le filtre retenu) : un voyant plus vif, qui brille, et un libelle pale
  // (contraste superieur a 6:1 sur le fond teinte du badge).
  static const availableLed = Color(0xFF3FE0C5);
  static const availableOnDark = Color(0xFFA6F0E2);

  static const occupiedLed = Color(0xFFFF5C61);
  static const occupiedOnDark = Color(0xFFFFB8BA);

  static const reservedLed = Color(0xFFFFC23D);
  static const reservedOnDark = Color(0xFFFFDC8F);

  static const cleaningLed = Color(0xFF7D95FF);
  static const cleaningOnDark = Color(0xFFC6D0FF);

  static const outOfOrderLed = Color(0xFFA9AFC0);
  static const outOfOrderOnDark = Color(0xFFDDE0E8);
}

/// Les couleurs des graphiques, passees au validateur dataviz sur les deux
/// fonds (blanc et #141B31) : bleu, laiton, sarcelle, prune. L'ecart pour un
/// lecteur deuteranope entre sarcelle et prune (6,7) n'est admis que parce
/// que chaque part porte aussi son libelle et sa valeur en legende.
abstract final class AtriumChartColors {
  static const current = Color(0xFF3D68DD);

  /// La periode precedente : un gris-bleu en retrait, elle sert de repere.
  static const previous = Color(0xFF9AA6C4);
  static const arrivals = Color(0xFF11A08B);
  static const departures = Color(0xFF3D68DD);
  static const types = [
    Color(0xFF3D68DD),
    Color(0xFFBD8A2E),
    Color(0xFF11A08B),
    Color(0xFFB44F9F),
  ];
  static const other = Color(0xFF8A92AE);
}

/// Les rayons : 12 pour ce qui se touche (bouton, champ, filtre), 16 pour
/// ce qui contient (carte), 20 pour ce qui se superpose (dialogue).
abstract final class AtriumRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
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

/// Les ombres, teintees de bleu plutot que de gris neutre, et tenues tres
/// basses : la bordure detache la carte, l'ombre ne fait que la poser.
abstract final class AtriumShadows {
  /// La carte de connexion : un peu plus d'air dessous, elle est seule.
  static const card = [
    BoxShadow(color: Color(0x0A14244F), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x1214244F),
      blurRadius: 32,
      spreadRadius: -12,
      offset: Offset(0, 16),
    ),
  ];

  /// Touche du pave, case du PIN : a peine un relief.
  static const key = [
    BoxShadow(color: Color(0x0D14244F), blurRadius: 1, offset: Offset(0, 1)),
  ];

  /// L'embleme sur un fond bleu.
  static const emblem = [
    BoxShadow(
      color: Color(0x3305081A),
      blurRadius: 16,
      spreadRadius: -4,
      offset: Offset(0, 6),
    ),
  ];

  /// Carte du tableau de bord : la bordure fait le travail.
  static const soft = [
    BoxShadow(color: Color(0x0814244F), blurRadius: 2, offset: Offset(0, 1)),
  ];

  /// Ancien halo autour d'un element actif : garde pour les appels, mais
  /// reduit a une ombre portee nette -- un halo colore faisait gadget.
  static List<BoxShadow> glow(Color couleur, {double force = 0.45}) => [
    BoxShadow(
      color: couleur.withValues(alpha: force * 0.4),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
  ];

  /// Halo de focus autour d'un champ.
  static List<BoxShadow> focusRing(Color couleur) => [
    BoxShadow(color: couleur.withValues(alpha: 0.18), spreadRadius: 3),
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

/// La police des titres d'ecran : Cormorant Garamond, la serif de ChronoFS
/// (`assets/fonts/cormorant`). Jamais en dessous de 26 points : ses
/// empattements fins disparaissent a petite taille sur une tablette.
const atriumDisplayFamily = 'CormorantGaramond';

/// Le style d'un titre d'ecran, regle comme `.heading-display` de ChronoFS :
/// graisse 600, interlettrage de -0,01 em, chiffres alignes.
TextStyle atriumDisplay(double taille, {Color? color, double height = 1.05}) =>
    TextStyle(
      fontFamily: atriumDisplayFamily,
      fontSize: taille,
      fontWeight: FontWeight.w600,
      height: height,
      letterSpacing: -0.01 * taille,
      color: color ?? AtriumPalette.current.text,
      fontFeatures: const [FontFeature.liningFigures()],
    );

/// La chasse fixe des codes et references : JetBrains Mono, comme les
/// cartouches de ChronoFS (`assets/fonts/jetbrains`). Reservee aux
/// identifiants qu'on recopie ou qu'on dicte -- code client, numero
/// d'ardoise ou de facture, code agent --, jamais aux libelles : un zero
/// barre ne se confond pas avec un O.
const atriumMonoFamily = 'JetBrainsMono';

/// Le style d'un code ou d'une reference.
TextStyle atriumCode(double taille, {Color? color, FontWeight? weight}) =>
    TextStyle(
      fontFamily: atriumMonoFamily,
      fontSize: taille,
      fontWeight: weight ?? FontWeight.w600,
      letterSpacing: 0.02 * taille,
      color: color ?? AtriumPalette.current.text,
    );

/// Chiffres a chasse fixe : un code ou un montant ne doit pas bouger
/// horizontalement pendant qu'on le tape.
const tabularFigures = [FontFeature.tabularFigures()];
