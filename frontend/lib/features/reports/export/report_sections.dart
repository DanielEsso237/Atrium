/// Les blocs du rapport financier, decrits une fois pour l'ecran et les
/// exports.
///
/// Chaque bloc dit en une phrase quels filtres il suit : un rapport filtre
/// sur un agent qui afficherait l'occupation de tout l'hotel sans le dire
/// laisserait croire que l'agent remplit les chambres.
library;

import '../../../core/formats.dart';
import '../../../data/local/enums.dart';
import '../../../data/local/queries/report_queries.dart';
import '../../billing/charge_labels.dart';
import 'export_model.dart';

/// Les couleurs des graphiques, en ARGB (voir `AtriumChartColors`).
abstract final class CouleursExport {
  static const actuel = 0xFF3D68DD;
  static const laiton = 0xFFBD8A2E;
  static const sarcelle = 0xFF11A08B;
  static const prune = 0xFFB44F9F;
  static const precedent = 0xFF9AA6C4;
}

String libelleCategorie(String cle) {
  for (final c in ChargeCategory.values) {
    if (c.name == cle) return chargeCategoryLabel(c);
  }
  return cle;
}

String libelleMoyen(String cle) {
  for (final m in PaymentMethod.values) {
    if (m.name == cle) return paymentMethodLabel(m);
  }
  return cle;
}

/// Variation en points de base, ou `null` quand la periode precedente est
/// vide (une hausse « infinie » n'apprend rien).
int? variationBp(int actuel, int precedent) => precedent == 0
    ? null
    : ((actuel - precedent) * 10000 / precedent.abs()).round();

/// Part d'un total en points de base.
int partBp(int valeur, int total) =>
    total == 0 ? 0 : (valeur * 10000 / total).round();

String libelleCaisses(int n) => switch (n) {
  0 => 'aucune caisse close',
  1 => '1 caisse close',
  _ => '$n caisses closes',
};

/// Les ventes avant remises : la base des parts par categorie. Rapportees au
/// chiffre net, les parts depassaient 100 % des qu'une remise etait faite.
int ventesBrutes(RapportFinancier r) =>
    r.parCategorie.fold(0, (s, c) => s + c.montant);

String libelleOrigine(String cle) => switch (cle) {
  'DIRECT' => 'Direct',
  'PHONE' => 'Téléphone',
  'WALK_IN' => 'Sans réservation',
  'OTA' => 'Plateformes en ligne',
  'CORPORATE' => 'Entreprises',
  'EMAIL' => 'Courriel',
  _ => cle,
};

String libelleMouvement(StockMovementType t) => switch (t) {
  StockMovementType.IN => 'Entrées',
  StockMovementType.OUT => 'Sorties',
  StockMovementType.TRANSFER => 'Transferts',
  StockMovementType.ADJUSTMENT => 'Ajustements',
  StockMovementType.LOSS => 'Pertes',
  StockMovementType.RETURN => 'Retours',
};

/// Un instant lisible : `09/10/2026 à 14 h 05`, a l'heure locale.
String formatInstant(DateTime? instant) {
  if (instant == null) return '';
  final l = instant.toLocal();
  return '${formatShortDate(l)} à ${l.hour} h ${l.minute.toString().padLeft(2, '0')}';
}

/// Une date de graphique : `28 sept.`.
String etiquetteJour(DateTime j) => formatDayMonth(j);

class SectionsRapport {
  const SectionsRapport(this.r);

  final RapportFinancier r;

  List<Section> get toutes => [
    synthese,
    chiffreAffaires,
    encaissements,
    occupation,
    activite,
    pointsDeVente,
    stockEtMarges,
    caisses,
    menageEtMaintenance,
  ];

