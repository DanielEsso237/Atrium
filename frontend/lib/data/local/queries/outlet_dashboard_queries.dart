/// Les chiffres du tableau de bord des points de vente : recette, ventes,
/// ticket moyen, paye sur place ou porte aux chambres, meilleures ventes et
/// heures de pointe, sur un jour, une semaine ou un mois.
///
/// Un seul calcul pour tous les points de vente, existants ou crees demain :
/// il prend la liste des points de vente a couvrir -- le perimetre de l'agent,
/// ou celui qu'il a choisi dans le filtre -- et ne connait aucun d'eux par
/// son nom. Une vente, c'est une ligne d'ardoise venue d'un point de vente
/// (`source_table = 'outlets'`), d'ou qu'elle ait ete saisie : la descente
/// range aussi celles des autres postes.
library;

import 'package:drift/drift.dart';

import '../../../core/formats.dart';
import '../database.dart';

/// La periode regardee. Toujours « a date » : la semaine depuis lundi, le
/// mois depuis le 1er, compares au meme nombre de jours de la periode
/// precedente -- sinon un mardi se compare a une semaine pleine et parait
/// toujours en chute.
enum PeriodePdv { jour, semaine, mois }

/// Ce que l'on regarde : des points de vente et une periode.
///
/// Immuable et comparable : il sert de cle au fournisseur du tableau de bord.
class FiltresPdv {
  FiltresPdv({
    required List<String> pointsDeVente,
    required this.periode,
    required DateTime reference,
  }) : pointsDeVente = List.unmodifiable(pointsDeVente),
       reference = DateTime(reference.year, reference.month, reference.day);

  /// Les points de vente couverts. Vide : rien a montrer, pas « tous ».
  final List<String> pointsDeVente;
  final PeriodePdv periode;

  /// La journee hoteliere de reference, en general aujourd'hui.
  final DateTime reference;

  /// Premiere journee incluse.
  DateTime get du => switch (periode) {
    PeriodePdv.jour => reference,
    PeriodePdv.semaine => DateTime(
      reference.year,
      reference.month,
      reference.day - (reference.weekday - DateTime.monday),
    ),
    PeriodePdv.mois => DateTime(reference.year, reference.month),
  };

  /// Derniere journee incluse : la reference.
  DateTime get au => reference;

  /// La meme periode, juste avant, arretee au meme point.
  ///
  /// Composantes et non durees : un changement d'heure ferait sauter un jour.
  /// Le 31 mars se compare au 28 (ou 29) fevrier, pas au 3 mars.
  FiltresPdv get precedente => FiltresPdv(
    pointsDeVente: pointsDeVente,
    periode: periode,
    reference: switch (periode) {
      PeriodePdv.jour => DateTime(reference.year, reference.month, reference.day - 1),
      PeriodePdv.semaine => DateTime(
        reference.year,
        reference.month,
        reference.day - 7,
      ),
      PeriodePdv.mois => DateTime(
        reference.year,
        reference.month - 1,
        _min(reference.day, _joursDuMois(reference.year, reference.month - 1)),
      ),
    },
  );

  static int _joursDuMois(int annee, int mois) =>
      DateTime(annee, mois + 1, 0).day;

  static int _min(int a, int b) => a < b ? a : b;

  @override
  bool operator ==(Object other) =>
      other is FiltresPdv &&
      other.periode == periode &&
      other.reference == reference &&
      _memeListe(other.pointsDeVente, pointsDeVente);

  @override
  int get hashCode => Object.hash(periode, reference, Object.hashAll(pointsDeVente));

