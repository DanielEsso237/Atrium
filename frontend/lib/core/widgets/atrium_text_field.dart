/// Champ de saisie de la charte : une pastille ronde et le libelle au-dessus,
/// le champ teinte de menthe dessous, l'erreur sous le champ.
///
/// Le libelle est pose **au-dessus** du champ et non flottant dedans. Un
/// libelle flottant se reduit des qu'il y a une valeur, et le code agent est
/// pre-rempli : il serait donc toujours a sa taille reduite, illisible a bout
/// de bras.
///
/// L'erreur s'affiche sous le champ qu'elle concerne, pas en tete de
/// formulaire : l'agent sait ce qu'il doit corriger sans chercher.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

class AtriumTextField extends StatefulWidget {
  const AtriumTextField({
    super.key,
    required this.label,
    required this.labelIcon,
    required this.controller,
    required this.icon,
    this.errorText,
    this.obscureText = false,
    this.suffix,
    this.onSubmitted,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.autofillHints,
    this.valueStyle,
    this.enabled = true,
  });

  final String label;

  /// L'icone de la pastille, a gauche du libelle.
  final IconData labelIcon;
  final TextEditingController controller;

  /// L'icone dans le champ.
  final IconData icon;
  final String? errorText;
  final bool obscureText;
  final Widget? suffix;
  final ValueChanged<String>? onSubmitted;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final TextStyle? valueStyle;
  final bool enabled;

  @override
  State<AtriumTextField> createState() => _AtriumTextFieldState();
}

class _AtriumTextFieldState extends State<AtriumTextField> {
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enErreur = widget.errorText != null;
    final accent = enErreur ? AtriumColors.error : AtriumColors.mintStrong;
    final rayon = BorderRadius.circular(AtriumRadii.md);
    final duree = AtriumMotion.of(context, AtriumMotion.base);

    OutlineInputBorder bordure(Color couleur, [double epaisseur = 1]) =>
        OutlineInputBorder(
          borderRadius: rayon,
          borderSide: BorderSide(color: couleur, width: epaisseur),
        );

    // Toucher la pastille ou le libelle place le curseur dans le champ.
    final VoidCallback? viser = widget.enabled
        ? () => _focus.requestFocus()
        : null;

    final champ = AnimatedContainer(
      duration: duree,
      curve: AtriumMotion.standard,
      decoration: BoxDecoration(
        borderRadius: rayon,
        boxShadow: _focused ? AtriumShadows.focusRing(accent) : const [],
      ),
      child: Semantics(
        label: widget.label,
        child: TextField(
          controller: widget.controller,
          focusNode: _focus,
          enabled: widget.enabled,
          obscureText: widget.obscureText,
          onSubmitted: widget.onSubmitted,
          textCapitalization: widget.textCapitalization,
          textInputAction: widget.textInputAction,
          autofillHints: widget.autofillHints,
          cursorColor: AtriumColors.purple,
          style:
              widget.valueStyle ??
              const TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: AtriumColors.ink,
              ),
          decoration: InputDecoration(
            filled: true,
            fillColor: enErreur
                ? AtriumColors.errorTint
                : AtriumColors.mintTint,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AtriumSpacing.md,
              vertical: 18,
            ),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(
                left: AtriumSpacing.md + 2,
                right: AtriumSpacing.md,
              ),
              child: Icon(widget.icon, size: 24),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 0),
            prefixIconColor: enErreur
                ? AtriumColors.error
                : AtriumColors.textOnMuted,
            suffixIcon: widget.suffix,
            suffixIconColor: AtriumColors.textOnMuted,
            border: bordure(AtriumColors.mintBorder),
            enabledBorder: bordure(
              enErreur ? AtriumColors.error : AtriumColors.mintBorder,
            ),
            focusedBorder: bordure(accent, 1.5),
            disabledBorder: bordure(AtriumColors.mintBorder),
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // L'etiquette descend vers son champ : trop haute, elle flottait
        // entre le champ et le bord de la carte sans appartenir a aucun.
        const SizedBox(height: 6),
        ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: viser,
            child: Row(
              children: [
                _Pastille(
                  icone: widget.labelIcon,
                  active: _focused,
                  erreur: enErreur,
                  duree: duree,
                ),
                const SizedBox(width: AtriumSpacing.sm),
                Text(
                  widget.label,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AtriumSpacing.xxs),
        champ,
        AnimatedSize(
          duration: duree,
          curve: AtriumMotion.standard,
          alignment: Alignment.topCenter,
          child: enErreur
              ? Padding(
                  padding: const EdgeInsets.only(top: AtriumSpacing.xs),
                  child: FieldMessage(widget.errorText!),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// La pastille ronde qui porte l'icone du libelle.
///
/// Detachee du champ, mais pas indifferente : elle s'eclaire quand le champ
/// prend la main et rougit avec lui quand il est refuse. C'est ce lien qui
/// fait qu'on la lit comme l'etiquette de ce champ-la, pas comme un
/// ornement pose au hasard.
class _Pastille extends StatelessWidget {
  const _Pastille({
    required this.icone,
    required this.active,
    required this.erreur,
    required this.duree,
  });

  final IconData icone;
  final bool active;
  final bool erreur;
  final Duration duree;

  static const double _diametre = 36;

  @override
  Widget build(BuildContext context) {
    final List<Color> fond;
    final Color bord;
    final Color encre;
    if (erreur) {
      fond = const [AtriumColors.errorTint, AtriumColors.errorTint];
      bord = AtriumColors.error.withValues(alpha: 0.45);
      encre = AtriumColors.error;
    } else if (active) {
      fond = const [AtriumColors.mint, AtriumColors.mintStrong];
      bord = AtriumColors.mintStrong;
      encre = AtriumColors.purple;
    } else {
      fond = const [AtriumColors.mintTint, AtriumColors.mintSoft];
      bord = AtriumColors.mintBorder;
      encre = AtriumColors.ink;
    }

    return AnimatedScale(
      scale: active ? 1.06 : 1,
      duration: duree,
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: duree,
        curve: AtriumMotion.standard,
        width: _diametre,
        height: _diametre,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: fond,
          ),
          border: Border.all(color: bord, width: active ? 1.5 : 1),
          boxShadow: active
              ? AtriumShadows.glow(AtriumColors.mintStrong, force: 0.35)
              : const [],
        ),
        alignment: Alignment.center,
        child: Icon(icone, size: 19, color: encre),
      ),
    );
  }
}

/// Message d'erreur place sous un champ.
///
/// Annonce par le lecteur d'ecran des qu'il apparait (`liveRegion`) : une
/// erreur qui ne se voit qu'a l'ecran laisse un agent malvoyant taper dans le
/// vide.
class FieldMessage extends StatelessWidget {
  const FieldMessage(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: AtriumColors.error,
            ),
          ),
          const SizedBox(width: AtriumSpacing.xs),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 14,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: AtriumColors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
