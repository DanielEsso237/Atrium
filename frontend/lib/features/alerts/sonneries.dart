/// Le choix d'une sonnerie : par l'administration pour tout l'hotel, par
/// chaque agent pour lui-meme.
///
/// Choisir une sonnerie la fait entendre aussitot, comme sur un telephone :
/// on ne choisit pas un son sur son nom.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import '../../data/local/queries/alert_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../auth/session.dart';
import 'alert_center.dart';
import 'alert_signal.dart';

IconData iconeEvenement(TypeEvenement t) => switch (t) {
  TypeEvenement.envoiBloque => PhosphorIconsLight.cloudSlash,
  TypeEvenement.chambreAFaire => PhosphorIconsLight.broom,
  TypeEvenement.panne => PhosphorIconsLight.wrench,
  TypeEvenement.arriveeAttendue => PhosphorIconsLight.signIn,
  TypeEvenement.departDepasse => PhosphorIconsLight.doorOpen,
  TypeEvenement.transfertAValider => PhosphorIconsLight.arrowsLeftRight,
  TypeEvenement.stockBas => PhosphorIconsLight.package,
  TypeEvenement.commandeChambre => PhosphorIconsLight.forkKnife,
};

/// Fait entendre une sonnerie, sur le flux de la vraie alerte, sans vibrer.
void ecouterSonnerie(WidgetRef ref, TypeEvenement type, Sonnerie sonnerie) =>
    ref
        .read(signalAlerteProvider)
        .emettre(type.graviteHabituelle, sonnerie: sonnerie, vibration: false);

/// Une sonnerie dessinee : ses deux notes, a la hauteur ou elles sonnent.
/// Cinq fois la meme note de musique ne distinguerait rien ; ici « Qui
/// monte » monte et « Bois étouffé » reste en bas.
class ContourSonnerie extends StatelessWidget {
  const ContourSonnerie(this.sonnerie, {super.key, required this.couleur});

  final Sonnerie sonnerie;
  final Color couleur;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: const Size(26, 18),
      painter: _Contour(sonnerie, couleur),
    ),
  );
}

class _Contour extends CustomPainter {
  const _Contour(this.sonnerie, this.couleur);

  final Sonnerie sonnerie;
  final Color couleur;

  @override
  void paint(Canvas canvas, Size taille) {
    final plein = Paint()..color = couleur;
    final trait = Paint()
      ..color = couleur
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    Offset a(double x, double y) => Offset(taille.width * x, taille.height * y);

    switch (sonnerie) {
      case Sonnerie.memeNote:
        canvas.drawCircle(a(.28, .5), 3.4, plein);
        canvas.drawCircle(a(.72, .5), 3.4, plein);
      case Sonnerie.quiMonte:
        canvas.drawCircle(a(.28, .74), 3.4, plein);
        canvas.drawCircle(a(.72, .26), 3.4, plein);
      case Sonnerie.aiguLeger:
        canvas.drawCircle(a(.3, .26), 2.4, plein);
        canvas.drawCircle(a(.7, .14), 2.4, plein);
      case Sonnerie.bulles:
        canvas.drawCircle(a(.28, .62), 3.4, trait);
        canvas.drawCircle(a(.72, .38), 3.4, trait);
      case Sonnerie.boisEtouffe:
        for (final c in [a(.28, .78), a(.72, .64)]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: c, width: 6.4, height: 6.4),
              const Radius.circular(1.6),
            ),
            plein,
          );
        }
    }
  }

  @override
  bool shouldRepaint(_Contour avant) =>
      avant.sonnerie != sonnerie || avant.couleur != couleur;
}

/// Ce qu'on peut choisir dans le menu : une sonnerie, ou celle de l'hotel.
const _celleDeLHotel = 'hotel';

/// Le bouton d'une sonnerie, et son menu des cinq.
///
/// Pour un agent, `hotel` est la sonnerie de l'hotel : le menu propose d'y
/// revenir quand l'agent en a choisi une autre. `surChoix` recoit alors
/// `null`.
class ChoixSonnerie extends ConsumerWidget {
  const ChoixSonnerie({
    super.key,
    required this.type,
    required this.actuelle,
    required this.surChoix,
    this.hotel,
    this.personnalisee = false,
    this.actif = true,
  });

  final TypeEvenement type;
  final Sonnerie actuelle;
  final ValueChanged<Sonnerie?> surChoix;
  final Sonnerie? hotel;
  final bool personnalisee;
  final bool actif;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final encre = actif ? p.primary : p.textDisabled;

