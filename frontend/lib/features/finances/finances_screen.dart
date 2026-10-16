/// Les finances de l'hotel en un coup d'oeil (demande du 16 octobre).
///
/// Un clic sur « Finances » ouvre ce mini tableau de bord, sur le modele
/// d'Entretien : une tuile par ecran -- la caisse du jour, les factures,
/// les depenses, la comptabilite, les rapports -- chacune avec ses chiffres
/// et le bouton qui l'ouvre. La fleche du menu deplie ces ecrans. Chaque
/// tuile ne s'affiche qu'a qui peut ouvrir son ecran : le comptoir n'y voit
/// que sa caisse et ses factures.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../core/widgets/tuile_metier.dart';
import '../../data/local/database.dart' show ExpenseRow;
import '../../data/local/database_provider.dart';
import '../../data/local/enums.dart';
import '../../data/local/queries/compta_queries.dart';
import '../../data/repositories/cash_repository.dart';
import '../../data/repositories/folio_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

final _encaisseProvider = StreamProvider.family<List<DayPayment>, String>(
  (ref, jour) => ref.watch(cashRepositoryProvider).watchDayPayments(jour),
);

final _caissesProvider = StreamProvider<List<CashSessionSummary>>(
  (ref) => ref.watch(cashRepositoryProvider).watchSessions(),
);

final _ardoisesOuvertesProvider = StreamProvider<List<FolioSummary>>(
  (ref) =>
      ref.watch(folioRepositoryProvider).watchFolios(status: FolioStatus.OPEN),
);

final _depensesProvider =
    StreamProvider.family<List<ExpenseRow>, (String, String)>(
      (ref, periode) => ref
          .watch(expenseRepositoryProvider)
          .watch(du: periode.$1, au: periode.$2),
    );

final _margesProvider =
    StreamProvider.family<List<MargePointDeVente>, (DateTime, DateTime)>(
      (ref, periode) => ref
          .watch(databaseProvider)
          .watchMargesPointsDeVente(du: periode.$1, au: periode.$2),
    );

class FinancesScreen extends ConsumerWidget {
  const FinancesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final acces = session.acces;
    final jour = businessDayFor(DateTime.now());
    final debutDuMois = DateTime(jour.year, jour.month);
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;

    // Les memes droits que les entrees du menu qu'elles ouvrent.
    final hotel = acces.peut('folio.read');
    final compta = acces.peut('accounting.read');
    final comptoirCaisse = acces.peut('cash.session') && !hotel;
    final comptoirFactures = acces.peut('order.read') && !hotel;

    List<Widget> tuilesPour({required bool etiree}) => [
      if (hotel) _caisseDuJour(context, ref, jour, etiree),
      if (hotel) _factures(context, ref, etiree),
      if (comptoirCaisse) _maCaisse(context, ref, session, etiree),
      if (comptoirFactures)
        TuileMetier(
          titre: 'Mes factures',
          icone: PhosphorIconsLight.receipt,
          phrase: 'Les ventes payées du comptoir et leurs tickets.',
          chiffres: const [],
          bouton: 'Ouvrir mes factures',
          onOuvrir: () => context.go('/mes-factures'),
          etiree: etiree,
        ),
      if (compta) _depenses(context, ref, jour, debutDuMois, etiree),
      if (compta) _comptabilite(context, ref, jour, debutDuMois, etiree),
      if (hotel)
        TuileMetier(
          titre: 'Rapports',
          icone: PhosphorIconsLight.chartLineUp,
          phrase:
              'Une période, des filtres, et de quoi la remettre au '
              'comptable.',
          chiffres: const [],
          bouton: 'Ouvrir les rapports',
          onOuvrir: () => context.go('/rapports'),
          etiree: etiree,
        ),
    ];

