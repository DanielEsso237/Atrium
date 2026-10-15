/// L'ecran Comptabilite (ticket D8) : « la compta en gros ».
///
/// Trois questions, de haut en bas :
///
/// - ce que chaque point de vente a gagne sur la periode -- recette, cout de
///   ce qui est sorti du stock, marge --, et article par article ;
/// - ce qu'une unite de chaque produit rapporte au prix de la carte ;
/// - ce que vaut le stock de chaque magasin.
///
/// Le benefice de l'hotel (recettes moins couts du stock moins depenses) reste
/// dans les Rapports, ou il a ses filtres et son export ; cet ecran s'y
/// arrete a la marge. Reserve a `accounting.read`, comme sur le serveur : une
/// marge donnerait au comptoir la recette de son tiroir.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/compta_queries.dart';
import '../reports/export/export_model.dart' show formatPointsDeBase;

enum _Periode { jour, septJours, mois, moisDernier }

String _libellePeriode(_Periode p) => switch (p) {
  _Periode.jour => 'Aujourd’hui',
  _Periode.septJours => '7 derniers jours',
  _Periode.mois => 'Ce mois',
  _Periode.moisDernier => 'Mois dernier',
};

/// Les journees hotelieres de la periode, la premiere et la derniere.
(DateTime, DateTime) _bornes(_Periode p, DateTime jour) => switch (p) {
  _Periode.jour => (jour, jour),
  _Periode.septJours => (DateTime(jour.year, jour.month, jour.day - 6), jour),
  _Periode.mois => (DateTime(jour.year, jour.month), jour),
  _Periode.moisDernier => (
    DateTime(jour.year, jour.month - 1),
    DateTime(jour.year, jour.month, 0),
  ),
};

final _margesPdvProvider =
    StreamProvider.family<List<MargePointDeVente>, (DateTime, DateTime)>(
      (ref, b) => ref
          .watch(databaseProvider)
          .watchMargesPointsDeVente(du: b.$1, au: b.$2),
    );

final _margesProduitsProvider = StreamProvider<List<MargeProduit>>(
  (ref) => ref.watch(databaseProvider).watchMargesProduits(),
);

final _valeurStockProvider = StreamProvider<List<ValeurMagasin>>(
  (ref) => ref.watch(databaseProvider).watchValeurStock(),
);

class AccountingScreen extends ConsumerStatefulWidget {
  const AccountingScreen({super.key});

  @override
  ConsumerState<AccountingScreen> createState() => _AccountingScreenState();
}

class _AccountingScreenState extends ConsumerState<AccountingScreen> {
  _Periode _periode = _Periode.septJours;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final jour = businessDayFor(DateTime.now());
    final bornes = _bornes(_periode, jour);
    final points = ref.watch(_margesPdvProvider(bornes)).value ?? const [];
    final produits = ref.watch(_margesProduitsProvider).value ?? const [];
    final magasins = ref.watch(_valeurStockProvider).value ?? const [];

    final recette = points.fold(0, (s, m) => s + m.recette);
    final sansCout = points.fold(0, (s, m) => s + m.sansCout);
    final cout = points.fold(0, (s, m) => s + m.cout);
    final marge = recette - sansCout - cout;
    final taux = tauxMargeBp(marge, recette - sansCout);
    final valeurStock = magasins.fold(0, (s, m) => s + m.valeur);

    final etroit = MediaQuery.sizeOf(context).width < 600;
    final bord = etroit ? 18.0 : 32.0;
    final periode = bornes.$1 == bornes.$2
        ? formatLongDate(bornes.$1)
        : 'du ${formatShortDate(bornes.$1)} au ${formatShortDate(bornes.$2)}';

