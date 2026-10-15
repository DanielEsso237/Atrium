/// L'ecran Comptabilite (ticket D8) : ce que chaque point de vente a gagne,
/// ce qu'une unite de chaque produit rapporte, et ce que vaut le stock.
///
/// Les memes trois lectures que `/accounting/margins`, `/product-margins` et
/// `/stock-value` sur le serveur, calculees sur la base locale : l'ecran lit
/// Drift, jamais le reseau.
///
/// **Le cout d'un produit est son cout moyen pondere**, que le serveur
/// recalcule a chaque livraison et fait descendre (`products.average_cost`) ;
/// a zero, son prix d'achat -- la regle de `unit_cost_of`. Une difference
/// avec le serveur : lui fige le cout de chaque vente sur sa sortie de stock,
/// la tablette prend le cout du jour. Ses mouvements de stock ne descendent
/// pas ; une livraison recente change donc un peu la marge d'hier ici, pas
/// la-bas.
///
/// **Ce qui ne sort d'aucun stock n'a pas de cout connu** -- un plat du jour,
/// un service. Sa recette est comptee a part et reste hors de la marge : l'y
/// mettre le donnerait pour gratuit.
library;

import 'package:drift/drift.dart';

import '../../../core/formats.dart';
import '../database.dart';

/// Le cout retenu d'une unite, en SQL, sur l'alias `p` des produits.
const _coutUnitaire =
    'CASE WHEN p.average_cost > 0 THEN p.average_cost ELSE p.purchase_price END';

/// La marge rapportee a ce qu'elle mesure, en points de base ; nulle sans
/// base.
int? tauxMargeBp(int marge, int base) =>
    base == 0 ? null : (marge * 10000 / base).round();

/// Un article vendu par un point de vente sur la periode.
class ArticleVendu {
  const ArticleVendu({
    required this.libelle,
    required this.quantite,
    required this.recette,
    this.cout,
  });

  final String libelle;
  final int quantite;
  final int recette;

  /// Nul quand l'article ne sort d'aucun stock.
  final int? cout;

  int? get marge => cout == null ? null : recette - cout!;
}

/// Ce qu'un point de vente a gagne sur la periode.
class MargePointDeVente {
  const MargePointDeVente({
    required this.id,
    required this.libelle,
    required this.articles,
  });

  final String id;
  final String libelle;

  /// Les mieux vendus d'abord.
  final List<ArticleVendu> articles;

  int get recette => articles.fold(0, (s, a) => s + a.recette);

  /// La part de la recette sans cout connu.
  int get sansCout => articles
      .where((a) => a.cout == null)
      .fold(0, (s, a) => s + a.recette);
  int get cout => articles.fold(0, (s, a) => s + (a.cout ?? 0));
  int get marge => recette - sansCout - cout;
  int? get tauxBp => tauxMargeBp(marge, recette - sansCout);
}

/// La marge d'une unite d'un produit, au prix de la carte.
class MargeProduit {
  const MargeProduit({
    required this.id,
    required this.reference,
    required this.libelle,
    required this.coutMoyen,
    required this.prixAchat,
    required this.prixVente,
  });

  final String id;
  final String reference;
  final String libelle;
  final int coutMoyen;
  final int prixAchat;
  final int prixVente;

  /// Le cout retenu : le cout moyen, sinon le prix d'achat.
  int get cout => coutMoyen > 0 ? coutMoyen : prixAchat;
  int get marge => prixVente - cout;
  int? get tauxBp => tauxMargeBp(marge, prixVente);
}

/// Un produit en stock dans un magasin, et ce qu'il vaut.
class LigneValeurStock {
  const LigneValeurStock({
    required this.libelle,
    required this.quantite,
    required this.coutUnitaire,
  });

  final String libelle;
  final int quantite;
  final int coutUnitaire;

  int get valeur => quantite * coutUnitaire;
}

/// Ce que vaut le stock d'un magasin.
class ValeurMagasin {
  const ValeurMagasin({
    required this.id,
    required this.libelle,
    required this.central,
    required this.lignes,
  });

  final String id;
  final String libelle;
  final bool central;

  /// Les plus grosses valeurs d'abord.
  final List<LigneValeurStock> lignes;

  int get valeur => lignes.fold(0, (s, l) => s + l.valeur);
}

