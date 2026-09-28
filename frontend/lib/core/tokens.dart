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
