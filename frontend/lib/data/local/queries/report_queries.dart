/// Les rapports financiers : chiffre d'affaires, encaissements, occupation,
/// points de vente, stock et marges, sur une periode et des filtres.
///
/// Tout se calcule sur la base locale, hors ligne. La descente y range aussi
/// les ventes closes et les encaissements des autres postes (fenetre de
/// `Descente.fenetreRapports` jours) : sans eux, chaque tablette n'aurait vu
/// que ses propres ventes.
///
/// Les filtres ne s'appliquent qu'ou ils ont un sens, et `FiltresRapport`
/// dit lesquels pour chaque bloc : le moyen de paiement ne filtre que des
/// encaissements, le type de chambre que ce qui se rattache a un sejour.
library;

import 'package:drift/drift.dart';

import '../../../core/business_day.dart';
import '../../../core/formats.dart';
import '../database.dart';
import '../enums.dart';

/// Ce que l'on regarde : une periode de journees hotelieres et des filtres.
///
/// Immuable et comparable : il sert de cle au fournisseur du rapport.
class FiltresRapport {
  FiltresRapport({
    required DateTime du,
    required DateTime au,
    this.pointDeVenteId,
    this.agentId,
    this.moyen,
    this.typeChambreId,
  }) : du = DateTime(du.year, du.month, du.day),
       au = DateTime(au.year, au.month, au.day);

  /// Premiere et derniere journee hoteliere, incluses.
  final DateTime du;
  final DateTime au;
  final String? pointDeVenteId;
  final String? agentId;
  final PaymentMethod? moyen;
  final String? typeChambreId;

  int get nbJours => au.difference(du).inDays + 1;

  /// Les journees de la periode, une par une. Composantes et non durees : un
  /// changement d'heure ferait sauter ou doubler un jour.
  List<DateTime> get jours => [
    for (var i = 0; i < nbJours; i++) DateTime(du.year, du.month, du.day + i),
  ];

  /// La periode de meme longueur juste avant : le repere des variations.
  FiltresRapport get precedente => copier(
    du: DateTime(du.year, du.month, du.day - nbJours),
    au: DateTime(du.year, du.month, du.day - 1),
  );

  bool get filtre =>
      pointDeVenteId != null ||
      agentId != null ||
      moyen != null ||
      typeChambreId != null;

  FiltresRapport copier({
    DateTime? du,
    DateTime? au,
    String? Function()? pointDeVenteId,
    String? Function()? agentId,
    PaymentMethod? Function()? moyen,
    String? Function()? typeChambreId,
  }) => FiltresRapport(
    du: du ?? this.du,
    au: au ?? this.au,
    pointDeVenteId: pointDeVenteId == null
        ? this.pointDeVenteId
        : pointDeVenteId(),
    agentId: agentId == null ? this.agentId : agentId(),
    moyen: moyen == null ? this.moyen : moyen(),
    typeChambreId: typeChambreId == null ? this.typeChambreId : typeChambreId(),
  );

  /// Les variables de requete, toujours dans cet ordre : ?1 du, ?2 au,
  /// ?3 point de vente, ?4 agent, ?5 type de chambre, ?6 moyen.
  ///
  /// SQLite compte les parametres jusqu'au plus grand indice cite : une
  /// requete qui s'arrete a ?4 n'en recoit que quatre.
  List<Variable<Object>> variables(int combien) => [
    Variable.withString(formatIsoDate(du)),
    Variable.withString(formatIsoDate(au)),
    Variable<String>(pointDeVenteId),
    Variable<String>(agentId),
    Variable<String>(typeChambreId),
    Variable<String>(moyen?.name),
  ].take(combien).toList();

  @override
  bool operator ==(Object other) =>
      other is FiltresRapport &&
      other.du == du &&
      other.au == au &&
      other.pointDeVenteId == pointDeVenteId &&
      other.agentId == agentId &&
      other.moyen == moyen &&
      other.typeChambreId == typeChambreId;

  @override
  int get hashCode =>
      Object.hash(du, au, pointDeVenteId, agentId, moyen, typeChambreId);
}

/// Une valeur nommee : une part d'un total (categorie, moyen, agent...).
class Part {
  const Part(this.cle, this.libelle, this.montant, {this.nombre = 0});

  final String cle;
  final String libelle;
  final int montant;

  /// Combien d'operations la composent.
  final int nombre;
}

/// Une journee de la courbe financiere.
class JourneeFinanciere {
  const JourneeFinanciere(this.jour, this.chiffreAffaires, this.encaisse);

  final DateTime jour;
  final int chiffreAffaires;
  final int encaisse;
}

/// Une nuit de la courbe d'occupation.
class NuitOccupation {
  const NuitOccupation(this.jour, this.occupees, this.disponibles);

  final DateTime jour;
  final int occupees;
  final int disponibles;

  /// En pourcentage entier.
  int get taux => disponibles == 0 ? 0 : (occupees * 100 / disponibles).round();
}

/// L'occupation et le chiffre d'une categorie de chambre.
class LigneTypeChambre {
  const LigneTypeChambre({
    required this.id,
    required this.libelle,
    required this.chambres,
    required this.nuitees,
    required this.nuiteesDisponibles,
    required this.chiffreAffaires,
  });

  final String id;
  final String libelle;
  final int chambres;
  final int nuitees;
  final int nuiteesDisponibles;
  final int chiffreAffaires;

  int get taux => nuiteesDisponibles == 0
      ? 0
      : (nuitees * 100 / nuiteesDisponibles).round();

  /// Prix moyen d'une nuit vendue.
  int get prixMoyen => nuitees == 0 ? 0 : (chiffreAffaires / nuitees).round();
}

