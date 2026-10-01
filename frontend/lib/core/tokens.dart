/// Les jetons de la charte Atrium : violet profond, menthe, anthracite.
///
/// Chaque couleur, rayon, espacement, ombre et duree de l'interface vient
/// d'ici. Un ecran qui ecrit `Color(0xFF...)` a la main finit toujours par
/// diverger des autres d'une nuance, et sur une tablette de comptoir lue en
/// biais, deux violets presque identiques se lisent comme deux intentions.
///
/// La page de connexion est la premiere a les employer ; les autres ecrans y
/// passeront un par un, en quittant `themeAtrium()` pour `atriumBrandTheme()`.
library;

import 'package:flutter/material.dart';

abstract final class AtriumColors {
  // La charte.
  static const purple = Color(0xFF2D1B69);
  static const mint = Color(0xFFB8F7E4);
  static const ink = Color(0xFF25272C);
  static const white = Color(0xFFFFFFFF);

  // Les violets derives.
  /// Le fond du bandeau, sous la photo : le violet de la charte pousse vers
  /// la nuit, pour que le blanc des titres ressorte sans ombre portee.
  static const purpleNight = Color(0xFF191136);
  static const purpleDeep = Color(0xFF221452);

  /// Le haut du degrade de l'embleme, un cran plus clair que la charte.
  static const purpleBright = Color(0xFF3B2386);

  /// Teinte multipliee sur la photo du bandeau : les blancs de la chambre
  /// virent au lavande et la photo se fond dans le violet au lieu d'y etre
  /// collee.
  static const photoTint = Color(0xFFD9D3F7);

  /// Le sous-titre et la devise, poses sur le bandeau sombre.
  static const onPurpleSoft = Color(0xFFE6E3F0);

  // Les menthes derivees.
  /// Menthe soutenue : bordures actives, filets, curseur. La menthe de la
  /// charte, trop claire sur blanc, y disparaitrait.
  static const mintStrong = Color(0xFF5ED9C0);

  /// Bordure d'un champ au repos.
  static const mintBorder = Color(0xFFBDEFE3);

  /// Onglet du libelle, touche d'effacement.
  static const mintSoft = Color(0xFFCCF8EE);

  /// Fond d'un champ, de l'encart de demonstration, d'une touche pressee.
  static const mintTint = Color(0xFFE8FAF6);

  // Les neutres.
  static const background = Color(0xFFF2F3F8);
  static const surface = Color(0xFFF9FAFC);
  static const surfaceMuted = Color(0xFFEEF1F8);
  static const border = Color(0xFFE3E6EF);
  static const textPrimary = ink;
  static const textSecondary = Color(0xFF6A7181);

  /// Texte d'une option inactive, pose sur `surfaceMuted`.
  static const textOnMuted = Color(0xFF3A3D4A);

  /// Point d'une case de PIN encore vide.
  static const placeholder = Color(0xFFAFBAD6);
  static const textDisabled = Color(0xFF9AA1B2);

  // Les etats, dans des teintes sobres : une erreur doit se voir sans crier.
  static const success = Color(0xFF15803D);
  static const error = Color(0xFFE5484D);
  static const errorTint = Color(0xFFFDEEEE);
  static const warning = Color(0xFFB45309);
}

/// Les couleurs propres au tableau de bord : la barre laterale de nuit, les
/// tuiles d'icone, les titres.
abstract final class AtriumDashColors {
  static const sidebar = Color(0xFF151934);
  static const sidebarRaised = Color(0xFF1D2242);
  static const sidebarText = Color(0xFFF1F6FF);
  static const sidebarMuted = Color(0xFFA7ADCF);
  static const sidebarDivider = Color(0x1FFFFFFF);

  /// La pastille de l'entree active : un degrade sarcelle, cercle de menthe.
  static const activeStart = Color(0xFF2A8C85);
  static const activeEnd = Color(0xFF256A78);
  static const activeBorder = Color(0xFF4CC9B8);

  static const title = Color(0xFF14223C);
  static const page = Color(0xFFF3F5FB);

  /// Le haut gauche du bandeau d'accueil, un cran plus clair que la page.
  static const headerLight = Color(0xFFF8F8FD);
  static const card = Color(0xFFFFFFFF);
  static const cardBorder = Color(0xFFEBEEF5);

  /// Fond des petites pastilles grises (fleche, menu, periode).
  static const control = Color(0xFFF1F3F9);

  /// Tuiles d'icone : fond pale, pictogramme soutenu de la meme famille.
  static const tileMint = Color(0xFFC9F4EA);
  static const tileMintInk = Color(0xFF16806F);
  static const tileLavender = Color(0xFFE3E0FC);
  static const tileLavenderInk = Color(0xFF3B2FB0);
  static const tileBlue = Color(0xFFDDE8FD);
  static const tileBlueInk = Color(0xFF2F63D0);

  /// La pastille « hors ligne » du bandeau.
  static const chipMint = Color(0xFFC9F5EC);
  static const chipMintInk = Color(0xFF1F5A55);

  static const grid = Color(0xFFEDF0F6);

  /// La main qui salue, a cote du bonjour.
  static const wave = Color(0xFFF5B83D);
}