    return ModuleScaffold(
      title: 'Comptabilité',
      subtitle: 'Marges des points de vente et valeur du stock',
      body: ListView(
        padding: EdgeInsets.fromLTRB(bord, 0, bord, 40),
        children: [
          FilterPills<_Periode>(
            selected: _periode,
            onChanged: (v) => setState(() => _periode = v),
            options: [
              for (final v in _Periode.values)
                FilterOption(v, _libellePeriode(v)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            periode,
            style: TextStyle(fontSize: 13, color: p.textSecondary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Chiffre('Recette des points de vente', formatAmount(recette)),
              _Chiffre('Coût du stock vendu', formatAmount(cout)),
              _Chiffre(
                'Marge',
                formatAmount(marge),
                detail: taux == null ? null : formatPointsDeBase(taux),
                negatif: marge < 0,
              ),
              _Chiffre('Valeur du stock', formatAmount(valeurStock)),
            ],
          ),
          if (sansCout > 0) ...[
            const SizedBox(height: 10),
            Text(
              '${formatAmount(sansCout)} de recette sans coût connu (plats, '
              'services : rien ne sort du stock) restent hors de la marge.',
              style: TextStyle(fontSize: 13, color: p.textSecondary),
            ),
          ],
          const SizedBox(height: 26),
          const Eyebrow('Par point de vente'),
          const SizedBox(height: 10),
          if (points.isEmpty)
            _Vide('Aucune vente sur la période.')
          else
            for (final m in points) ...[
              _PointDeVente(marge: m, etroit: etroit),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 18),
          const Eyebrow('Marge par produit, au prix de la carte'),
          const SizedBox(height: 4),
          Text(
            'Le coût est le coût moyen des livraisons, sinon le prix d’achat.',
            style: TextStyle(fontSize: 13, color: p.textSecondary),
          ),
          const SizedBox(height: 10),
          if (produits.isEmpty)
            _Vide('Aucun produit.')
          else
            _Produits(produits: produits, etroit: etroit),
          const SizedBox(height: 28),
          const Eyebrow('Valeur du stock'),
          const SizedBox(height: 10),
          if (magasins.isEmpty)
            _Vide('Aucun magasin.')
          else
            for (final m in magasins) ...[
              _Magasin(magasin: m),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }
}

TextStyle _nombre(Color couleur, {double taille = 14, bool gras = false}) =>
    TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: taille,
      fontWeight: gras ? FontWeight.w700 : FontWeight.w500,
      color: couleur,
      fontFeatures: tabularFigures,
    );

class _Chiffre extends StatelessWidget {
  const _Chiffre(this.libelle, this.valeur, {this.detail, this.negatif = false});

  final String libelle;
  final String valeur;
  final String? detail;
  final bool negatif;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return SizedBox(
      width: 210,
      child: Bezel(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(libelle, style: TextStyle(fontSize: 12.5, color: p.textSecondary)),
            const SizedBox(height: 4),
            Text(
              valeur,
              style: _nombre(negatif ? p.error : p.text, taille: 19, gras: true),
            ),
            if (detail != null)
              Text(
                'taux $detail',
                style: TextStyle(fontSize: 12.5, color: p.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}

class _Vide extends StatelessWidget {
  const _Vide(this.texte);

  final String texte;

  @override
  Widget build(BuildContext context) => Text(
    texte,
    style: TextStyle(fontSize: 14, color: AtriumPalette.current.textSecondary),
  );
}

/// Une ligne de tableau : un libelle, puis des colonnes de chiffres a droite.
class _Ligne extends StatelessWidget {
  const _Ligne({
    required this.libelle,
    required this.colonnes,
    this.entete = false,
    this.sousLibelle,
  });

  final String libelle;
  final String? sousLibelle;

  /// (texte, couleur particuliere) ; une colonne vide se laisse vide.
  final List<(String, Color?)> colonnes;
  final bool entete;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final style = entete
        ? TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: p.textSecondary,
          )
        : _nombre(p.text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  libelle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: entete
                      ? style
                      : TextStyle(fontSize: 14, color: p.text),
                ),
                if (sousLibelle != null)
                  Text(
                    sousLibelle!,
                    style: TextStyle(fontSize: 12, color: p.textSecondary),
                  ),
              ],
            ),
          ),
          for (final (texte, couleur) in colonnes)
            SizedBox(
              width: 104,
              child: Text(
                texte,
                textAlign: TextAlign.right,
                style: couleur == null ? style : style.copyWith(color: couleur),
              ),
            ),
        ],
      ),
    );
  }
}