  static bool _memeListe(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Les chiffres d'une periode.
class ChiffresPdv {
  const ChiffresPdv({
    this.recette = 0,
    this.ventes = 0,
    this.articles = 0,
    this.surPlace = 0,
  });

  /// Tout ce qui a ete vendu, paye ou non.
  final int recette;

  /// Une vente, c'est un client servi dans la journee : une ardoise de
  /// passage, ou l'ardoise d'une chambre un jour donne. Trois bieres portees
  /// en 101 dans la soiree font une vente, pas trois.
  final int ventes;
  final int articles;

  /// Paye au comptoir (ardoise de passage, « Payer maintenant » compris).
  final int surPlace;

  /// Porte sur l'ardoise d'une chambre : encaisse au depart du client.
  int get enChambre => recette - surPlace;

  int get ticketMoyen => ventes == 0 ? 0 : (recette / ventes).round();
}

/// Un article et ce qu'il a rapporte.
class LigneVentePdv {
  const LigneVentePdv({
    required this.libelle,
    required this.quantite,
    required this.montant,
  });

  final String libelle;
  final int quantite;
  final int montant;
}

/// Une heure de la journee, a l'heure de la tablette.
class HeurePdv {
  const HeurePdv(this.heure, {this.montant = 0, this.articles = 0});

  /// 0 a 23.
  final int heure;
  final int montant;
  final int articles;
}

class TableauDeBordPdv {
  const TableauDeBordPdv({
    required this.filtres,
    required this.chiffres,
    required this.precedent,
    required this.meilleuresVentes,
    required this.parHeure,
  });

  final FiltresPdv filtres;
  final ChiffresPdv chiffres;

  /// La periode precedente, arretee au meme point.
  final ChiffresPdv precedent;

  /// Les articles qui rapportent le plus, dans l'ordre.
  final List<LigneVentePdv> meilleuresVentes;

  /// Les 24 heures, toujours toutes : une heure creuse est un renseignement.
  final List<HeurePdv> parHeure;

  /// L'heure qui rapporte le plus, ou `null` sans vente.
  HeurePdv? get heureDePointe {
    HeurePdv? meilleure;
    for (final h in parHeure) {
      if (h.montant > 0 && (meilleure == null || h.montant > meilleure.montant)) {
        meilleure = h;
      }
    }
    return meilleure;
  }
}

extension OutletDashboardQueries on AtriumDatabase {
  /// Le tableau de bord, recalcule a chaque vente ecrite ou descendue.
  Stream<TableauDeBordPdv> watchTableauDeBordPdv(FiltresPdv f) async* {
    yield await chargerTableauDeBordPdv(f);
    yield* tableUpdates(
      TableUpdateQuery.onAllTables([folioItems, folios]),
    ).asyncMap((_) => chargerTableauDeBordPdv(f));
  }

  Future<TableauDeBordPdv> chargerTableauDeBordPdv(FiltresPdv f) async =>
      TableauDeBordPdv(
        filtres: f,
        chiffres: await chiffresPdv(f),
        precedent: await chiffresPdv(f.precedente),
        meilleuresVentes: await _meilleuresVentes(f),
        parHeure: await _parHeure(f),
      );

  Future<ChiffresPdv> chiffresPdv(FiltresPdv f) async {
    if (f.pointsDeVente.isEmpty) return const ChiffresPdv();
    final l = await customSelect(
      '''
      SELECT COALESCE(SUM(fi.amount), 0)   AS recette,
             COUNT(DISTINCT fi.folio_id || '|' || fi.business_date) AS ventes,
             COALESCE(SUM(fi.quantity), 0) AS articles,
             COALESCE(SUM(CASE WHEN f.type = 'WALK_IN'
                               THEN fi.amount ELSE 0 END), 0) AS sur_place
        ${_ventes(f)}
      ''',
      variables: _variables(f),
      readsFrom: {folioItems, folios},
    ).getSingle();
    return ChiffresPdv(
      recette: l.read<int>('recette'),
      ventes: l.read<int>('ventes'),
      articles: l.read<int>('articles'),
      surPlace: l.read<int>('sur_place'),
    );
  }

  Future<List<LigneVentePdv>> _meilleuresVentes(
    FiltresPdv f, {
    int combien = 10,
  }) async {
    if (f.pointsDeVente.isEmpty) return const [];
    final lignes = await customSelect(
      '''
      SELECT fi.label                      AS libelle,
             COALESCE(SUM(fi.quantity), 0) AS quantite,
             COALESCE(SUM(fi.amount), 0)   AS montant
        ${_ventes(f)}
       GROUP BY fi.label
       ORDER BY montant DESC, quantite DESC, libelle
       LIMIT $combien
      ''',
      variables: _variables(f),
      readsFrom: {folioItems, folios},
    ).get();
    return [
      for (final l in lignes)
        LigneVentePdv(
          libelle: l.read<String>('libelle'),
          quantite: l.read<int>('quantite'),
          montant: l.read<int>('montant'),
        ),
    ];
  }

  /// Les ventes heure par heure, a l'heure locale de la tablette.
  ///
  /// L'instant de la saisie (`posted_at`) d'abord. A defaut -- une ligne
  /// saisie avant qu'on ne le note --, l'instant de creation, moins sur : la
  /// descente le reecrit.
  Future<List<HeurePdv>> _parHeure(FiltresPdv f) async {
    final montants = List.filled(24, 0);
    final articles = List.filled(24, 0);
    if (f.pointsDeVente.isNotEmpty) {
      final lignes = await customSelect(
        '''
        SELECT COALESCE(fi.posted_at, fi.created_at) AS moment,
               fi.amount AS montant, fi.quantity AS quantite
          ${_ventes(f)}
        ''',
        variables: _variables(f),
        readsFrom: {folioItems, folios},
      ).get();
      for (final l in lignes) {
        final moment = l.readNullable<DateTime>('moment');
        if (moment == null) continue;
        final h = moment.toLocal().hour;
        montants[h] += l.read<int>('montant');
        articles[h] += l.read<int>('quantite');
      }
    }
    return [
      for (var h = 0; h < 24; h++)
        HeurePdv(h, montant: montants[h], articles: articles[h]),
    ];
  }

  /// Les lignes vendues par ces points de vente sur la periode.
  ///
  /// Les variables : ?1 du, ?2 au, puis un point de vente par variable.
  /// Une ligne annulee n'est pas une vente.
  String _ventes(FiltresPdv f) {
    final dans = [
      for (var i = 0; i < f.pointsDeVente.length; i++) '?${i + 3}',
    ].join(', ');
    return '''
        FROM folio_items fi
        JOIN folios f ON f.id = fi.folio_id
       WHERE fi.deleted_at IS NULL
         AND fi.is_void = 0
         AND fi.source_table = 'outlets'
         AND fi.source_id IN ($dans)
         AND fi.business_date BETWEEN ?1 AND ?2
    ''';
  }

  List<Variable<Object>> _variables(FiltresPdv f) => [
    Variable.withString(formatIsoDate(f.du)),
    Variable.withString(formatIsoDate(f.au)),
    for (final id in f.pointsDeVente) Variable.withString(id),
  ];
}
