/// Un filtre de rapport en pilule, qui ouvre sa liste : la periode, le
/// point de vente, l'agent... Partage entre l'ecran Rapports et les rapports
/// de chaque module (F3.3, 19 octobre).
library;

import 'package:flutter/material.dart';

import '../../core/tokens.dart';
import '../../core/ui/icons.dart';

/// Un filtre en pilule qui ouvre sa liste. Plein quand il restreint le
/// rapport : on voit d'un coup d'oeil ce qui est filtre.
class FiltreRapport<T> extends StatelessWidget {
  const FiltreRapport({
    super.key,
    required this.icone,
    required this.libelle,
    required this.actif,
    required this.choix,
    required this.courant,
    required this.surChoix,
    this.tous = '',
    this.sansTous = false,
  });

  final IconData icone;
  final String libelle;
  final bool actif;
  final List<(T, String)> choix;
  final T? courant;
  final ValueChanged<T?> surChoix;
  final String tous;
  final bool sansTous;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final style = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14,
      fontWeight: actif ? FontWeight.w700 : FontWeight.w500,
      color: actif ? p.accent : p.text,
    );
    MenuItemButton item(T? valeur, String texte) => MenuItemButton(
      onPressed: () => surChoix(valeur),
      trailingIcon: valeur == courant
          ? Icon(PhosphorIconsLight.check, size: 18, color: p.accent)
          : null,
      style: MenuItemButton.styleFrom(minimumSize: const Size(220, 46)),
      child: Text(
        texte,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 14,
          fontWeight: valeur == courant ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );

    return MenuAnchor(
      menuChildren: [
        if (!sansTous) item(null, tous),
        for (final (v, t) in choix) item(v, t),
      ],
      builder: (context, menu, _) => Semantics(
        button: true,
        label: 'Filtre $libelle',
        child: InkWell(
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: AtriumMotion.of(context, AtriumMotion.base),
            curve: AtriumMotion.standard,
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: actif ? p.accentFill : p.paper,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: actif ? p.accentBorder : p.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icone, size: 18, color: actif ? p.accent : p.textSecondary),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    libelle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  PhosphorIconsLight.caretDown,
                  size: 14,
                  color: actif ? p.accent : p.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
