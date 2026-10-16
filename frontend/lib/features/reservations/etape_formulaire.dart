/// L'etape d'un formulaire en plusieurs temps : la nouvelle reservation,
/// la nouvelle arrivee. Les deux se presentent pareil (15 octobre).
library;

import 'package:flutter/material.dart';

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
