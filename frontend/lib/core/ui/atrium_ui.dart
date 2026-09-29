/// Les composants de la refonte : ce qui donne a Atrium sa matiere.
///
/// - `Bezel` : une carte a double bordure -- une coque fine qui tient un
///   noyau, comme une plaque de verre dans un cadre d'aluminium. Les rayons
///   sont concentriques (rayon du noyau = rayon de la coque - l'epaisseur).
/// - `PillButton` : bouton en pilule, l'icone dans sa propre pastille qui se
///   deplace au survol et s'enfonce a l'appui.
/// - `FadeUp` : l'entree d'un element -- il monte, se precise et apparait,
///   avec un decalage selon son rang.
/// - `AmbientBackground` : le fond d'une page, deux halos de lumiere et un
///   grain tres fin pour casser l'aplat numerique.
///
/// Toutes les courbes sont a ressort, jamais lineaires. Toutes les
/// animations tombent a zero quand le systeme demande de les reduire.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// La courbe maison : un depart vif, une arrivee longue et douce, comme un
/// objet qui a du poids.
const atriumSpring = Cubic(0.32, 0.72, 0, 1);

bool _animationsCoupees(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);

// ---------------------------------------------------------------------------
// Bezel
// ---------------------------------------------------------------------------

class Bezel extends StatelessWidget {
  const Bezel({
    super.key,
    required this.child,
    this.radius = 28,
    this.shell = 6,
    this.padding = const EdgeInsets.all(20),
    this.core,
    this.onTap,
  });

  final Widget child;
  final double radius;

  /// Epaisseur de la coque.
  final double shell;
  final EdgeInsetsGeometry padding;

  /// Couleur du noyau ; par defaut le papier.
  final Color? core;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sombre = AtriumPalette.current.isDark;
    final inner = radius - shell;
    final coreColor = core ?? AtriumColors.white;

    Widget noyau = DecoratedBox(
      decoration: BoxDecoration(
        color: coreColor,
        borderRadius: BorderRadius.circular(inner),
        // Le reflet du bord haut : un filet clair, comme la tranche d'une
        // plaque de verre qui accroche la lumiere.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 0.04, 1],
          colors: [
            Color.alphaBlend(
              Colors.white.withValues(alpha: sombre ? 0.07 : 0.6),
              coreColor,
            ),
            coreColor,
            coreColor,
          ],
        ),
      ),
      child: Padding(padding: padding, child: child),
    );

    if (onTap != null) {
      noyau = _Pressable(
        radius: inner,
        onTap: onTap!,
        child: noyau,
      );
    }

    return Container(
      padding: EdgeInsets.all(shell),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: sombre
            ? Colors.white.withValues(alpha: 0.035)
            : AtriumColors.purpleNight.withValues(alpha: 0.035),
        border: Border.all(
          color: sombre
              ? Colors.white.withValues(alpha: 0.08)
              : AtriumColors.purpleNight.withValues(alpha: 0.06),
        ),
        boxShadow: [
          // Ombre teintee de nuit, tres diffuse : la carte flotte, elle ne
          // pese pas sur la page.
          BoxShadow(
            color: AtriumPalette.current.shadow.withValues(
              alpha: sombre ? 0.35 : 0.06,
            ),
            blurRadius: 40,
            spreadRadius: -12,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: noyau,
    );
  }
}

