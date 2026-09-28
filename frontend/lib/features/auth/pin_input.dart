/// Les cases du code PIN et le pave numerique.
///
/// Concus pour la saisie du paragraphe 6.2 : dix agents se succedent sur la
/// meme tablette, tapent vite, souvent sans regarder, parfois avec des gants.
/// D'ou des touches plus hautes que la cible minimale, un retour visuel a
/// chaque appui, et une case « courante » cerclee de menthe dont le point
/// clignote comme un curseur : on sait ou en est la saisie sans compter.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/tokens.dart';

/// Les cases du code : une par chiffre, un point gris tant qu'elle est vide,
/// un point anthracite quand le chiffre est saisi.
class PinCells extends StatelessWidget {
  const PinCells({
    super.key,
    required this.filled,
    required this.length,
    this.error = false,
    this.busy = false,
  });

  final int filled;
  final int length;

  /// Le code vient d'etre refuse : les cases passent au rouge jusqu'a la
  /// saisie suivante.
  final bool error;

  /// La verification est en cours : les points passent au violet.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Code PIN, $filled chiffres saisis sur $length',
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, c) {
            // Les proportions de la maquette : chaque case prend un septieme
            // de la largeur utile, un peu plus large que haute.
            final largeur = (c.maxWidth * 0.148).clamp(46.0, 62.0);
            final ecart = largeur * 0.2;
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < length; i++) ...[
                  if (i > 0) SizedBox(width: ecart),
                  _Case(
                    largeur: largeur,
                    hauteur: largeur * 0.92,
                    remplie: i < filled,
                    courante: !busy && !error && i == filled,
                    error: error,
                    busy: busy,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Case extends StatelessWidget {
  const _Case({
    required this.largeur,
    required this.hauteur,
    required this.remplie,
    required this.courante,
    required this.error,
    required this.busy,
  });

  final double largeur;
  final double hauteur;
  final bool remplie;
  final bool courante;
  final bool error;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final duree = AtriumMotion.of(context, AtriumMotion.base);

    final Color bordure;
    final double epaisseur;
    if (error) {
      bordure = AtriumColors.error;
      epaisseur = 1.5;
    } else if (courante) {
      bordure = AtriumColors.mintStrong;
      epaisseur = 2.5;
    } else if (busy) {
      bordure = AtriumColors.mintStrong;
      epaisseur = 1.5;
    } else {
      bordure = AtriumColors.border;
      epaisseur = 1;
    }

    final Widget point;
    if (remplie) {
      // Le point apparait en grossissant, avec un leger depassement : c'est
      // la confirmation qu'un appui a ete pris, sans regarder le pave.
      point = TweenAnimationBuilder<double>(
        key: const ValueKey('rempli'),
        tween: Tween(begin: 0.3, end: 1),
        duration: duree,
        curve: Curves.easeOutBack,
        builder: (context, t, enfant) =>
            Transform.scale(scale: t, child: enfant),
        child: _Point(
          taille: 12,
          couleur: busy ? AtriumColors.purple : AtriumColors.ink,
        ),
      );
    } else if (courante) {
      point = const _Curseur(key: ValueKey('curseur'));
    } else {
      point = _Point(
        key: const ValueKey('vide'),
        taille: 9,
        couleur: error
            ? AtriumColors.error.withValues(alpha: 0.45)
            : AtriumColors.placeholder,
      );
    }

    return AnimatedContainer(
      duration: duree,
      curve: AtriumMotion.standard,
      width: largeur,
      height: hauteur,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: error
              ? [AtriumColors.errorTint, AtriumColors.errorTint]
              : [AtriumColors.white, AtriumColors.surface],
        ),
        borderRadius: BorderRadius.circular(largeur * 0.22),
        border: Border.all(color: bordure, width: epaisseur),
        boxShadow: courante
            ? AtriumShadows.glow(AtriumColors.mintStrong, force: 0.4)
            : AtriumShadows.key,
      ),
      alignment: Alignment.center,
      child: AnimatedSwitcher(duration: duree, child: point),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({super.key, required this.taille, required this.couleur});

  final double taille;
  final Color couleur;

  @override
  Widget build(BuildContext context) => Container(
    width: taille,
    height: taille,
    decoration: BoxDecoration(shape: BoxShape.circle, color: couleur),
  );
}

/// Le point de la case courante, qui clignote comme un curseur de texte.
///
/// Un minuteur plutot qu'une animation continue : la page de connexion reste
/// affichee des heures sur une tablette de comptoir, et un clignotement a
/// deux etats ne demande que deux images par seconde, pas soixante.
class _Curseur extends StatefulWidget {
  const _Curseur({super.key});

  @override
  State<_Curseur> createState() => _CurseurState();
}

class _CurseurState extends State<_Curseur> {
  Timer? _minuteur;
  bool _visible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _minuteur?.cancel();
    _minuteur = null;
    _visible = true;
    if (!MediaQuery.disableAnimationsOf(context)) {
      _minuteur = Timer.periodic(
        const Duration(milliseconds: 560),
        (_) => setState(() => _visible = !_visible),
      );
    }
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0.35,
      duration: const Duration(milliseconds: 220),
      child: _Point(taille: 10, couleur: AtriumColors.ink),
    );
  }
}

