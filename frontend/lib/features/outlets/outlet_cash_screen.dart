/// Ma caisse : l'onglet Caisse de l'agent d'un point de vente.
///
/// L'ecran « Caisse du jour » est celui de la caisse centrale : il montre
/// tous les encaissements de l'hotel et l'ecart de chacun. Le barman n'y a
/// rien a faire. Ici, il voit ses tiroirs, les ouvre et les ferme sur place,
/// et suit ses versements jusqu'a leur reception.
///
/// **Comptage a l'aveugle** (decision du 11 octobre) : tant que le tiroir
/// est ouvert, les especes ne se chiffrent pas -- fond plus especes, c'est
/// l'attendu qu'il doit retrouver seul. Les autres moyens (carte, mobile
/// money) ne sont pas dans le tiroir : ils se montrent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/cash_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../billing/cash_dialog.dart' show CashButton;
import '../billing/charge_labels.dart' show paymentMethodLabel;

const _titre = 'Ma caisse';

class OutletCashScreen extends ConsumerWidget {
  const OutletCashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agentId = ref.watch(sessionProvider).agent?.id;
    if (agentId == null) {
      return const ModuleScaffold(title: _titre, body: SizedBox.shrink());
    }
    final perimetre = ref.watch(perimetrePdvProvider(agentId)).value;
    final tiroirs = ref.watch(mesTiroirsProvider(agentId)).value ?? const [];
    final points = perimetre?.pointsDeVente ?? const [];
    final libelles = {for (final o in points) o.id: o.label};
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final verses = tiroirs.where((t) => !t.ouvert).toList();

    return ModuleScaffold(
      title: _titre,
      subtitle: points.isEmpty
          ? null
          : 'Vos tiroirs : ${points.map((o) => o.label).join(', ')}',
      body: points.isEmpty
          ? const EmptyState(
              icon: PhosphorIconsLight.cashRegister,
              title: 'Aucun point de vente',
              message:
                  'Les points de vente arrivent du serveur : lancez une '
                  'synchronisation.',
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(marge, 0, marge, 36),
              children: [
                for (final o in points) ...[
                  _Tiroir(
                    libelle: o.label,
                    outletId: o.id,
                    tiroir: tiroirs
                        .where((t) => t.ouvert && t.session.outletId == o.id)
                        .firstOrNull,
                  ),
                  const SizedBox(height: 14),
                ],
                _Versements(verses: verses, libelles: libelles),
              ],
            ),
    );
  }
}

TextStyle _st(double taille, FontWeight poids, Color couleur) => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: taille,
  fontWeight: poids,
  color: couleur,
  fontFeatures: tabularFigures,
);

String _hm(DateTime d) {
  final l = d.toLocal();
  return '${l.hour} h ${l.minute.toString().padLeft(2, '0')}';
}

/// Le tiroir d'un point de vente : ouvert ou non, et ce qui y est entre.
class _Tiroir extends StatelessWidget {
  const _Tiroir({
    required this.libelle,
    required this.outletId,
    required this.tiroir,
  });

  final String libelle;
  final String outletId;

  /// `null` : pas de tiroir ouvert sur ce point de vente.
  final TiroirAgent? tiroir;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final t = tiroir;
    final depuis = t?.session.openedAt;

    return Bezel(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(libelle, trailing: CashButton(outletId: outletId)),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: t != null ? p.success : p.textSecondary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t == null
                      ? 'Caisse fermée'
                      : 'Ouverte${depuis == null ? '' : ' depuis ${_hm(depuis)}'}',
                  style: _st(15, FontWeight.w700, p.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (t == null)
            Text(
              'Rien ne se sert sans le tiroir ouvert, même porté à la chambre.',
              style: _st(13.5, FontWeight.w500, p.textSecondary),
            )
          else ...[
            Text(
              'Fond de caisse : ${formatAmount(t.session.openingFloat)} · '
              '${t.nombre} encaissement${t.nombre > 1 ? 's' : ''}',
              style: _st(13.5, FontWeight.w500, p.textSecondary),
            ),
            for (final MapEntry(key: moyen, value: (nombre, montant))
                in t.parMoyen.entries)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${paymentMethodLabel(moyen)} · $nombre',
                        style: _st(14, FontWeight.w500, p.text),
                      ),
                    ),
                    // Les especes sont dans le tiroir : a compter, pas a lire.
                    Text(
                      moyen == PaymentMethod.CASH
                          ? 'à compter au versement'
                          : formatAmount(montant),
                      style: _st(
                        14,
                        FontWeight.w600,
                        moyen == PaymentMethod.CASH ? p.textSecondary : p.text,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Les versements : ce que l'agent a declare, ce que la reception a recu,
/// et l'ecart constate a la fermeture.
class _Versements extends StatelessWidget {
  const _Versements({required this.verses, required this.libelles});

  final List<TiroirAgent> verses;
  final Map<String, String> libelles;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Mes versements'),
          const SizedBox(height: 6),
          if (verses.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Aucun versement encore.',
                style: _st(14, FontWeight.w500, p.textSecondary),
              ),
            ),
          for (final (i, t) in verses.indexed) ...[
            if (i > 0) Divider(height: 1, color: p.border),
            _LigneVersement(
              tiroir: t,
              libelle: libelles[t.session.outletId] ?? 'Point de vente',
            ),
          ],
        ],
      ),
    );
  }
}

class _LigneVersement extends StatelessWidget {
  const _LigneVersement({required this.tiroir, required this.libelle});

  final TiroirAgent tiroir;
  final String libelle;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final s = tiroir.session;
    final fin = s.closedAt?.toLocal();

    final Widget etat;
    if (s.countedAmount == null) {
      etat = const Tag('Fermée');
    } else if (s.variance == 0) {
      etat = Tag('Juste', color: p.success);
    } else {
      // Le signe dit le sens : la couleur n'est qu'un renfort.
      etat = Tag(
        '${s.variance > 0 ? '+' : '−'}${formatAmount(s.variance.abs())}',
        color: p.error,
      );
    }

    final detail = [
      if (s.countedAmount != null) 'versé ${formatAmount(s.countedAmount!)}',
      if (s.receivedAt != null)
        'reçu ${formatAmount(s.receivedAmount ?? 0)}'
      else
        'en attente de la réception',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fin == null
                      ? libelle
                      : '$libelle · ${formatDayMonth(fin)} ${_hm(fin)}',
                  style: _st(14.5, FontWeight.w700, p.text),
                ),
                Text(detail, style: _st(12.5, FontWeight.w500, p.textSecondary)),
              ],
            ),
          ),
          etat,
        ],
      ),
    );
  }
}