extension ComptaQueries on AtriumDatabase {
  /// La marge de chaque point de vente du [du] au [au] inclus (journees
  /// hotelieres), article par article. Une ligne annulee ne compte ni en
  /// recette ni en cout.
  ///
  /// Le cout d'un article se retrouve par l'article de la carte du meme
  /// libelle, dans le point de vente qui a vendu : la ligne d'ardoise garde
  /// le libelle, pas l'id de l'article (comme les marges des Rapports).
  Stream<List<MargePointDeVente>> watchMargesPointsDeVente({
    required DateTime du,
    required DateTime au,
  }) {
    return customSelect(
      '''
      WITH ventes AS (
        SELECT fi.source_id AS outlet_id, fi.label AS libelle,
               fi.quantity AS quantite, fi.amount AS montant,
               (SELECT mi.stock_quantity * $_coutUnitaire
                  FROM menu_items mi
                  JOIN menu_categories mc ON mc.id = mi.menu_category_id
                  JOIN products p         ON p.id = mi.product_id
                 WHERE mi.label = fi.label
                   AND mi.deleted_at IS NULL
                   AND p.deleted_at IS NULL
                   AND (mc.outlet_id IS NULL OR mc.outlet_id = fi.source_id)
                 LIMIT 1) AS cout_unitaire
          FROM folio_items fi
         WHERE fi.deleted_at IS NULL
           AND fi.is_void = 0
           AND fi.source_table = 'outlets'
           AND fi.business_date BETWEEN ?1 AND ?2
      )
      SELECT v.outlet_id, o.label AS point_de_vente, v.libelle,
             SUM(v.quantite) AS quantite,
             SUM(v.montant)  AS recette,
             CASE WHEN MAX(v.cout_unitaire) IS NULL THEN NULL
                  ELSE SUM(v.quantite * v.cout_unitaire) END AS cout
        FROM ventes v
        JOIN outlets o ON o.id = v.outlet_id
       GROUP BY v.outlet_id, o.label, v.libelle
       ORDER BY o.label, SUM(v.montant) DESC, v.libelle
      ''',
      variables: [
        Variable.withString(formatIsoDate(du)),
        Variable.withString(formatIsoDate(au)),
      ],
      readsFrom: {folioItems, menuItems, menuCategories, products, outlets},
    ).watch().map((rangs) {
      final parPoint = <String, (String, List<ArticleVendu>)>{};
      for (final r in rangs) {
        final id = r.read<String>('outlet_id');
        parPoint
            .putIfAbsent(id, () => (r.read<String>('point_de_vente'), []))
            .$2
            .add(
              ArticleVendu(
                libelle: r.read<String>('libelle'),
                quantite: r.read<int>('quantite'),
                recette: r.read<int>('recette'),
                cout: r.readNullable<int>('cout'),
              ),
            );
      }
      final marges = [
        for (final e in parPoint.entries)
          MargePointDeVente(id: e.key, libelle: e.value.$1, articles: e.value.$2),
      ];
      // Le point de vente qui rapporte le plus d'abord.
      marges.sort((a, b) => b.recette.compareTo(a.recette));
      return marges;
    });
  }

  /// La marge d'une unite de chaque produit actif, au prix de la carte.
  Stream<List<MargeProduit>> watchMargesProduits() {
    return customSelect(
      '''
      SELECT id, reference, label, average_cost, purchase_price, sale_price
        FROM products
       WHERE deleted_at IS NULL AND is_active = 1
       ORDER BY label, id
      ''',
      readsFrom: {products},
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          MargeProduit(
            id: r.read<String>('id'),
            reference: r.read<String>('reference'),
            libelle: r.read<String>('label'),
            coutMoyen: r.read<int>('average_cost'),
            prixAchat: r.read<int>('purchase_price'),
            prixVente: r.read<int>('sale_price'),
          ),
      ],
    );
  }

  /// Ce que vaut le stock de chaque magasin, l'economat d'abord.
  ///
  /// Un stock negatif est un comptage en retard (livraison pas encore
  /// saisie), pas une dette : il vaut zero, comme sur le serveur.
  Stream<List<ValeurMagasin>> watchValeurStock() {
    return customSelect(
      '''
      SELECT sl.id AS magasin, sl.label AS libelle_magasin,
             sl.is_central AS central,
             p.label AS produit, l.quantity AS quantite,
             $_coutUnitaire AS cout
        FROM stock_locations sl
        LEFT JOIN stock_levels l
               ON l.stock_location_id = sl.id
              AND l.deleted_at IS NULL
              AND l.quantity > 0
        LEFT JOIN products p
               ON p.id = l.product_id
              AND p.deleted_at IS NULL
       WHERE sl.deleted_at IS NULL
       ORDER BY sl.is_central DESC, sl.sort_order, sl.label, sl.id
      ''',
      readsFrom: {stockLocations, stockLevels, products},
    ).watch().map((rangs) {
      final magasins = <String, (String, bool, List<LigneValeurStock>)>{};
      for (final r in rangs) {
        final m = magasins.putIfAbsent(
          r.read<String>('magasin'),
          () => (
            r.read<String>('libelle_magasin'),
            r.read<bool>('central'),
            <LigneValeurStock>[],
          ),
        );
        final produit = r.readNullable<String>('produit');
        if (produit == null) continue;
        m.$3.add(
          LigneValeurStock(
            libelle: produit,
            quantite: r.read<int>('quantite'),
            coutUnitaire: r.read<int>('cout'),
          ),
        );
      }
      return [
        for (final e in magasins.entries)
          ValeurMagasin(
            id: e.key,
            libelle: e.value.$1,
            central: e.value.$2,
            lignes: e.value.$3..sort((a, b) => b.valeur.compareTo(a.valeur)),
          ),
      ];
    });
  }
}