class _PointDeVente extends StatelessWidget {
  const _PointDeVente({required this.marge, required this.etroit});

  final MargePointDeVente marge;
  final bool etroit;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final m = marge;
    return Bezel(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text(
            m.libelle,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          subtitle: Text(
            'Recette ${formatAmount(m.recette)} · coût ${formatAmount(m.cout)}'
            ' · marge ${formatAmount(m.marge)}'
            '${m.tauxBp == null ? '' : ' (${formatPointsDeBase(m.tauxBp!)})'}',
            style: _nombre(p.textSecondary, taille: 13),
          ),
          children: [
            _Ligne(
              libelle: 'Article',
              entete: true,
              colonnes: [
                if (!etroit) ('Qté', null),
                ('Recette', null),
                if (!etroit) ('Coût', null),
                ('Marge', null),
              ],
            ),
            for (final a in m.articles)
              _Ligne(
                libelle: a.libelle,
                colonnes: [
                  if (!etroit) ('${a.quantite}', null),
                  (formatAmount(a.recette), null),
                  if (!etroit)
                    (a.cout == null ? '—' : formatAmount(a.cout!), null),
                  a.marge == null
                      ? ('sans coût', p.textSecondary)
                      : (
                          formatAmount(a.marge!),
                          a.marge! < 0 ? p.error : null,
                        ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Produits extends StatelessWidget {
  const _Produits({required this.produits, required this.etroit});

  final List<MargeProduit> produits;
  final bool etroit;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Column(
        children: [
          _Ligne(
            libelle: 'Produit',
            entete: true,
            colonnes: [
              ('Coût', null),
              if (!etroit) ('Prix', null),
              ('Marge', null),
              if (!etroit) ('Taux', null),
            ],
          ),
          for (final m in produits)
            _Ligne(
              libelle: m.libelle,
              // Le coût vient du prix d'achat : aucune livraison ne l'a
              // encore precise.
              sousLibelle: m.coutMoyen > 0 ? null : 'coût = prix d’achat',
              colonnes: [
                (formatAmount(m.cout), null),
                if (!etroit)
                  (m.prixVente == 0 ? '—' : formatAmount(m.prixVente), null),
                m.prixVente == 0
                    ? ('non vendu', p.textSecondary)
                    : (formatAmount(m.marge), m.marge < 0 ? p.error : null),
                if (!etroit)
                  (
                    m.tauxBp == null ? '—' : formatPointsDeBase(m.tauxBp!),
                    null,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Magasin extends StatelessWidget {
  const _Magasin({required this.magasin});

  final ValeurMagasin magasin;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final m = magasin;
    return Bezel(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          leading: Icon(
            m.central
                ? PhosphorIconsLight.buildings
                : PhosphorIconsLight.storefront,
            color: p.textSecondary,
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  m.libelle,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              ),
              Text(formatAmount(m.valeur), style: _nombre(p.text, gras: true)),
            ],
          ),
          subtitle: Text(
            m.lignes.isEmpty
                ? 'Rien en stock'
                : '${m.lignes.length} produit${m.lignes.length > 1 ? 's' : ''}',
            style: TextStyle(fontSize: 13, color: p.textSecondary),
          ),
          children: [
            if (m.lignes.isNotEmpty)
              _Ligne(
                libelle: 'Produit',
                entete: true,
                colonnes: const [('Qté', null), ('Coût', null), ('Valeur', null)],
              ),
            for (final l in m.lignes)
              _Ligne(
                libelle: l.libelle,
                colonnes: [
                  ('${l.quantite}', null),
                  (formatAmount(l.coutUnitaire), null),
                  (formatAmount(l.valeur), null),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