  Section get synthese {
    final c = r.cles;
    final p = r.precedent;
    List<Object?> ligne(String nom, int a, int b, Unite u) => [
      nom,
      formaterValeur(a, u),
      formaterValeur(b, u),
      variationBp(a, b) ?? 'sans repère',
    ];
    return Section(
      titre: "Vue d'ensemble",
      description:
          "Les chiffres clés de la période, comparés à la période de même "
          "durée qui la précède.",
      chiffres: [
        Chiffre("Chiffre d'affaires", c.chiffreAffaires, Unite.montant),
        Chiffre('Encaissé', c.encaisse, Unite.montant),
        Chiffre("Taux d'occupation", c.tauxOccupation, Unite.pourcentage),
        Chiffre('Prix moyen par nuit', c.prixMoyen, Unite.montant),
        Chiffre('RevPAR', c.revPar, Unite.montant,
            detail: 'revenu hébergement par chambre disponible'),
        Chiffre('Marge brute', r.margeBrute, Unite.montant,
            detail: 'articles reliés au stock'),
        Chiffre('Reste à encaisser', r.creances, Unite.montant,
            detail: 'soldes des ardoises ouvertes'),
        Chiffre('Arrhes détenues', r.arrhesDetenues, Unite.montant,
            detail: 'dossiers pas encore arrivés'),
        Chiffre('Taxes collectées', r.taxes, Unite.montant),
        Chiffre('Remises accordées', r.remises, Unite.montant),
        Chiffre('Écart de caisse', r.ecartCaisse, Unite.montant,
            detail: libelleCaisses(r.sessionsCloses)),
      ],
      tableaux: [
        Tableau(
          titre: 'Comparaison avec la période précédente',
          colonnes: const [
            Colonne('Indicateur'),
            Colonne('Période', Unite.texte, true),
            Colonne('Période précédente', Unite.texte, true),
            Colonne('Variation', Unite.pointsDeBase),
          ],
          lignes: [
            ligne("Chiffre d'affaires", c.chiffreAffaires, p.chiffreAffaires,
                Unite.montant),
            ligne('Encaissé', c.encaisse, p.encaisse, Unite.montant),
            ligne("Taux d'occupation", c.tauxOccupation, p.tauxOccupation,
                Unite.pourcentage),
            ligne('Nuitées vendues', c.nuitees, p.nuitees, Unite.nombre),
            ligne('Prix moyen par nuit', c.prixMoyen, p.prixMoyen,
                Unite.montant),
            ligne('RevPAR', c.revPar, p.revPar, Unite.montant),
          ],
        ),
      ],
    );
  }

  Section get chiffreAffaires {
    final total = r.cles.chiffreAffaires;
    final brut = ventesBrutes(r);
    final jours = r.filtres.nbJours;
    return Section(
      titre: "Chiffre d'affaires",
      description:
          'Tout ce qui est porté sur les ardoises, remises déduites, hors '
          "acomptes. Suit la période, le point de vente, l'agent et le type "
          'de chambre.',
      chiffres: [
        Chiffre('Total TTC', total, Unite.montant),
        Chiffre('Moyenne par jour', jours == 0 ? 0 : total ~/ jours,
            Unite.montant),
        Chiffre('Taxes collectées', r.taxes, Unite.montant),
        Chiffre('Remises accordées', r.remises, Unite.montant),
      ],
      graphique: Graphique(
        type: TypeGraphique.courbe,
        etiquettes: [for (final j in r.parJour) etiquetteJour(j.jour)],
        series: [
          Serie("Chiffre d'affaires",
              [for (final j in r.parJour) j.chiffreAffaires],
              CouleursExport.actuel),
          Serie('Encaissé', [for (final j in r.parJour) j.encaisse],
              CouleursExport.laiton),
        ],
        unite: Unite.montant,
      ),
      tableaux: [
        Tableau(
          titre: 'Par catégorie',
          colonnes: const [
            Colonne('Catégorie'),
            Colonne('Montant', Unite.montant),
            Colonne('Part', Unite.pointsDeBase),
            Colonne('Lignes', Unite.nombre),
          ],
          lignes: [
            for (final c in r.parCategorie)
              [
                libelleCategorie(c.cle),
                c.montant,
                partBp(c.montant, brut),
                c.nombre,
              ],
            if (r.remises != 0) ['Remises accordées', -r.remises, null, null],
          ],
          total: [
            'Total net',
            total,
            null,
            r.parCategorie.fold<int>(0, (s, c) => s + c.nombre),
          ],
        ),
        Tableau(
          titre: 'Par jour',
          colonnes: const [
            Colonne('Jour'),
            Colonne("Chiffre d'affaires", Unite.montant),
            Colonne('Encaissé', Unite.montant),
          ],
          lignes: [
            for (final j in r.parJour)
              [formatShortDate(j.jour), j.chiffreAffaires, j.encaisse],
          ],
          total: ['Total', total, r.cles.encaisse],
        ),
      ],
    );
  }

