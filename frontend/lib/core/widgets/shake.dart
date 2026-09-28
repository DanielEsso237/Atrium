/// Secousse horizontale, le « non » d'un champ refuse.
///
/// Declaree plutot que commandee : le parent incremente `trigger` a chaque
/// refus, et le widget rejoue la secousse. Pas de controleur a faire circuler
/// entre l'ecran et le champ.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class Shake extends StatefulWidget {
  const Shake({super.key, required this.trigger, required this.child});

  /// Chaque changement de valeur rejoue la secousse.
  final int trigger;
  final Widget child;

  @override
  State<Shake> createState() => _ShakeState();
}

class _ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  late final _controleur = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void didUpdateWidget(Shake ancien) {
    super.didUpdateWidget(ancien);
    if (widget.trigger != ancien.trigger &&
        !MediaQuery.disableAnimationsOf(context)) {
      _controleur.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controleur.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controleur,
      child: widget.child,
      builder: (context, enfant) {
        final t = _controleur.value;
        // Deux allers-retours qui s'amortissent : assez pour se voir du coin
        // de l'oeil, pas assez pour ressembler a une alarme.
        final decalage = math.sin(t * math.pi * 4) * 8 * (1 - t);
        return Transform.translate(offset: Offset(decalage, 0), child: enfant);
      },
    );
  }
}
