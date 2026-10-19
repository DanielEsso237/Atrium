/// Les pieces des historiques des grands onglets -- Ventes, Stocks,
/// Entretien, Finances (demande du 18 octobre) : une chronologie rangee par
/// journee hoteliere, la plus recente en haut, comme l'historique de la
/// Réception.
///
/// Chaque ecran traduit ses lignes en [EntreeHistorique] ; la chronologie
/// les range, ecrit l'en-tete de chaque journee et dessine les lignes. Une
/// vente a une heure du matin appartient a la veille, comme sur tous les
/// chiffres de l'application.
library;

import 'package:flutter/material.dart';

import '../business_day.dart';
import '../formats.dart';
import '../tokens.dart';
import '../ui/atrium_ui.dart';

/// La periode qu'un historique remonte.
enum PeriodeHistorique {
  jour("Aujourd'hui", 0),
  semaine('7 jours', 6),
  mois('30 jours', 29),
  tout('Tout', null);

  const PeriodeHistorique(this.libelle, this.jours);
  final String libelle;

  /// Jours avant la journee en cours ; `null` : depuis toujours.
  final int? jours;

  /// Le debut de la periode : l'heure de bascule de son premier jour, en
  /// heure locale. `null` : depuis toujours.
  DateTime? get depuis {
    final n = jours;
    if (n == null) return null;
    final j = businessDayFor(DateTime.now()).subtract(Duration(days: n));
    return DateTime(j.year, j.month, j.day, heureBasculeParDefaut);
  }
}

/// Les pastilles de la periode, les memes sur chaque historique.
class FiltrePeriode extends StatelessWidget {
  const FiltrePeriode({
    super.key,
    required this.periode,
    required this.onChanged,
  });

  final PeriodeHistorique periode;
  final ValueChanged<PeriodeHistorique> onChanged;

  @override
  Widget build(BuildContext context) => FilterPills<PeriodeHistorique>(
    selected: periode,
    onChanged: onChanged,
    options: [
      for (final p in PeriodeHistorique.values) FilterOption(p, p.libelle),
    ],
  );
}

/// Une ligne de la chronologie, deja mise en mots.
class EntreeHistorique {
  const EntreeHistorique({
    required this.id,
    required this.moment,
    required this.icone,
    required this.couleur,
    required this.titre,
    this.detail,
    this.montant,
    this.negatif = false,
    this.etat,
    this.couleurEtat,
  });

  final String id;

  /// L'instant, en UTC.
  final DateTime moment;
  final IconData icone;

  /// La couleur du genre de la ligne : celle de sa pastille, jamais du texte.
  final Color couleur;
  final String titre;

  /// Pour qui, ou, par qui -- en clair.
  final String? detail;

  /// Le montant ou la quantite, deja ecrit : « 4 500 FCFA », « 24 ».
  final String? montant;

  /// Ce qui sort ou se retranche : le montant passe en rouge.
  final bool negatif;

  /// Un etat en badge : « En attente », « Annulée ».
  final String? etat;
  final Color? couleurEtat;
}

/// Les lignes rangees par journee : l'en-tete de chaque jour, son resume,
/// puis ses lignes dans une carte.
///
/// [entete] -- les totaux, les filtres de genre -- defile avec la liste :
/// sur un telephone, figes en haut, ils ne laissaient a la liste qu'un
/// bandeau. Sans ligne, [vide] prend la place des journees, sous l'entete :
/// on garde de quoi retirer le filtre.
class ChronologieHistorique extends StatelessWidget {
  const ChronologieHistorique({
    super.key,
    required this.entrees,
    required this.padding,
    this.entete,
    this.vide,
    this.resumeJour,
    this.onTap,
  });

  final Widget? entete;
  final Widget? vide;

  /// Deja triees, la plus recente d'abord.
  final List<EntreeHistorique> entrees;
  final EdgeInsets padding;

  /// Ce que la journee a fait, a cote de sa date : « 12 ventes ».
  final String Function(List<EntreeHistorique> duJour)? resumeJour;
  final void Function(EntreeHistorique)? onTap;