  Section get encaissements {
    final total = r.cles.encaisse;
    return Section(
      titre: 'Encaissements',
      description:
          "L'argent reçu, arrhes comprises, remboursements déduits. Suit la "
          "période, le point de vente, l'agent, le moyen de paiement et le "
          'type de chambre.',
      chiffres: [
        Chiffre('Encaissé net', total, Unite.montant),
        Chiffre('Remboursé', r.rembourse, Unite.montant),
        Chiffre('Opérations', r.nbEncaissements, Unite.nombre),
        Chiffre(
          'Ticket moyen',
          r.nbEncaissements == 0 ? 0 : total ~/ r.nbEncaissements,
          Unite.montant,
        ),
      ],
      graphique: Graphique(
        type: TypeGraphique.barres,
        etiquettes: [for (final m in r.parMoyen) libelleMoyen(m.cle)],
        series: [
          Serie('Encaissé', [for (final m in r.parMoyen) m.montant],
              CouleursExport.laiton),
        ],
        unite: Unite.montant,
      ),
      tableaux: [
        Tableau(
          titre: 'Par moyen de paiement',
          colonnes: const [
            Colonne('Moyen'),
            Colonne('Montant', Unite.montant),
            Colonne('Part', Unite.pointsDeBase),
            Colonne('Opérations', Unite.nombre),
          ],
          lignes: [
            for (final m in r.parMoyen)
              [libelleMoyen(m.cle), m.montant, partBp(m.montant, total),
                m.nombre],
          ],
          total: ['Total', total, null, r.nbEncaissements],
        ),
        Tableau(
          titre: 'Par agent',
          colonnes: const [
            Colonne('Agent'),
            Colonne('Montant', Unite.montant),
            Colonne('Part', Unite.pointsDeBase),
            Colonne('Opérations', Unite.nombre),
          ],
          lignes: [
            for (final a in r.parAgent)
              [a.libelle, a.montant, partBp(a.montant, total), a.nombre],
          ],
          total: ['Total', total, null, r.nbEncaissements],
        ),
      ],
    );
  }

  Section get occupation {
    final c = r.cles;
    return Section(
      titre: 'Occupation',
      description:
          'Les nuits vendues sur le parc actif, jusqu’à la nuit dernière. '
          'Suit la période et le type de chambre.',
      chiffres: [
        Chiffre("Taux d'occupation", c.tauxOccupation, Unite.pourcentage),
        Chiffre('Nuitées vendues', c.nuitees, Unite.nombre),
        Chiffre('Nuitées disponibles', c.nuiteesDisponibles, Unite.nombre),
        Chiffre('Chiffre hébergement', c.chiffreHebergement, Unite.montant),
        Chiffre('Prix moyen par nuit', c.prixMoyen, Unite.montant),
        Chiffre('RevPAR', c.revPar, Unite.montant),
      ],
      graphique: Graphique(
        type: TypeGraphique.courbe,
        etiquettes: [for (final n in r.occupation) etiquetteJour(n.jour)],
        series: [
          Serie("Taux d'occupation", [for (final n in r.occupation) n.taux],
              CouleursExport.actuel),
        ],
        unite: Unite.pourcentage,
      ),
      tableaux: [
        Tableau(
          titre: 'Par type de chambre',
          colonnes: const [
            Colonne('Type'),
            Colonne('Chambres', Unite.nombre),
            Colonne('Nuitées', Unite.nombre),
            Colonne('Taux', Unite.pourcentage),
            Colonne('Chiffre hébergement', Unite.montant),
            Colonne('Prix moyen', Unite.montant),
          ],
          lignes: [
            for (final t in r.parType)
              [t.libelle, t.chambres, t.nuitees, t.taux, t.chiffreAffaires,
                t.prixMoyen],
          ],
          total: [
            'Total',
            r.chambres,
            c.nuitees,
            c.tauxOccupation,
            r.parType.fold<int>(0, (s, t) => s + t.chiffreAffaires),
            c.prixMoyen,
          ],
        ),
        Tableau(
          titre: 'Par nuit',
          colonnes: const [
            Colonne('Nuit'),
            Colonne('Occupées', Unite.nombre),
            Colonne('Disponibles', Unite.nombre),
            Colonne('Taux', Unite.pourcentage),
          ],
          lignes: [
            for (final n in r.occupation)
              [formatShortDate(n.jour), n.occupees, n.disponibles, n.taux],
          ],
        ),
      ],
    );
  }

