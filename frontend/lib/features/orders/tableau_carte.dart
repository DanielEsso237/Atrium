/// La carte du point de vente en tableau, a droite des fiches en plein
/// ecran (demande du 15 octobre).
///
/// Ce qui se vend le plus d'abord : le comptoir trouve l'article d'un coup
/// d'oeil au lieu de le chercher dans la liste deroulante. Seuls le nom et
/// le stock restent (16 octobre) : la commande, a gauche, gagne la place des
/// colonnes Vendus et Prix. Une barre de recherche resserre le tableau ;
/// toucher une ligne ajoute l'article. Un article en rupture reste visible,
/// grise, sans pouvoir etre choisi.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/recherche.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/repositories/order_repository.dart' show MenuEntry;

/// La largeur du tableau a cote d'une fiche en plein ecran.
const double largeurCarteFiche = 460;

class TableauCarte extends StatefulWidget {
  const TableauCarte({
    super.key,
    required this.carte,
    required this.onChoisi,
    this.dejaChoisis,
  });

  /// La carte, deja rangee par ventes decroissantes.
  final List<MenuEntry> carte;
  final void Function(MenuEntry) onChoisi;

  /// Combien de fois l'article est deja dans la commande en cours.
  final int Function(MenuEntry)? dejaChoisis;

  @override
  State<TableauCarte> createState() => _TableauCarteState();
}

class _TableauCarteState extends State<TableauCarte> {
  String _cherche = '';

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final r = Recherche(_cherche);
    final articles = [
      for (final e in widget.carte)
        if (r.garde([e.label, e.categoryLabel])) e,
    ];
    final entete = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: p.textSecondary,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('La carte, ce qui se vend le plus d’abord'),
          const SizedBox(height: 12),
          SearchPill(
            hint: 'Chercher un article, une catégorie…',
            onChanged: (v) => setState(() => _cherche = v),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(child: Text('Article', style: entete)),
                SizedBox(
                  width: 90,
                  child: Text(
                    'En stock',
                    style: entete,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 44),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: articles.isEmpty
                ? EmptyState(
                    icon: PhosphorIconsLight.magnifyingGlass,
                    title: widget.carte.isEmpty
                        ? 'La carte est vide'
                        : 'Rien ne correspond',
                    message: widget.carte.isEmpty
                        ? 'Les articles de ce point de vente apparaissent ici.'
                        : '« $_cherche » ne correspond à aucun article.',
                  )
                : ListView.separated(
                    itemCount: articles.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: p.border),
                    itemBuilder: (_, i) => _LigneArticle(
                      article: articles[i],
                      dejaChoisi: widget.dejaChoisis?.call(articles[i]) ?? 0,
                      onTap: articles[i].isAvailable
                          ? () => widget.onChoisi(articles[i])
                          : null,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _LigneArticle extends StatelessWidget {
  const _LigneArticle({
    required this.article,
    required this.dejaChoisi,
    required this.onTap,
  });

  final MenuEntry article;
  final int dejaChoisi;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final e = article;
    final actif = onTap != null;
    final encre = actif ? p.text : p.textSecondary;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: encre,
                      ),
                    ),
                    Text(
                      actif ? e.categoryLabel : '${e.categoryLabel} · rupture',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              // Ce qui reste a vendre ici ; a zero, en rouge : on previent le
              // client avant de servir (le stock peut passer sous zero).
              SizedBox(
                width: 90,
                child: Text(
                  e.enStock == null ? '—' : '${math.max(e.enStock!, 0)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: e.enStock != null && e.enStock! <= 0
                        ? p.error
                        : encre,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                child: dejaChoisi > 0
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 26),
                          height: 26,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: p.accent,
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Text(
                            '$dejaChoisi',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: p.onAccent,
                              fontFeatures: tabularFigures,
                            ),
                          ),
                        ),
                      )
                    : Align(
                        alignment: Alignment.centerRight,
                        child: Icon(
                          PhosphorIconsLight.plus,
                          size: 18,
                          color: actif ? p.textSecondary : Colors.transparent,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
