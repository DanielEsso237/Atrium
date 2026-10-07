/// Les composants de la refonte : ce qui donne a Atrium sa matiere.
///
/// - `Bezel` : la carte. Du papier, un filet d'un point, une ombre a peine
///   posee. Le nom vient d'une version a double bordure, abandonnee : elle
///   faisait objet decoratif la ou il faut un support de lecture.
/// - `PillButton` : le bouton maison, rectangle arrondi, icone en tete.
/// - `FadeUp` : l'apparition d'un element, un fondu court.
/// - `AmbientBackground` : le fond d'une page, uni.
///
/// Toutes les animations tombent a zero quand le systeme demande de les
/// reduire.
library;

import 'dart:math' as math;

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

  /// Rayon demande ; plafonne a 18 pour que toutes les cartes de l'ecran
  /// parlent le meme langage, quelle que soit la page qui les pose.
  final double radius;

  /// Garde pour les appels existants : la coque n'existe plus.
  final double shell;
  final EdgeInsetsGeometry padding;

  /// Couleur du fond ; par defaut le papier.
  final Color? core;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final rayon = math.min(radius - shell, 18.0).clamp(8.0, 18.0);
    final fond = core ?? p.paper;
    // Un aplat colore (bloc fort) n'a pas besoin de filet pour se detacher.
    final aplat = core != null && core != p.paper;

    Widget carte = DecoratedBox(
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(rayon),
        border: aplat ? null : Border.all(color: p.border),
        boxShadow: p.isDark ? null : AtriumShadows.soft,
      ),
      child: Padding(padding: padding, child: child),
    );

    if (onTap != null) {
      carte = _Pressable(radius: rayon, onTap: onTap!, child: carte);
    }
    return carte;
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

/// Le bouton maison. Le nom date de la version en pilule ; la forme est
/// maintenant celle de tous les boutons de l'application : un rectangle a
/// coins de 12.
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

  /// L'icone, devant le libelle -- sauf une fleche vers l'avant, qui se lit
  /// apres lui (« Se connecter », puis la direction).
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
    final plein = widget.tone != PillTone.quiet;
    final fond = plein
        ? (_presse || _survol ? p.primaryPressed : p.primary)
        : (_presse ? p.surfaceMuted : (_survol ? p.surface : p.paper));
    final encre = !actif ? p.textDisabled : (plein ? Colors.white : p.text);
    final duree = _animationsCoupees(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);
    final hauteur = widget.compact ? 44.0 : 50.0;
    final apres = widget.icon == PhosphorIconsLight.arrowRight;

    final icone = widget.icon == null
        ? null
        : Icon(widget.icon, size: widget.compact ? 18 : 20, color: encre);

    final contenu = Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.compact ? 14 : 18),
      child: Row(
        mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icone != null && !apres) ...[icone, const SizedBox(width: 8)],
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: widget.compact ? 14.5 : 15.5,
                fontWeight: FontWeight.w600,
                color: encre,
              ),
            ),
          ),
          if (icone != null && apres) ...[const SizedBox(width: 10), icone],
        ],
      ),
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
            scale: _presse ? 0.98 : 1,
            duration: duree,
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: duree,
              curve: Curves.easeOut,
              height: hauteur,
              decoration: BoxDecoration(
                color: actif
                    ? fond
                    : (plein ? p.surfaceMuted : fond.withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(AtriumRadii.md),
                border: plein
                    ? null
                    : Border.all(
                        color: _survol
                            ? p.accent.withValues(alpha: 0.4)
                            : p.border,
                      ),
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

/// L'apparition d'un element : un fondu court, et un leger decalage selon
/// son rang. Pas de glissement : une page de travail qui remonte a chaque
/// ouverture finit par donner le mal de mer.
class FadeUp extends StatelessWidget {
  const FadeUp({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (_animationsCoupees(context)) return child;
    final delai = math.min(index * 40, 160);
    const duree = 280;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: duree + delai),
      curve: Interval(delai / (duree + delai), 1, curve: Curves.easeOut),
      builder: (context, t, enfant) =>
          Opacity(opacity: t.clamp(0, 1), child: enfant),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// AmbientBackground
// ---------------------------------------------------------------------------

/// Le fond d'une page : uni. Les halos et le grain d'avant ont ete retires,
/// ils salissaient les tableaux et coutaient aux tablettes d'entree de gamme.
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: AtriumPalette.current.background, child: child);
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
        color: strong ? c : c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: strong ? Colors.white : AtriumColors.textPrimary,
        ),
      ),
    );
  }
}

/// Un code dans son cartouche : chasse fixe, fond bleu pale, filet bleu --
/// le `.code-ue` de ChronoFS. Pour les identifiants seulement (code client,
/// numero d'ardoise, code agent).
class CodeCartouche extends StatelessWidget {
  const CodeCartouche(this.code, {super.key, this.taille = 12.5});

