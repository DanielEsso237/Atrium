/// Le signal visuel des alertes : un bandeau en tete de chaque ecran, et
/// pour le critique un cadre rouge qui bat autour de toute la page.
///
/// Le cadre se voit de l'autre bout du hall, la ou un bandeau ne se lit
/// plus ; le bandeau dit quoi faire. Les deux restent jusqu'a ce que
/// l'agent appuie sur « J'ai vu ».
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import '../../data/local/queries/alert_queries.dart';
import 'alert_center.dart';

/// Enveloppe le contenu d'un ecran : bandeau au-dessus, cadre par-dessus.
class BandeauAlertes extends ConsumerWidget {
  const BandeauAlertes({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final etat = ref.watch(centreAlertesProvider);
    final bandeau = etat.bandeau;
    final premiere = bandeau.isEmpty ? null : bandeau.first;
    final critique = premiere?.niveau == NiveauAlerte.critique;

    return Stack(
      children: [
        Column(
          children: [
            AnimatedSize(
              duration: AtriumMotion.of(context, AtriumMotion.slow),
              curve: AtriumMotion.standard,
              alignment: Alignment.topCenter,
              child: premiere == null
                  ? const SizedBox(width: double.infinity)
                  : SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                        // Une surface Material : sans elle, le texte se
                        // souligne en jaune et les boutons perdent leur encre.
                        child: Material(
                          type: MaterialType.transparency,
                          child: _Bandeau(
                            key: ValueKey(premiere.cle),
                            alerte: premiere,
                            autres: bandeau.length - 1,
                          ),
                        ),
                      ),
                    ),
            ),
            Expanded(child: child),
          ],
        ),
        if (critique) const Positioned.fill(child: _CadreCritique()),
      ],
    );
  }
}

class _Bandeau extends ConsumerWidget {
  const _Bandeau({super.key, required this.alerte, required this.autres});

  final Alerte alerte;
  final int autres;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final critique = alerte.niveau == NiveauAlerte.critique;
    // Une arrivee attendue n'est pas un avertissement : le bleu de la
    // maison pour l'information, l'ambre pour l'urgent, le rouge pour le
    // critique.
    final fond = switch (alerte.niveau) {
      NiveauAlerte.critique => p.error,
      NiveauAlerte.urgente => p.warning,
      NiveauAlerte.info => p.primary,
    };
    final centre = ref.read(centreAlertesProvider.notifier);
    final etroit = MediaQuery.sizeOf(context).width < 600;

    final boutons = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        if (alerte.route case final route?)
          OutlinedButton(
            onPressed: () {
              centre.acquitter(alerte.cle);
              context.go(route);
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.transparent,
              side: const BorderSide(color: Colors.white70),
              minimumSize: const Size(64, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Voir'),
          ),
        // Dix arrivees le matin font dix alertes : une seule touche pour
        // toutes, plutot que dix « J'ai vu ».
        if (autres > 0)
          TextButton(
            onPressed: centre.acquitterTout,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size(64, 44),
            ),
            child: const Text('Tout vu'),
          ),
        FilledButton(
          onPressed: () => centre.acquitter(alerte.cle),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: fond,
            minimumSize: const Size(88, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(
              fontFamily: atriumFontFamily,
              fontWeight: FontWeight.w700,
            ),
          ),
          child: const Text("J'ai vu"),
        ),
      ],
    );

    final texte = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          alerte.titre,
          style: const TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          alerte.corps,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 13.5,
            height: 1.35,
            color: Colors.white.withValues(alpha: 0.92),
          ),
        ),
        if (autres > 0) ...[
          const SizedBox(height: 4),
          Text(
            autres == 1
                ? 'Une autre alerte attend derrière.'
                : '$autres autres alertes attendent derrière.',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ],
      ],
    );

    return Semantics(
      liveRegion: true,
      container: true,
      label: '${critique ? 'Alerte critique' : 'Alerte'} : ${alerte.titre}. '
          '${alerte.corps}',
      child: TweenAnimationBuilder<double>(
        // L'arrivee du bandeau : il descend d'un cran et prend sa couleur.
        tween: Tween(begin: 0, end: 1),
        duration: AtriumMotion.of(context, AtriumMotion.slow),
        curve: Curves.easeOutBack,
        builder: (context, t, enfant) => Transform.translate(
          offset: Offset(0, -12 * (1 - t)),
          child: Opacity(opacity: t.clamp(0, 1), child: enfant),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            color: fond,
            borderRadius: BorderRadius.circular(16),
            boxShadow: AtriumShadows.glow(fond, force: 0.35),
          ),
          child: etroit
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Pastille(critique: critique),
                        const SizedBox(width: 12),
                        Expanded(child: texte),
                      ],
                    ),
                    const SizedBox(height: 10),
                    boutons,
                  ],
                )
              : Row(
                  children: [
                    _Pastille(critique: critique),
                    const SizedBox(width: 14),
                    Expanded(child: texte),
                    const SizedBox(width: 12),
                    boutons,
                  ],
                ),
        ),
      ),
    );
  }
}

