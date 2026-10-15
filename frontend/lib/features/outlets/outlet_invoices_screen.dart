/// Les factures des points de vente (demande du 14 octobre, ticket D2).
///
/// Le comptoir retrouve ce qu'il a encaisse : chaque vente payee, son
/// montant, son moyen, ce qui a ete servi, et le ticket a refaire quand un
/// client le redemande. Un jour a la fois, aujourd'hui par defaut.
///
/// Le total du jour s'affiche, tiroir ouvert ou non (decision du 15 octobre) :
/// chaque facture disait deja son montant, cacher la somme ne protegeait rien.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/recherche.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/confirmation.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/factures_pdv_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../billing/charge_labels.dart' show paymentMethodLabel;
import '../billing/invoice_pdf.dart' show partagerPdf, ticketDeComptoir;
import '../billing/payment_dialog.dart' show iconePaiement;
import '../hotel/logo_images.dart' show logoTicketProvider;

const _titre = 'Factures';

/// Ce que l'on regarde : des points de vente et une journee.
typedef _Cle = ({String pointsDeVente, DateTime jour});

final _facturesProvider = StreamProvider.family<List<FacturePdv>, _Cle>(
  (ref, c) => ref
      .watch(databaseProvider)
      .watchFacturesPdv(
        pointsDeVente: c.pointsDeVente.split(','),
        jour: c.jour,
      ),
);

class OutletInvoicesScreen extends ConsumerStatefulWidget {
  const OutletInvoicesScreen({super.key});

  @override
  ConsumerState<OutletInvoicesScreen> createState() =>
      _OutletInvoicesScreenState();
}

class _OutletInvoicesScreenState extends ConsumerState<OutletInvoicesScreen> {
  DateTime _jour = businessDayFor(DateTime.now());

  /// Le point de vente choisi ; `null` : tous ceux de l'agent.
  String? _pointDeVente;
  String _cherche = '';

  Future<void> _choisirJour() async {
    final aujourdhui = businessDayFor(DateTime.now());
    final choisi = await showDatePicker(
      context: context,
      initialDate: _jour,
      firstDate: DateTime(aujourdhui.year - 1),
      lastDate: aujourdhui,
      helpText: 'Factures du',
    );
    if (choisi != null) setState(() => _jour = choisi);
  }

  void _decaler(int jours) => setState(
    () => _jour = DateTime(_jour.year, _jour.month, _jour.day + jours),
  );

