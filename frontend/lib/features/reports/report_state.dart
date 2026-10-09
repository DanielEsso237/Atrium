/// L'etat de l'ecran Rapports : la periode, les filtres, et le rapport qui
/// en decoule.
library;

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../data/local/database.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/report_queries.dart';
import '../billing/charge_labels.dart';

/// Les periodes qu'un gerant demande d'habitude, plus la sienne.
enum Periode {
  aujourdhui("Aujourd'hui"),
  hier('Hier'),
  septJours('7 derniers jours'),
  trenteJours('30 derniers jours'),
  ceMois('Ce mois-ci'),
  moisPrecedent('Mois précédent'),
  cetteAnnee('Cette année'),
  personnalisee('Dates choisies');

  const Periode(this.libelle);

  final String libelle;

  /// Bornes en journees hotelieres : a 2 h du matin, « aujourd'hui » est
  /// encore la journee d'hier pour le service de nuit.
  (DateTime, DateTime) bornes(DateTime jour) {
    DateTime j(int decalage) =>
        DateTime(jour.year, jour.month, jour.day + decalage);
    return switch (this) {
      aujourdhui || personnalisee => (jour, jour),
      hier => (j(-1), j(-1)),
      septJours => (j(-6), jour),
      trenteJours => (j(-29), jour),
      ceMois => (DateTime(jour.year, jour.month), jour),
      moisPrecedent => (
        DateTime(jour.year, jour.month - 1),
        DateTime(jour.year, jour.month, 0),
      ),
      cetteAnnee => (DateTime(jour.year), jour),
    };
  }
}

class EtatRapport {
  const EtatRapport(this.periode, this.filtres);

  final Periode periode;
  final FiltresRapport filtres;
}

class EtatRapportNotifier extends Notifier<EtatRapport> {
  @override
  EtatRapport build() {
    const periode = Periode.ceMois;
    final (du, au) = periode.bornes(businessDayFor(DateTime.now()));
    return EtatRapport(periode, FiltresRapport(du: du, au: au));
  }

  void choisirPeriode(Periode p) {
    final (du, au) = p.bornes(businessDayFor(DateTime.now()));
    state = EtatRapport(p, state.filtres.copier(du: du, au: au));
  }

  void choisirDates(DateTime du, DateTime au) => state = EtatRapport(
    Periode.personnalisee,
    state.filtres.copier(du: du, au: au),
  );

  void pointDeVente(String? id) => state = EtatRapport(
    state.periode,
    state.filtres.copier(pointDeVenteId: () => id),
  );

  void agent(String? id) =>
      state = EtatRapport(state.periode, state.filtres.copier(agentId: () => id));

  void moyen(PaymentMethod? m) =>
      state = EtatRapport(state.periode, state.filtres.copier(moyen: () => m));

  void typeChambre(String? id) => state = EtatRapport(
    state.periode,
    state.filtres.copier(typeChambreId: () => id),
  );

  /// Retire les filtres, garde la periode.
  void effacerFiltres() => state = EtatRapport(
    state.periode,
    FiltresRapport(du: state.filtres.du, au: state.filtres.au),
  );
}

final etatRapportProvider =
    NotifierProvider<EtatRapportNotifier, EtatRapport>(EtatRapportNotifier.new);

final rapportProvider = StreamProvider.autoDispose
    .family<RapportFinancier, FiltresRapport>(
      (ref, f) => ref.watch(databaseProvider).watchRapport(f),
    );

// --- Les choix des filtres ----------------------------------------------------

final pointsDeVenteRapportProvider = StreamProvider.autoDispose<List<OutletRow>>(
  (ref) {
    final db = ref.watch(databaseProvider);
    return (db.select(db.outlets)
          ..where((o) => o.deletedAt.isNull())
          ..orderBy([(o) => OrderingTerm(expression: o.sortOrder)]))
        .watch();
  },
);

final agentsRapportProvider = StreamProvider.autoDispose<List<UserRow>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.users)
        ..where((u) => u.deletedAt.isNull())
        ..orderBy([
          (u) => OrderingTerm(expression: u.firstName),
          (u) => OrderingTerm(expression: u.lastName),
        ]))
      .watch();
});

final typesChambreRapportProvider =
    StreamProvider.autoDispose<List<RoomTypeRow>>((ref) {
      final db = ref.watch(databaseProvider);
      return (db.select(db.roomTypes)
            ..where((t) => t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
          .watch();
    });

/// Le nom de l'hotel, en tete des exports.
final nomHotelProvider = FutureProvider.autoDispose<String>((ref) async {
  final db = ref.watch(databaseProvider);
  final hotel = await (db.select(db.hotels)..limit(1)).getSingleOrNull();
  return hotel?.name ?? 'Edge Hotel';
});

/// La periode en toutes lettres : « Du 1 octobre au 9 octobre 2026 ».
String libellePeriode(FiltresRapport f) {
  if (f.du == f.au) return 'Journée du ${formatLongDate(f.du)}';
  final debut = f.du.year != f.au.year
      ? formatLongDate(f.du)
      : f.du.month != f.au.month
      ? '${f.du.day} ${formatLongDate(f.du).split(' ')[1]}'
      : '${f.du.day}';
  return 'Du $debut au ${formatLongDate(f.au)}';
}

/// Les filtres retenus, en clair, pour l'en-tete des exports.
List<String> libellesFiltres(
  FiltresRapport f, {
  required List<OutletRow> pointsDeVente,
  required List<UserRow> agents,
  required List<RoomTypeRow> types,
}) {
  String? nom<T>(List<T> l, String? id, String Function(T) lire,
      String Function(T) cle) {
    if (id == null) return null;
    for (final e in l) {
      if (cle(e) == id) return lire(e);
    }
    return null;
  }

  return [
    if (nom(pointsDeVente, f.pointDeVenteId, (o) => o.label, (o) => o.id)
        case final n?)
      'point de vente $n',
    if (nom(agents, f.agentId, (u) => '${u.firstName} ${u.lastName}',
        (u) => u.id)
        case final n?)
      'agent $n',
    if (f.moyen case final m?) 'paiement ${paymentMethodLabel(m)}',
    if (nom(types, f.typeChambreId, (t) => t.label, (t) => t.id) case final n?)
      'chambres $n',
  ];
}