  @override
  Widget build(BuildContext context) {
    final jours = <DateTime, List<EntreeHistorique>>{};
    for (final e in entrees) {
      jours.putIfAbsent(businessDayFor(e.moment.toLocal()), () => []).add(e);
    }
    final liste = jours.entries.toList();
    final decalage = entete == null ? 0 : 1;
    return ListView.builder(
      padding: padding,
      itemCount: decalage + (liste.isEmpty ? (vide == null ? 0 : 1) : liste.length),
      itemBuilder: (context, n) {
        if (n < decalage) return entete!;
        if (liste.isEmpty) {
          return Padding(padding: const EdgeInsets.only(top: 24), child: vide);
        }
        final i = n - decalage;
        final jour = liste[i];
        return Padding(
          padding: EdgeInsets.only(bottom: i == liste.length - 1 ? 0 : 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EnteteJourHistorique(
                jour: jour.key,
                resume: resumeJour?.call(jour.value),
              ),
              const SizedBox(height: 8),
              Bezel(
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    for (final (n, e) in jour.value.indexed) ...[
                      if (n > 0)
                        Divider(
                          height: 1,
                          indent: 60,
                          color: AtriumPalette.current.border,
                        ),
                      LigneHistorique(
                        entree: e,
                        onTap: onTap == null ? null : () => onTap!(e),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// La date d'une journee, en mots, et ce qu'elle a fait.
class EnteteJourHistorique extends StatelessWidget {
  const EnteteJourHistorique({super.key, required this.jour, this.resume});

  final DateTime jour;
  final String? resume;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final aujourdhui = businessDayFor(DateTime.now());
    final titre = jour == aujourdhui
        ? "Aujourd'hui"
        : jour == aujourdhui.subtract(const Duration(days: 1))
        ? 'Hier'
        : '${formatWeekdayShort(jour)} ${formatLongDate(jour)}';
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            titre,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          if (resume != null && resume!.isNotEmpty) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                resume!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13.5,
                  color: p.textSecondary,
                  fontFeatures: tabularFigures,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Une ligne : l'heure, la pastille du genre, ce qui s'est passe et pour
/// qui, l'etat, le montant.
class LigneHistorique extends StatelessWidget {
  const LigneHistorique({super.key, required this.entree, this.onTap});

  final EntreeHistorique entree;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final e = entree;
    final local = e.moment.toLocal();
    final heure =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final etat = e.etat == null
        ? null
        : Tag(e.etat!, color: e.couleurEtat ?? p.textSecondary);
    final montant = e.montant == null
        ? null
        : Text(
            '${e.negatif ? '−' : ''}${e.montant}',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: e.negatif ? p.error : p.text,
              fontFeatures: tabularFigures,
            ),
          );
    final textes = <Widget>[
      Text(
        e.titre,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: p.text,
        ),
      ),
      if (e.detail != null && e.detail!.isNotEmpty)
        Text(
          e.detail!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 12.5,
            color: p.textSecondary,
            fontFeatures: tabularFigures,
          ),
        ),
    ];

    final ligne = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: LayoutBuilder(
          builder: (context, zone) {
            // Etroit (telephone) : l'etat et le montant passent sous le
            // libelle, a gauche, au lieu de lui prendre sa ligne.
            final etroit = zone.maxWidth < 480;
            return Row(
              crossAxisAlignment: etroit
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 44,
                  child: Padding(
                    padding: EdgeInsets.only(top: etroit ? 8 : 0),
                    child: Text(
                      heure,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13,
                        color: p.textSecondary,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: e.couleur.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(e.icone, size: 17, color: e.couleur),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...textes,
                      if (etroit && (etat != null || montant != null)) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 10,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [?montant, ?etat],
                        ),
                      ],
                    ],
                  ),
                ),
                if (!etroit && etat != null) ...[
                  const SizedBox(width: 10),
                  etat,
                ],
                if (!etroit && montant != null) ...[
                  const SizedBox(width: 14),
                  montant,
                ],
              ],
            );
          },
        ),
      ),
    );
    if (onTap == null) return ligne;
    return InkWell(
      borderRadius: BorderRadius.circular(AtriumRadii.md),
      onTap: onTap,
      child: ligne,
    );
  }
}
