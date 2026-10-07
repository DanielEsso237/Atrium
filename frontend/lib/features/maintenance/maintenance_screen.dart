/// Maintenance (cahier des charges, F2.3, F4.1-F4.4).
///
/// Un tableau a trois colonnes, comme le menage : ce qui est signale, ce qui
/// est pris en charge, ce qui est repare et attend d'etre verifie. Un seul
/// bouton par ticket, l'etape suivante. Les tickets clos se rangent a part.
///
/// Un probleme se signale aussi depuis la fiche d'une chambre : c'est la que
/// la reception le decouvre, quand un client appelle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../core/widgets/kanban_drag.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/maintenance_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

class MaintenanceScreen extends ConsumerStatefulWidget {
  const MaintenanceScreen({super.key});

  @override
  ConsumerState<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends ConsumerState<MaintenanceScreen> {
  bool _voirClos = false;

  @override
  Widget build(BuildContext context) {
    final tickets = ref.watch(ticketsProvider);
    final liste = tickets.value ?? const <TicketSummary>[];
    final peutGerer = ref
        .watch(sessionProvider)
        .acces
        .peut('maintenance.manage');
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    final ouverts = liste.where((t) => t.status == TicketStatus.OPEN).toList();
    final pris = liste
        .where(
          (t) =>
              t.status == TicketStatus.ASSIGNED ||
              t.status == TicketStatus.IN_PROGRESS,
        )
        .toList();
    final resolus = liste
        .where((t) => t.status == TicketStatus.RESOLVED)
        .toList();
    final clos = liste
        .where(
          (t) =>
              t.status == TicketStatus.CLOSED ||
              t.status == TicketStatus.CANCELLED,
        )
        .toList();
    final bloquees = [
      ...ouverts,
      ...pris,
      ...resolus,
    ].where((t) => t.blocksRoom).length;

    return ModuleScaffold(
      title: 'Maintenance',
      subtitle: liste.isEmpty
          ? null
          : '${ouverts.length + pris.length} en cours, '
                '$bloquees chambre${bloquees > 1 ? 's' : ''} '
                'hors service',
      action: peutGerer
          ? PillButton(
              label: 'Signaler un problème',
              icon: PhosphorIconsLight.warningDiamond,
              tone: PillTone.accent,
              onPressed: () => showReportIssueDialog(context),
            )
          : null,
      body: tickets.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: PhosphorIconsLight.warningCircle,
          title: 'Lecture impossible',
          message: '$e',
        ),
        data: (_) {
          if (liste.isEmpty) {
            return EmptyState(
              icon: PhosphorIconsLight.wrench,
              title: 'Aucun ticket',
              message:
                  'Une ampoule, une fuite, une clim : signalez-le ici ou '
                  'depuis la fiche de la chambre.',
              action: peutGerer
                  ? PillButton(
                      label: 'Signaler un problème',
                      icon: PhosphorIconsLight.warningDiamond,
                      tone: PillTone.quiet,
                      onPressed: () => showReportIssueDialog(context),
                    )
                  : null,
            );
          }
          final filtre = Padding(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 14),
            child: FilterPills<bool>(
              selected: _voirClos,
              onChanged: (v) => setState(() => _voirClos = v),
              options: [
                FilterOption(
                  false,
                  'En cours',
                  count: ouverts.length + pris.length + resolus.length,
                ),
                FilterOption(true, 'Clos', count: clos.length),
              ],
            ),
          );

          if (_voirClos) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                filtre,
                Expanded(
                  child: clos.isEmpty
                      ? const EmptyState(
                          icon: PhosphorIconsLight.archive,
                          title: 'Aucun ticket clos',
                        )
                      : ListView(
                          padding: EdgeInsets.fromLTRB(marge, 0, marge, 32),
                          children: [
                            for (final t in clos)
                              _CarteTicket(ticket: t, peutGerer: peutGerer),
                          ],
                        ),
                ),
              ],
            );
          }

          return LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth >= 900) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    filtre,
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(marge, 0, marge, 20),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _Colonne(
                                titre: 'Signalés',
                                statut: TicketStatus.OPEN,
                                couleur: CouleursEtat.occupee,
                                tickets: ouverts,
                                peutGerer: peutGerer,
                                vide: 'Rien de nouveau.',
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: _Colonne(
                                titre: 'Pris en charge',
                                statut: TicketStatus.ASSIGNED,
                                couleur: CouleursEtat.nettoyage,
                                tickets: pris,
                                peutGerer: peutGerer,
                                vide: 'Personne sur un ticket.',
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: _Colonne(
                                titre: 'Résolus',
                                statut: TicketStatus.RESOLVED,
                                couleur: CouleursEtat.disponible,
                                tickets: resolus,
                                peutGerer: peutGerer,
                                vide:
                                    'Les réparations faites attendent ici '
                                    "d'être vérifiées.",
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }
              return ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  filtre,
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: marge),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (titre, groupe) in [
                          ('Signalés', ouverts),
                          ('Pris en charge', pris),
                          ('Résolus', resolus),
                        ])
                          if (groupe.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.only(
                                top: 8,
                                bottom: 10,
                              ),
                              child: Eyebrow('$titre (${groupe.length})'),
                            ),
                            for (final t in groupe)
                              _CarteTicket(ticket: t, peutGerer: peutGerer),
                          ],
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _Colonne extends StatelessWidget {
  const _Colonne({
    required this.titre,
    required this.statut,
    required this.couleur,
    required this.tickets,
    required this.peutGerer,
    required this.vide,
  });

  final String titre;
  final TicketStatus statut;
  final Color couleur;
  final List<TicketSummary> tickets;
  final bool peutGerer;
  final String vide;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return DragTarget<_TicketDrag>(
      key: ValueKey('maintenance-column-${statut.name}'),
      onWillAcceptWithDetails: (details) =>
          peutGerer &&
          switch ((details.data.ticket.status, statut)) {
            (TicketStatus.OPEN, TicketStatus.ASSIGNED) => true,
            (
              TicketStatus.ASSIGNED || TicketStatus.IN_PROGRESS,
              TicketStatus.RESOLVED,
            ) =>
              true,
            (
              TicketStatus.ASSIGNED || TicketStatus.IN_PROGRESS,
              TicketStatus.OPEN,
            ) =>
              true,
            (
              TicketStatus.RESOLVED,
              TicketStatus.OPEN || TicketStatus.ASSIGNED,
            ) =>
              true,
            _ => false,
          },
      // Le depot appelle exactement l'action du bouton de la carte : meme
      // compte rendu obligatoire, memes controles et meme file d'envoi.
      onAcceptWithDetails: (details) => details.data.deplacer(statut),
      builder: (context, candidats, refuses) => Container(
        decoration: BoxDecoration(
          color: candidats.isNotEmpty
              ? couleur.withValues(alpha: 0.1)
              : p.isDark
              ? Colors.white.withValues(alpha: 0.025)
              : p.accent.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: candidats.isNotEmpty ? couleur : p.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: couleur,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Text(
                    titre,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tag('${tickets.length}'),
                ],
              ),
            ),
            Expanded(
              child: tickets.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        vide,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 13.5,
                          color: p.textSecondary,
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      children: [
                        for (var i = 0; i < tickets.length; i++)
                          FadeUp(
                            key: ValueKey(tickets[i].id),
                            index: i.clamp(0, 6),
                            child: _CarteTicket(
                              ticket: tickets[i],
                              peutGerer: peutGerer,
                              draggable: true,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TicketDrag {
  const _TicketDrag(this.ticket, this.deplacer);

  final TicketSummary ticket;
  final void Function(TicketStatus) deplacer;
}

String _libellePriorite(Priority p) => switch (p) {
  Priority.URGENT => 'Urgent',
  Priority.HIGH => 'Prioritaire',
  Priority.NORMAL => 'Normal',
  Priority.LOW => 'Peut attendre',
};

class _CarteTicket extends ConsumerStatefulWidget {
  const _CarteTicket({
    required this.ticket,
    required this.peutGerer,
    this.draggable = false,
  });

  final TicketSummary ticket;
  final bool peutGerer;
  final bool draggable;

  @override
  ConsumerState<_CarteTicket> createState() => _CarteTicketState();
}

class _CarteTicketState extends ConsumerState<_CarteTicket> {
  bool _occupe = false;

  Future<void> _agir({TicketStatus? to}) async {
    if (_occupe || !mounted || !widget.peutGerer) return;
    final t = widget.ticket;
    final depot = ref.read(maintenanceRepositoryProvider);
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null) return;

    setState(() => _occupe = true);
    try {
      if (to == TicketStatus.OPEN ||
          (t.status == TicketStatus.RESOLVED && to == TicketStatus.ASSIGNED) ||
          (t.status == TicketStatus.CLOSED && to == TicketStatus.RESOLVED)) {
        await depot.revert(t.id, to: to!, by: agent);
        return;
      }
      String? resolution;
      if (t.status == TicketStatus.ASSIGNED ||
          t.status == TicketStatus.IN_PROGRESS) {
        resolution = await _demanderResolution(context, t);
        if (resolution == null || !mounted) return;
      }
      switch (t.status) {
        case TicketStatus.OPEN:
          await depot.take(t.id, by: agent);
        case TicketStatus.ASSIGNED || TicketStatus.IN_PROGRESS:
          await depot.resolve(t.id, resolution: resolution!, by: agent);
        case TicketStatus.RESOLVED:
          await depot.close(t.id, by: agent);
          if (mounted && t.blocksRoom && t.roomNumber != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Ticket clos, chambre ${t.roomNumber} de nouveau en vente.',
                ),
              ),
            );
          }
        default:
          break;
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('La modification a échoué. Réessayez.')),
        );
      }
    } finally {
      if (mounted) setState(() => _occupe = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.ticket;
    final p = AtriumPalette.current;
    final couleurPriorite = switch (t.priority) {
      Priority.URGENT => p.error,
      Priority.HIGH => CouleursEtat.reservee,
      Priority.NORMAL => p.textSecondary,
      Priority.LOW => p.textSecondary,
    };
    final (String? action, IconData? icone, PillTone ton) = switch (t.status) {
      TicketStatus.OPEN => (
        "Je m'en occupe",
        PhosphorIconsLight.handGrabbing,
        PillTone.primary,
      ),
      TicketStatus.ASSIGNED || TicketStatus.IN_PROGRESS => (
        'Marquer résolu',
        PhosphorIconsLight.check,
        PillTone.accent,
      ),
      TicketStatus.RESOLVED => (
        'Clore',
        PhosphorIconsLight.sealCheck,
        PillTone.quiet,
      ),
      _ => (null, null, PillTone.quiet),
    };
    final ou = t.roomNumber != null
        ? 'Chambre ${t.roomNumber}'
        : (t.location ?? 'Sans lieu précis');
    final quand = t.reportedAt == null
        ? ''
        : '${formatDayMonth(t.reportedAt!.toLocal())} '
              '${t.reportedAt!.toLocal().hour.toString().padLeft(2, '0')}:'
              '${t.reportedAt!.toLocal().minute.toString().padLeft(2, '0')}';

    final carte = Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.paper,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: t.priority == Priority.URGENT
                ? p.error.withValues(alpha: 0.5)
                : p.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                Tag(_libellePriorite(t.priority), color: couleurPriorite),
                if (t.blocksRoom && t.status != TicketStatus.CLOSED)
                  Tag('Chambre bloquée', color: CouleursEtat.maintenance),
                Tag(t.number),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              t.title,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: p.text,
              ),
            ),
            if (t.description != null && t.description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                t.description!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13.5,
                  height: 1.35,
                  color: p.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(PhosphorIconsLight.mapPin, size: 16, color: p.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    [ou, if (quand.isNotEmpty) quand].join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                ),
              ],
            ),
            if (t.assigneeName != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    PhosphorIconsLight.user,
                    size: 16,
                    color: p.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    t.assigneeName!,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
            if (t.resolution != null && t.resolution!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: CouleursEtat.disponible.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  t.resolution!,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13,
                    color: p.text,
                  ),
                ),
              ),
            ],
            if (action != null && widget.peutGerer) ...[
              const SizedBox(height: 14),
              PillButton(
                label: _occupe ? '…' : action,
                icon: icone,
                tone: ton,
                compact: true,
                expand: true,
                onPressed: _occupe ? null : _agir,
              ),
            ],
            if (widget.peutGerer &&
                t.status != TicketStatus.OPEN &&
                t.status != TicketStatus.CANCELLED)
              TextButton.icon(
                icon: const Icon(PhosphorIconsLight.arrowLeft, size: 16),
                label: Text(switch (t.status) {
                  TicketStatus.CLOSED => 'Rouvrir le ticket',
                  TicketStatus.RESOLVED => 'Reprendre la réparation',
                  _ => 'Remettre dans Signalés',
                }),
                onPressed: _occupe
                    ? null
                    : () => _agir(
                        to: switch (t.status) {
                          TicketStatus.CLOSED => TicketStatus.RESOLVED,
                          TicketStatus.RESOLVED => TicketStatus.ASSIGNED,
                          _ => TicketStatus.OPEN,
                        },
                      ),
              ),
          ],
        ),
      ),
    );

    final peutDeplacer =
        widget.draggable &&
        widget.peutGerer &&
        !_occupe &&
        (t.status == TicketStatus.OPEN ||
            t.status == TicketStatus.ASSIGNED ||
            t.status == TicketStatus.IN_PROGRESS ||
            t.status == TicketStatus.RESOLVED);
    if (!peutDeplacer) return carte;

    return KanbanDragCard<_TicketDrag>(
      data: _TicketDrag(t, (to) => _agir(to: to)),
      feedbackChild: carte.child,
      child: carte,
    );
  }
}