/// Ce qu'un point de vente a vendu sur la periode.
class LignePointDeVente {
  const LignePointDeVente({
    required this.id,
    required this.libelle,
    required this.chiffreAffaires,
    required this.ventes,
    required this.articles,
  });

  final String id;
  final String libelle;
  final int chiffreAffaires;

  /// Nombre d'ardoises distinctes touchees : une vente, un client.
  final int ventes;
  final int articles;

  int get panierMoyen => ventes == 0 ? 0 : (chiffreAffaires / ventes).round();
}

/// La marge d'un article vendu, quand il est relie a un produit du stock.
class LigneMarge {
  const LigneMarge({
    required this.libelle,
    required this.quantite,
    required this.chiffreAffaires,
    required this.cout,
  });

  final String libelle;
  final int quantite;
  final int chiffreAffaires;
  final int cout;

  int get marge => chiffreAffaires - cout;

  /// Taux de marge sur le prix de vente, en points de base (18 % -> 1800).
  int get tauxBp =>
      chiffreAffaires == 0 ? 0 : (marge * 10000 / chiffreAffaires).round();
}

/// Un produit en stock, a la date du jour.
class LigneStock {
  const LigneStock({
    required this.libelle,
    required this.reference,
    required this.quantite,
    required this.seuil,
    required this.prixAchat,
    required this.prixVente,
  });

  final String libelle;
  final String reference;
  final int quantite;
  final int seuil;
  final int prixAchat;
  final int prixVente;

  int get valeurAchat => quantite * prixAchat;
  int get valeurVente => quantite * prixVente;
  bool get sousLeSeuil => seuil > 0 && quantite < seuil;
}

/// Les grands chiffres d'une periode, pour la comparer a la precedente.
class ChiffresCles {
  const ChiffresCles({
    required this.chiffreAffaires,
    required this.encaisse,
    required this.nuitees,
    required this.nuiteesDisponibles,
    required this.chiffreHebergement,
  });

  final int chiffreAffaires;
  final int encaisse;
  final int nuitees;
  final int nuiteesDisponibles;
  final int chiffreHebergement;

  int get tauxOccupation => nuiteesDisponibles == 0
      ? 0
      : (nuitees * 100 / nuiteesDisponibles).round();

  /// Prix moyen par nuit vendue (ADR).
  int get prixMoyen =>
      nuitees == 0 ? 0 : (chiffreHebergement / nuitees).round();

  /// Revenu hebergement par chambre disponible (RevPAR).
  int get revPar => nuiteesDisponibles == 0
      ? 0
      : (chiffreHebergement / nuiteesDisponibles).round();
}

/// L'activite de l'hotel : arrivees, departs, reservations.
class ActiviteRapport {
  const ActiviteRapport({
    required this.arriveesPrevues,
    required this.arrivees,
    required this.departs,
    required this.nouvelles,
    required this.annulations,
    required this.nonPresentes,
    required this.personnes,
    required this.dureeMoyenneDixiemes,
    required this.parJour,
    required this.parOrigine,
  });

  final int arriveesPrevues;

  /// Arrivees enregistrees (check-in fait).
  final int arrivees;
  final int departs;

  /// Dossiers crees sur la periode.
  final int nouvelles;
  final int annulations;
  final int nonPresentes;

  /// Adultes et enfants des arrivees enregistrees.
  final int personnes;

  /// Duree moyenne de sejour en dixiemes de nuit (23 -> 2,3 nuits) : un
  /// entier, comme tout ce que le rapport transporte.
  final int dureeMoyenneDixiemes;

  /// (jour, arrivees, departs).
  final List<(DateTime, int, int)> parJour;

  /// Arrivees prevues par origine du dossier (`montant` = nombre).
  final List<Part> parOrigine;
}

/// Une caisse ouverte ou close sur la periode.
class LigneCaisse {
  const LigneCaisse({
    required this.agent,
    required this.ouverture,
    required this.cloture,
    required this.fond,
    required this.attendu,
    required this.compte,
    required this.ecart,
  });

  final String agent;
  final DateTime? ouverture;
  final DateTime? cloture;
  final int fond;
  final int attendu;
  final int? compte;
  final int ecart;

  bool get close => cloture != null;
}

/// Le menage d'un agent sur la periode.
class LigneMenage {
  const LigneMenage(this.agent, this.faites, this.minutes);

  final String agent;
  final int faites;

  /// Minutes cumulees des taches terminees dont la duree est connue.
  final int minutes;
}

/// Les tickets d'une categorie de maintenance.
class LigneMaintenance {
  const LigneMaintenance(this.categorie, this.tickets, this.resolus, this.cout);

  final String categorie;
  final int tickets;
  final int resolus;
  final int cout;
}

/// Les mouvements de stock d'un type.
class LigneMouvement {
  const LigneMouvement(this.type, this.mouvements, this.quantite, this.valeur);

  final StockMovementType type;
  final int mouvements;
  final int quantite;

  /// Au cout du mouvement, ou au prix d'achat du produit a defaut.
  final int valeur;
}

/// La gestion de la periode : caisses, menage, maintenance, stock.
class GestionRapport {
  const GestionRapport({
    required this.caisses,
    required this.tachesMenage,
    required this.tachesFaites,
    required this.tachesEnAttente,
    required this.menageParAgent,
    required this.ticketsSignales,
    required this.ticketsResolus,
    required this.ticketsUrgents,
    required this.coutMaintenance,
    required this.delaiResolutionDixiemesHeure,
    required this.maintenanceParCategorie,
    required this.mouvements,
  });

  final List<LigneCaisse> caisses;
  final int tachesMenage;
  final int tachesFaites;
  final int tachesEnAttente;
  final List<LigneMenage> menageParAgent;
  final int ticketsSignales;
  final int ticketsResolus;
  final int ticketsUrgents;
  final int coutMaintenance;

