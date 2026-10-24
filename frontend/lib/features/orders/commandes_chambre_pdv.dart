/// Les commandes en chambre, cote point de vente (F2.7, reunion du 18
/// octobre).
///
/// La reception a commande pour une chambre ; le bar voit la commande
/// arriver en tete de son ecran, la prend en charge, la prepare et la monte.
/// Devant le plateau, le client choisit : il paie maintenant, ou la commande
/// reste sur l'ardoise de sa chambre (decision du client, 18 octobre).
///
/// Le bandeau n'apparait que s'il y a quelque chose a monter : un point de
/// vente sans commande en route garde son ecran tel quel.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/confirmation.dart';
import '../../core/ui/fenetre_motif.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/room_order_repository.dart';
import '../auth/session.dart';
import '../billing/cash_dialog.dart' show avecCaisse;
import '../billing/charge_labels.dart';
import '../billing/payment_dialog.dart' show iconePaiement;

/// Le bandeau des commandes a monter, ou rien.
class CommandesEnChambre extends ConsumerWidget {
  const CommandesEnChambre({
    super.key,
    required this.outlet,
    required this.marge,
  });

  final OutletRow outlet;
  final double marge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!outlet.allowsRoomCharge) return const SizedBox.shrink();
    final commandes =
        ref.watch(commandesEnRouteProvider(outlet.id)).value ??
        const <CommandeChambre>[];
    if (commandes.isEmpty) return const SizedBox.shrink();
    final p = AtriumPalette.current;
    final n = commandes.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(marge, 0, marge, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$n commande${n > 1 ? 's' : ''} en chambre à monter',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final c in commandes) _CarteCommande(commande: c),
            ],
          ),
        ],
      ),
    );
  }
}

/// « 21 h 40 », l'heure telle qu'on la dit au telephone.
String _heure(DateTime t) =>
    '${t.hour} h ${t.minute.toString().padLeft(2, '0')}';

class _CarteCommande extends ConsumerWidget {
  const _CarteCommande({required this.commande});

  final CommandeChambre commande;

  Future<void> _geste(
    BuildContext context,
    Future<void> Function() geste,
    String succes,
  ) async {
    try {
      await geste();
      if (context.mounted) montrerSucces(context, succes);
    } on StateError catch (e) {
      if (context.mounted) montrerRefus(context, e.message);
    }
  }

  Future<void> _livrer(BuildContext context, WidgetRef ref, String by) async {
    final choix = await showDialog<_ChoixLivraison>(
      context: context,
      builder: (_) => _Livraison(commande: commande),
    );
    if (choix == null || !context.mounted) return;
    final chambre = commande.chambre ?? '—';
    await _geste(
      context,
      // Caisse fermee : on propose de l'ouvrir, puis on livre.
      () => avecCaisse(
        context,
        ref,
        () => ref
            .read(roomOrderRepositoryProvider)
            .livrer(orderId: commande.id, by: by, payeMaintenant: choix.moyen),
      ),
      choix.moyen == null
          ? 'Livrée en $chambre : ${formatAmount(commande.total)} sur '
                'l’ardoise de la chambre.'
          : 'Livrée en $chambre : ${formatAmount(commande.total)} encaissés.',
    );
  }

