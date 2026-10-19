/// Les rapports par module (F3.3, demande du 19 octobre) : un document par
/// grand onglet -- la reception, les ventes, les stocks, l'entretien --,
/// exportable en PDF ou en Excel, avec ses filtres.
///
/// Chaque rapport reprend les blocs du rapport financier qui le concernent
/// (memes chiffres, un seul calcul) et y ajoute ses registres, ligne par
/// ligne, comme un document administratif : chaque sejour, chaque vente,
/// chaque mouvement de stock, chaque chambre faite, chaque panne. Les
/// finances gardent l'ecran Rapports, qui est deja le leur.
library;

import 'package:flutter/widgets.dart' show IconData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/access_queries.dart' show AccessProfile;
import '../../data/local/queries/registres_queries.dart';
import '../../data/local/queries/report_queries.dart';
import 'export/export_model.dart';
import 'export/report_sections.dart';

/// Un module et son rapport.
enum ModuleRapport {
  reception(
    titre: 'Rapport de la réception',
    chemin: 'reception',
    parent: '/mouvements',
    permission: 'reservation.read',
    filtreTypeChambre: true,
  ),
  ventes(
    titre: 'Rapport des ventes',
    chemin: 'ventes',
    parent: '/ventes',
    permission: 'order.read',
    filtrePointDeVente: true,
  ),
  stocks(
    titre: 'Rapport des stocks',
    chemin: 'stocks',
    parent: '/stocks',
    permission: 'stock.read',
    filtrePointDeVente: true,
  ),
  entretien(
    titre: 'Rapport de l’entretien',
    chemin: 'entretien',
    parent: '/entretien',
    permission: 'housekeeping.read|maintenance.read',
    filtreTypeChambre: true,
  );

  const ModuleRapport({
    required this.titre,
    required this.chemin,
    required this.parent,
    required this.permission,
    this.filtrePointDeVente = false,
    this.filtreTypeChambre = false,
  });

  /// Le nom du document, et de l'entree du menu.
  final String titre;

  /// Sous `/rapports` : `/rapports/ventes`.
  final String chemin;

  /// L'onglet sous lequel l'entree se range.
  final String parent;

  /// Le droit d'ouvrir le rapport : celui de son module.
  final String permission;
  final bool filtrePointDeVente;
  final bool filtreTypeChambre;

  String get route => '/rapports/$chemin';

  IconData get icone => PhosphorIconsLight.chartLineUp;

  /// Les visas en fin de document : un rapport remis a la direction se
  /// vise.
  static const visas = ['Établi par', 'Visa de la direction'];
}

/// Les registres d'un module, lus pour une periode et des filtres.
typedef CleRegistres = (ModuleRapport, FiltresRapport);

final registresProvider = FutureProvider.autoDispose
    .family<Registres, CleRegistres>((ref, cle) async {
      final db = ref.watch(databaseProvider);
      final (module, f) = cle;
      return switch (module) {
        ModuleRapport.reception => Registres(sejours: await db.registreSejours(f)),
        ModuleRapport.ventes => Registres(
          ventes: await db.journalVentes(f),
          articles: await db.ventesParArticle(f),
        ),
        ModuleRapport.stocks => Registres(
          mouvements: await db.mouvementsStock(f),
        ),
        ModuleRapport.entretien => Registres(
          menage: await db.registreMenage(f),
          pannes: await db.registrePannes(f),
        ),
      };
    });

/// Ce que les registres d'un module ont lu.
class Registres {
  const Registres({
    this.sejours = const [],
    this.ventes = const [],
    this.articles = const [],
    this.mouvements = const [],
    this.menage = const [],
    this.pannes = const [],
  });

  final List<LigneSejour> sejours;
  final List<LigneVente> ventes;
  final List<LigneArticle> articles;
  final List<LigneMouvementStock> mouvements;
  final List<TacheRegistre> menage;
  final List<LignePanne> pannes;
}

