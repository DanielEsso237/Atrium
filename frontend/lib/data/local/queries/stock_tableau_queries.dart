/// Le tableau de bord et l'historique des stocks (demande du 18 octobre).
///
/// - **L'etat de chaque magasin** : combien de produits, combien en stock,
///   bas, en rupture, sous zero, et ce que vaut le stock au prix d'achat.
///   Les memes regles que l'ecran Stocks : un magasin de point de vente ne
///   compte que les produits qu'il a deja eus ; l'economat les compte tous,
///   pour voir ce qui manque.
/// - **Ce qui demande une action** : les produits sous zero, en rupture ou
///   sous leur seuil, le plus urgent d'abord.
/// - **Les mouvements** : entrees, sorties, transferts, pertes, ajustements,
///   avec qui les a faits et, pour un transfert, qui l'a valide.
/// - **Les inventaires** : ouverts, reequilibres, abandonnes.
///
/// Les mouvements ne descendent pas du serveur, hormis les transferts qui
/// attendent une validation : l'historique montre ce que cette tablette a
/// saisi, et les demandes de tous les postes.
library;

import 'package:drift/drift.dart';

import '../database.dart';
import '../enums.dart';

/// Un magasin et ses chiffres.
class EtatMagasin {
  const EtatMagasin({
    required this.id,
    required this.libelle,
    required this.central,
    required this.produits,
    required this.bas,
    required this.rupture,
    required this.negatif,
    required this.valeur,
  });

  final String id;
  final String libelle;
  final bool central;

  /// Les produits suivis : ceux que le magasin a deja eus, tous a
  /// l'economat.
  final int produits;
  final int bas;
  final int rupture;
  final int negatif;

  /// Le stock positif au prix d'achat.
  final int valeur;

  int get enStock => produits - bas - rupture - negatif;
  int get enAlerte => bas + rupture + negatif;
}

/// L'etat d'un produit dans un magasin, comme sur l'ecran Stocks.
enum EtatProduit { negatif, rupture, bas }

/// Un produit qui demande une action.
class AlerteStock {
  const AlerteStock({
    required this.produitId,
    required this.produit,
    required this.unite,
    required this.magasinId,
    required this.magasin,
    required this.quantite,
    required this.seuil,
  });

  final String produitId;
  final String produit;
  final String unite;
  final String magasinId;
  final String magasin;
  final int quantite;
  final int seuil;

  EtatProduit get etat => quantite < 0
      ? EtatProduit.negatif
      : quantite == 0
      ? EtatProduit.rupture
      : EtatProduit.bas;
}

/// Un mouvement de stock, mis en clair.
class MouvementStock {
  const MouvementStock({
    required this.id,
    required this.type,
    required this.statut,
    required this.produit,
    required this.unite,
    required this.quantite,
    required this.coutUnitaire,
    required this.magasinId,
    required this.magasin,
    this.contrepartieId,
    this.contrepartie,
    this.motif,
    this.agent,
    this.moment,
    this.decidePar,
  });

  final String id;
  final StockMovementType type;
  final StockMovementStatus statut;
  final String produit;
  final String unite;

  /// Toujours positive : le genre dit le sens.
  final int quantite;
  final int coutUnitaire;

  /// Le magasin d'ou part un transfert, ou celui qui recoit ou perd.
  final String magasinId;
  final String magasin;

  /// Pour un transfert : le magasin qui recoit.
  final String? contrepartieId;
  final String? contrepartie;
  final String? motif;
  final String? agent;
  final DateTime? moment;

  /// Qui a valide ou refuse un transfert.
  final String? decidePar;

  /// Ce que le mouvement retire du magasin : sortie, perte, transfert parti.
  bool get sortant =>
      type == StockMovementType.OUT ||
      type == StockMovementType.LOSS ||
      type == StockMovementType.TRANSFER;
}

/// Un inventaire, de son ouverture a sa cloture.
class InventaireStock {
  const InventaireStock({
    required this.id,
    required this.libelle,
    required this.magasinId,
    required this.magasin,
    required this.lignes,
    required this.comptees,
    required this.ecarts,
    this.ouvertLe,
    this.closLe,
    this.abandonneLe,
  });

  final String id;
  final String libelle;
  final String magasinId;
  final String magasin;
  final int lignes;
  final int comptees;

  /// Les lignes comptees qui ne tombent pas juste.
  final int ecarts;
  final DateTime? ouvertLe;
  final DateTime? closLe;
  final DateTime? abandonneLe;

  bool get ouvert => closLe == null && abandonneLe == null;
}

