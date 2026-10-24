/// Le petit carre au milieu de l'ecran : ce qui vient de reussir, ou ce qui
/// a ete refuse et pourquoi.
///
/// Demande de Daniel le 14 octobre, a la place des messages en bas de
/// l'ecran : ils passaient derriere les fenetres ouvertes (le refus du
/// plafond se cachait sous la fenetre de consommation), et un agent qui
/// regarde le client ne les voyait pas partir.
///
/// - **Succes** : une coche verte se dessine dans un cercle, avec le message.
///   Le carre s'en va seul apres un moment, ou des qu'on touche l'ecran.
/// - **Refus** : une croix rouge et la raison. Le carre attend « OK » : une
///   raison qui disparait avant d'etre lue ne sert a rien.
/// - **Refus avec remede** : quand le geste attend une etape (ouvrir la
///   caisse, encaisser le solde), le carre propose de la faire plutot que de
///   renvoyer l'agent la chercher (demande de Daniel, 24 octobre).
///
/// Il s'affiche au-dessus de tout, fenetres et fiches comprises. Sans
/// animation quand l'appareil les a coupees.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// Combien de temps un succes reste a l'ecran.
const dureeSucces = Duration(milliseconds: 1500);

/// Le carre de succes : la coche, le message, puis il s'en va seul.
Future<void> montrerSucces(BuildContext context, String message) =>
    _montrer(context, message: message, succes: true);

/// Le carre de refus : la croix, la raison, et « OK » pour le fermer.
///
/// [remede] : l'etape qui manque, proposee en bouton principal (« Ouvrir la
/// caisse »). La toucher ferme le carre puis la lance ; « Plus tard » ferme
/// seulement.
Future<void> montrerRefus(
  BuildContext context,
  String message, {
  Remede? remede,
}) => _montrer(context, message: message, succes: false, remede: remede);

/// L'etape qui debloque un geste refuse : son libelle, et de quoi la faire.
class Remede {
  const Remede(this.libelle, this.faire);

  final String libelle;
  final VoidCallback faire;
}

/// Le carre est une couche de l'overlay racine, pas une page du navigateur.
///
/// En page, il etait a la merci du premier `Navigator.pop()` venu : la fiche
/// d'une chambre se ferme juste apres une arrivee, et c'est le carre qu'elle
/// aurait ferme a sa place. En couche, aucun `pop` ne le touche ; l'ordre
/// des appels n'a plus d'importance.
Future<void> _montrer(
  BuildContext context, {
  required String message,
  required bool succes,
  Remede? remede,
}) {
  if (!context.mounted) return Future.value();
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return Future.value();
  final fini = Completer<void>();
  late final OverlayEntry couche;
  void fermer() {
    if (couche.mounted) couche.remove();
    if (!fini.isCompleted) fini.complete();
  }

  couche = OverlayEntry(
    builder: (_) => _Carre(
      message: message,
      succes: succes,
      remede: remede,
      onFermer: fermer,
    ),
  );
  overlay.insert(couche);
  return fini.future;
}

class _Carre extends StatefulWidget {
  const _Carre({
    required this.message,
    required this.succes,
    required this.onFermer,
    this.remede,
  });

  final String message;
  final bool succes;
  final Remede? remede;
  final VoidCallback onFermer;

  @override
  State<_Carre> createState() => _CarreState();
}