/// Retour physique au toucher : la surface s'enfonce legerement.
class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.child,
    required this.onTap,
    required this.radius,
  });

  final Widget child;
  final VoidCallback onTap;
  final double radius;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _presse = false;
  bool _survol = false;

  @override
  Widget build(BuildContext context) {
    final duree = _animationsCoupees(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _survol = true),
      onExit: (_) => setState(() => _survol = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _presse = true),
        onTapCancel: () => setState(() => _presse = false),
        onTapUp: (_) => setState(() => _presse = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _presse ? 0.985 : 1,
          duration: duree,
          curve: atriumSpring,
          child: AnimatedContainer(
            duration: duree,
            curve: atriumSpring,
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              color: AtriumColors.mintStrong.withValues(
                alpha: _survol ? 0.04 : 0,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PillButton
// ---------------------------------------------------------------------------

enum PillTone { primary, accent, quiet }

class PillButton extends StatefulWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.tone = PillTone.primary,
    this.compact = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Icone de fin, posee dans sa propre pastille.
  final IconData? icon;
  final PillTone tone;
  final bool compact;

  /// Occupe toute la largeur disponible.
  final bool expand;

  @override
  State<PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<PillButton> {
  bool _survol = false;
  bool _presse = false;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final actif = widget.onPressed != null;
    final (Color fond, Color encre, Color pastille) = switch (widget.tone) {
      PillTone.primary => (
        p.isDark ? p.accent : p.night,
        p.isDark ? p.night : p.onNight,
        p.isDark
            ? p.night.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.12),
      ),
      PillTone.accent => (
        p.accent,
        p.night,
        p.night.withValues(alpha: 0.12),
      ),
      PillTone.quiet => (
        p.isDark ? Colors.white.withValues(alpha: 0.06) : p.night.withValues(alpha: 0.05),
        p.text,
        p.isDark ? Colors.white.withValues(alpha: 0.08) : p.night.withValues(alpha: 0.06),
      ),
    };
    final duree = _animationsCoupees(context)
        ? Duration.zero
        : const Duration(milliseconds: 380);
    final hauteur = widget.compact ? 44.0 : 52.0;

    final contenu = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: Padding(
            padding: EdgeInsets.only(
              left: widget.compact ? 16 : 22,
              right: widget.icon == null ? (widget.compact ? 16 : 22) : 10,
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: widget.compact ? 14.5 : 15.5,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
                color: actif ? encre : encre.withValues(alpha: 0.45),
              ),
            ),
          ),
        ),
        if (widget.icon != null)
          Padding(
            padding: EdgeInsets.only(right: (hauteur - 36) / 2),
            child: AnimatedSlide(
              duration: duree,
              curve: atriumSpring,
              offset: _survol ? const Offset(0.08, -0.04) : Offset.zero,
              child: AnimatedScale(
                duration: duree,
                curve: atriumSpring,
                scale: _survol ? 1.06 : 1,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: pastille,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(widget.icon, size: 18, color: encre),
                ),
              ),
            ),
          ),
      ],
    );

    return Semantics(
      button: true,
      enabled: actif,
      label: widget.label,
      child: MouseRegion(
        cursor: actif ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _survol = true),
        onExit: (_) => setState(() => _survol = false),
        child: GestureDetector(
          onTapDown: actif ? (_) => setState(() => _presse = true) : null,
          onTapCancel: () => setState(() => _presse = false),
          onTapUp: (_) => setState(() => _presse = false),
          onTap: widget.onPressed,
          child: AnimatedScale(
            scale: _presse ? 0.97 : 1,
            duration: duree,
            curve: atriumSpring,
            child: AnimatedContainer(
              duration: duree,
              curve: atriumSpring,
              height: hauteur,
              decoration: BoxDecoration(
                color: actif ? fond : fond.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(hauteur),
                boxShadow: widget.tone == PillTone.quiet || !actif
                    ? null
                    : [
                        BoxShadow(
                          color: fond.withValues(alpha: _survol ? 0.45 : 0.28),
                          blurRadius: _survol ? 26 : 18,
                          spreadRadius: -6,
                          offset: const Offset(0, 10),
                        ),
                      ],
              ),
              child: contenu,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FadeUp
// ---------------------------------------------------------------------------

/// L'entree d'un element : il monte de 18 px, passe du flou au net et
/// apparait. `index` decale l'entree dans une cascade.
class FadeUp extends StatelessWidget {
  const FadeUp({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (_animationsCoupees(context)) return child;
    final delai = math.min(index * 70, 560);
    const duree = 820;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: duree + delai),
      curve: Interval(delai / (duree + delai), 1, curve: atriumSpring),
      builder: (context, t, enfant) {
        final flou = (1 - t) * 8;
        return Opacity(
          opacity: t.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - t)),
            child: flou < 0.2
                ? enfant
                : ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: flou, sigmaY: flou),
                    child: enfant,
                  ),
          ),
        );
      },
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// AmbientBackground
// ---------------------------------------------------------------------------

/// Le fond d'une page : deux halos de lumiere (mangue en haut a droite,
/// indigo en bas a gauche) et un grain fin, fixes, sous le contenu.
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return ColoredBox(
      color: p.background,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _Halos(p)),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: _Grain(p.isDark)),
              ),
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class _Halos extends CustomPainter {
  _Halos(this.p);

  final AtriumPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    void halo(Offset centre, double rayon, Color couleur, double force) {
      canvas.drawCircle(
        centre,
        rayon,
        Paint()
          ..shader = RadialGradient(
            colors: [couleur.withValues(alpha: force), couleur.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: centre, radius: rayon)),
      );
    }

    final r = math.max(size.width, size.height);
    halo(
      Offset(size.width * 0.92, -r * 0.08),
      r * 0.55,
      p.accent,
      p.isDark ? 0.16 : 0.18,
    );
    halo(
      Offset(size.width * 0.02, size.height * 1.02),
      r * 0.6,
      p.isDark ? const Color(0xFF3B47C9) : const Color(0xFF7C8BFF),
      p.isDark ? 0.18 : 0.10,
    );
  }

  @override
  bool shouldRepaint(covariant _Halos old) => old.p != p;
}

