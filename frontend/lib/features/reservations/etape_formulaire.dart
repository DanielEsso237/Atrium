/// L'etape d'un formulaire en plusieurs temps : la nouvelle reservation,
/// la nouvelle arrivee. Les deux se presentent pareil (15 octobre).
library;

import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';

/// Une etape du formulaire : son numero dans une pastille, qui se coche une
/// fois l'etape remplie. On voit d'un coup d'oeil ce qui manque.
class EtapeFormulaire extends StatelessWidget {
  const EtapeFormulaire({
    required this.numero,
    required this.titre,
    required this.fait,
    required this.child,
    this.facultatif = false,
  });

  final int numero;
  final String titre;
  final bool fait;
  final bool facultatif;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 420));
    return Bezel(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: duree,
                curve: atriumSpring,
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: fait ? p.accent : p.surfaceMuted,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: AnimatedSwitcher(
                  duration: duree,
                  child: fait
                      ? Icon(
                          PhosphorIconsFill.check,
                          key: const ValueKey('ok'),
                          size: 17,
                          color: p.onAccent,
                        )
                      : Text(
                          '$numero',
                          key: const ValueKey('n'),
                          style: TextStyle(
                            fontFamily: atriumFontFamily,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: p.textSecondary,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                titre,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: p.text,
                ),
              ),
              if (facultatif) ...[
                const SizedBox(width: 10),
                const Tag('Facultatif'),
              ],
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

/// Une carte a choisir dans une etape : la categorie de la reservation et
/// celle de la nouvelle arrivee (16 octobre) : un nom, un prix, une
/// precision ; la carte retenue se teinte et se coche.
class CarteChoix extends StatelessWidget {
  const CarteChoix({
    super.key,
    required this.titre,
    required this.montant,
    required this.detail,
    required this.choisie,
    required this.onTap,
  });

  final String titre;
  final int montant;
  final String detail;
  final bool choisie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 380));
    return Semantics(
      button: true,
      selected: choisie,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: duree,
            curve: atriumSpring,
            width: 176,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: choisie ? p.accent.withValues(alpha: 0.12) : p.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: choisie ? p.accent : p.border,
                width: choisie ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        titre,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                    ),
                    Icon(
                      choisie
                          ? PhosphorIconsFill.checkCircle
                          : PhosphorIconsLight.circle,
                      size: 20,
                      color: choisie ? p.accent : p.placeholder,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  formatAmount(montant),
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: p.text,
                    fontFeatures: tabularFigures,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 12.5,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