  Section get pointsDeVente {
    final total = r.ventesPointsDeVente;
    final ventes = r.pointsDeVente.fold<int>(0, (s, l) => s + l.ventes);
    return Section(
      titre: 'Ventes par point de vente',
      description:
          'Ce que chaque point de vente a porté sur les ardoises, au '
          "comptoir comme sur la chambre. Suit la période, le point de vente "
          "et l'agent.",
      chiffres: [
        Chiffre('Ventes', total, Unite.montant),
        Chiffre('Clients servis', ventes, Unite.nombre),
        Chiffre('Panier moyen', ventes == 0 ? 0 : total ~/ ventes,
            Unite.montant),
      ],
      graphique: Graphique(
        type: TypeGraphique.barres,
        etiquettes: [for (final l in r.pointsDeVente) l.libelle],
        series: [
          Serie('Ventes', [for (final l in r.pointsDeVente) l.chiffreAffaires],
              CouleursExport.sarcelle),
        ],
        unite: Unite.montant,
      ),
      tableaux: [
        Tableau(
          titre: 'Détail',
          colonnes: const [
            Colonne('Point de vente'),
            Colonne('Ventes', Unite.montant),
            Colonne('Part', Unite.pointsDeBase),
            Colonne('Clients', Unite.nombre),
            Colonne('Articles', Unite.nombre),
            Colonne('Panier moyen', Unite.montant),
          ],
          lignes: [
            for (final l in r.pointsDeVente)
              [
                l.libelle,
                l.chiffreAffaires,
                partBp(l.chiffreAffaires, total),
                l.ventes,
                l.articles,
                l.panierMoyen,
              ],
          ],
          total: [
            'Total',
            total,
            null,
            ventes,
            r.pointsDeVente.fold<int>(0, (s, l) => s + l.articles),
            ventes == 0 ? 0 : total ~/ ventes,
          ],
        ),
      ],
    );
  }