/// Un grain deterministe : quelques milliers de points presque invisibles.
class _Grain extends CustomPainter {
  _Grain(this.sombre);

  final bool sombre;

  @override
  void paint(Canvas canvas, Size size) {
    final alea = math.Random(7);
    final nombre = (size.width * size.height / 900).clamp(0, 9000).toInt();
    final points = <Offset>[
      for (var i = 0; i < nombre; i++)
        Offset(alea.nextDouble() * size.width, alea.nextDouble() * size.height),
    ];
    canvas.drawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = (sombre ? Colors.white : Colors.black).withValues(
          alpha: sombre ? 0.045 : 0.035,
        )
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _Grain old) => old.sombre != sombre;
}

// ---------------------------------------------------------------------------
// Petits elements
// ---------------------------------------------------------------------------

/// Une etiquette discrete : etat, compteur, categorie.
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color, this.strong = false});

  final String label;
  final Color? color;

  /// Fond plein (pour un etat qui doit sauter aux yeux).
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AtriumColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: strong ? c : c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
          color: strong ? AtriumColors.purpleNight : AtriumColors.textPrimary,
        ),
      ),
    );
  }
}

/// Une vignette d'initiales, en carre arrondi plutot qu'en rond.
class Monogram extends StatelessWidget {
  const Monogram(this.name, {super.key, this.size = 42});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final lettres = name
        .split(RegExp(r'\s+'))
        .where((m) => m.isNotEmpty)
        .take(2)
        .map((m) => m.characters.first.toUpperCase())
        .join();
    // Une teinte par nom, stable : on reconnait un client a sa couleur.
    final teintes = [
      const Color(0xFFFFC65A),
      const Color(0xFF52E3A6),
      const Color(0xFF93B0FF),
      const Color(0xFFFF9F8F),
      const Color(0xFFC9A8FF),
    ];
    final teinte = teintes[name.hashCode.abs() % teintes.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: teinte.withValues(alpha: AtriumPalette.current.isDark ? 0.18 : 0.35),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Text(
        lettres.isEmpty ? '?' : lettres,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.34,
          color: AtriumPalette.current.isDark ? teinte : AtriumColors.textPrimary,
        ),
      ),
    );
  }
}
