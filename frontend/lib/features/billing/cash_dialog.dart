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
  const CashButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(sessionProvider).agent?.id;
    if (agent == null) return const SizedBox.shrink();

    final caisse = ref.watch(currentCashProvider(agent));

    return caisse.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (vue) => vue == null
          ? PillButton(
              label: 'Ouvrir la caisse',
              icon: PhosphorIconsLight.lockSimpleOpen,
              tone: PillTone.accent,
              onPressed: () => _ouvrir(context, ref, agent),
            )
          // L'attendu n'est pas affiche ici : il se revele apres le
          // comptage, pas avant (voir l'en-tete du fichier).
          : PillButton(
              label: 'Fermer la caisse',
              icon: PhosphorIconsLight.cashRegister,
              tone: PillTone.quiet,
              onPressed: () => _fermer(context, ref, vue),
            ),
    );
  }

  Future<void> _ouvrir(
    BuildContext context,
    WidgetRef ref,
    String agent,
  ) async {
    final montant = await _demanderMontant(
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
          .open(userId: agent, openingFloat: montant, by: agent);
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
    final compte = await _demanderMontant(
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
      builder: (_) =>
          _Resultat(attendu: vue.expected, compte: compte, ecart: ecart),
    );
  }
}

/// Le bilan de fermeture. Un ecart se regarde en face.
class _Resultat extends StatelessWidget {
  const _Resultat({
    required this.attendu,
    required this.compte,
    required this.ecart,
  });

  final int attendu;
  final int compte;
  final int ecart;

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
      title: const Text('Caisse fermée'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Ligne(label: 'Attendu', montant: attendu),
            _Ligne(label: 'Compté', montant: compte),
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
                    juste ? 'Caisse juste' : 'Écart',
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
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                        color: couleur,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                    Text(
                      ecart > 0 ? 'de trop dans le tiroir' : 'manquants',
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

Future<int?> _demanderMontant(
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
                fontWeight: FontWeight.w800,
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

/// La caisse du jour, ouverte depuis la navigation : le chiffre de la
/// journee, l'etat du tiroir de l'agent, et le geste qui va avec (ouvrir ou
/// fermer). L'attendu du tiroir n'y figure pas, pour la meme raison qu'au
/// bouton : il se revele apres le comptage.
Future<void> showCaisseDuJour(BuildContext context, {required int caDuJour}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CaisseDuJour(caDuJour: caDuJour),
  );
}

class _CaisseDuJour extends ConsumerWidget {
  const _CaisseDuJour({required this.caDuJour});

  final int caDuJour;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final agent = ref.watch(sessionProvider).agent?.id;
    final caisse = agent == null
        ? null
        : ref.watch(currentCashProvider(agent)).value;
    final ouverte = caisse?.open ?? false;
    final depuis = caisse?.session.openedAt?.toLocal();

    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.cashRegister, size: 32),
      title: const Text('Caisse du jour'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: p.isDark ? p.nightRaised : p.night,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Encaissé aujourd'hui, tous moyens",
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13,
                      color: p.onNightSoft,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatAmount(caDuJour),
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.2,
                      color: p.accent,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: ouverte ? p.success : p.textSecondary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ouverte
                        ? 'Votre caisse est ouverte'
                              '${depuis == null ? '' : ' depuis ${depuis.hour.toString().padLeft(2, '0')}:${depuis.minute.toString().padLeft(2, '0')}'}.'
                        : "Vous n'avez pas de caisse ouverte.",
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Align(child: CashButton()),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
