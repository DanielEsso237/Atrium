/// Prise de poste et fin de service : la caisse (F1.4).
///
/// Deux gestes, une fois chacun par service. D'ou un seul bouton qui change de
/// sens selon l'etat : ouvrir quand il n'y a pas de caisse, fermer quand il y
/// en a une.
///
/// **L'attendu ne s'affiche pas avant le comptage.** Montrer « vous devriez
/// avoir 48 000 » puis demander de compter, c'est demander de confirmer un
/// chiffre plutot que de compter. L'agent saisit ce qu'il a dans le tiroir, et
/// l'ecart se revele ensuite.
///
/// **La caisse d'un point de vente se ferme en versant.** La reception est la
/// caisse centrale : le soir, l'agent du point de vente declare ce qu'il lui
/// remet, et c'est ce geste qui ferme son tiroir. La reception confirme
/// ensuite ce qu'elle recoit, sur l'ecran Caisse.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/repositories/cash_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

/// Le bouton de caisse du module Factures.
class CashButton extends ConsumerWidget {
  const CashButton({super.key, this.outletId});

  /// Le point de vente dont c'est le tiroir ; nul pour la caisse centrale.
  ///
  /// Un tiroir par point de vente, quel que soit l'agent : ouvrir le bar
  /// n'ouvre plus la caisse de tous les points de vente.
  final String? outletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final agent = session.agent?.id;
    if (agent == null) return const SizedBox.shrink();
    final pointDeVente = outletId;

    final caisse = ref.watch(currentCashProvider((agent, pointDeVente)));

    return caisse.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (vue) => vue == null
          ? PillButton(
              label: 'Ouvrir la caisse',
              icon: PhosphorIconsLight.lockSimpleOpen,
              tone: PillTone.accent,
              onPressed: () => _ouvrir(context, ref, agent, pointDeVente),
            )
          // L'attendu n'est pas affiche ici : il se revele apres le
          // comptage, pas avant (voir l'en-tete du fichier).
          : PillButton(
              label: vue.ofOutlet ? 'Verser à la réception' : 'Fermer la caisse',
              icon: vue.ofOutlet
                  ? PhosphorIconsLight.coins
                  : PhosphorIconsLight.cashRegister,
              tone: PillTone.quiet,
              onPressed: () => _fermer(context, ref, vue),
            ),
    );
  }

  Future<void> _ouvrir(
    BuildContext context,
    WidgetRef ref,
    String agent,
    String? pointDeVente,
  ) async {
    final montant = await demanderMontant(
      context,
      titre: 'Ouvrir la caisse',
      question: 'Combien y a-t-il dans le tiroir en prenant votre poste ?',
      champ: 'Fond de caisse (FCFA)',
      action: 'Ouvrir',
    );
    if (montant == null || !context.mounted) return;

    try {
      await ref
          .read(cashRepositoryProvider)
          .open(
            userId: agent,
            openingFloat: montant,
            by: agent,
            outletId: pointDeVente,
          );
    } on StateError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Caisse ouverte à ${formatAmount(montant)}.')),
    );
  }

  Future<void> _fermer(
    BuildContext context,
    WidgetRef ref,
    CashView vue,
  ) async {
    final versement = vue.ofOutlet;
    final compte = versement
        ? await demanderMontant(
            context,
            titre: 'Verser à la réception',
            question:
                'Comptez le tiroir et saisissez ce que vous remettez à la '
                'réception. Votre caisse se ferme, et la réception confirmera '
                "ce qu'elle reçoit.",
            champ: 'Montant versé (FCFA)',
            action: 'Verser',
          )
        : await demanderMontant(
            context,
            titre: 'Fermer la caisse',
            question:
                'Comptez le tiroir et saisissez ce que vous trouvez. '
                "L'écart s'affichera ensuite.",
            champ: 'Montant compte (FCFA)',
            action: 'Fermer',
          );
    if (compte == null || !context.mounted) return;

    final int ecart;
    try {
      ecart = await ref
          .read(cashRepositoryProvider)
          .close(
            sessionId: vue.session.id,
            countedAmount: compte,
            by: ref.read(sessionProvider).agent?.id,
          );
    } on StateError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _Resultat(
        attendu: vue.expected,
        compte: compte,
        ecart: ecart,
        versement: versement,
      ),
    );
  }
}

/// Le bilan de fermeture. Un ecart se regarde en face.
class _Resultat extends StatelessWidget {
  const _Resultat({
    required this.attendu,
    required this.compte,
    required this.ecart,
    this.versement = false,
  });

  final int attendu;
  final int compte;
  final int ecart;

  /// Le versement d'un point de vente, et non un simple comptage.
  final bool versement;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final juste = ecart == 0;
    final couleur = juste ? p.success : p.error;

    return AlertDialog(
      icon: Icon(
        juste ? PhosphorIconsLight.sealCheck : PhosphorIconsLight.scales,
        size: 34,
        color: couleur,
      ),
      title: Text(versement ? 'Versement déclaré' : 'Caisse fermée'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Ligne(label: 'Attendu', montant: attendu),
            _Ligne(label: versement ? 'Versé' : 'Compté', montant: compte),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: couleur.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: couleur.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  Text(
                    juste
                        ? (versement ? 'Versement juste' : 'Caisse juste')
                        : 'Écart',
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                  if (!juste) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${ecart > 0 ? '+' : ''}${formatAmount(ecart)}',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                        color: couleur,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                    Text(
                      ecart > 0
                          ? (versement ? 'de trop' : 'de trop dans le tiroir')
                          : 'manquants',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 14,
                        color: p.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (versement) ...[
              const SizedBox(height: 14),
              Text(
                'Remettez cette somme à la réception : elle confirmera ce '
                "qu'elle reçoit.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 14,
                  color: p.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Terminé'),
        ),
      ],
    );
  }
}

class _Ligne extends StatelessWidget {
  const _Ligne({required this.label, required this.montant});

  final String label;
  final int montant;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 15,
            color: AtriumColors.textSecondary,
          ),
        ),
        const Spacer(),
        Text(
          formatAmount(montant),
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AtriumColors.textPrimary,
            fontFeatures: tabularFigures,
          ),
        ),
      ],
    ),
  );
}

/// Demande un montant en francs CFA ; `null` si l'agent renonce.
Future<int?> demanderMontant(
  BuildContext context, {
  required String titre,
  required String question,
  required String champ,
  required String action,
}) {
  final controleur = TextEditingController();

  return showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(PhosphorIconsLight.cashRegister, size: 32),
      title: Text(titre),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(question),
            const SizedBox(height: 18),
            TextField(
              controller: controleur,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
                color: AtriumColors.textPrimary,
                fontFeatures: tabularFigures,
              ),
              decoration: InputDecoration(
                labelText: champ,
                prefixIcon: const Icon(PhosphorIconsLight.coins, size: 22),
                suffixText: 'FCFA',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () {
            final n = int.tryParse(controleur.text.trim());
            if (n == null || n < 0) return;
            Navigator.of(dialogContext).pop(n);
          },
          child: Text(action),
        ),
      ],
    ),
  );
}