  /// Delai moyen entre signalement et resolution, en dixiemes d'heure.
  final int delaiResolutionDixiemesHeure;
  final List<LigneMaintenance> maintenanceParCategorie;
  final List<LigneMouvement> mouvements;

  /// Duree moyenne d'une tache de menage terminee, en minutes.
  int get dureeMoyenneMenage {
    final faites = menageParAgent.fold(0, (s, l) => s + l.faites);
    final minutes = menageParAgent.fold(0, (s, l) => s + l.minutes);
    return faites == 0 ? 0 : (minutes / faites).round();
  }

  int get ecartCaisses =>
      caisses.where((c) => c.close).fold(0, (s, c) => s + c.ecart);
  int get caissesCloses => caisses.where((c) => c.close).length;

  int get valeurPertes => mouvements
      .where((m) => m.type == StockMovementType.LOSS)
      .fold(0, (s, m) => s + m.valeur);
}

/// Le rapport complet d'une periode.
class RapportFinancier {
  const RapportFinancier({
    required this.filtres,
    required this.cles,
    required this.precedent,
    required this.taxes,
    required this.remises,
    required this.parJour,
    required this.parCategorie,
    required this.rembourse,
    required this.nbEncaissements,
    required this.parMoyen,
    required this.parAgent,
    required this.chambres,
    required this.occupation,
    required this.parType,
    required this.pointsDeVente,
    required this.marges,
    required this.stock,
    required this.creances,
    required this.arrhesDetenues,
    required this.activite,
    required this.gestion,
  });

  final FiltresRapport filtres;
  final ChiffresCles cles;

  /// La periode de meme longueur juste avant.
  final ChiffresCles precedent;

  final int taxes;

  /// Valeur absolue des remises accordees.
  final int remises;
  final List<JourneeFinanciere> parJour;
  final List<Part> parCategorie;

  final int rembourse;
  final int nbEncaissements;
  final List<Part> parMoyen;
  final List<Part> parAgent;

  /// Le parc retenu (type de chambre compris).
  final int chambres;
  final List<NuitOccupation> occupation;
  final List<LigneTypeChambre> parType;

  final List<LignePointDeVente> pointsDeVente;
  final List<LigneMarge> marges;
  final List<LigneStock> stock;

  /// Soldes restant dus sur les ardoises ouvertes, a date.
  final int creances;

  /// Arrhes encaissees sur des dossiers pas encore arrives, a date.
  final int arrhesDetenues;

  final ActiviteRapport activite;
  final GestionRapport gestion;

  /// Somme des ecarts des caisses closes sur la periode (negatif : manque).
  int get ecartCaisse => gestion.ecartCaisses;
  int get sessionsCloses => gestion.caissesCloses;

  int get ventesStock => marges.fold(0, (s, m) => s + m.chiffreAffaires);
  int get coutStock => marges.fold(0, (s, m) => s + m.cout);
  int get margeBrute => ventesStock - coutStock;
  int get tauxMargeBp =>
      ventesStock == 0 ? 0 : (margeBrute * 10000 / ventesStock).round();

  int get valeurStockAchat => stock.fold(0, (s, l) => s + l.valeurAchat);
  int get valeurStockVente => stock.fold(0, (s, l) => s + l.valeurVente);
  int get articlesSousSeuil => stock.where((l) => l.sousLeSeuil).length;

  int get ventesPointsDeVente =>
      pointsDeVente.fold(0, (s, l) => s + l.chiffreAffaires);
}

extension ReportQueries on AtriumDatabase {
  /// Le rapport, recalcule a chaque ecriture dans une table qu'il lit.
  ///
  /// Un seul flux pour tout le rapport : les chiffres d'un ecran pris au meme
  /// instant, et un export qui dit exactement ce que l'ecran montre.
  Stream<RapportFinancier> watchRapport(FiltresRapport f) async* {
    yield await chargerRapport(f);
    yield* tableUpdates(
      TableUpdateQuery.onAllTables([
        folioItems,
        folios,
        payments,
        reservationRooms,
        rooms,
        outlets,
        products,
        stockLevels,
        cashSessions,
        reservations,
        housekeepingTasks,
        maintenanceTickets,
        stockMovements,
      ]),
    ).asyncMap((_) => chargerRapport(f));
  }