/// Ce qui a ete fait : une ligne, obligatoire -- le serveur la garde, et
/// c'est elle que lira le prochain a intervenir sur la meme panne.
Future<String?> _demanderResolution(BuildContext context, TicketSummary t) {
  final champ = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialogue) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        icon: const Icon(PhosphorIconsLight.check, size: 30),
        title: Text('Résolu : ${t.title}'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: champ,
            autofocus: true,
            maxLines: 3,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: "Ce qui a été fait",
              hintText: 'Joint du siphon changé, fuite arrêtée…',
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogue).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: champ.text.trim().isEmpty
                ? null
                : () => Navigator.of(dialogue).pop(champ.text.trim()),
            child: const Text('Marquer résolu'),
          ),
        ],
      ),
    ),
  );
}

/// Signaler un probleme, depuis le module ou depuis la fiche d'une chambre.
Future<void> showReportIssueDialog(
  BuildContext context, {
  String? roomId,
  String? roomNumber,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _Signalement(roomId: roomId, roomNumber: roomNumber),
  );
}

class _Signalement extends ConsumerStatefulWidget {
  const _Signalement({this.roomId, this.roomNumber});

  final String? roomId;
  final String? roomNumber;

  @override
  ConsumerState<_Signalement> createState() => _SignalementState();
}