/// L'icone de l'alerte ; elle bat tant que l'alerte critique n'est pas vue.
class _Pastille extends StatefulWidget {
  const _Pastille({required this.critique});

  final bool critique;

  @override
  State<_Pastille> createState() => _PastilleState();
}

class _PastilleState extends State<_Pastille>
    with SingleTickerProviderStateMixin {
  late final _battement = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.critique && !MediaQuery.disableAnimationsOf(context)) {
      _battement.repeat(reverse: true);
    } else {
      _battement.stop();
    }
  }

  @override
  void dispose() {
    _battement.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _battement,
    builder: (context, enfant) => Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.18),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.35 * _battement.value),
            blurRadius: 4 + 10 * _battement.value,
            spreadRadius: 2 * _battement.value,
          ),
        ],
      ),
      child: enfant,
    ),
    child: Icon(
      widget.critique ? PhosphorIconsLight.siren : PhosphorIconsLight.bell,
      size: 24,
      color: Colors.white,
    ),
  );
}

/// Le cadre rouge autour de la page : il ne capte aucun toucher.
class _CadreCritique extends StatefulWidget {
  const _CadreCritique();

  @override
  State<_CadreCritique> createState() => _CadreCritiqueState();
}

class _CadreCritiqueState extends State<_CadreCritique>
    with SingleTickerProviderStateMixin {
  late final _pouls = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pouls.value = 1;
    } else {
      _pouls.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pouls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rouge = AtriumPalette.current.error;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _pouls,
        builder: (context, _) => DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: rouge.withValues(alpha: 0.35 + 0.55 * _pouls.value),
              width: 5,
            ),
          ),
        ),
      ),
    );
  }
}

/// La liste des alertes en cours, pour la cloche : on y retrouve aussi
/// celles deja vues, tant qu'elles ne sont pas reglees.
class ListeAlertes extends ConsumerWidget {
  const ListeAlertes({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final etat = ref.watch(centreAlertesProvider);
    if (etat.actives.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in etat.actives)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: Icon(
                    switch (a.niveau) {
                      NiveauAlerte.critique => PhosphorIconsLight.siren,
                      NiveauAlerte.urgente => PhosphorIconsLight.bell,
                      NiveauAlerte.info => PhosphorIconsLight.warningCircle,
                    },
                    size: 20,
                    color: switch (a.niveau) {
                      NiveauAlerte.critique => p.error,
                      NiveauAlerte.urgente => p.warning,
                      NiveauAlerte.info => p.textSecondary,
                    },
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.titre,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 14.5,
                          fontWeight: etat.vues.contains(a.cle)
                              ? FontWeight.w500
                              : FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                      Text(
                        a.corps,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 13,
                          color: p.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (a.route case final route?)
                  TextButton(
                    onPressed: () {
                      // Le routeur avant de fermer : le contexte du dialogue
                      // ne vit plus apres.
                      final routeur = GoRouter.of(context);
                      ref.read(centreAlertesProvider.notifier).acquitter(a.cle);
                      Navigator.of(context).pop();
                      routeur.go(route);
                    },
                    style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
                    child: const Text('Voir'),
                  ),
              ],
            ),
          ),
        const Divider(height: 24),
      ],
    );
  }
}