  Future<RapportFinancier> chargerRapport(FiltresRapport f) async {
    final ventes = await _ventesParJourEtCategorie(f);
    final encaissements = await _encaissements(f);
    final (chambres, occupation, parType) = await _occupation(f);
    final agents = await _nomsAgents();

    // Le chiffre d'affaires et les encaissements, journee par journee.
    final caJour = <String, int>{};
    final categories = <String, (int, int)>{};
    var taxes = 0;
    var remises = 0;
    for (final v in ventes) {
      caJour[v.jour] = (caJour[v.jour] ?? 0) + v.montant;
      final (m, n) = categories[v.categorie] ?? (0, 0);
      categories[v.categorie] = (m + v.montant, n + v.nombre);
      taxes += v.taxes;
      if (v.categorie == ChargeCategory.DISCOUNT.name) remises -= v.montant;
    }
    final encJour = <String, int>{};
    final moyens = <String, (int, int)>{};
    final parAgent = <String, (int, int)>{};
    var rembourse = 0;
    var nbEnc = 0;
    for (final e in encaissements) {
      encJour[e.jour] = (encJour[e.jour] ?? 0) + e.net;
      final (m, n) = moyens[e.moyen] ?? (0, 0);
      moyens[e.moyen] = (m + e.net, n + e.nombre);
      final cle = e.agent ?? '';
      final (ma, na) = parAgent[cle] ?? (0, 0);
      parAgent[cle] = (ma + e.net, na + e.nombre);
      rembourse += e.rembourse;
      nbEnc += e.nombre;
    }

    final parJour = [
      for (final j in f.jours)
        JourneeFinanciere(
          j,
          caJour[formatIsoDate(j)] ?? 0,
          encJour[formatIsoDate(j)] ?? 0,
        ),
    ];
    final chiffreHebergement = categories[ChargeCategory.ROOM.name]?.$1 ?? 0;
    final cles = ChiffresCles(
      chiffreAffaires: caJour.values.fold(0, (s, v) => s + v),
      encaisse: encJour.values.fold(0, (s, v) => s + v),
      nuitees: occupation.fold(0, (s, n) => s + n.occupees),
      nuiteesDisponibles: occupation.fold(0, (s, n) => s + n.disponibles),
      chiffreHebergement: chiffreHebergement,
    );

    return RapportFinancier(
      filtres: f,
      cles: cles,
      precedent: await chiffresCles(f.precedente),
      taxes: taxes,
      remises: remises,
      parJour: parJour,
      parCategorie: _trier([
        for (final c in categories.entries)
          if (c.key != ChargeCategory.DISCOUNT.name)
            Part(c.key, c.key, c.value.$1, nombre: c.value.$2),
      ]),
      rembourse: rembourse,
      nbEncaissements: nbEnc,
      parMoyen: _trier([
        for (final m in moyens.entries)
          Part(m.key, m.key, m.value.$1, nombre: m.value.$2),
      ]),
      parAgent: _trier([
        for (final a in parAgent.entries)
          Part(
            a.key,
            agents[a.key] ?? 'Agent inconnu',
            a.value.$1,
            nombre: a.value.$2,
          ),
      ]),
      chambres: chambres,
      occupation: occupation,
      parType: parType,
      pointsDeVente: await _pointsDeVente(f),
      marges: await _marges(f),
      stock: await _stock(f),
      creances: await _entier(
        "SELECT COALESCE(SUM(balance), 0) AS n FROM folios "
        "WHERE deleted_at IS NULL AND status = 'OPEN' AND balance > 0",
      ),
      arrhesDetenues: await _entier(
        'SELECT COALESCE(SUM(deposit_amount), 0) AS n FROM reservations '
        'WHERE deleted_at IS NULL AND deposit_paid_at IS NOT NULL '
        "AND status IN ('PENDING','CONFIRMED')",
      ),
      activite: await _activite(f),
      gestion: await _gestion(f, agents),
    );
  }

  /// Les seuls chiffres qu'on compare d'une periode a l'autre.
  Future<ChiffresCles> chiffresCles(FiltresRapport f) async {
    final ventes = await _ventesParJourEtCategorie(f);
    final encaissements = await _encaissements(f);
    final (_, occupation, _) = await _occupation(f);
    return ChiffresCles(
      chiffreAffaires: ventes.fold(0, (s, v) => s + v.montant),
      encaisse: encaissements.fold(0, (s, e) => s + e.net),
      nuitees: occupation.fold(0, (s, n) => s + n.occupees),
      nuiteesDisponibles: occupation.fold(0, (s, n) => s + n.disponibles),
      chiffreHebergement: ventes
          .where((v) => v.categorie == ChargeCategory.ROOM.name)
          .fold(0, (s, v) => s + v.montant),
    );
  }

  // --- Ventes -----------------------------------------------------------------

  /// Le chiffre d'affaires par journee et par categorie.
  ///
  /// Les acomptes ne sont pas des ventes (l'argent est encaisse, rien n'est
  /// vendu) ; les remises, negatives, se deduisent. Le type de chambre ne
  /// retient que ce qui est porte sur l'ardoise d'un sejour de ce type.
  Future<List<_Vente>> _ventesParJourEtCategorie(FiltresRapport f) async {
    final lignes = await customSelect(
      '''
      SELECT fi.business_date AS jour, fi.category AS categorie,
             COALESCE(SUM(fi.amount), 0)     AS montant,
             COALESCE(SUM(fi.tax_amount), 0) AS taxes,
             COUNT(*)                        AS n
        FROM folio_items fi
        LEFT JOIN folios f             ON f.id = fi.folio_id
        LEFT JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
       WHERE fi.deleted_at IS NULL
         AND fi.is_void = 0
         AND fi.business_date BETWEEN ?1 AND ?2
         AND fi.category <> 'DEPOSIT'
         AND (?3 IS NULL OR (fi.source_table = 'outlets' AND fi.source_id = ?3))
         AND (?4 IS NULL OR fi.posted_by = ?4)
         AND (?5 IS NULL OR rr.room_type_id = ?5)
       GROUP BY fi.business_date, fi.category
      ''',
      variables: f.variables(5),
      readsFrom: {folioItems, folios, reservationRooms},
    ).get();
    return [
      for (final l in lignes)
        _Vente(
          l.read<String>('jour'),
          l.read<String>('categorie'),
          l.read<int>('montant'),
          l.read<int>('taxes'),
          l.read<int>('n'),
        ),
    ];
  }

  // --- Encaissements ----------------------------------------------------------