extension StockTableauQueries on AtriumDatabase {
  /// L'etat de ces magasins, l'economat d'abord.
  Stream<List<EtatMagasin>> watchEtatsMagasins(List<String> magasins) {
    if (magasins.isEmpty) return Stream.value(const []);
    final dans = _dans(magasins, 1);
    return customSelect(
      '''
      SELECT l.id, l.label, l.is_central,
             COUNT(p.id) AS produits,
             SUM(CASE WHEN COALESCE(s.quantity, 0) < 0 THEN 1 ELSE 0 END)
               AS negatif,
             SUM(CASE WHEN COALESCE(s.quantity, 0) = 0 THEN 1 ELSE 0 END)
               AS rupture,
             SUM(CASE WHEN s.quantity > 0 AND p.min_stock > 0
                       AND s.quantity < p.min_stock THEN 1 ELSE 0 END) AS bas,
             COALESCE(SUM(CASE WHEN s.quantity > 0
                               THEN s.quantity * p.purchase_price
                               ELSE 0 END), 0) AS valeur
        FROM stock_locations l
        JOIN products p ON p.deleted_at IS NULL
        LEFT JOIN stock_levels s ON s.product_id = p.id
                                AND s.stock_location_id = l.id
       WHERE l.id IN ($dans)
         AND (l.is_central = 1 OR s.id IS NOT NULL)
       GROUP BY l.id
       ORDER BY l.is_central DESC, l.sort_order, l.label
      ''',
      variables: [for (final m in magasins) Variable.withString(m)],
      readsFrom: {stockLocations, products, stockLevels},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          EtatMagasin(
            id: r.read<String>('id'),
            libelle: r.read<String>('label'),
            central: r.read<bool>('is_central'),
            produits: r.read<int>('produits'),
            bas: r.readNullable<int>('bas') ?? 0,
            rupture: r.readNullable<int>('rupture') ?? 0,
            negatif: r.readNullable<int>('negatif') ?? 0,
            valeur: r.read<int>('valeur'),
          ),
      ],
    );
  }

  /// Les produits sous zero, en rupture ou sous leur seuil dans ces
  /// magasins : sous zero d'abord, puis en rupture, puis le plus loin de son
  /// seuil.
  Stream<List<AlerteStock>> watchAlertesStock(
    List<String> magasins, {
    int limite = 50,
  }) {
    if (magasins.isEmpty) return Stream.value(const []);
    final dans = _dans(magasins, 1);
    return customSelect(
      '''
      SELECT p.id AS produit_id, p.label AS produit, p.unit, p.min_stock,
             l.id AS magasin_id, l.label AS magasin,
             COALESCE(s.quantity, 0) AS quantite
        FROM stock_locations l
        JOIN products p ON p.deleted_at IS NULL
        LEFT JOIN stock_levels s ON s.product_id = p.id
                                AND s.stock_location_id = l.id
       WHERE l.id IN ($dans)
         AND (l.is_central = 1 OR s.id IS NOT NULL)
         AND (COALESCE(s.quantity, 0) <= 0
              OR (p.min_stock > 0 AND s.quantity < p.min_stock))
       ORDER BY CASE WHEN COALESCE(s.quantity, 0) < 0 THEN 0
                     WHEN COALESCE(s.quantity, 0) = 0 THEN 1
                     ELSE 2 END,
                CASE WHEN p.min_stock > 0
                     THEN CAST(COALESCE(s.quantity, 0) AS REAL) / p.min_stock
                     ELSE 0 END,
                p.label
       LIMIT $limite
      ''',
      variables: [for (final m in magasins) Variable.withString(m)],
      readsFrom: {stockLocations, products, stockLevels},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          AlerteStock(
            produitId: r.read<String>('produit_id'),
            produit: r.read<String>('produit'),
            unite: r.read<String>('unit'),
            magasinId: r.read<String>('magasin_id'),
            magasin: r.read<String>('magasin'),
            quantite: r.read<int>('quantite'),
            seuil: r.read<int>('min_stock'),
          ),
      ],
    );
  }

  /// Les mouvements qui touchent ces magasins -- au depart ou a l'arrivee
  /// d'un transfert --, depuis [depuis] (tous sans lui), les plus recents
  /// d'abord.
  Stream<List<MouvementStock>> watchMouvementsStock(
    List<String> magasins, {
    DateTime? depuis,
    int limite = 2000,
  }) {
    if (magasins.isEmpty) return Stream.value(const []);
    final dans = _dans(magasins, 2);
    return customSelect(
      '''
      SELECT m.id, m.type, m.status, m.quantity, m.unit_cost, m.reason,
             m.stock_location_id, m.counterpart_location_id,
             COALESCE(m.moved_at, m.created_at) AS moment,
             p.label AS produit, p.unit,
             l.label AS magasin, c.label AS contrepartie,
             u.first_name AS agent_prenom, u.last_name AS agent_nom,
             d.first_name AS decide_prenom, d.last_name AS decide_nom
        FROM stock_movements m
        JOIN products p        ON p.id = m.product_id
        JOIN stock_locations l ON l.id = m.stock_location_id
        LEFT JOIN stock_locations c ON c.id = m.counterpart_location_id
        LEFT JOIN users u ON u.id = m.moved_by
        LEFT JOIN users d ON d.id = m.decided_by
       WHERE m.deleted_at IS NULL
         AND (m.stock_location_id IN ($dans)
              OR m.counterpart_location_id IN ($dans))
         AND (?1 IS NULL OR COALESCE(m.moved_at, m.created_at) >= ?1)
       ORDER BY moment DESC
       LIMIT $limite
      ''',
      variables: [
        Variable<DateTime>(depuis?.toUtc()),
        for (final m in magasins) Variable.withString(m),
      ],
      readsFrom: {stockMovements, products, stockLocations, users},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          MouvementStock(
            id: r.read<String>('id'),
            type: StockMovementType.values.byName(r.read<String>('type')),
            statut: StockMovementStatus.values.byName(r.read<String>('status')),
            produit: r.read<String>('produit'),
            unite: r.read<String>('unit'),
            quantite: r.read<int>('quantity'),
            coutUnitaire: r.read<int>('unit_cost'),
            magasinId: r.read<String>('stock_location_id'),
            magasin: r.read<String>('magasin'),
            contrepartieId: r.readNullable<String>('counterpart_location_id'),
            contrepartie: r.readNullable<String>('contrepartie'),
            motif: r.readNullable<String>('reason'),
            agent: _nom(r, 'agent_prenom', 'agent_nom'),
            moment: r.readNullable<DateTime>('moment'),
            decidePar: _nom(r, 'decide_prenom', 'decide_nom'),
          ),
      ],
    );
  }

  /// Les inventaires de ces magasins, abandonnes compris, les plus recents
  /// d'abord.
  Stream<List<InventaireStock>> watchInventairesStock(List<String> magasins) {
    if (magasins.isEmpty) return Stream.value(const []);
    final dans = _dans(magasins, 1);
    return customSelect(
      '''
      SELECT i.id, i.label, i.stock_location_id, l.label AS magasin,
             COALESCE(i.started_at, i.created_at) AS ouvert_le,
             i.closed_at, i.deleted_at,
             (SELECT COUNT(*) FROM inventory_lines x
               WHERE x.inventory_id = i.id) AS lignes,
             (SELECT COUNT(*) FROM inventory_lines x
               WHERE x.inventory_id = i.id
                 AND x.counted_qty IS NOT NULL) AS comptees,
             (SELECT COUNT(*) FROM inventory_lines x
               WHERE x.inventory_id = i.id
                 AND x.counted_qty IS NOT NULL
                 AND x.counted_qty <> x.theoretical_qty) AS ecarts
        FROM inventories i
        JOIN stock_locations l ON l.id = i.stock_location_id
       WHERE i.stock_location_id IN ($dans)
       ORDER BY ouvert_le DESC
      ''',
      variables: [for (final m in magasins) Variable.withString(m)],
      readsFrom: {inventories, inventoryLines, stockLocations},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          InventaireStock(
            id: r.read<String>('id'),
            libelle: r.read<String>('label'),
            magasinId: r.read<String>('stock_location_id'),
            magasin: r.read<String>('magasin'),
            lignes: r.read<int>('lignes'),
            comptees: r.read<int>('comptees'),
            ecarts: r.read<int>('ecarts'),
            ouvertLe: r.readNullable<DateTime>('ouvert_le'),
            closLe: r.readNullable<DateTime>('closed_at'),
            abandonneLe: r.readNullable<DateTime>('deleted_at'),
          ),
      ],
    );
  }

  /// Les quantites entrees et sorties de ces magasins, jour par jour, de
  /// [du] a [au] compris (journees calendaires de la tablette). Un
  /// transfert sort de l'un et entre dans l'autre ; seul un transfert valide
  /// a bouge le stock.
  Stream<(List<int>, List<int>)> watchFluxStock(
    List<String> magasins, {
    required DateTime du,
    required DateTime au,
  }) {
    final debut = DateTime(du.year, du.month, du.day);
    final jours = DateTime(au.year, au.month, au.day)
            .difference(debut)
            .inDays +
        1;
    if (jours <= 0) return Stream.value((const <int>[], const <int>[]));
    if (magasins.isEmpty) {
      return Stream.value((List.filled(jours, 0), List.filled(jours, 0)));
    }
    return watchMouvementsStock(magasins, depuis: debut, limite: 100000).map((
      mouvements,
    ) {
      final entrees = List.filled(jours, 0);
      final sorties = List.filled(jours, 0);
      final ici = magasins.toSet();
      for (final m in mouvements) {
        final instant = m.moment?.toLocal();
        if (instant == null || m.statut != StockMovementStatus.APPROVED) {
          continue;
        }
        final i = DateTime(instant.year, instant.month, instant.day)
            .difference(debut)
            .inDays;
        if (i < 0 || i >= jours) continue;
        if (m.type == StockMovementType.TRANSFER) {
          if (ici.contains(m.magasinId)) sorties[i] += m.quantite;
          if (ici.contains(m.contrepartieId)) entrees[i] += m.quantite;
        } else if (m.sortant) {
          sorties[i] += m.quantite;
        } else {
          entrees[i] += m.quantite;
        }
      }
      return (entrees, sorties);
    });
  }

  /// « ?1, ?2… » a partir de [premier].
  static String _dans(List<String> ids, int premier) => [
    for (var i = 0; i < ids.length; i++) '?${i + premier}',
  ].join(', ');

  static String? _nom(QueryRow r, String prenom, String nom) {
    final n =
        '${r.readNullable<String>(prenom) ?? ''} '
                '${r.readNullable<String>(nom) ?? ''}'
            .trim();
    return n.isEmpty ? null : n;
  }
}
