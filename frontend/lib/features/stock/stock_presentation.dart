/// Les mouvements et les inventaires mis en mots, les memes sur le tableau
/// de bord des stocks et dans leur historique (demande du 18 octobre).
library;

import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/historique.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/stock_tableau_queries.dart';

/// Le genre d'un mouvement, son icone et sa couleur.
(String, IconData, Color) apparenceMouvementStock(StockMovementType t) {
  final p = AtriumPalette.current;
  return switch (t) {
    StockMovementType.IN => ('Entrée', PhosphorIconsLight.downloadSimple, p.success),
    StockMovementType.OUT => ('Sortie', PhosphorIconsLight.uploadSimple, p.accent),
    StockMovementType.TRANSFER => (
      'Transfert',
      PhosphorIconsLight.arrowsLeftRight,
      p.accent,
    ),
    StockMovementType.LOSS => ('Perte', PhosphorIconsLight.trash, p.error),
    StockMovementType.ADJUSTMENT => (
      'Ajustement',
      PhosphorIconsLight.scales,
      p.textSecondary,
    ),
    StockMovementType.RETURN => (
      'Retour',
      PhosphorIconsLight.arrowCounterClockwise,
      p.success,
    ),
  };
}

/// Un mouvement pour la chronologie. [regardes] : les magasins affiches --
/// un transfert sort de l'un et entre dans l'autre ; vu des deux, il ne
/// fait que deplacer.
EntreeHistorique entreeDeMouvement(
  MouvementStock m, {
  Set<String>? regardes,
}) {
  final p = AtriumPalette.current;
  final (genre, icone, couleur) = apparenceMouvementStock(m.type);
  final ou = switch (m.type) {
    StockMovementType.TRANSFER =>
      'de ${m.magasin} vers ${m.contrepartie ?? 'un autre magasin'}',
    StockMovementType.IN || StockMovementType.RETURN => 'à ${m.magasin}',
    _ => 'de ${m.magasin}',
  };
  final part = regardes == null
      ? null
      : (regardes.contains(m.magasinId), regardes.contains(m.contrepartieId));
  // Le sens, vu des magasins affiches.
  final String signe;
  final bool negatif;
  if (m.type == StockMovementType.TRANSFER) {
    final (depart, arrivee) = part ?? (true, true);
    negatif = depart && !arrivee;
    signe = arrivee && !depart ? '+' : '';
  } else {
    negatif = m.sortant;
    signe = m.sortant ? '' : '+';
  }
  return EntreeHistorique(
    id: m.id,
    moment: m.moment ?? DateTime.now().toUtc(),
    icone: icone,
    couleur: couleur,
    titre: m.produit,
    detail: [
      '$genre $ou',
      if (m.type == StockMovementType.IN && m.coutUnitaire > 0)
        '${formatAmount(m.coutUnitaire)} l’unité',
      if (m.motif != null && m.motif!.trim().isNotEmpty) m.motif!.trim(),
      if (m.agent != null) 'par ${m.agent}',
      if (m.decidePar != null)
        m.statut == StockMovementStatus.REJECTED
            ? 'refusé par ${m.decidePar}'
            : 'validé par ${m.decidePar}',
    ].join(', '),
    montant: '$signe${m.quantite} ${m.unite}',
    negatif: negatif,
    etat: switch (m.statut) {
      StockMovementStatus.PENDING => 'En attente',
      StockMovementStatus.REJECTED => 'Refusé',
      StockMovementStatus.APPROVED => null,
    },
    couleurEtat: m.statut == StockMovementStatus.REJECTED
        ? p.error
        : p.warning,
  );
}

/// Un inventaire en un, deux ou trois temps : ouvert, puis reequilibre ou
/// abandonne.
List<EntreeHistorique> entreesDInventaire(InventaireStock i) {
  final p = AtriumPalette.current;
  // L'accord suit le total : « 0 sur 4 articles comptés ».
  final compte = '${i.comptees} sur ${i.lignes} article${i.lignes > 1 ? 's' : ''} '
      'compté${i.lignes > 1 ? 's' : ''}';
  return [
    if (i.ouvertLe != null)
      EntreeHistorique(
        id: '${i.id}|ouvert',
        moment: i.ouvertLe!,
        icone: PhosphorIconsLight.checks,
        couleur: p.accent,
        titre: 'Inventaire ouvert',
        detail: '${i.magasin}, ${i.libelle}${i.ouvert ? ', $compte' : ''}',
        etat: i.ouvert ? 'En cours' : null,
        couleurEtat: p.accent,
      ),
    if (i.closLe != null)
      EntreeHistorique(
        id: '${i.id}|clos',
        moment: i.closLe!,
        icone: PhosphorIconsLight.sealCheck,
        couleur: p.success,
        titre: 'Inventaire rééquilibré',
        detail: '${i.magasin}, $compte, '
            '${i.ecarts} écart${i.ecarts > 1 ? 's' : ''} corrigé'
            '${i.ecarts > 1 ? 's' : ''}',
      ),
    if (i.abandonneLe != null)
      EntreeHistorique(
        id: '${i.id}|abandonne',
        moment: i.abandonneLe!,
        icone: PhosphorIconsLight.xCircle,
        couleur: p.textSecondary,
        titre: 'Inventaire abandonné',
        detail: '${i.magasin}, ${i.libelle}, le stock n’a pas bougé',
      ),
  ];
}

/// Le mot et la couleur de l'etat d'un produit, comme sur l'ecran Stocks.
(String, Color) libelleEtatProduit(EtatProduit e) {
  final p = AtriumPalette.current;
  return switch (e) {
    EtatProduit.negatif => ('Négatif', p.error),
    EtatProduit.rupture => ('Rupture', p.error),
    EtatProduit.bas => ('Stock bas', p.warning),
  };
}