  /// Les encaissements nets (remboursements deduits) par journee, moyen et
  /// agent. Un encaissement suit le point de vente de son ardoise.
  Future<List<_Encaissement>> _encaissements(FiltresRapport f) async {
    final lignes = await customSelect(
      '''
      SELECT p.business_date AS jour, p.method AS moyen, p.received_by AS agent,
             COALESCE(SUM(CASE WHEN p.is_refund = 1 THEN -p.amount
                               ELSE p.amount END), 0)            AS net,
             COALESCE(SUM(CASE WHEN p.is_refund = 1 THEN p.amount
                               ELSE 0 END), 0)                   AS rembourse,
             COUNT(*)                                            AS n
        FROM payments p
       WHERE p.deleted_at IS NULL
         AND p.business_date BETWEEN ?1 AND ?2
         AND (?3 IS NULL OR EXISTS (
               SELECT 1 FROM folio_items fi
                WHERE fi.folio_id = p.folio_id
                  AND fi.deleted_at IS NULL
                  AND fi.source_table = 'outlets'
                  AND fi.source_id = ?3))
         AND (?4 IS NULL OR p.received_by = ?4)
         AND (?5 IS NULL OR EXISTS (
               SELECT 1 FROM folios f
                 JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
                WHERE f.id = p.folio_id
                  AND rr.room_type_id = ?5))
         AND (?6 IS NULL OR p.method = ?6)
       GROUP BY p.business_date, p.method, p.received_by
      ''',
      variables: f.variables(6),
      readsFrom: {payments, folioItems, folios, reservationRooms},
    ).get();
    return [
      for (final l in lignes)
        _Encaissement(
          l.read<String>('jour'),
          l.read<String>('moyen'),
          l.read<String?>('agent'),
          l.read<int>('net'),
          l.read<int>('rembourse'),
          l.read<int>('n'),
        ),
    ];
  }

  // --- Occupation -------------------------------------------------------------

  /// Les nuits occupees, nuit par nuit, sur le parc retenu.
  ///
  /// Calculees ici plutot qu'en SQL : une requete par nuit sur une annee en
  /// ferait trois cent soixante-cinq. Une chambre est occupee la nuit du `d`
  /// si le client est arrive au plus tard le `d` et repart apres. Les nuits a
  /// venir ne comptent pas : un sejour en cours n'a pas encore occupe la
  /// semaine prochaine.
  Future<(int, List<NuitOccupation>, List<LigneTypeChambre>)> _occupation(
    FiltresRapport f,
  ) async {
    final types = await customSelect(
      '''
      SELECT t.id AS id, t.label AS libelle,
             (SELECT COUNT(*) FROM rooms r
               WHERE r.room_type_id = t.id
                 AND r.deleted_at IS NULL
                 AND r.is_active = 1) AS chambres
        FROM room_types t
       WHERE t.deleted_at IS NULL
         AND (?1 IS NULL OR t.id = ?1)
       ORDER BY t.sort_order, t.label
      ''',
      variables: [Variable<String>(f.typeChambreId)],
      readsFrom: {roomTypes, rooms},
    ).get();

    final debut = formatIsoDate(f.du);
    final lendemain = formatIsoDate(DateTime(f.au.year, f.au.month, f.au.day + 1));
    final sejours = await customSelect(
      '''
      SELECT rr.room_type_id AS type, rr.arrival_date AS arrivee,
             rr.departure_date AS depart
        FROM reservation_rooms rr
       WHERE rr.deleted_at IS NULL
         AND rr.status IN ('CHECKED_IN','CHECKED_OUT')
         AND rr.arrival_date < ?2
         AND rr.departure_date > ?1
         AND (?3 IS NULL OR rr.room_type_id = ?3)
      ''',
      variables: [
        Variable.withString(debut),
        Variable.withString(lendemain),
        Variable<String>(f.typeChambreId),
      ],
      readsFrom: {reservationRooms},
    ).get();

    final hebergementParType = {
      for (final l in await customSelect(
        '''
        SELECT rr.room_type_id AS type, COALESCE(SUM(fi.amount), 0) AS montant
          FROM folio_items fi
          JOIN folios f             ON f.id = fi.folio_id
          JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
         WHERE fi.deleted_at IS NULL
           AND fi.is_void = 0
           AND fi.category = 'ROOM'
           AND fi.business_date BETWEEN ?1 AND ?2
           AND (?4 IS NULL OR fi.posted_by = ?4)
         GROUP BY rr.room_type_id
        ''',
        variables: f.variables(4),
        readsFrom: {folioItems, folios, reservationRooms},
      ).get())
        l.read<String>('type'): l.read<int>('montant'),
    };

    final aujourdhui = businessDayFor(DateTime.now());
    final chambresParType = {
      for (final t in types) t.read<String>('id'): t.read<int>('chambres'),
    };
    final parc = chambresParType.values.fold(0, (s, n) => s + n);
    final nuitsParType = <String, int>{};
    final nuitsDispoParType = <String, int>{};
    final nuits = <NuitOccupation>[];

    for (final j in f.jours) {
      if (j.isAfter(aujourdhui)) {
        nuits.add(NuitOccupation(j, 0, 0));
        continue;
      }
      final d = formatIsoDate(j);
      var occupees = 0;
      for (final s in sejours) {
        if (s.read<String>('arrivee').compareTo(d) <= 0 &&
            s.read<String>('depart').compareTo(d) > 0) {
          occupees++;
          final t = s.read<String>('type');
          nuitsParType[t] = (nuitsParType[t] ?? 0) + 1;
        }
      }
      for (final e in chambresParType.entries) {
        nuitsDispoParType[e.key] = (nuitsDispoParType[e.key] ?? 0) + e.value;
      }
      nuits.add(NuitOccupation(j, occupees, parc));
    }

    final lignes = [
      for (final t in types)
        if (t.read<int>('chambres') > 0)
          LigneTypeChambre(
            id: t.read<String>('id'),
            libelle: t.read<String>('libelle'),
            chambres: t.read<int>('chambres'),
            nuitees: nuitsParType[t.read<String>('id')] ?? 0,
            nuiteesDisponibles: nuitsDispoParType[t.read<String>('id')] ?? 0,
            chiffreAffaires: hebergementParType[t.read<String>('id')] ?? 0,
          ),
    ];
    return (parc, nuits, lignes);
  }

  // --- Points de vente --------------------------------------------------------