/// Les blocs du rapport d'un module, dans l'ordre du document. Un bloc ne
/// figure que pour qui a le droit de le lire : la marge ne va pas au
/// comptoir, les pannes pas a la femme de chambre.
List<Section> sectionsDuModule(
  ModuleRapport module,
  RapportFinancier r,
  Registres reg,
  AccessProfile acces,
) {
  final s = SectionsRapport(r);
  return switch (module) {
    ModuleRapport.reception => [
      s.occupation,
      s.activite,
      _registreSejours(reg.sejours),
    ],
    ModuleRapport.ventes => [
      s.pointsDeVente,
      _journalVentes(reg.ventes),
      _ventesParArticle(reg.articles),
    ],
    ModuleRapport.stocks => [
      if (acces.peut('stock.manage') || acces.peut('accounting.read'))
        s.stockEtMarges,
      _registreMouvements(reg.mouvements),
    ],
    ModuleRapport.entretien => [
      s.menageEtMaintenance,
      if (acces.peut('housekeeping.read')) _registreMenage(reg.menage),
      if (acces.peut('maintenance.read')) _registrePannes(reg.pannes),
    ],
  };
}

// --- Les registres ------------------------------------------------------------------

String _heure(DateTime? instant) {
  if (instant == null) return '';
  final l = instant.toLocal();
  return '${l.hour.toString().padLeft(2, '0')} h ${l.minute.toString().padLeft(2, '0')}';
}

Section _registreSejours(List<LigneSejour> l) {
  final nuits = l.fold(0, (s, x) => s + x.nuits);
  final hebergement = l.fold(0, (s, x) => s + x.nuits * x.tarif);
  return Section(
    titre: 'Registre des séjours',
    description:
        'Chaque séjour qui touche la période : arrivé avant sa fin, parti '
        'après son début. Suit la période, l’agent (arrivée ou départ) et le '
        'type de chambre.',
    chiffres: [
      Chiffre('Séjours', l.length, Unite.nombre),
      Chiffre('Nuitées', nuits, Unite.nombre),
      Chiffre('Hébergement au tarif', hebergement, Unite.montant,
          detail: 'nuitées × tarif de la nuit'),
    ],
    tableaux: [
      Tableau(
        titre: 'Séjours',
        largeurs: const [0.8, 1.6, 1.2, 1, 1, 0.7, 1.1, 0.9],
        colonnes: const [
          Colonne('Chambre'),
          Colonne('Client'),
          Colonne('Catégorie'),
          Colonne('Arrivée'),
          Colonne('Départ'),
          Colonne('Nuits', Unite.nombre),
          Colonne('Tarif de la nuit', Unite.montant),
          Colonne('Statut'),
        ],
        lignes: [
          for (final x in l)
            [
              x.chambre,
              x.client,
              x.categorie,
              formatShortDate(x.arrivee),
              formatShortDate(x.depart),
              x.nuits,
              x.tarif,
              x.statut == ReservationStatus.CHECKED_IN ? 'En séjour' : 'Parti',
            ],
        ],
        total: ['Total', '${l.length} séjours', '', '', '', nuits, '', ''],
      ),
    ],
  );
}

Section _journalVentes(List<LigneVente> l) {
  final total = l.fold(0, (s, x) => s + x.montant);
  int part(String reglement) =>
      l.where((x) => x.reglement == reglement).fold(0, (s, x) => s + x.montant);
  return Section(
    titre: 'Journal des ventes',
    description:
        'Chaque vente, dans l’ordre : une ardoise servie à un comptoir dans '
        'la journée, ce qui a été servi et où en est l’argent. Suit la '
        'période, le point de vente et l’agent.',
    chiffres: [
      Chiffre('Ventes', l.length, Unite.nombre),
      Chiffre('Montant vendu', total, Unite.montant),
      Chiffre('Ticket moyen', l.isEmpty ? 0 : total ~/ l.length, Unite.montant),
      Chiffre('Payé', part('Payée'), Unite.montant),
      Chiffre('Reste à payer', part('À payer'), Unite.montant),
      Chiffre('Porté aux chambres', part('Sur la chambre'), Unite.montant),
    ],
    tableaux: [
      Tableau(
        titre: 'Ventes',
        largeurs: const [1, 0.75, 1.1, 1.3, 2, 0.9, 1.1],
        colonnes: const [
          Colonne('Date'),
          Colonne('Heure'),
          Colonne('Point de vente'),
          Colonne('Client'),
          Colonne('Articles'),
          Colonne('Règlement'),
          Colonne('Montant', Unite.montant),
        ],
        lignes: [
          for (final x in l)
            [
              formatShortDate(x.jour),
              _heure(x.moment),
              x.pointDeVente,
              x.client,
              x.articles,
              x.reglement,
              x.montant,
            ],
        ],
        total: ['Total', '', '', '${l.length} ventes', '', '', total],
      ),
    ],
  );
}

