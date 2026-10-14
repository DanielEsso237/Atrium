/// Les alertes : la liste des evenements arretee avec l'hotel, le niveau de
/// chacun -- discret, sonore, sonore et vibration -- et sa sonnerie.
///
/// Le choix s'applique tout de suite, sur toutes les tablettes : il remonte
/// au serveur et redescend ailleurs. Chaque agent peut, en plus, couper le
/// son ou choisir ses sonneries pour lui-meme depuis son menu ; ces
/// reglages-la ne se font pas ici.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/queries/alert_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../alerts/alert_signal.dart';
import '../alerts/sonneries.dart';

class AlertsSection extends ConsumerWidget {
  const AlertsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final niveaux =
        ref.watch(niveauxAlertesProvider).value ?? const NiveauxAlertes();
    final sonneries =
        ref.watch(sonneriesAlertesProvider).value ?? const SonneriesAlertes();

    Future<void> choisir(TypeEvenement type, NiveauSignal niveau) => ref
        .read(settingsRepositoryProvider)
        .setNiveauxAlertes(niveaux.avec(type, niveau));

    Future<void> choisirSonnerie(TypeEvenement type, Sonnerie sonnerie) => ref
        .read(settingsRepositoryProvider)
        .setSonneriesAlertes(sonneries.avec(type, sonnerie));

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Eyebrow('Niveau de chaque alerte'),
        const SizedBox(height: 8),
        // `Align` : une ListView impose toute sa largeur a ses enfants, et la
        // limite de 720 serait ignoree -- une ligne de 150 caracteres.
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Text(
              'Discret : l’alerte attend dans la cloche, sans bruit. Sonore : '
              'un bandeau et une sonnerie, rappelée jusqu’à ce que l’agent '
              'appuie sur « J’ai vu ». Sonore et vibration : la tablette vibre '
              'en plus. Les alertes sonnent aussi tablette en veille. Chaque '
              'alerte a sa sonnerie, à choisir parmi cinq : choisir la fait '
              'entendre.',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 14.5,
                height: 1.5,
                color: p.textSecondary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        DecoratedBox(
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.border),
          ),
          child: Column(
            children: [
              for (final (i, type) in TypeEvenement.values.indexed) ...[
                if (i > 0) Divider(height: 1, color: p.border),
                _Ligne(
                  type: type,
                  niveau: niveaux.de(type),
                  sonnerie: sonneries.de(type),
                  surChoix: (n) => choisir(type, n),
                  surSonnerie: (s) => choisirSonnerie(type, s),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              PhosphorIconsLight.musicNotes,
              size: 18,
              color: p.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Chaque agent peut, depuis son menu, choisir ses propres '
                'sonneries ou couper le son, pour lui seul et sur cette '
                'tablette. Sans son, le bandeau et la vibration restent.',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13.5,
                  height: 1.45,
                  color: p.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Ligne extends ConsumerWidget {
  const _Ligne({
    required this.type,
    required this.niveau,
    required this.sonnerie,
    required this.surChoix,
    required this.surSonnerie,
  });

  final TypeEvenement type;
  final NiveauSignal niveau;
  final Sonnerie sonnerie;
  final ValueChanged<NiveauSignal> surChoix;
  final ValueChanged<Sonnerie> surSonnerie;

  static IconData _iconeNiveau(NiveauSignal n) => switch (n) {
    NiveauSignal.discret => PhosphorIconsLight.bellSlash,
    NiveauSignal.sonore => PhosphorIconsLight.speakerHigh,
    NiveauSignal.sonoreVibration => PhosphorIconsLight.vibrate,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final etroit = MediaQuery.sizeOf(context).width < 900;
    final critique = type.graviteHabituelle == NiveauAlerte.critique;

    final pastille = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: critique ? p.errorTint : p.accentTint,
      ),
      child: Icon(
        iconeEvenement(type),
        size: 22,
        color: critique ? p.error : p.primary,
      ),
    );

    final texte = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          type.libelle,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: p.text,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          type.description,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 14,
            height: 1.4,
            color: p.textSecondary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Prévient : ${type.destinataires.toLowerCase()}',
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: p.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        ChoixSonnerie(
          type: type,
          actuelle: sonnerie,
          surChoix: (s) {
            if (s != null) surSonnerie(s);
          },
        ),
      ],
    );

    final reglage = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<NiveauSignal>(
          showSelectedIcon: false,
          segments: [
            for (final n in NiveauSignal.values)
              ButtonSegment(
                value: n,
                icon: Icon(_iconeNiveau(n), size: 18),
                label: Text(n.libelle),
              ),
          ],
          selected: {niveau},
          onSelectionChanged: (choix) => surChoix(choix.single),
          style: SegmentedButton.styleFrom(
            minimumSize: const Size(0, 48),
            textStyle: const TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: niveau.sonne
              ? 'Essayer : ${niveau.libelle.toLowerCase()}, '
                    '${sonnerie.libelle.toLowerCase()}'
              : 'Discret : rien à entendre',
          iconSize: 22,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: niveau.sonne
              ? () => ref
                    .read(signalAlerteProvider)
                    .emettre(
                      type.graviteHabituelle,
                      sonnerie: sonnerie,
                      vibration: niveau.vibre,
                    )
              : null,
          icon: const Icon(PhosphorIconsLight.play),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
      child: etroit
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    pastille,
                    const SizedBox(width: 14),
                    Expanded(child: texte),
                  ],
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.only(left: 58),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: reglage,
                  ),
                ),
              ],
            )
          : Row(
              children: [
                pastille,
                const SizedBox(width: 14),
                Expanded(child: texte),
                const SizedBox(width: 16),
                reglage,
              ],
            ),
    );
  }
}
