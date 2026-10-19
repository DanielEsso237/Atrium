/// Le menage et les pannes mis en mots, les memes sur le tableau de bord de
/// l'entretien et dans son historique (demande du 18 octobre).
library;

import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/historique.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/entretien_queries.dart';

/// Comme l'ecran Ménage.
String libelleTypeMenage(HousekeepingTaskType t) => switch (t) {
  HousekeepingTaskType.DEPARTURE => 'Après départ',
  HousekeepingTaskType.STAYOVER => 'Client en place',
  HousekeepingTaskType.REFRESH => 'Rafraîchissement',
  HousekeepingTaskType.DEEP_CLEAN => 'Nettoyage complet',
  HousekeepingTaskType.INSPECTION => 'Contrôle',
};

/// Comme l'ecran Maintenance.
String libellePriorite(Priority p) => switch (p) {
  Priority.URGENT => 'Urgent',
  Priority.HIGH => 'Prioritaire',
  Priority.NORMAL => 'Normal',
  Priority.LOW => 'Peut attendre',
};

Color couleurPriorite(Priority priorite) {
  final p = AtriumPalette.current;
  return switch (priorite) {
    Priority.URGENT => p.error,
    Priority.HIGH => p.warning,
    Priority.NORMAL || Priority.LOW => p.textSecondary,
  };
}

String libelleStatutPanne(TicketStatus s) => switch (s) {
  TicketStatus.OPEN => 'Ouverte',
  TicketStatus.ASSIGNED => 'Prise en main',
  TicketStatus.IN_PROGRESS => 'En intervention',
  TicketStatus.RESOLVED => 'Réglée',
  TicketStatus.CLOSED => 'Close',
  TicketStatus.CANCELLED => 'Annulée',
};

String libelleStatutTache(TaskStatus s) => switch (s) {
  TaskStatus.PENDING => 'À faire',
  TaskStatus.ASSIGNED => 'Confiée',
  TaskStatus.IN_PROGRESS => 'En cours',
  TaskStatus.DONE => 'Faite',
  TaskStatus.INSPECTED => 'Contrôlée',
  TaskStatus.CANCELLED => 'Annulée',
};

/// « 35 min », « 1 h 10 ».
String duree(int minutes) => minutes < 60
    ? '$minutes min'
    : '${minutes ~/ 60} h${minutes % 60 == 0 ? '' : ' ${(minutes % 60).toString().padLeft(2, '0')}'}';

/// Une tache en ses temps : demandee, commencee, faite, controlee.
List<EntreeHistorique> entreesDeTache(TacheMenage t) {
  final p = AtriumPalette.current;
  final chambre = 'Chambre ${t.chambre}';
  final quoi = libelleTypeMenage(t.type);
  return [
    if (t.creeLe != null)
      EntreeHistorique(
        id: '${t.id}|cree',
        moment: t.creeLe!,
        icone: PhosphorIconsLight.broom,
        couleur: p.textSecondary,
        titre: '$chambre à faire',
        detail: [
          quoi,
          if (t.priorite == Priority.URGENT || t.priorite == Priority.HIGH)
            libellePriorite(t.priorite).toLowerCase(),
          if (t.agent != null) 'confiée à ${t.agent}',
        ].join(', '),
        etat: t.aFaire || t.statut == TaskStatus.CANCELLED
            ? libelleStatutTache(t.statut)
            : null,
        couleurEtat: t.statut == TaskStatus.CANCELLED
            ? p.textSecondary
            : p.warning,
      ),
    if (t.commenceLe != null && t.termineLe == null)
      EntreeHistorique(
        id: '${t.id}|commence',
        moment: t.commenceLe!,
        icone: PhosphorIconsLight.play,
        couleur: p.accent,
        titre: 'Ménage commencé, ${chambre.toLowerCase()}',
        detail: [quoi, if (t.agent != null) 'par ${t.agent}'].join(', '),
      ),
    if (t.termineLe != null)
      EntreeHistorique(
        id: '${t.id}|fait',
        moment: t.termineLe!,
        icone: PhosphorIconsLight.checkCircle,
        couleur: p.success,
        titre: '$chambre faite',
        detail: [
          quoi,
          if (t.agent != null) 'par ${t.agent}',
          if (t.duree != null) 'en ${duree(t.duree!)}',
        ].join(', '),
      ),
    if (t.inspecteLe != null)
      EntreeHistorique(
        id: '${t.id}|controle',
        moment: t.inspecteLe!,
        icone: PhosphorIconsLight.sealCheck,
        couleur: p.success,
        titre: '$chambre contrôlée',
        detail: t.inspectePar == null ? null : 'par ${t.inspectePar}',
      ),
  ];
}

/// Une panne en ses temps : signalee, prise en main, reglee, close.
List<EntreeHistorique> entreesDePanne(PanneEntretien m) {
  final p = AtriumPalette.current;
  return [
    if (m.signaleLe != null)
      EntreeHistorique(
        id: '${m.id}|signalee',
        moment: m.signaleLe!,
        icone: PhosphorIconsLight.warningCircle,
        couleur: m.urgente ? p.error : p.warning,
        titre: 'Panne signalée : ${m.titre}',
        detail: [
          m.ou,
          if (m.urgente) libellePriorite(m.priorite),
          if (m.bloqueChambre) 'la chambre ne se loue plus',
          if (m.signalePar != null) 'par ${m.signalePar}',
        ].join(', '),
        etat: m.ouverte ? libelleStatutPanne(m.statut) : null,
        couleurEtat: m.urgente ? p.error : p.warning,
      ),
    if (m.assigneLe != null)
      EntreeHistorique(
        id: '${m.id}|prise',
        moment: m.assigneLe!,
        icone: PhosphorIconsLight.wrench,
        couleur: p.accent,
        titre: 'Panne prise en main : ${m.titre}',
        detail: [m.ou, if (m.assigneA != null) 'par ${m.assigneA}'].join(', '),
      ),
    if (m.regleeLe != null)
      EntreeHistorique(
        id: '${m.id}|reglee',
        moment: m.regleeLe!,
        icone: PhosphorIconsLight.checkCircle,
        couleur: p.success,
        titre: 'Panne réglée : ${m.titre}',
        detail: [
          m.ou,
          if (m.resolution != null && m.resolution!.trim().isNotEmpty)
            m.resolution!.trim(),
          if (m.assigneA != null) 'par ${m.assigneA}',
          if (m.signaleLe != null)
            'en ${_delai(m.regleeLe!.difference(m.signaleLe!))}',
        ].join(', '),
        montant: m.cout > 0 ? formatAmount(m.cout) : null,
      ),
    if (m.closeLe != null)
      EntreeHistorique(
        id: '${m.id}|close',
        moment: m.closeLe!,
        icone: PhosphorIconsLight.sealCheck,
        couleur: p.textSecondary,
        titre: 'Panne close : ${m.titre}',
        detail: m.ou,
      ),
  ];
}

/// Un delai de reparation en mots : « 3 h », « 2 jours ».
String _delai(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} min';
  if (d.inHours < 48) return '${d.inHours} h';
  return '${d.inDays} jours';
}

/// Le delai moyen entre le signalement et la reparation, en mots ; `null`
/// sans panne reglee.
String? delaiMoyen(Iterable<PanneEntretien> pannes) {
  final delais = [
    for (final m in pannes)
      if (m.signaleLe != null && m.regleeLe != null)
        m.regleeLe!.difference(m.signaleLe!),
  ];
  if (delais.isEmpty) return null;
  final total = delais.fold(Duration.zero, (s, d) => s + d);
  return _delai(total ~/ delais.length);
}