  Future<List<LignePointDeVente>> _pointsDeVente(FiltresRapport f) async {
    final lignes = await customSelect(
      '''
      SELECT o.id AS id, o.label AS libelle,
             COALESCE(SUM(fi.amount), 0)     AS ca,
             COUNT(DISTINCT fi.folio_id)     AS ventes,
             COALESCE(SUM(fi.quantity), 0)   AS articles
        FROM outlets o
        LEFT JOIN folio_items fi
               ON fi.source_table = 'outlets'
              AND fi.source_id = o.id
              AND fi.deleted_at IS NULL
              AND fi.is_void = 0
              AND fi.business_date BETWEEN ?1 AND ?2
              AND (?4 IS NULL OR fi.posted_by = ?4)
       WHERE o.deleted_at IS NULL
         AND (?3 IS NULL OR o.id = ?3)
       GROUP BY o.id, o.label
       ORDER BY ca DESC, o.sort_order, o.label
      ''',
      variables: f.variables(4),
      readsFrom: {outlets, folioItems},
    ).get();
    return [
      for (final l in lignes)
        LignePointDeVente(
          id: l.read<String>('id'),
          libelle: l.read<String>('libelle'),
          chiffreAffaires: l.read<int>('ca'),
          ventes: l.read<int>('ventes'),
          articles: l.read<int>('articles'),
        ),
    ];
  }

  // --- Marges -----------------------------------------------------------------

  /// La marge des articles vendus relies a un produit du stock.
  ///
  /// Le cout se retrouve par l'article de la carte du meme libelle, dans le
  /// point de vente qui a vendu : la ligne d'ardoise garde le libelle de la
  /// carte, pas l'id de l'article. Les mouvements de stock ne serviraient
  /// pas : ceux d'une vente ne naissent que sur le poste qui l'a saisie.
  /// Le cout est le prix d'achat du produit multiplie par ce que l'article
  /// en consomme.
  Future<List<LigneMarge>> _marges(FiltresRapport f) async {
    final lignes = await customSelect(
      '''
      WITH ventes AS (
        SELECT fi.label AS libelle, fi.quantity AS quantite, fi.amount AS montant,
               (SELECT mi.stock_quantity * p.purchase_price
                  FROM menu_items mi
                  JOIN menu_categories mc ON mc.id = mi.menu_category_id
                  JOIN products p         ON p.id = mi.product_id
                 WHERE mi.label = fi.label
                   AND mi.deleted_at IS NULL
                   AND (mc.outlet_id IS NULL OR mc.outlet_id = fi.source_id)
                 LIMIT 1) AS cout_unitaire
          FROM folio_items fi
         WHERE fi.deleted_at IS NULL
           AND fi.is_void = 0
           AND fi.source_table = 'outlets'
           AND fi.business_date BETWEEN ?1 AND ?2
           AND (?3 IS NULL OR fi.source_id = ?3)
           AND (?4 IS NULL OR fi.posted_by = ?4)
      )
      SELECT libelle,
             SUM(quantite)                 AS quantite,
             SUM(montant)                  AS ca,
             SUM(quantite * cout_unitaire) AS cout
        FROM ventes
       WHERE cout_unitaire IS NOT NULL
       GROUP BY libelle
       ORDER BY SUM(montant) - SUM(quantite * cout_unitaire) DESC
      ''',
      variables: f.variables(4),
      readsFrom: {folioItems, menuItems, menuCategories, products},
    ).get();
    return [
      for (final l in lignes)
        LigneMarge(
          libelle: l.read<String>('libelle'),
          quantite: l.read<int>('quantite'),
          chiffreAffaires: l.read<int>('ca'),
          cout: l.read<int>('cout'),
        ),
    ];
  }

  // --- Stock ------------------------------------------------------------------

  /// Le stock a date, tous magasins ou ceux du point de vente retenu.
  Future<List<LigneStock>> _stock(FiltresRapport f) async {
    final lignes = await customSelect(
      '''
      SELECT p.label AS libelle, p.reference AS reference,
             p.min_stock AS seuil, p.purchase_price AS achat,
             p.sale_price AS vente,
             COALESCE(SUM(l.quantity), 0) AS quantite
        FROM products p
        LEFT JOIN stock_levels l
               ON l.product_id = p.id
              AND l.deleted_at IS NULL
              AND (?1 IS NULL OR l.stock_location_id IN (
                     SELECT id FROM stock_locations WHERE outlet_id = ?1))
       WHERE p.deleted_at IS NULL
         AND p.is_active = 1
       GROUP BY p.id, p.label, p.reference, p.min_stock, p.purchase_price,
                p.sale_price
       ORDER BY p.label
      ''',
      variables: [Variable<String>(f.pointDeVenteId)],
      readsFrom: {products, stockLevels, stockLocations},
    ).get();
    return [
      for (final l in lignes)
        LigneStock(
          libelle: l.read<String>('libelle'),
          reference: l.read<String>('reference'),
          quantite: l.read<int>('quantite'),
          seuil: l.read<int>('seuil'),
          prixAchat: l.read<int>('achat'),
          prixVente: l.read<int>('vente'),
        ),
    ];
  }

  // --- Activite -------------------------------------------------------------

  /// Le jour d'exploitation d'un instant est-il dans la periode ?
  static bool _dans(FiltresRapport f, DateTime? instant) {
    if (instant == null) return false;
    final j = businessDayFor(instant);
    return !j.isBefore(f.du) && !j.isAfter(f.au);
  }

