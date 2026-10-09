/// Le logo Edge Hotel : le symbole « EH » en immeuble, et le nom.
///
/// Le symbole vient de l'original fourni, detoure sur fond transparent, et
/// garde toujours ses couleurs d'origine. Sur fond clair il se pose tel
/// quel ; sur le bleu de la navigation ou la photo de la connexion, ou son
/// marine se perdrait, il se pose sur une tuile blanche arrondie, comme une
/// icone d'application, avec la marge qu'il faut pour respirer.
///
/// Le nom est du texte, pas une image : net a toutes les tailles, en
/// Montserrat, la geometrie la plus proche du lettrage d'origine. « Edge »
/// en marine, « Hotel » en bleu vif, comme sur l'original ; sur fond bleu,
/// blanc et bleu clair pour rester lisibles.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

const _symbole = 'assets/images/edge-hotel-mark.png';

/// Largeur sur hauteur du symbole detoure (548 x 585).
const _proportion = 548 / 585;

/// Les couleurs du nom, relevees sur l'original.
const _marine = Color(0xFF021A4C);
const _bleuVif = Color(0xFF006BEB);

/// Sur le bleu de la navigation : blanc, et un bleu clair qui garde
/// l'opposition des deux mots avec un contraste de 5:1.
const _bleuClair = Color(0xFF8EBBFF);

class _Symbole extends StatelessWidget {
  const _Symbole({required this.hauteur, required this.tuile});

  /// Hauteur totale, tuile comprise.
  final double hauteur;

  /// Sur fond sombre : la tuile blanche qui garde le bleu lisible.
  final bool tuile;

  @override
  Widget build(BuildContext context) {
    if (!tuile) {
      return Image.asset(
        _symbole,
        height: hauteur,
        width: hauteur * _proportion,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        excludeFromSemantics: true,
      );
    }
    return Container(
      width: hauteur,
      height: hauteur,
      padding: EdgeInsets.all(hauteur * 0.16),
      decoration: BoxDecoration(
        color: Colors.white,
        // L'arrondi d'une icone d'application, proportionne a la taille :
        // le meme rayon partout ferait une pastille en petit, un carre en
        // grand.
        borderRadius: BorderRadius.circular(hauteur * 0.26),
        boxShadow: [
          BoxShadow(
            color: _marine.withValues(alpha: 0.28),
            blurRadius: hauteur * 0.3,
            offset: Offset(0, hauteur * 0.08),
          ),
        ],
      ),
      child: Image.asset(
        _symbole,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        excludeFromSemantics: true,
      ),
    );
  }
}

class _Nom extends StatelessWidget {
  const _Nom({required this.taille, required this.clair, this.encre});

  final double taille;
  final bool clair;

  /// Remplace le marine de « Edge » (la facture l'accorde a son encre).
  final Color? encre;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: 'Edge ',
          style: TextStyle(color: clair ? Colors.white : (encre ?? _marine)),
        ),
        TextSpan(
          text: 'Hotel',
          style: TextStyle(color: clair ? _bleuClair : _bleuVif),
        ),
      ],
    ),
    maxLines: 1,
    softWrap: false,
    style: TextStyle(
      fontFamily: 'Montserrat',
      fontSize: taille,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.02 * taille,
      height: 1.1,
      // Hors d'un Material (un apercu, une capture), le texte se
      // soulignerait en jaune.
      decoration: TextDecoration.none,
    ),
  );
}

/// Le symbole seul, pour le rail de navigation.
class AtriumMark extends StatelessWidget {
  const AtriumMark({super.key, this.size = 44, this.onNight = false});

  final double size;
  final bool onNight;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'Edge Hotel',
    child: SizedBox.square(
      dimension: size,
      child: Center(child: _Symbole(hauteur: size, tuile: onNight)),
    ),
  );
}

/// Le logo complet dans sa composition officielle, symbole au-dessus du
/// nom, pour la connexion.
class EdgeHotelLogo extends StatelessWidget {
  const EdgeHotelLogo({super.key, this.width = 232, this.onNight = true});

  final double width;
  final bool onNight;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'Edge Hotel',
    child: SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Symbole(hauteur: width * 0.5, tuile: onNight),
          SizedBox(height: width * 0.07),
          // Le nom tient toute la largeur du logo, comme sur l'original.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: _Nom(taille: width * 0.19, clair: onNight),
          ),
        ],
      ),
    ),
  );
}

/// Le symbole et le nom cote a cote, pour la navigation et la facture ;
/// le nom de l'etablissement en dessous quand il est donne.
class AtriumLockup extends StatelessWidget {
  const AtriumLockup({
    super.key,
    this.markSize = 40,
    this.hotelName,
    this.onNight = true,
    this.ink,
  });

  final Color? ink;
  final double markSize;
  final String? hotelName;
  final bool onNight;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        image: true,
        label: 'Edge Hotel',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Symbole(hauteur: markSize, tuile: onNight),
            SizedBox(width: markSize * 0.26),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _Nom(
                  taille: markSize * 0.5,
                  clair: onNight,
                  encre: ink,
                ),
              ),
            ),
          ],
        ),
      ),
      if (hotelName != null) ...[
        const SizedBox(height: 4),
        Text(
          hotelName!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: ink ?? (onNight ? Colors.white : AtriumColors.textSecondary),
          ),
        ),
      ],
    ],
  );
}