/// Les cinq etats d'une chambre (cahier des charges, paragraphe 5.2) : libre
/// en vert, occupee en rouge, reservee en jaune, en nettoyage en bleu, hors
/// service en gris.
///
/// Les teintes du cahier des charges, raffinees pour la charte et passees au
/// validateur dataviz. Le vert tire vers l'eau : c'est ce qui le garde
/// distinct du rouge pour un lecteur daltonien (ecart de 12 contre 5 pour un
/// vert franc) -- et il rejoint la menthe de la charte. La couleur n'est
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

  // Les memes etats poses sur le violet des cartes-cles : un voyant plus vif,
  // qui brille sur le fond sombre, et un libelle pale (contraste superieur a
  // 6:1 sur le fond teinte du badge).
  static const availableLed = Color(0xFF3FE0C5);
  static const availableOnDark = AtriumColors.mint;

  static const occupiedLed = Color(0xFFFF5C61);
  static const occupiedOnDark = Color(0xFFFFB8BA);

  static const reservedLed = Color(0xFFFFC23D);
  static const reservedOnDark = Color(0xFFFFDC8F);

  static const cleaningLed = Color(0xFF7D95FF);
  static const cleaningOnDark = Color(0xFFC6D0FF);

  static const outOfOrderLed = Color(0xFFA9AFC0);
  static const outOfOrderOnDark = Color(0xFFDDE0E8);
}

/// Les cartes-cles du plan des chambres : toutes taillees dans le violet de
/// la charte, comme les cles d'un meme hotel. L'etat ne les teint jamais.
abstract final class AtriumKeyCardColors {
  /// Le haut de la carte, ou la lumiere accroche : un cran au-dessus de la
  /// charte, pas davantage, sinon le degrade se voit.
  static const light = Color(0xFF38227F);
  static const base = AtriumColors.purple;
  static const deep = Color(0xFF231457);

  /// Le liseret interieur qui donne son epaisseur a la carte.
  static const edge = Color(0x1FFFFFFF);
  static const divider = Color(0x1AFFFFFF);

  /// Categorie, depart, prix : le texte secondaire sur le violet.
  static const muted = Color(0xFFC9C2E8);

  /// Le signe sans contact, a peine grave.
  static const glyph = Color(0x5CFFFFFF);

  /// Le fond des pictogrammes et la piste de l'anneau de sejour.
  static const well = Color(0x17FFFFFF);
}

/// Les couleurs des graphiques.
///
/// Passees au validateur dataviz (clarte, separation pour les daltonismes
/// protan, deutan et tritan, contraste) avant d'etre posees ici : a l'oeil,
/// le bleu et le lavande de la maquette se confondaient pour un lecteur
/// daltonien, et presque pour tout le monde.
abstract final class AtriumChartColors {
  /// La periode en cours, et toutes les series « menthe ».
  static const current = Color(0xFF1FB39B);

  /// La periode precedente, et toutes les series « lavande ».
  static const previous = Color(0xFF8B80E8);

  static const arrivals = Color(0xFF2EC4B6);
  static const departures = Color(0xFF6C65F1);

  /// Les types de chambre, dans l'ordre du parametrage. Jamais recycles : un
  /// cinquieme type rejoint « Autres », en gris.
  static const types = [
    Color(0xFF159488),
    Color(0xFF4B42D6),
    Color(0xFF52A9F5),
    Color(0xFF8E6FEF),
  ];
  static const other = Color(0xFFAAB1C2);
}

/// Les rayons, du plus petit au plus grand.
///
/// Un element contenu a un rayon plus petit que son contenant : c'est ce qui
/// fait qu'une carte et ses champs semblent tailles dans la meme piece.
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

/// Les ombres, teintees de violet plutot que de gris neutre : sur un fond
/// lavande, une ombre grise salit la surface au lieu de la detacher.
abstract final class AtriumShadows {
  /// La carte de connexion : large et diffuse, elle flotte sur le bandeau.
  static const card = [
    BoxShadow(color: Color(0x0F2D1B69), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x1F2D1B69),
      blurRadius: 48,
      spreadRadius: -8,
      offset: Offset(0, 20),
    ),
  ];

  /// Touche du pave, case du PIN : un relief de bouton physique, a peine.
  static const key = [
    BoxShadow(color: Color(0x0D25272C), blurRadius: 1, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x1425272C),
      blurRadius: 10,
      spreadRadius: -2,
      offset: Offset(0, 4),
    ),
  ];

  /// L'embleme sur le bandeau sombre.
  static const emblem = [
    BoxShadow(
      color: Color(0x6612082E),
      blurRadius: 24,
      spreadRadius: -4,
      offset: Offset(0, 10),
    ),
  ];

  /// Carte du tableau de bord : un voile a peine perceptible, la bordure
  /// fait le travail.
  static const soft = [
    BoxShadow(color: Color(0x0814223C), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x0D14223C),
      blurRadius: 24,
      spreadRadius: -6,
      offset: Offset(0, 10),
    ),
  ];

  /// Carte-cle du plan : une ombre violette, courte, qui la pose sur la page
  /// comme une carte sur un comptoir.
  static const keyCard = [
    BoxShadow(color: Color(0x1A2D1B69), blurRadius: 3, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x292D1B69),
      blurRadius: 26,
      spreadRadius: -12,
      offset: Offset(0, 14),
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

/// La police de la charte, embarquee dans `assets/fonts/montserrat`.
const atriumFontFamily = 'Montserrat';

/// Chiffres a chasse fixe : un code ou un montant ne doit pas bouger
/// horizontalement pendant qu'on le tape.
const tabularFigures = [FontFeature.tabularFigures()];