  Future<ActiviteRapport> _activite(FiltresRapport f) async {
    final du = formatIsoDate(f.du);
    final au = formatIsoDate(f.au);
    final lignes = await customSelect(
      '''
      SELECT rr.arrival_date AS arrivee, rr.departure_date AS depart,
             rr.status AS statut, rr.adults AS adultes, rr.children AS enfants,
             rr.checked_in_by AS par_arrivee, rr.checked_out_by AS par_depart,
             r.source AS origine
        FROM reservation_rooms rr
        LEFT JOIN reservations r ON r.id = rr.reservation_id
       WHERE rr.deleted_at IS NULL
         AND (rr.arrival_date BETWEEN ?1 AND ?2
              OR rr.departure_date BETWEEN ?1 AND ?2)
         AND (?3 IS NULL OR rr.room_type_id = ?3)
      ''',
      variables: [
        Variable.withString(du),
        Variable.withString(au),
        Variable<String>(f.typeChambreId),
      ],
      readsFrom: {reservationRooms, reservations},
    ).get();

    bool dedans(String d) => d.compareTo(du) >= 0 && d.compareTo(au) <= 0;
    final arriveesJour = <String, int>{};
    final departsJour = <String, int>{};
    final origines = <String, int>{};
    var prevues = 0, arrivees = 0, departs = 0, absents = 0, personnes = 0;
    var nuits = 0;
    for (final l in lignes) {
      final a = l.read<String>('arrivee');
      final d = l.read<String>('depart');
      final statut = l.read<String>('statut');
      if (dedans(a) && statut != ReservationStatus.CANCELLED.name) {
        prevues++;
        final o = l.readNullable<String>('origine') ?? ReservationSource.DIRECT.name;
        origines[o] = (origines[o] ?? 0) + 1;
        if (statut == ReservationStatus.NO_SHOW.name) absents++;
      }
      final arrive = statut == ReservationStatus.CHECKED_IN.name ||
          statut == ReservationStatus.CHECKED_OUT.name;
      if (dedans(a) &&
          arrive &&
          (f.agentId == null || l.readNullable<String>('par_arrivee') == f.agentId)) {
        arrivees++;
        arriveesJour[a] = (arriveesJour[a] ?? 0) + 1;
        personnes += l.read<int>('adultes') + l.read<int>('enfants');
        final duree = parseIsoDate(d)!.difference(parseIsoDate(a)!).inDays;
        nuits += duree < 0 ? 0 : duree;
      }
      if (dedans(d) &&
          statut == ReservationStatus.CHECKED_OUT.name &&
          (f.agentId == null || l.readNullable<String>('par_depart') == f.agentId)) {
        departs++;
        departsJour[d] = (departsJour[d] ?? 0) + 1;
      }
    }

    // Les dossiers crees ou annules : des instants, ranges par journee
    // hoteliere ici plutot que par une comparaison de texte en SQL.
    final avant = DateTime(f.du.year, f.du.month, f.du.day - 2).toUtc();
    final dossiers = await (select(reservations)..where(
          (r) =>
              r.deletedAt.isNull() &
              (r.createdAt.isBiggerOrEqualValue(avant) |
                  r.cancelledAt.isBiggerOrEqualValue(avant)),
        ))
        .get();
    final typesParDossier = f.typeChambreId == null
        ? null
        : {
            for (final l in await (select(reservationRooms)..where(
                  (rr) => rr.roomTypeId.equals(f.typeChambreId!),
                ))
                .get())
              l.reservationId,
          };
    var nouvelles = 0, annulations = 0;
    for (final r in dossiers) {
      if (typesParDossier != null && !typesParDossier.contains(r.id)) continue;
      if (_dans(f, r.createdAt)) nouvelles++;
      if (_dans(f, r.cancelledAt)) annulations++;
    }

    return ActiviteRapport(
      arriveesPrevues: prevues,
      arrivees: arrivees,
      departs: departs,
      nouvelles: nouvelles,
      annulations: annulations,
      nonPresentes: absents,
      personnes: personnes,
      dureeMoyenneDixiemes: arrivees == 0 ? 0 : (nuits * 10 / arrivees).round(),
      parJour: [
        for (final j in f.jours)
          (
            j,
            arriveesJour[formatIsoDate(j)] ?? 0,
            departsJour[formatIsoDate(j)] ?? 0,
          ),
      ],
      parOrigine: _trier([
        for (final o in origines.entries) Part(o.key, o.key, o.value),
      ]),
    );
  }

  // --- Gestion --------------------------------------------------------------