  Future<void> _annuler(BuildContext context, WidgetRef ref, String by) async {
    final motif = await demanderMotif(
      context,
      titre: 'Annuler la commande de la ${commande.chambre ?? 'chambre'}',
      libelleRenoncer: 'Garder la commande',
      libelleConfirmer: 'Annuler la commande',
      libelleMotif: 'Motif',
      indice: 'Plus de stock, le client s’est ravisé…',
      autofocus: true,
      largeur: 420,
    );
    if (motif == null || !context.mounted) return;
    await _geste(
      context,
      () => ref
          .read(roomOrderRepositoryProvider)
          .annuler(orderId: commande.id, motif: motif, by: by),
      'Commande annulée.',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final session = ref.watch(sessionProvider);
    final agent = session.agent?.id;
    final peut = agent != null && session.acces.peut('order.manage');
    final prise = commande.statut == OrderStatus.IN_PREP;
    final quand = commande.commandeeA == null
        ? ''
        : ' à ${_heure(commande.commandeeA!.toLocal())}';
    final secondaire = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 13.5,
      height: 1.4,
      color: p.textSecondary,
    );

    return Container(
      width: 320,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: prise ? p.warning : p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Chambre ${commande.chambre ?? '—'}',
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: p.text,
                  ),
                ),
              ),
              Text(
                formatAmount(commande.total),
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                  fontFeatures: tabularFigures,
                ),
              ),
            ],
          ),
          Text(
            [
              if (commande.client != null) commande.client!,
              prise ? 'En préparation' : 'Commandée$quand',
            ].join(' · '),
            style: secondaire,
          ),
          const SizedBox(height: 10),
          for (final l in commande.lignes)
            Text(
              '${l.quantite} × ${l.libelle}'
              '${l.notes == null ? '' : ' (${l.notes})'}',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 15,
                color: p.text,
              ),
            ),
          if (commande.notes != null) ...[
            const SizedBox(height: 6),
            Text('« ${commande.notes} »', style: secondaire),
          ],
          if (peut) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!prise)
                  OutlinedButton(
                    onPressed: () => _geste(
                      context,
                      () => ref
                          .read(roomOrderRepositoryProvider)
                          .prendreEnCharge(orderId: commande.id, by: agent),
                      'Commande de la ${commande.chambre ?? 'chambre'} prise '
                      'en charge.',
                    ),
                    child: const Text('Prendre en charge'),
                  ),
                FilledButton(
                  onPressed: () => _livrer(context, ref, agent),
                  child: const Text('Livrer'),
                ),
                IconButton(
                  tooltip: 'Annuler la commande',
                  onPressed: () => _annuler(context, ref, agent),
                  icon: const Icon(PhosphorIconsLight.x),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Ce que le client a choisi devant le plateau : `moyen` nul, sur l'ardoise.
typedef _ChoixLivraison = ({PaymentMethod? moyen});

/// Le client paie maintenant, ou laisse sur l'ardoise de sa chambre.
class _Livraison extends StatefulWidget {
  const _Livraison({required this.commande});

  final CommandeChambre commande;

  @override
  State<_Livraison> createState() => _LivraisonState();
}

class _LivraisonState extends State<_Livraison> {
  bool _payeMaintenant = false;
  PaymentMethod _moyen = PaymentMethod.CASH;

  static const _moyens = [
    PaymentMethod.CASH,
    PaymentMethod.MOBILE_MONEY,
    PaymentMethod.CARD,
  ];

  @override
  Widget build(BuildContext context) {
    final c = widget.commande;
    return AlertDialog(
      scrollable: true,
      icon: const Icon(PhosphorIconsLight.bell, size: 30),
      title: Text(
        'Livrer en ${c.chambre ?? 'chambre'} : ${formatAmount(c.total)}',
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ChoiceTiles<bool>(
              selected: _payeMaintenant,
              tileWidth: 220,
              onChanged: (v) => setState(() => _payeMaintenant = v),
              options: const [
                (false, PhosphorIconsLight.bed, 'Sur l’ardoise de la chambre'),
                (true, PhosphorIconsLight.coins, 'Le client paie maintenant'),
              ],
            ),
            if (_payeMaintenant) ...[
              const SizedBox(height: 16),
              ChoiceTiles<PaymentMethod>(
                selected: _moyen,
                tileWidth: 148,
                onChanged: (m) => setState(() => _moyen = m),
                options: [
                  for (final m in _moyens)
                    (m, iconePaiement(m), paymentMethodLabel(m)),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Retour'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop<_ChoixLivraison>((moyen: _payeMaintenant ? _moyen : null)),
          child: Text(_payeMaintenant ? 'Encaisser et livrer' : 'Livrer'),
        ),
      ],
    );
  }
}