    return ModuleScaffold(
      title: 'Finances',
      subtitle: 'La caisse, les factures et les comptes, en un coup d’œil',
      body: LayoutBuilder(
        builder: (context, zone) {
          // Deux par rangee sur une tablette couchee, l'une sous l'autre
          // ailleurs.
          final cote = zone.maxWidth >= 900;
          final tuiles = tuilesPour(etiree: cote);
          return ListView(
            padding: EdgeInsets.fromLTRB(marge, 4, marge, 32),
            children: [
              if (cote)
                for (var i = 0; i < tuiles.length; i += 2) ...[
                  if (i > 0) const SizedBox(height: 16),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: FadeUp(index: i, child: tuiles[i]),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: i + 1 < tuiles.length
                              ? FadeUp(index: i + 1, child: tuiles[i + 1])
                              : const SizedBox(),
                        ),
                      ],
                    ),
                  ),
                ]
              else
                for (var i = 0; i < tuiles.length; i++) ...[
                  if (i > 0) const SizedBox(height: 16),
                  FadeUp(index: i, child: tuiles[i]),
                ],
            ],
          );
        },
      ),
    );
  }

  Widget _caisseDuJour(
    BuildContext context,
    WidgetRef ref,
    DateTime jour,
    bool etiree,
  ) {
    final paiements = ref.watch(_encaisseProvider(formatIsoDate(jour))).value;
    final tiroirs = ref.watch(_caissesProvider).value;
    final total = paiements?.fold<int>(0, (t, p) => t + p.amount);
    final especes = paiements
        ?.where((p) => p.method == PaymentMethod.CASH)
        .fold<int>(0, (t, p) => t + p.amount);
    final ouverts = tiroirs
        ?.where((c) => c.session.status == CashSessionStatus.OPEN)
        .length;
    return TuileMetier(
      titre: 'Caisse du jour',
      icone: PhosphorIconsLight.coins,
      phrase: total == null
          ? '…'
          : total == 0
          ? 'Rien d’encaissé aujourd’hui.'
          : '${formatAmount(total)} encaissés aujourd’hui.',
      chiffres: [
        ('Paiements', '${paiements?.length ?? 0}', false),
        ('Dont espèces', formatAmount(especes ?? 0), false),
        ('Tiroirs ouverts', '${ouverts ?? 0}', false),
      ],
      bouton: 'Ouvrir la caisse du jour',
      onOuvrir: () => context.go('/caisse'),
      etiree: etiree,
    );
  }

  Widget _factures(BuildContext context, WidgetRef ref, bool etiree) {
    final ardoises = ref.watch(_ardoisesOuvertesProvider).value;
    final dues = ardoises?.where((f) => f.balance > 0).toList();
    final resteDu = dues?.fold<int>(0, (t, f) => t + f.balance);
    return TuileMetier(
      titre: 'Factures',
      icone: PhosphorIconsLight.receipt,
      phrase: dues == null
          ? '…'
          : dues.isEmpty
          ? 'Aucune ardoise ouverte ne doit d’argent.'
          : '${formatAmount(resteDu!)} restent à encaisser.',
      alerte: (dues?.length ?? 0) > 0,
      chiffres: [
        ('Ardoises ouvertes', '${ardoises?.length ?? 0}', false),
        ('À encaisser', '${dues?.length ?? 0}', (dues?.length ?? 0) > 0),
      ],
      bouton: 'Ouvrir les factures',
      onOuvrir: () => context.go('/factures'),
      etiree: etiree,
    );
  }

  Widget _maCaisse(
    BuildContext context,
    WidgetRef ref,
    SessionState session,
    bool etiree,
  ) {
    final tiroirs = ref.watch(_caissesProvider).value;
    final ouverte = tiroirs
        ?.where(
          (c) =>
              c.session.userId == session.agent?.id &&
              c.session.status == CashSessionStatus.OPEN,
        )
        .firstOrNull;
    final depuis = ouverte?.session.openedAt?.toLocal();
    return TuileMetier(
      titre: 'Ma caisse',
      icone: PhosphorIconsLight.cashRegister,
      phrase: tiroirs == null
          ? '…'
          : ouverte == null
          ? 'Aucune caisse ouverte.'
          : depuis == null
          ? 'Votre caisse est ouverte.'
          : 'Votre caisse est ouverte depuis '
                '${depuis.hour.toString().padLeft(2, '0')} h '
                '${depuis.minute.toString().padLeft(2, '0')}.',
      chiffres: const [],
      bouton: 'Ouvrir ma caisse',
      onOuvrir: () => context.go('/ma-caisse'),
      etiree: etiree,
    );
  }

  Widget _depenses(
    BuildContext context,
    WidgetRef ref,
    DateTime jour,
    DateTime debutDuMois,
    bool etiree,
  ) {
    final iso = formatIsoDate(jour);
    // Les annulees restent dans la liste, barrees : elles ne comptent pas.
    final duMois = ref
        .watch(_depensesProvider((formatIsoDate(debutDuMois), iso)))
        .value
        ?.where((d) => !d.isVoid)
        .toList();
    final total = duMois?.fold<int>(0, (t, d) => t + d.amount);
    final aujourdhui = duMois
        ?.where((d) => d.businessDate == iso)
        .fold<int>(0, (t, d) => t + d.amount);
    return TuileMetier(
      titre: 'Dépenses',
      icone: PhosphorIconsLight.wallet,
      phrase: total == null
          ? '…'
          : total == 0
          ? 'Aucune dépense ce mois-ci.'
          : '${formatAmount(total)} dépensés ce mois-ci.',
      chiffres: [
        ('Ce mois-ci', '${duMois?.length ?? 0}', false),
        ('Aujourd’hui', formatAmount(aujourdhui ?? 0), false),
      ],
      bouton: 'Ouvrir les dépenses',
      onOuvrir: () => context.go('/depenses'),
      etiree: etiree,
    );
  }

  Widget _comptabilite(
    BuildContext context,
    WidgetRef ref,
    DateTime jour,
    DateTime debutDuMois,
    bool etiree,
  ) {
    final marges = ref.watch(_margesProvider((debutDuMois, jour))).value;
    final recette = marges?.fold<int>(0, (t, m) => t + m.recette);
    final benefice = marges?.fold<int>(0, (t, m) => t + m.marge);
    return TuileMetier(
      titre: 'Comptabilité',
      icone: PhosphorIconsLight.chartPieSlice,
      phrase: recette == null
          ? '…'
          : recette == 0
          ? 'Aucune vente ce mois-ci aux points de vente.'
          : '${formatAmount(benefice!)} de marge ce mois-ci aux points de '
                'vente.',
      alerte: (benefice ?? 0) < 0,
      chiffres: [
        ('Ventes du mois', formatAmount(recette ?? 0), false),
        ('Marge', formatAmount(benefice ?? 0), (benefice ?? 0) < 0),
      ],
      bouton: 'Ouvrir la comptabilité',
      onOuvrir: () => context.go('/comptabilite'),
      etiree: etiree,
    );
  }
}