class _CarreState extends State<_Carre> with TickerProviderStateMixin {
  /// L'apparition : le carre se pose en grandissant un peu.
  late final AnimationController _entree = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// Le cercle, puis la coche ou la croix.
  late final AnimationController _trace = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  Timer? _depart;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entree.isAnimating || _entree.isCompleted) return;
    // Animations coupees sur l'appareil : tout s'affiche d'emblee.
    if (MediaQuery.disableAnimationsOf(context)) {
      _entree.value = 1;
      _trace.value = 1;
    } else {
      _entree.forward();
      _trace.forward();
    }
    // Un succes s'en va seul ; un refus attend « OK ».
    if (widget.succes) _depart = Timer(dureeSucces, _fermer);
  }

  void _fermer() {
    _depart?.cancel();
    widget.onFermer();
  }

  @override
  void dispose() {
    _depart?.cancel();
    _entree.dispose();
    _trace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apparition = CurvedAnimation(
      parent: _entree,
      curve: Curves.easeOutCubic,
    );
    return Stack(
      children: [
        // Le voile : un succes se ferme d'une touche, un refus non.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.succes ? _fermer : null,
            child: FadeTransition(
              opacity: apparition,
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
            ),
          ),
        ),
        FadeTransition(
          opacity: apparition,
          child: ScaleTransition(
            scale: Tween(begin: 0.92, end: 1.0).animate(apparition),
            child: _contenu(context),
          ),
        ),
      ],
    );
  }

  Widget _contenu(BuildContext context) {
    final p = AtriumPalette.current;
    final couleur = widget.succes ? p.success : p.error;
    return Center(
      child: Semantics(
        liveRegion: true,
        label: '${widget.succes ? 'Fait' : 'Refusé'} : ${widget.message}',
        child: Material(
          color: p.paper,
          elevation: 8,
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320, minWidth: 220),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 72,
                    child: ExcludeSemantics(
                      child: AnimatedBuilder(
                        animation: _trace,
                        builder: (_, _) => CustomPaint(
                          painter: _Signe(
                            progression: _trace.value,
                            succes: widget.succes,
                            couleur: couleur,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      color: p.text,
                    ),
                  ),
                  if (!widget.succes && widget.remede == null) ...[
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        autofocus: true,
                        onPressed: _fermer,
                        child: const Text('OK'),
                      ),
                    ),
                  ],
                  if (!widget.succes && widget.remede != null) ...[
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        autofocus: true,
                        onPressed: () {
                          _fermer();
                          widget.remede!.faire();
                        },
                        child: Text(widget.remede!.libelle),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: _fermer,
                        child: const Text('Plus tard'),
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

/// Le cercle qui se ferme, puis la coche (ou la croix) qui se dessine.
class _Signe extends CustomPainter {
  const _Signe({
    required this.progression,
    required this.succes,
    required this.couleur,
  });

  /// 0 a 1 : la premiere moitie trace le cercle, la seconde le signe.
  final double progression;
  final bool succes;
  final Color couleur;

  @override
  void paint(Canvas canvas, Size taille) {
    final c = taille.center(Offset.zero);
    final r = taille.shortestSide / 2 - 3;
    final trait = Paint()
      ..color = couleur
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Un disque tres pale sous le trait : le signe se lit meme en plein
    // soleil, sur une tablette au comptoir.
    canvas.drawCircle(
      c,
      r,
      Paint()..color = couleur.withValues(alpha: 0.12),
    );

    final cercle = (progression * 2).clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      2 * math.pi * cercle,
      false,
      trait,
    );

    final signe = ((progression - 0.5) * 2).clamp(0.0, 1.0);
    if (signe <= 0) return;
    final chemin = Path();
    if (succes) {
      chemin
        ..moveTo(c.dx - r * 0.42, c.dy + r * 0.02)
        ..lineTo(c.dx - r * 0.1, c.dy + r * 0.34)
        ..lineTo(c.dx + r * 0.46, c.dy - r * 0.3);
    } else {
      final d = r * 0.36;
      chemin
        ..moveTo(c.dx - d, c.dy - d)
        ..lineTo(c.dx + d, c.dy + d)
        ..moveTo(c.dx + d, c.dy - d)
        ..lineTo(c.dx - d, c.dy + d);
    }
    // Le signe se dessine a la longueur parcourue, segment apres segment.
    final metriques = chemin.computeMetrics().toList();
    final total = metriques.fold(0.0, (s, m) => s + m.length);
    var reste = total * signe;
    for (final m in metriques) {
      if (reste <= 0) break;
      final longueur = math.min(reste, m.length);
      canvas.drawPath(m.extractPath(0, longueur), trait);
      reste -= longueur;
    }
  }

  @override
  bool shouldRepaint(_Signe ancien) =>
      ancien.progression != progression ||
      ancien.couleur != couleur ||
      ancien.succes != succes;
}