/// Le pave : 1 a 9, puis une case vide, 0 et la touche d'effacement.
///
/// La disposition est celle d'un telephone et non d'une calculatrice : c'est
/// celle que les doigts connaissent.
class PinKeypad extends StatelessWidget {
  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    required this.enabled,
    this.keyHeight = 60,
    this.spacing = AtriumSpacing.sm,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;
  final bool enabled;
  final double keyHeight;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    Widget rangee(List<Widget> touches) => Row(
      children: [
        for (var i = 0; i < touches.length; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          Expanded(child: touches[i]),
        ],
      ],
    );

    Widget chiffre(String c) => _Touche(
      hauteur: keyHeight,
      semantique: c,
      onTap: enabled ? () => onDigit(c) : null,
      child: Text(c),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final ligne in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ]) ...[
          rangee([for (final c in ligne) chiffre(c)]),
          SizedBox(height: spacing),
        ],
        rangee([
          SizedBox(height: keyHeight),
          chiffre('0'),
          _Touche(
            hauteur: keyHeight,
            semantique: 'Effacer le dernier chiffre',
            effacement: true,
            onTap: enabled ? onDelete : null,
            child: const Icon(Icons.backspace_outlined, size: 26),
          ),
        ]),
      ],
    );
  }
}

class _Touche extends StatefulWidget {
  const _Touche({
    required this.hauteur,
    required this.semantique,
    required this.onTap,
    required this.child,
    this.effacement = false,
  });

  final double hauteur;
  final String semantique;
  final VoidCallback? onTap;
  final Widget child;

  /// La touche d'effacement se distingue des chiffres au premier coup d'oeil :
  /// fond menthe, sans relief. Taper « effacer » a la place de « 0 » est
  /// l'erreur la plus frequente sur un pave tape sans regarder.
  final bool effacement;

  @override
  State<_Touche> createState() => _ToucheState();
}

class _ToucheState extends State<_Touche> {
  bool _pressee = false;
  bool _focus = false;

  void _presser(bool valeur) {
    if (_pressee != valeur) setState(() => _pressee = valeur);
  }

  @override
  Widget build(BuildContext context) {
    final actif = widget.onTap != null;
    final rayon = BorderRadius.circular(AtriumRadii.lg);

    final List<Color> fond;
    final Color bordure;
    final Color encre;
    if (widget.effacement) {
      fond = _pressee
          ? [AtriumColors.mintBorder, AtriumColors.mintBorder]
          : [AtriumColors.mintSoft, AtriumColors.mintSoft];
      bordure = _focus ? AtriumColors.mintStrong : Colors.transparent;
      encre = actif ? AtriumColors.ink : AtriumColors.textDisabled;
    } else if (_pressee) {
      fond = [AtriumColors.mintTint, AtriumColors.mintTint];
      bordure = AtriumColors.mintStrong;
      encre = AtriumColors.purple;
    } else {
      fond = [AtriumColors.white, AtriumColors.surface];
      bordure = _focus ? AtriumColors.mintStrong : AtriumColors.border;
      encre = actif ? AtriumColors.ink : AtriumColors.textDisabled;
    }

    // Enfoncement a l'appui, relachement plus lent : l'oeil percoit le
    // retour sans que la touche semble molle.
    final duree = AtriumMotion.of(
      context,
      _pressee ? const Duration(milliseconds: 60) : AtriumMotion.fast,
    );

    // Le libelle est porte ici, et le contenu visuel exclu plus bas : sans
    // quoi le lecteur d'ecran lirait « icone retour arriere » au lieu de
    // « effacer ». L'action de toucher reste celle de l'InkWell.
    return Semantics(
      container: true,
      button: true,
      enabled: actif,
      label: widget.semantique,
      child: AnimatedScale(
        scale: _pressee ? 0.96 : 1,
        duration: duree,
        curve: AtriumMotion.standard,
        child: AnimatedContainer(
          duration: duree,
          height: widget.hauteur,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: fond,
            ),
            borderRadius: rayon,
            border: Border.all(color: bordure, width: _focus ? 1.5 : 1),
            boxShadow: widget.effacement || _pressee
                ? const []
                : AtriumShadows.key,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: rayon,
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.transparent,
              hoverColor: AtriumColors.purple.withValues(alpha: 0.03),
              focusColor: Colors.transparent,
              // Le lisere ne sert qu'a la navigation au clavier : apres un
              // toucher, il laissait croire que la touche restait enfoncee.
              onFocusChange: (f) => setState(
                () => _focus =
                    f &&
                    FocusManager.instance.highlightMode ==
                        FocusHighlightMode.traditional,
              ),
              onTapDown: actif ? (_) => _presser(true) : null,
              onTapUp: actif ? (_) => _presser(false) : null,
              onTapCancel: () => _presser(false),
              onTap: actif
                  ? () {
                      HapticFeedback.selectionClick();
                      widget.onTap!();
                    }
                  : null,
              child: ExcludeSemantics(
                child: Center(
                  child: IconTheme(
                    data: IconThemeData(color: encre),
                    child: DefaultTextStyle(
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: encre,
                        fontFeatures: tabularFigures,
                        height: 1,
                      ),
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
