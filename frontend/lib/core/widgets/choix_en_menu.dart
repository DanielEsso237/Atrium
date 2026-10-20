/// Choisir un lieu dans un menu deroulant plutot qu'en pastilles : une
/// quinzaine de magasins ou de points de vente ne tiennent pas sur une
/// ligne (Stock le 14 octobre, Points de vente et Ventes le 18).
///
/// Le bouton dit ce qui est montre -- son genre en petit, son nom en gras --
/// et combien il y en a ; le menu les liste, une coche sur le choisi.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';
import '../ui/icons.dart';

class OptionMenu<T> {
  const OptionMenu(
    this.valeur,
    this.libelle, {
    required this.icone,
    required this.genre,
  });

  final T valeur;
  final String libelle;
  final IconData icone;

  /// Au-dessus du nom, dans le bouton : « Magasin central », « Service ».
  final String genre;
}

class ChoixEnMenu<T> extends StatelessWidget {
  const ChoixEnMenu({
    super.key,
    required this.options,
    required this.choisi,
    required this.onChoisi,
    this.compte,
  });

  final List<OptionMenu<T>> options;
  final T choisi;
  final ValueChanged<T> onChoisi;

  /// En bout de bouton : « 5 magasins ».
  final String? compte;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final actuelle = options.firstWhere(
      (o) => o.valeur == choisi,
      orElse: () => options.first,
    );

    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        for (final o in options)
          MenuItemButton(
            leadingIcon: Icon(o.icone, size: 18),
            trailingIcon: o.valeur == actuelle.valeur
                ? Icon(PhosphorIconsLight.check, size: 18, color: p.accent)
                : null,
            onPressed: () => onChoisi(o.valeur),
            child: Text(o.libelle),
          ),
      ],
      builder: (context, menu, _) => Material(
        color: p.paper,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AtriumRadii.md),
          side: BorderSide(color: p.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AtriumRadii.md),
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: p.accentTint,
                    borderRadius: BorderRadius.circular(AtriumRadii.sm),
                  ),
                  child: Icon(actuelle.icone, size: 19, color: p.accent),
                ),
                const SizedBox(width: 12),
                // Souple : un nom long se coupe au lieu de pousser le compte
                // hors de l'ecran.
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        actuelle.genre,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 12,
                          color: p.textSecondary,
                        ),
                      ),
                      Text(
                        actuelle.libelle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                    ],
                  ),
                ),
                if (compte != null) ...[
                  const SizedBox(width: 14),
                  Text(
                    compte!,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 12.5,
                      color: p.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                Icon(
                  PhosphorIconsLight.caretDown,
                  size: 16,
                  color: p.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