Section _ventesParArticle(List<LigneArticle> l) {
  final total = l.fold(0, (s, x) => s + x.montant);
  final quantite = l.fold(0, (s, x) => s + x.quantite);
  return Section(
    titre: 'Ventes par article',
    description:
        'Ce qui s’est vendu, article par article, le plus gros montant '
        'd’abord. Suit la période, le point de vente et l’agent.',
    tableaux: [
      Tableau(
        titre: 'Articles',
        colonnes: const [
          Colonne('Article'),
          Colonne('Quantité', Unite.nombre),
          Colonne('Montant', Unite.montant),
          Colonne('Part', Unite.pointsDeBase),
        ],
        lignes: [
          for (final x in l)
            [
              x.article,
              x.quantite,
              x.montant,
              total == 0 ? 0 : (x.montant * 10000 / total).round(),
            ],
        ],
        total: ['Total', quantite, total, total == 0 ? 0 : 10000],
      ),
    ],
  );
}

Section _registreMouvements(List<LigneMouvementStock> l) {
  int nombre(StockMovementType t) => l.where((x) => x.type == t).length;
  return Section(
    titre: 'Registre des mouvements de stock',
    description:
        'Chaque entrée, sortie, transfert, perte ou ajustement, dans l’ordre, '
        'avec qui l’a saisi. Les mouvements ne descendent pas du serveur : '
        'ce sont ceux que connaît cette tablette. Suit la période, le point '
        'de vente (ses magasins) et l’agent.',
    chiffres: [
      Chiffre('Mouvements', l.length, Unite.nombre),
      Chiffre('Entrées', nombre(StockMovementType.IN), Unite.nombre),
      Chiffre('Sorties', nombre(StockMovementType.OUT), Unite.nombre),
      Chiffre('Transferts', nombre(StockMovementType.TRANSFER), Unite.nombre),
      Chiffre('Pertes', nombre(StockMovementType.LOSS), Unite.nombre),
      Chiffre(
        'En attente',
        l.where((x) => x.statut == StockMovementStatus.PENDING).length,
        Unite.nombre,
        detail: 'transferts à valider',
      ),
    ],
    tableaux: [
      Tableau(
        titre: 'Mouvements',
        largeurs: const [1.4, 0.9, 1.4, 1.1, 1.1, 0.9, 1.3, 1.1, 0.9],
        colonnes: const [
          Colonne('Date'),
          Colonne('Genre'),
          Colonne('Produit'),
          Colonne('Magasin'),
          Colonne('Vers'),
          Colonne('Quantité', Unite.texte, true),
          Colonne('Motif'),
          Colonne('Agent'),
          Colonne('Statut'),
        ],
        lignes: [
          for (final x in l)
            [
              formatInstant(x.moment),
              libelleMouvement(x.type),
              x.produit,
              x.magasin,
              x.vers ?? '',
              '${x.quantite} ${x.unite}',
              x.motif ?? '',
              x.agent ?? '',
              switch (x.statut) {
                StockMovementStatus.APPROVED => 'Validé',
                StockMovementStatus.PENDING => 'En attente',
                StockMovementStatus.REJECTED => 'Refusé',
              },
            ],
        ],
      ),
    ],
  );
}

String _prestation(HousekeepingTaskType t) => switch (t) {
  HousekeepingTaskType.DEPARTURE => 'Après départ',
  HousekeepingTaskType.STAYOVER => 'Client en place',
  HousekeepingTaskType.REFRESH => 'Rafraîchissement',
  HousekeepingTaskType.DEEP_CLEAN => 'Nettoyage complet',
  HousekeepingTaskType.INSPECTION => 'Contrôle',
};