  @override
  Widget build(BuildContext context) {
    final agentId = ref.watch(sessionProvider).agent?.id;
    if (agentId == null) {
      return const ModuleScaffold(title: _titre, body: SizedBox.shrink());
    }
    final points =
        ref.watch(perimetrePdvProvider(agentId)).value?.pointsDeVente ??
        const [];
    if (points.isEmpty) {
      return const ModuleScaffold(
        title: _titre,
        body: EmptyState(
          icon: PhosphorIconsLight.receipt,
          title: 'Aucun point de vente',
          message:
              'Les points de vente arrivent du serveur : lancez une '
              'synchronisation.',
        ),
      );
    }
    final choisis = _pointDeVente != null &&
            points.any((o) => o.id == _pointDeVente)
        ? [_pointDeVente!]
        : [for (final o in points) o.id];
    final cle = choisis.join(',');
    final factures =
        ref.watch(_facturesProvider((pointsDeVente: cle, jour: _jour))).value ??
        const <FacturePdv>[];
    final recherche = Recherche(_cherche);
    final visibles = [
      for (final f in factures)
        if (recherche.garde([
          f.numero,
          f.client,
          f.agent,
          f.pointDeVente,
          paymentMethodLabel(f.moyen),
          '${f.montant}',
          for (final l in f.lignes) l.$1,
        ]))
          f,
    ];
    final aujourdhui = businessDayFor(DateTime.now());
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    final p = AtriumPalette.current;
    final total = factures.fold(0, (t, f) => t + f.montant);

    return ModuleScaffold(
      title: _titre,
      subtitle: points.length == 1
          ? 'Les ventes payées : ${points.single.label}'
          : 'Les ventes payées de vos points de vente',
      body: ListView(
        padding: EdgeInsets.fromLTRB(marge, 0, marge, 36),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton.outlined(
                tooltip: 'Jour précédent',
                onPressed: () => _decaler(-1),
                icon: const Icon(PhosphorIconsLight.arrowLeft),
              ),
              OutlinedButton.icon(
                onPressed: _choisirJour,
                icon: const Icon(PhosphorIconsLight.calendarBlank),
                label: Text(
                  _jour == aujourdhui
                      ? "Aujourd'hui"
                      : formatShortDate(_jour),
                ),
              ),
              IconButton.outlined(
                tooltip: 'Jour suivant',
                onPressed: _jour.isBefore(aujourdhui) ? () => _decaler(1) : null,
                icon: const Icon(PhosphorIconsLight.arrowRight),
              ),
            ],
          ),
          if (points.length > 1) ...[
            const SizedBox(height: 12),
            FilterPills<String?>(
              selected: _pointDeVente,
              onChanged: (v) => setState(() => _pointDeVente = v),
              options: [
                const FilterOption(null, 'Tous'),
                for (final o in points) FilterOption(o.id, o.label),
              ],
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            onChanged: (v) => setState(() => _cherche = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(PhosphorIconsLight.magnifyingGlass),
              hintText: 'Un client, un article, un numéro, un montant…',
            ),
          ),
          const SizedBox(height: 16),
          Text(
            factures.isEmpty
                ? 'Aucune vente payée ce jour-là.'
                : '${factures.length} vente${factures.length > 1 ? 's' : ''}'
                      ' payée${factures.length > 1 ? 's' : ''}'
                      ' · ${formatAmount(total)}',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
              fontFeatures: tabularFigures,
            ),
          ),
          const SizedBox(height: 12),
          for (final f in visibles) ...[
            _Facture(facture: f, plusieurs: points.length > 1),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

String _hm(DateTime d) {
  final l = d.toLocal();
  return '${l.hour} h ${l.minute.toString().padLeft(2, '0')}';
}

/// Une facture : l'heure, le client, ce qui a ete servi, le montant et le
/// moyen ; « Ticket » le refait.
class _Facture extends ConsumerWidget {
  const _Facture({required this.facture, required this.plusieurs});

  final FacturePdv facture;

  /// Plusieurs points de vente a l'ecran : chaque facture dit le sien.
  final bool plusieurs;

  Future<void> _ticket(BuildContext context, WidgetRef ref) async {
    final f = facture;
    try {
      final hotel = await ref.read(hotelProvider.future);
      Uint8List? logo;
      try {
        logo = await ref.read(logoTicketProvider.future);
      } on Object {
        // Sans logo, le ticket reste lisible.
      }
      final octets = await ticketDeComptoir(
        hotel: hotel,
        logoNoirBlanc: logo,
        pointDeVente: f.pointDeVente,
        numero: f.numero,
        date: f.recueLe?.toLocal() ?? DateTime.now(),
        lignes: f.lignes,
        moyen: paymentMethodLabel(f.moyen),
        client: f.client,
        agent: f.agent,
      );
      await partagerPdf(
        octets,
        nom: 'Ticket ${f.numero}',
        sujet: 'Ticket ${f.pointDeVente}',
      );
    } on Object catch (e) {
      if (context.mounted) {
        montrerRefus(context, 'Le ticket n’a pas pu être fait : $e');
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final f = facture;
    final articles = f.lignes
        .map((l) => l.$3 > 1 ? '${l.$3} × ${l.$1}' : l.$1)
        .join(', ');
    final entete = [
      if (f.recueLe != null) _hm(f.recueLe!),
      f.client ?? 'Client divers',
      if (plusieurs) f.pointDeVente,
    ].join(' · ');

    return Bezel(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
      child: Row(
        children: [
          Icon(iconePaiement(f.moyen), size: 26, color: p.text),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entete,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  articles.isEmpty ? f.numero : articles,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: p.textSecondary),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    paymentMethodLabel(f.moyen),
                    f.numero,
                    if (f.agent != null) f.agent!,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: p.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatAmount(f.montant),
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: p.text,
                  fontFeatures: tabularFigures,
                ),
              ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () => _ticket(context, ref),
                icon: const Icon(PhosphorIconsLight.printer, size: 18),
                label: const Text('Ticket'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
