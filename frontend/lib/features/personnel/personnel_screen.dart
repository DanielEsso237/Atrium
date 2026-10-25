/// L'onglet Personnel (demande du 15 octobre) : la liste des agents, leur
/// role, les points de vente qu'ils tiennent, et ce qu'ils generent sur une
/// periode -- chiffre d'affaires, ventes, encaisse, caisses et leur ecart.
///
/// Reserve a qui lit les agents (`users.read` : administration, direction).
/// Ceux qui vendent le plus d'abord ; une ligne se deplie sur le detail par
/// point de vente.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/recherche.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/personnel_queries.dart';

enum _Periode { jour, septJours, mois, moisDernier }

String _libellePeriode(_Periode p) => switch (p) {
  _Periode.jour => 'Aujourd’hui',
  _Periode.septJours => '7 derniers jours',
  _Periode.mois => 'Ce mois',
  _Periode.moisDernier => 'Mois dernier',
};

(DateTime, DateTime) _bornes(_Periode p, DateTime jour) => switch (p) {
  _Periode.jour => (jour, jour),
  _Periode.septJours => (DateTime(jour.year, jour.month, jour.day - 6), jour),
  _Periode.mois => (DateTime(jour.year, jour.month), jour),
  _Periode.moisDernier => (
    DateTime(jour.year, jour.month - 1),
    DateTime(jour.year, jour.month, 0),
  ),
};

final _personnelProvider =
    StreamProvider.family<List<AgentPersonnel>, (DateTime, DateTime)>(
      (ref, b) =>
          ref.watch(databaseProvider).watchPersonnel(du: b.$1, au: b.$2),
    );

final _partsProvider =
    StreamProvider.family<Map<String, List<PartAgent>>, (DateTime, DateTime)>(
      (ref, b) =>
          ref.watch(databaseProvider).watchPartsAgents(du: b.$1, au: b.$2),
    );

class PersonnelScreen extends ConsumerStatefulWidget {
  const PersonnelScreen({super.key});

  @override
  ConsumerState<PersonnelScreen> createState() => _PersonnelScreenState();
}

class _PersonnelScreenState extends ConsumerState<PersonnelScreen> {
  _Periode _periode = _Periode.mois;
  String _cherche = '';

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final bornes = _bornes(_periode, businessDayFor(DateTime.now()));
    final agents = ref.watch(_personnelProvider(bornes)).value ?? const [];
    final parts = ref.watch(_partsProvider(bornes)).value ?? const {};
    final r = Recherche(_cherche);
    final visibles = [
      for (final a in agents)
        if (r.garde([a.nom, a.code, ...a.roles, ...a.pointsDeVente])) a,
    ];
    final actifs = agents.where((a) => a.actif).length;
    final ca = agents.fold(0, (s, a) => s + a.chiffreAffaires);
    final bord = MediaQuery.sizeOf(context).width < 600 ? 18.0 : 32.0;

    return ModuleScaffold(
      title: 'Personnel',
      subtitle:
          '$actifs agent${actifs > 1 ? 's' : ''} actif${actifs > 1 ? 's' : ''}'
          ' · ${formatAmount(ca)} sur la période',
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
          const SizedBox(height: 12),
          SearchPill(
            hint: 'Un nom, un code, un rôle, un point de vente…',
            onChanged: (v) => setState(() => _cherche = v),
          ),
          const SizedBox(height: 16),
          if (visibles.isEmpty)
            EmptyState(
              icon: agents.isEmpty
                  ? PhosphorIconsLight.usersThree
                  : PhosphorIconsLight.magnifyingGlass,
              title: agents.isEmpty ? 'Aucun agent' : 'Rien ne correspond',
              message: agents.isEmpty
                  ? 'Les agents créés dans l’administration apparaissent ici.'
                  : '« $_cherche » ne correspond à aucun agent.',
            )
          else
            for (final a in visibles) ...[
              _CarteAgent(agent: a, parts: parts[a.id] ?? const []),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 8),
          Text(
            'Chiffre d’affaires : ce que l’agent a porté sur les ardoises '
            '(consommations, nuitées). Encaissé : ce qu’il a reçu, '
            'remboursements déduits.',
            style: TextStyle(fontSize: 12.5, color: p.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _CarteAgent extends StatelessWidget {
  const _CarteAgent({required this.agent, required this.parts});

  final AgentPersonnel agent;
  final List<PartAgent> parts;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final a = agent;
    final chiffre = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 15,
      fontWeight: FontWeight.w700,
      color: p.text,
      fontFeatures: tabularFigures,
    );
    final legende = TextStyle(fontSize: 12, color: p.textSecondary);
    Widget colonne(String valeur, String libelle, {Color? couleur}) => SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            valeur,
            style: couleur == null ? chiffre : chiffre.copyWith(color: couleur),
          ),
          Text(libelle, style: legende),
        ],
      ),
    );

    final chiffres = [
      colonne(formatAmount(a.chiffreAffaires), 'chiffre d’affaires'),
      colonne('${a.ventes}', 'vente${a.ventes > 1 ? 's' : ''}'),
      colonne(formatAmount(a.encaisse), 'encaissé'),
      colonne(
        a.ecartCaisse == 0
            ? '${a.caisses}'
            : '${a.caisses} · ${a.ecartCaisse > 0 ? '+' : '−'}'
                  '${formatAmount(a.ecartCaisse.abs())}',
        a.caisses > 1 ? 'caisses · écart' : 'caisse · écart',
        couleur: a.ecartCaisse == 0 ? null : p.error,
      ),
    ];

    return Bezel(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      // Le Bezel peint son fond dans un DecoratedBox : sans Material entre
      // lui et l'ExpansionTile, le ListTile peindrait son fond et ses
      // ondulations sous la carte, invisibles, et Flutter le refuse.
      child: Material(
        type: MaterialType.transparency,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
            leading: Monogram(a.nom),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    a.nom,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: a.actif ? p.text : p.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CodeCartouche(a.code),
                if (!a.actif) ...[
                  const SizedBox(width: 8),
                  const Tag('Inactif'),
                ],
              ],
            ),
            // Les chiffres sous le nom, pas a droite : la ligne n'a pas la
            // hauteur de deux lignes de texte a cote du titre.
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    a.roles.isEmpty ? 'Sans rôle' : a.roles.join(', '),
                    a.pointsDeVente.isEmpty
                        ? 'Tout l’hôtel'
                        : a.pointsDeVente.join(', '),
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 12, runSpacing: 8, children: chiffres),
              ],
            ),
            children: [
              if (parts.isEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Aucune vente sur la période.',
                    style: TextStyle(fontSize: 13.5, color: p.textSecondary),
                  ),
                )
              else
                for (final part in parts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            part.libelle,
                            style: TextStyle(fontSize: 14, color: p.text),
                          ),
                        ),
                        Text(
                          formatAmount(part.montant),
                          style: chiffre.copyWith(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
              if (a.derniereConnexion != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Dernière connexion : '
                      '${formatShortDate(a.derniereConnexion!.toLocal())}',
                      style: TextStyle(fontSize: 12.5, color: p.textSecondary),
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