  Section get stockEtMarges {
    final meilleures = r.marges.take(8).toList();
    return Section(
      titre: 'Stock et marges',
      description:
          "Les marges des articles vendus reliés à un produit du stock, au "
          "prix d'achat. Le stock est celui d'aujourd'hui ; les mouvements "
          "sont ceux que connaît cette tablette. Suit la période, le point de "
          "vente et l'agent.",
      chiffres: [
        Chiffre('Marge brute', r.margeBrute, Unite.montant),
        Chiffre('Taux de marge', r.tauxMargeBp, Unite.pointsDeBase),
        Chiffre('Ventes stockées', r.ventesStock, Unite.montant),
        Chiffre("Coût d'achat", r.coutStock, Unite.montant),
        Chiffre('Stock au prix d’achat', r.valeurStockAchat, Unite.montant),
        Chiffre('Stock au prix de vente', r.valeurStockVente, Unite.montant),
        Chiffre('Sous le seuil', r.articlesSousSeuil, Unite.nombre,
            detail: 'produits à réapprovisionner'),
        Chiffre('Pertes', r.gestion.valeurPertes, Unite.montant,
            detail: "au prix d'achat"),
      ],
      graphique: Graphique(
        type: TypeGraphique.barres,
        etiquettes: [for (final m in meilleures) m.libelle],
        series: [
          Serie('Marge', [for (final m in meilleures) m.marge],
              CouleursExport.prune),
        ],
        unite: Unite.montant,
      ),
      tableaux: [
        Tableau(
          titre: 'Marges par article',
          colonnes: const [
            Colonne('Article'),
            Colonne('Quantité', Unite.nombre),
            Colonne('Ventes', Unite.montant),
            Colonne("Coût d'achat", Unite.montant),
            Colonne('Marge', Unite.montant),
            Colonne('Taux', Unite.pointsDeBase),
          ],
          lignes: [
            for (final m in r.marges)
              [m.libelle, m.quantite, m.chiffreAffaires, m.cout, m.marge,
                m.tauxBp],
          ],
          total: [
            'Total',
            r.marges.fold<int>(0, (s, m) => s + m.quantite),
            r.ventesStock,
            r.coutStock,
            r.margeBrute,
            r.tauxMargeBp,
          ],
        ),
        Tableau(
          titre: 'État du stock',
          colonnes: const [
            Colonne('Produit'),
            Colonne('Référence'),
            Colonne('Quantité', Unite.nombre),
            Colonne('Seuil', Unite.nombre),
            Colonne("Prix d'achat", Unite.montant),
            Colonne("Valeur d'achat", Unite.montant),
            Colonne('Valeur de vente', Unite.montant),
            Colonne('État'),
          ],
          lignes: [
            for (final s in r.stock)
              [
                s.libelle,
                s.reference,
                s.quantite,
                s.seuil,
                s.prixAchat,
                s.valeurAchat,
                s.valeurVente,
                s.quantite <= 0
                    ? 'Rupture'
                    : s.sousLeSeuil
                    ? 'Sous le seuil'
                    : 'Suffisant',
              ],
          ],
          total: [
            'Total',
            null,
            null,
            null,
            null,
            r.valeurStockAchat,
            r.valeurStockVente,
            null,
          ],
        ),
        Tableau(
          titre: 'Mouvements de stock',
          colonnes: const [
            Colonne('Type'),
            Colonne('Mouvements', Unite.nombre),
            Colonne('Quantité', Unite.nombre),
            Colonne('Valeur', Unite.montant),
          ],
          lignes: [
            for (final m in r.gestion.mouvements)
              [libelleMouvement(m.type), m.mouvements, m.quantite, m.valeur],
          ],
        ),
      ],
    );
  }

  Section get activite {
    final a = r.activite;
    return Section(
      titre: "Activité de l'hôtel",
      description:
          'Arrivées, départs et réservations de la période. Suit la période, '
          "l'agent qui a fait l'arrivée ou le départ, et le type de chambre.",
      chiffres: [
        Chiffre('Arrivées', a.arrivees, Unite.nombre,
            detail: 'sur ${a.arriveesPrevues} prévues'),
        Chiffre('Départs', a.departs, Unite.nombre),
        Chiffre('Nouvelles réservations', a.nouvelles, Unite.nombre),
        Chiffre('Annulations', a.annulations, Unite.nombre),
        Chiffre('Non présentés', a.nonPresentes, Unite.nombre),
        Chiffre('Personnes accueillies', a.personnes, Unite.nombre),
        Chiffre('Durée moyenne de séjour', a.dureeMoyenneDixiemes,
            Unite.dixiemes, detail: 'nuits'),
      ],
      graphique: Graphique(
        type: TypeGraphique.courbe,
        etiquettes: [for (final j in a.parJour) etiquetteJour(j.$1)],
        series: [
          Serie('Arrivées', [for (final j in a.parJour) j.$2],
              CouleursExport.sarcelle),
          Serie('Départs', [for (final j in a.parJour) j.$3],
              CouleursExport.actuel),
        ],
        unite: Unite.nombre,
      ),
      tableaux: [
        Tableau(
          titre: 'Arrivées prévues par origine',
          colonnes: const [
            Colonne('Origine'),
            Colonne('Séjours', Unite.nombre),
            Colonne('Part', Unite.pointsDeBase),
          ],
          lignes: [
            for (final o in a.parOrigine)
              [libelleOrigine(o.cle), o.montant,
                partBp(o.montant, a.arriveesPrevues)],
          ],
          total: ['Total', a.arriveesPrevues, null],
        ),
        Tableau(
          titre: 'Par jour',
          colonnes: const [
            Colonne('Jour'),
            Colonne('Arrivées', Unite.nombre),
            Colonne('Départs', Unite.nombre),
          ],
          lignes: [
            for (final j in a.parJour) [formatShortDate(j.$1), j.$2, j.$3],
          ],
          total: ['Total', a.arrivees, a.departs],
        ),
      ],
    );
  }

