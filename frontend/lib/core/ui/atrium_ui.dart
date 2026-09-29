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
import 'icons.dart';

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
      noyau = _Pressable(radius: inner, onTap: onTap!, child: noyau);
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
      // Le jour, l'aplat prend la mangue franche des blocs forts ; l'accent
      // plus sombre reste pour le texte et les icones sur fond clair.
      PillTone.primary || PillTone.accent => (
        p.isDark ? p.accent : p.hero,
        p.onAccent,
        p.onAccent.withValues(alpha: 0.12),
      ),
      PillTone.quiet => (
        p.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : p.night.withValues(alpha: 0.05),
        p.text,
        p.isDark
            ? Colors.white.withValues(alpha: 0.08)
            : p.night.withValues(alpha: 0.06),
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
                color: actif ? fond : fond.withValues(alpha: fond.a * 0.45),
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
      // Opacite et translation seulement : un flou par element faisait
      // tomber le contexte WebGL et coute trop cher aux tablettes d'entree
      // de gamme.
      builder: (context, t, enfant) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - t)),
          child: enfant,
        ),
      ),
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
            child: IgnorePointer(child: CustomPaint(painter: _Halos(p))),
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
            colors: [
              couleur.withValues(alpha: force),
              couleur.withValues(alpha: 0),
            ],
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
        color: teinte.withValues(
          alpha: AtriumPalette.current.isDark ? 0.18 : 0.35,
        ),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Text(
        lettres.isEmpty ? '?' : lettres,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.34,
          color: AtriumPalette.current.isDark
              ? teinte
              : AtriumColors.textPrimary,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Barre d'outils des listes : filtres, recherche, etat vide
// ---------------------------------------------------------------------------

/// Un filtre de liste, avec le nombre de lignes qu'il donnerait.
class FilterOption<T> {
  const FilterOption(this.value, this.label, {this.count, this.color});

  final T value;
  final String label;
  final int? count;

  /// Pastille de couleur d'etat devant le libelle.
  final Color? color;
}

/// Des filtres en pilules : celle retenue est pleine (nuit), les autres
/// sont en retrait. Chaque pilule dit combien elle contient : on sait ce
/// qu'un filtre va montrer avant d'appuyer dessus.
class FilterPills<T> extends StatelessWidget {
  const FilterPills({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<FilterOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final o in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _FilterPill(
                option: o,
                actif: o.value == selected,
                onTap: () => onChanged(o.value),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterPill extends StatefulWidget {
  const _FilterPill({
    required this.option,
    required this.actif,
    required this.onTap,
  });

  final FilterOption option;
  final bool actif;
  final VoidCallback onTap;

  @override
  State<_FilterPill> createState() => _FilterPillState();
}

class _FilterPillState extends State<_FilterPill> {
  bool _survol = false;
  bool _presse = false;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final o = widget.option;
    final actif = widget.actif;
    final duree = _animationsCoupees(context)
        ? Duration.zero
        : const Duration(milliseconds: 380);
    final encre = actif ? p.onSelected : p.text;
    return Semantics(
      button: true,
      selected: actif,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _survol = true),
        onExit: (_) => setState(() => _survol = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _presse = true),
          onTapCancel: () => setState(() => _presse = false),
          onTapUp: (_) => setState(() => _presse = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _presse ? 0.96 : 1,
            duration: duree,
            curve: atriumSpring,
            child: AnimatedContainer(
              duration: duree,
              curve: atriumSpring,
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: actif
                    ? p.selected
                    : (_survol
                          ? p.surfaceMuted
                          : p.surface.withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(23),
                border: Border.all(
                  color: actif ? Colors.transparent : p.border,
                ),
                boxShadow: actif
                    ? [
                        BoxShadow(
                          color: p.selected.withValues(alpha: 0.35),
                          blurRadius: 18,
                          spreadRadius: -6,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (o.color != null) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: o.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    o.label,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: encre,
                    ),
                  ),
                  if (o.count != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: actif
                            ? p.onSelected.withValues(alpha: 0.16)
                            : p.surfaceMuted,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        '${o.count}',
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: actif ? p.onSelected : p.textSecondary,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le champ de recherche des listes, en pilule.
class SearchPill extends StatelessWidget {
  const SearchPill({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
  });

  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final bord = OutlineInputBorder(
      borderRadius: BorderRadius.circular(23),
      borderSide: BorderSide(color: p.border),
    );
    return SizedBox(
      height: 46,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: p.text,
        ),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: p.surface.withValues(alpha: 0.6),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          prefixIcon: Icon(
            PhosphorIconsLight.magnifyingGlass,
            size: 20,
            color: p.textSecondary,
          ),
          border: bord,
          enabledBorder: bord,
          focusedBorder: bord.copyWith(
            borderSide: BorderSide(color: p.accent, width: 1.6),
          ),
        ),
      ),
    );
  }
}

/// Un etat vide compose : une icone posee dans un squircle, une phrase qui
/// dit pourquoi c'est vide, et quoi faire.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: FadeUp(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: p.accent.withValues(alpha: 0.25)),
                  ),
                  child: Icon(icon, size: 34, color: p.accent),
                ),
                const SizedBox(height: 18),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: p.text,
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 15,
                      height: 1.4,
                      color: p.textSecondary,
                    ),
                  ),
                ],
                if (action != null) ...[const SizedBox(height: 20), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Une ligne de liste qui s'eclaire au survol et s'enfonce a l'appui.
class HoverRow extends StatefulWidget {
  const HoverRow({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    this.radius = 18,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool _survol = false;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _survol = true),
      onExit: (_) => setState(() => _survol = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: _animationsCoupees(context)
              ? Duration.zero
              : const Duration(milliseconds: 260),
          curve: atriumSpring,
          padding: widget.padding,
          decoration: BoxDecoration(
            color: _survol
                ? p.surfaceMuted.withValues(alpha: 0.7)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Un petit intitule de section, en capitales espacees.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Row(
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
            color: p.textSecondary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Container(height: 1, color: p.border)),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

/// Un choix parmi quelques options, en tuiles avec icone plutot qu'en menu
/// deroulant : tout se voit, un seul geste suffit.
class ChoiceTiles<T> extends StatelessWidget {
  const ChoiceTiles({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.tileWidth = 132,
  });

  final List<(T, IconData, String)> options;
  final T? selected;
  final ValueChanged<T> onChanged;
  final double tileWidth;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final duree = _animationsCoupees(context)
        ? Duration.zero
        : const Duration(milliseconds: 320);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (valeur, icone, libelle) in options)
          Semantics(
            button: true,
            selected: valeur == selected,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onChanged(valeur),
                child: AnimatedContainer(
                  duration: duree,
                  curve: atriumSpring,
                  width: tileWidth,
                  padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                  decoration: BoxDecoration(
                    color: valeur == selected
                        ? p.accent.withValues(alpha: 0.14)
                        : p.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: valeur == selected ? p.accent : p.border,
                      width: valeur == selected ? 1.8 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        icone,
                        size: 22,
                        color: valeur == selected ? p.accent : p.textSecondary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        libelle,
                        maxLines: 2,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          color: p.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Le style d'un gros champ de montant.
TextStyle get montantSaisieStyle => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 26,
  fontWeight: FontWeight.w800,
  letterSpacing: -0.6,
  color: AtriumColors.textPrimary,
  fontFeatures: tabularFigures,
);

/// Une chambre a choisir : son numero dans une tuile qui s'allume.
class RoomChoiceTile extends StatelessWidget {
  const RoomChoiceTile({
    super.key,
    required this.numero,
    required this.choisie,
    required this.onTap,
  });

  final String numero;
  final bool choisie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Semantics(
      button: true,
      selected: choisie,
      label: 'Chambre $numero',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: AtriumMotion.of(
              context,
              const Duration(milliseconds: 320),
            ),
            curve: atriumSpring,
            width: 76,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: choisie ? p.accent : p.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: choisie ? p.accent : p.border),
              boxShadow: choisie
                  ? [
                      BoxShadow(
                        color: p.accent.withValues(alpha: 0.4),
                        blurRadius: 16,
                        spreadRadius: -6,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: Text(
              numero,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: choisie ? p.onAccent : p.text,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