  final String code;
  final double taille;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: p.accentTint,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.accentBorder),
      ),
      child: Text(
        code,
        maxLines: 1,
        style: atriumCode(
          taille,
          color: p.isDark ? p.accent : const Color(0xFF183D95),
        ),
      ),
    );
  }
}

/// Un code en cartouche suivi d'un detail (telephone, role) : la ligne
/// d'identite sous un nom.
class LigneCode extends StatelessWidget {
  const LigneCode(this.code, {super.key, this.detail});

  final String code;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CodeCartouche(code, taille: 11.5),
        if (detail != null && detail!.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              detail!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13,
                color: AtriumColors.textSecondary,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Une vignette d'initiales.
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
    // Les teintes de la charte (bleu, laiton, sarcelle, prune, ardoise),
    // en fond pale et encre foncee.
    const teintes = [
      (Color(0xFFDCE7FF), Color(0xFF143894)),
      (Color(0xFFF6EEDD), Color(0xFF7D5F27)),
      (Color(0xFFDDF2EE), Color(0xFF0B6B5D)),
      (Color(0xFFF3E4F0), Color(0xFF7E3570)),
      (Color(0xFFE6EAF2), Color(0xFF3A4458)),
    ];
    final (fond, encre) = teintes[name.hashCode.abs() % teintes.length];
    final sombre = AtriumPalette.current.isDark;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: sombre ? encre.withValues(alpha: 0.35) : fond,
        shape: BoxShape.circle,
      ),
      child: Text(
        lettres.isEmpty ? '?' : lettres,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.36,
          color: sombre ? fond : encre,
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

/// Des filtres : celui retenu est plein (bleu), les autres sont en retrait. Chaque pilule dit combien elle contient : on sait ce
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
        : const Duration(milliseconds: 160);
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
            scale: _presse ? 0.98 : 1,
            duration: duree,
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: duree,
              curve: Curves.easeOut,
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: actif
                    ? p.selected
                    : (_survol || _presse ? p.surfaceMuted : p.paper),
                borderRadius: BorderRadius.circular(AtriumRadii.md - 2),
                border: Border.all(color: actif ? p.selected : p.border),
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
                      fontWeight: actif ? FontWeight.w600 : FontWeight.w500,
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
                            ? p.onSelected.withValues(alpha: 0.18)
                            : p.surfaceMuted,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '${o.count}',
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
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

/// Le champ de recherche des listes.
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
      borderRadius: BorderRadius.circular(AtriumRadii.md - 2),
      borderSide: BorderSide(color: p.border),
    );
    return SizedBox(
      height: 44,
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
          fillColor: p.paper,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          prefixIcon: Icon(
            PhosphorIconsLight.magnifyingGlass,
            size: 20,
            color: p.textSecondary,
          ),
          border: bord,
          enabledBorder: bord,
          focusedBorder: bord.copyWith(
            borderSide: BorderSide(color: p.accent, width: 1.4),
          ),
        ),
      ),
    );
  }
}

/// Un etat vide : une icone dans un cercle pale, une phrase qui dit
/// pourquoi c'est vide, et quoi faire.
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
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: p.accentTint,
                    shape: BoxShape.circle,
                    border: Border.all(color: p.accentSoft),
                  ),
                  child: Icon(icon, size: 28, color: p.accent),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
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
    this.radius = 12,
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
              : const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: widget.padding,
          decoration: BoxDecoration(
            color: _survol ? p.surfaceMuted : Colors.transparent,
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Le titre d'une section, en casse normale. Le nom date d'une version en
/// capitales espacees au-dessus d'un filet, retiree : elle criait sans
/// rien dire de plus.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
                color: p.text,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
        ),
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
        : const Duration(milliseconds: 160);
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
                  curve: Curves.easeOut,
                  width: tileWidth,
                  padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                  decoration: BoxDecoration(
                    color: valeur == selected ? p.accentTint : p.paper,
                    borderRadius: BorderRadius.circular(AtriumRadii.md),
                    border: Border.all(
                      color: valeur == selected ? p.accent : p.border,
                      width: valeur == selected ? 1.5 : 1,
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
                          fontWeight: FontWeight.w600,
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
  fontWeight: FontWeight.w700,
  letterSpacing: -0.4,
  color: AtriumColors.textPrimary,
  fontFeatures: tabularFigures,
);

/// Une chambre a choisir : son numero dans une tuile qui passe au bleu.
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
              const Duration(milliseconds: 160),
            ),
            curve: Curves.easeOut,
            width: 76,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: choisie ? p.selected : p.paper,
              borderRadius: BorderRadius.circular(AtriumRadii.md),
              border: Border.all(color: choisie ? p.selected : p.border),
            ),
            child: Text(
              numero,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: choisie ? p.onSelected : p.text,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