  Section get caisses {
    final g = r.gestion;
    final closes = g.caisses.where((c) => c.close);
    return Section(
      titre: 'Caisses',
      description:
          'Les caisses ouvertes ou closes sur la période : fond, espèces '
          "attendues, montant compté et écart. Suit la période et l'agent.",
      chiffres: [
        Chiffre('Caisses closes', g.caissesCloses, Unite.nombre,
            detail: switch (g.caisses.length - g.caissesCloses) {
              0 => 'aucune encore ouverte',
              1 => '1 encore ouverte',
              final n => '$n encore ouvertes',
            }),
        Chiffre('Écart total', g.ecartCaisses, Unite.montant,
            detail: 'négatif : il manque de l’argent'),
        Chiffre('Espèces attendues', closes.fold(0, (s, c) => s + c.attendu),
            Unite.montant, detail: 'caisses closes'),
      ],
      tableaux: [
        Tableau(
          titre: 'Détail des caisses',
          colonnes: const [
            Colonne('Agent'),
            Colonne('Ouverture'),
            Colonne('Clôture'),
            Colonne('Fond', Unite.montant),
            Colonne('Attendu', Unite.montant),
            Colonne('Compté', Unite.montant),
            Colonne('Écart', Unite.montant),
          ],
          lignes: [
            for (final c in g.caisses)
              [
                c.agent,
                formatInstant(c.ouverture),
                c.close ? formatInstant(c.cloture) : 'Ouverte',
                c.fond,
                c.attendu,
                c.compte,
                c.close ? c.ecart : null,
              ],
          ],
          total: [
            'Total',
            null,
            null,
            g.caisses.fold<int>(0, (s, c) => s + c.fond),
            closes.fold<int>(0, (s, c) => s + c.attendu),
            closes.fold<int>(0, (s, c) => s + (c.compte ?? 0)),
            g.ecartCaisses,
          ],
        ),
      ],
    );
  }

  Section get menageEtMaintenance {
    final g = r.gestion;
    return Section(
      titre: 'Ménage et maintenance',
      description:
          'Les chambres faites et les pannes signalées sur la période. Suit '
          "la période, l'agent et le type de chambre.",
      chiffres: [
        Chiffre('Chambres à faire', g.tachesMenage, Unite.nombre),
        Chiffre('Chambres faites', g.tachesFaites, Unite.nombre,
            detail: '${g.tachesEnAttente} en attente'),
        Chiffre('Durée moyenne', g.dureeMoyenneMenage, Unite.nombre,
            detail: 'minutes par chambre'),
        Chiffre('Pannes signalées', g.ticketsSignales, Unite.nombre,
            detail: switch (g.ticketsUrgents) {
              0 => 'aucune urgente',
              1 => '1 urgente',
              final n => '$n urgentes',
            }),
        Chiffre('Pannes résolues', g.ticketsResolus, Unite.nombre),
        Chiffre('Délai de résolution', g.delaiResolutionDixiemesHeure,
            Unite.dixiemes, detail: 'heures en moyenne'),
        Chiffre('Coût de la maintenance', g.coutMaintenance, Unite.montant),
      ],
      tableaux: [
        Tableau(
          titre: 'Ménage par agent',
          colonnes: const [
            Colonne('Agent'),
            Colonne('Chambres faites', Unite.nombre),
            Colonne('Durée moyenne (min)', Unite.nombre),
          ],
          lignes: [
            for (final l in g.menageParAgent)
              [l.agent, l.faites, l.faites == 0 ? 0 : l.minutes ~/ l.faites],
          ],
          total: ['Total', g.tachesFaites, g.dureeMoyenneMenage],
        ),
        Tableau(
          titre: 'Maintenance par catégorie',
          colonnes: const [
            Colonne('Catégorie'),
            Colonne('Pannes', Unite.nombre),
            Colonne('Résolues', Unite.nombre),
            Colonne('Coût', Unite.montant),
          ],
          lignes: [
            for (final l in g.maintenanceParCategorie)
              [l.categorie, l.tickets, l.resolus, l.cout],
          ],
          total: [
            'Total',
            g.ticketsSignales,
            g.ticketsResolus,
            g.coutMaintenance,
          ],
        ),
      ],
    );
  }
}