    final pastille = Container(
      height: 40,
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      decoration: BoxDecoration(
        color: actif ? p.accentSoft : p.surfaceMuted,
        borderRadius: BorderRadius.circular(AtriumRadii.md),
        border: Border.all(color: actif ? p.accentBorder : p.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ContourSonnerie(actuelle, couleur: encre),
          const SizedBox(width: 8),
          Text(
            actuelle.libelle,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: encre,
            ),
          ),
          const SizedBox(width: 6),
          Icon(PhosphorIconsLight.caretDown, size: 16, color: encre),
        ],
      ),
    );

    return PopupMenuButton<Object>(
      enabled: actif,
      tooltip: 'Sonnerie : ${actuelle.libelle}',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      constraints: const BoxConstraints(minWidth: 220),
      onSelected: (choix) {
        final sonnerie = choix is Sonnerie ? choix : null;
        surChoix(sonnerie);
        ecouterSonnerie(ref, type, sonnerie ?? hotel ?? actuelle);
      },
      itemBuilder: (_) => [
        for (final s in Sonnerie.values)
          PopupMenuItem<Object>(
            value: s,
            height: 48,
            child: Row(
              children: [
                ContourSonnerie(s, couleur: p.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    s.libelle,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 14.5,
                      fontWeight: s == actuelle
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: p.text,
                    ),
                  ),
                ),
                if (s == actuelle)
                  Icon(PhosphorIconsLight.check, size: 18, color: p.primary),
              ],
            ),
          ),
        if (hotel != null && personnalisee) ...[
          const PopupMenuDivider(),
          PopupMenuItem<Object>(
            value: _celleDeLHotel,
            height: 48,
            child: Row(
              children: [
                Icon(
                  PhosphorIconsLight.arrowCounterClockwise,
                  size: 18,
                  color: p.textSecondary,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Reprendre celle de l’hôtel (${hotel!.libelle})',
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 14,
                      color: p.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
      // 48 points de haut au toucher, pour un bouton de 40.
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: pastille,
      ),
    );
  }
}

/// « Mes sonneries » : l'agent choisit la sienne pour chaque alerte qu'il
/// recoit. Pour lui seul, sur cette tablette, comme le son coupe.
Future<void> ouvrirMesSonneries(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => Theme(data: atriumBrandTheme(), child: const _MesSonneries()),
);

class _MesSonneries extends ConsumerWidget {
  const _MesSonneries();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final session = ref.watch(sessionProvider);
    final agent = session.agent?.id;
    final mes =
        ref.watch(preferencesAlertesProvider).value ??
        const PreferencesAlertes();
    final hotel =
        ref.watch(sonneriesAlertesProvider).value ?? const SonneriesAlertes();
    final niveaux =
        ref.watch(niveauxAlertesProvider).value ?? const NiveauxAlertes();
    final contexte = ContexteAlertes(
      agentId: agent,
      peut: session.acces.peut,
      accueil: session.acces.homeRoute,
      maintenant: DateTime.now(),
    );
    final types = [
      for (final t in TypeEvenement.values)
        if (t.concerne(contexte)) t,
    ];

    final texte = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 14,
      height: 1.45,
      color: p.textSecondary,
    );

    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.musicNotes, size: 30),
      title: const Text('Mes sonneries'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Pour vous seul, sur cette tablette. Une alerte que vous ne '
                'changez pas garde la sonnerie choisie pour l’hôtel.',
                style: texte,
              ),
              if (mes.sonCoupe) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.accentTint,
                    borderRadius: BorderRadius.circular(AtriumRadii.md),
                    border: Border.all(color: p.accentBorder),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        PhosphorIconsLight.speakerSlash,
                        size: 18,
                        color: p.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Le son de vos alertes est coupé : ces sonneries '
                          'ne s’entendront qu’une fois le son rétabli, '
                          'depuis votre menu.',
                          style: texte.copyWith(color: p.textOnMuted),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              for (final (i, type) in types.indexed) ...[
                if (i > 0) Divider(height: 1, color: p.border),
                _LigneSonnerie(
                  type: type,
                  sonnerie: mes.sonnerie(type, hotel),
                  hotel: hotel.de(type),
                  personnalisee: mes.sonneries.containsKey(type),
                  sonne: niveaux.de(type).sonne,
                  surChoix: agent == null
                      ? null
                      : (s) => ref
                            .read(settingsRepositoryProvider)
                            .setSonnerieAgent(agent, type, s),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}

class _LigneSonnerie extends StatelessWidget {
  const _LigneSonnerie({
    required this.type,
    required this.sonnerie,
    required this.hotel,
    required this.personnalisee,
    required this.sonne,
    required this.surChoix,
  });

  final TypeEvenement type;
  final Sonnerie sonnerie;
  final Sonnerie hotel;
  final bool personnalisee;

  /// Faux quand l'administration a regle l'evenement « discret ».
  final bool sonne;
  final ValueChanged<Sonnerie?>? surChoix;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final critique = type.graviteHabituelle == NiveauAlerte.critique;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: critique ? p.errorTint : p.accentTint,
            ),
            child: Icon(
              iconeEvenement(type),
              size: 20,
              color: critique ? p.error : p.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  type.libelle,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  !sonne
                      ? 'Discrète pour tout l’hôtel : elle ne sonne pas'
                      : personnalisee
                      ? 'Votre choix'
                      : 'Celle de l’hôtel',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ChoixSonnerie(
            type: type,
            actuelle: sonnerie,
            hotel: hotel,
            personnalisee: personnalisee,
            actif: sonne && surChoix != null,
            surChoix: surChoix ?? (_) {},
          ),
        ],
      ),
    );
  }
}