Section _registreMenage(List<TacheRegistre> l) {
  final faites = [
    for (final x in l)
      if (x.statut == TaskStatus.DONE || x.statut == TaskStatus.INSPECTED) x,
  ];
  final durees = [
    for (final x in faites)
      if (x.duree != null) x.duree!,
  ];
  return Section(
    titre: 'Registre du ménage',
    description:
        'Chaque chambre à faire sur la période, qui s’en est chargé, quand '
        'et en combien de temps. Les tâches ne descendent pas du serveur : '
        'ce sont celles que connaît cette tablette. Suit la période, l’agent '
        'et le type de chambre.',
    chiffres: [
      Chiffre('Chambres à faire', l.length, Unite.nombre),
      Chiffre('Chambres faites', faites.length, Unite.nombre),
      Chiffre(
        'Durée moyenne',
        durees.isEmpty ? 0 : durees.fold(0, (s, d) => s + d) ~/ durees.length,
        Unite.nombre,
        detail: 'minutes par chambre',
      ),
    ],
    tableaux: [
      Tableau(
        titre: 'Chambres',
        largeurs: const [1, 0.8, 1.2, 1.3, 0.8, 0.8, 0.8, 0.9],
        colonnes: const [
          Colonne('Date'),
          Colonne('Chambre'),
          Colonne('Prestation'),
          Colonne('Agent'),
          Colonne('Début'),
          Colonne('Fin'),
          Colonne('Durée (min)', Unite.nombre),
          Colonne('Statut'),
        ],
        lignes: [
          for (final x in l)
            [
              formatShortDate(x.jour),
              x.chambre,
              _prestation(x.type),
              x.agent ?? 'Personne',
              _heure(x.debut),
              _heure(x.fin),
              x.duree,
              switch (x.statut) {
                TaskStatus.PENDING => 'À faire',
                TaskStatus.ASSIGNED => 'Confiée',
                TaskStatus.IN_PROGRESS => 'En cours',
                TaskStatus.DONE => 'Faite',
                TaskStatus.INSPECTED => 'Contrôlée',
                TaskStatus.CANCELLED => 'Annulée',
              },
            ],
        ],
      ),
    ],
  );
}

Section _registrePannes(List<LignePanne> l) {
  final cout = l.fold(0, (s, x) => s + x.cout);
  return Section(
    titre: 'Registre des pannes',
    description:
        'Chaque panne signalée ou réglée sur la période, son lieu, sa '
        'priorité et ce que la réparation a coûté. Les pannes ne descendent '
        'pas du serveur : ce sont celles que connaît cette tablette. Suit la '
        'période, l’agent et le type de chambre.',
    chiffres: [
      Chiffre('Pannes', l.length, Unite.nombre),
      Chiffre(
        'Réglées',
        l.where((x) => x.reglee != null).length,
        Unite.nombre,
      ),
      Chiffre('Coût des réparations', cout, Unite.montant),
    ],
    tableaux: [
      Tableau(
        titre: 'Pannes',
        largeurs: const [0.8, 1.3, 1, 1.6, 0.9, 1, 1.3, 1],
        colonnes: const [
          Colonne('N°'),
          Colonne('Signalée le'),
          Colonne('Lieu'),
          Colonne('Panne'),
          Colonne('Priorité'),
          Colonne('Statut'),
          Colonne('Réglée le'),
          Colonne('Coût', Unite.montant),
        ],
        lignes: [
          for (final x in l)
            [
              x.numero,
              formatInstant(x.signalee),
              x.lieu,
              x.titre,
              switch (x.priorite) {
                Priority.URGENT => 'Urgent',
                Priority.HIGH => 'Prioritaire',
                Priority.NORMAL => 'Normal',
                Priority.LOW => 'Peut attendre',
              },
              switch (x.statut) {
                TicketStatus.OPEN => 'Ouverte',
                TicketStatus.ASSIGNED => 'Prise en main',
                TicketStatus.IN_PROGRESS => 'En intervention',
                TicketStatus.RESOLVED => 'Réglée',
                TicketStatus.CLOSED => 'Close',
                TicketStatus.CANCELLED => 'Annulée',
              },
              formatInstant(x.reglee),
              x.cout,
            ],
        ],
        total: ['Total', '', '', '${l.length} pannes', '', '', '', cout],
      ),
    ],
  );
}