  Future<GestionRapport> _gestion(
    FiltresRapport f,
    Map<String, String> agents,
  ) async {
    String nom(String? id) =>
        id == null ? 'Non attribué' : agents[id] ?? 'Agent inconnu';

    // Les caisses : rangees a leur cloture, ou a leur ouverture tant
    // qu'elles tournent.
    final caisses = [
      for (final c in await (select(cashSessions)
            ..where((c) => c.deletedAt.isNull())
            ..orderBy([(c) => OrderingTerm(expression: c.openedAt)]))
          .get())
        if ((f.agentId == null || c.userId == f.agentId) &&
            _dans(f, c.closedAt ?? c.openedAt))
          LigneCaisse(
            agent: nom(c.userId),
            ouverture: c.openedAt,
            cloture: c.closedAt,
            fond: c.openingFloat,
            attendu: c.expectedAmount,
            compte: c.countedAmount,
            ecart: c.variance,
          ),
    ];

    final taches = await customSelect(
      '''
      SELECT t.status AS statut, t.assigned_to AS agent,
             t.duration_minutes AS minutes
        FROM housekeeping_tasks t
        LEFT JOIN rooms r ON r.id = t.room_id
       WHERE t.deleted_at IS NULL
         AND t.business_date BETWEEN ?1 AND ?2
         AND (?4 IS NULL OR t.assigned_to = ?4)
         AND (?5 IS NULL OR r.room_type_id = ?5)
      ''',
      variables: f.variables(5),
      readsFrom: {housekeepingTasks, rooms},
    ).get();
    var faites = 0, enAttente = 0;
    final parAgent = <String?, (int, int)>{};
    for (final t in taches) {
      final statut = t.read<String>('statut');
      if (statut == TaskStatus.DONE.name || statut == TaskStatus.INSPECTED.name) {
        faites++;
        final a = t.readNullable<String>('agent');
        final (n, m) = parAgent[a] ?? (0, 0);
        parAgent[a] = (n + 1, m + (t.readNullable<int>('minutes') ?? 0));
      } else if (statut != TaskStatus.CANCELLED.name) {
        enAttente++;
      }
    }

    final typeParChambre = f.typeChambreId == null
        ? null
        : {
            for (final r in await (select(rooms)..where(
                  (r) => r.roomTypeId.equals(f.typeChambreId!),
                ))
                .get())
              r.id,
          };
    final tickets = [
      for (final t in await (select(maintenanceTickets)
            ..where((t) => t.deletedAt.isNull()))
          .get())
        if (_dans(f, t.reportedAt ?? t.createdAt) &&
            (f.agentId == null ||
                t.assignedTo == f.agentId ||
                t.reportedBy == f.agentId) &&
            (typeParChambre == null || typeParChambre.contains(t.roomId)))
          t,
    ];
    final resolus = tickets.where(
      (t) => t.status == TicketStatus.RESOLVED || t.status == TicketStatus.CLOSED,
    );
    final delais = [
      for (final t in resolus)
        if (t.resolvedAt != null && t.reportedAt != null)
          t.resolvedAt!.difference(t.reportedAt!).inMinutes,
    ];
    final categories = <String, (int, int, int)>{};
    for (final t in tickets) {
      final c = (t.category == null || t.category!.trim().isEmpty)
          ? 'Sans catégorie'
          : t.category!.trim();
      final (n, r, cout) = categories[c] ?? (0, 0, 0);
      final resolu = t.status == TicketStatus.RESOLVED ||
          t.status == TicketStatus.CLOSED;
      categories[c] = (n + 1, r + (resolu ? 1 : 0), cout + t.cost);
    }

    // Les mouvements : ceux que cette tablette connait. Les sorties de vente
    // ne naissent que sur le poste qui a vendu.
    final mouvements = await customSelect(
      '''
      SELECT m.type AS type, m.quantity AS quantite, m.moved_at AS moment,
             CASE WHEN m.unit_cost > 0 THEN m.unit_cost
                  ELSE COALESCE(p.purchase_price, 0) END AS cout
        FROM stock_movements m
        LEFT JOIN products p ON p.id = m.product_id
        LEFT JOIN stock_locations l ON l.id = m.stock_location_id
       WHERE m.deleted_at IS NULL
         AND m.status <> 'REJECTED'
         AND m.moved_at IS NOT NULL
         AND (?1 IS NULL OR l.outlet_id = ?1)
         AND (?2 IS NULL OR m.moved_by = ?2)
      ''',
      variables: [
        Variable<String>(f.pointDeVenteId),
        Variable<String>(f.agentId),
      ],
      readsFrom: {stockMovements, products, stockLocations},
    ).get();
    final parType = <String, (int, int, int)>{};
    for (final m in mouvements) {
      if (!_dans(f, m.read<DateTime>('moment'))) continue;
      final q = m.read<int>('quantite').abs();
      final (n, qte, val) = parType[m.read<String>('type')] ?? (0, 0, 0);
      parType[m.read<String>('type')] =
          (n + 1, qte + q, val + q * m.read<int>('cout'));
    }

    return GestionRapport(
      caisses: caisses,
      tachesMenage: taches.length,
      tachesFaites: faites,
      tachesEnAttente: enAttente,
      menageParAgent: [
        for (final e in parAgent.entries)
          LigneMenage(nom(e.key), e.value.$1, e.value.$2),
      ]..sort((a, b) => b.faites.compareTo(a.faites)),
      ticketsSignales: tickets.length,
      ticketsResolus: resolus.length,
      ticketsUrgents: tickets
          .where((t) => t.priority == Priority.URGENT || t.priority == Priority.HIGH)
          .length,
      coutMaintenance: tickets.fold(0, (s, t) => s + t.cost),
      delaiResolutionDixiemesHeure: delais.isEmpty
          ? 0
          : (delais.reduce((a, b) => a + b) / delais.length / 6).round(),
      maintenanceParCategorie: [
        for (final e in categories.entries)
          LigneMaintenance(e.key, e.value.$1, e.value.$2, e.value.$3),
      ]..sort((a, b) => b.tickets.compareTo(a.tickets)),
      mouvements: [
        for (final t in StockMovementType.values)
          if (parType[t.name] case (final n, final q, final v))
            LigneMouvement(t, n, q, v),
      ],
    );
  }

  // --- Outils -----------------------------------------------------------------

  Future<Map<String, String>> _nomsAgents() async => {
    for (final u in await select(users).get())
      u.id: '${u.firstName} ${u.lastName}'.trim(),
  };

  Future<int> _entier(String sql) async =>
      (await customSelect(sql).getSingle()).read<int>('n');

  static List<Part> _trier(List<Part> parts) =>
      parts..sort((a, b) => b.montant.compareTo(a.montant));
}

class _Vente {
  const _Vente(this.jour, this.categorie, this.montant, this.taxes, this.nombre);

  final String jour;
  final String categorie;
  final int montant;
  final int taxes;
  final int nombre;
}

class _Encaissement {
  const _Encaissement(
    this.jour,
    this.moyen,
    this.agent,
    this.net,
    this.rembourse,
    this.nombre,
  );

  final String jour;
  final String moyen;
  final String? agent;
  final int net;
  final int rembourse;
  final int nombre;
}