class _SignalementState extends ConsumerState<_Signalement> {
  final _titre = TextEditingController();
  final _description = TextEditingController();
  final _lieu = TextEditingController();
  late String? _chambre = widget.roomId;
  Priority _priorite = Priority.NORMAL;
  bool _bloque = false;
  bool _occupe = false;
  late final Future<List<TicketRoomOption>> _chambres = ref
      .read(maintenanceRepositoryProvider)
      .rooms();

  @override
  void dispose() {
    _titre.dispose();
    _description.dispose();
    _lieu.dispose();
    super.dispose();
  }

  Future<void> _enregistrer() async {
    if (_titre.text.trim().isEmpty) return;
    setState(() => _occupe = true);
    await ref
        .read(maintenanceRepositoryProvider)
        .create(
          title: _titre.text,
          description: _description.text.trim().isEmpty
              ? null
              : _description.text.trim(),
          roomId: _chambre,
          location: _chambre == null && _lieu.text.trim().isNotEmpty
              ? _lieu.text.trim()
              : null,
          priority: _priorite,
          blocksRoom: _bloque,
          by: ref.read(sessionProvider).agent?.id,
        );
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _bloque && _chambre != null
              ? 'Ticket ouvert, la chambre est sortie de la vente.'
              : 'Ticket ouvert.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.warningDiamond, size: 32),
      title: Text(
        widget.roomNumber == null
            ? 'Signaler un problème'
            : 'Un problème en chambre ${widget.roomNumber}',
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _titre,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Le problème',
                  hintText: 'Climatisation en panne, fuite, serrure…',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Détails (facultatif)',
                  alignLabelWithHint: true,
                ),
              ),
              if (widget.roomId == null) ...[
                const SizedBox(height: 12),
                FutureBuilder<List<TicketRoomOption>>(
                  future: _chambres,
                  builder: (context, snap) => DropdownButtonFormField<String?>(
                    initialValue: _chambre,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Chambre',
                      prefixIcon: Icon(PhosphorIconsLight.door, size: 20),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Aucune (partie commune)'),
                      ),
                      for (final c in snap.data ?? const <TicketRoomOption>[])
                        DropdownMenuItem(
                          value: c.id,
                          child: Text('Chambre ${c.number}'),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _chambre = v;
                      if (v == null) _bloque = false;
                    }),
                  ),
                ),
                if (_chambre == null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _lieu,
                    decoration: const InputDecoration(
                      labelText: 'Où ?',
                      hintText: 'Hall, piscine, cuisine…',
                      prefixIcon: Icon(PhosphorIconsLight.mapPin, size: 20),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 16),
              const Eyebrow('Urgence'),
              const SizedBox(height: 10),
              ChoiceTiles<Priority>(
                selected: _priorite,
                tileWidth: 118,
                onChanged: (v) => setState(() => _priorite = v),
                options: const [
                  (Priority.LOW, PhosphorIconsLight.hourglass, 'Peut attendre'),
                  (Priority.NORMAL, PhosphorIconsLight.circle, 'Normal'),
                  (Priority.HIGH, PhosphorIconsLight.arrowFatUp, 'Prioritaire'),
                  (Priority.URGENT, PhosphorIconsLight.siren, 'Urgent'),
                ],
              ),
              if (_chambre != null) ...[
                const SizedBox(height: 14),
                Container(
                  decoration: BoxDecoration(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: p.border),
                  ),
                  child: SwitchListTile(
                    value: _bloque,
                    onChanged: (v) => setState(() => _bloque = v),
                    title: const Text('Sortir la chambre de la vente'),
                    subtitle: const Text(
                      'Une fuite, oui ; une ampoule, non. Elle reviendra à la '
                      'clôture du ticket.',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _occupe ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _occupe || _titre.text.trim().isEmpty
              ? null
              : _enregistrer,
          child: const Text('Ouvrir le ticket'),
        ),
      ],
    );
  }
}
