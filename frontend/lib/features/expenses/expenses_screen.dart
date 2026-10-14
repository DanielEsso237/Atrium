/// Les depenses : ce que l'hotel paie sans passer par le stock -- salaires,
/// electricite, eau, loyer, carburant... Elles font du benefice des Rapports
/// le vrai benefice.
///
/// Un mois a la fois : c'est le rythme des factures et des salaires. La
/// liste a gauche, jour par jour ; a droite, ou va l'argent. Une depense
/// saisie par erreur s'annule avec un motif et reste visible, barree.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/recherche.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/confirmation.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/expense_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../reports/report_charts.dart' show BarrePart, BarresParts;

final _depensesProvider =
    StreamProvider.family<List<ExpenseRow>, (String, String)>(
      (ref, periode) => ref
          .watch(expenseRepositoryProvider)
          .watch(du: periode.$1, au: periode.$2),
    );

IconData iconeRubrique(ExpenseCategory c) => switch (c) {
  ExpenseCategory.SALARIES => PhosphorIconsLight.usersThree,
  ExpenseCategory.ELECTRICITY => PhosphorIconsLight.lightning,
  ExpenseCategory.WATER => PhosphorIconsLight.drop,
  ExpenseCategory.RENT => PhosphorIconsLight.houseLine,
  ExpenseCategory.FUEL => PhosphorIconsLight.gasPump,
  ExpenseCategory.REPAIRS => PhosphorIconsLight.hammer,
  ExpenseCategory.TELECOM => PhosphorIconsLight.wifiHigh,
  ExpenseCategory.TAXES => PhosphorIconsLight.scales,
  ExpenseCategory.MARKETING => PhosphorIconsLight.megaphone,
  ExpenseCategory.BANK_FEES => PhosphorIconsLight.bank,
  ExpenseCategory.OTHER => PhosphorIconsLight.dotsThreeCircle,
};

String _libelleMoyen(PaymentMethod m) => switch (m) {
  PaymentMethod.CASH => 'Espèces',
  PaymentMethod.TRANSFER => 'Virement',
  PaymentMethod.MOBILE_MONEY => 'Mobile Money',
  PaymentMethod.CARD => 'Carte',
  PaymentMethod.CITY_LEDGER => 'Compte',
  PaymentMethod.VOUCHER => 'Bon',
};

const _moisLongs = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];

String _nomMois(DateTime m) {
  final nom = _moisLongs[m.month - 1];
  return '${nom[0].toUpperCase()}${nom.substring(1)} ${m.year}';
}

class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  late DateTime _mois;

  /// Ce que l'on cherche dans le journal : un libelle, un fournisseur, un
  /// montant.
  String _recherche = '';

  /// La rubrique montree ; `null` pour toutes.
  ExpenseCategory? _rubrique;

  @override
  void initState() {
    super.initState();
    final jour = businessDayFor(DateTime.now());
    _mois = DateTime(jour.year, jour.month);
  }

  (String, String) get _periode => (
    formatIsoDate(_mois),
    formatIsoDate(DateTime(_mois.year, _mois.month + 1, 0)),
  );

  bool get _moisCourant {
    final jour = businessDayFor(DateTime.now());
    return _mois.year == jour.year && _mois.month == jour.month;
  }

  void _decaler(int n) =>
      setState(() => _mois = DateTime(_mois.year, _mois.month + n));

  Future<void> _saisir([ExpenseRow? existante]) => showDialog<void>(
    context: context,
    builder: (_) => _FicheDepense(existante: existante),
  );

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final ecrit = ref.watch(sessionProvider).acces.peut('expense.write');
    final depenses = ref.watch(_depensesProvider(_periode));
    final liste = depenses.value ?? const <ExpenseRow>[];
    final valides = [
      for (final d in liste)
        if (!d.isVoid) d,
    ];
    final total = valides.fold(0, (s, d) => s + d.amount);
    final recherche = Recherche(_recherche);
    final trouvees = [
      for (final d in liste)
        if (recherche.garde([
          d.label,
          d.supplier,
          d.reference,
          d.notes,
          libelleRubrique(d.category),
          '${d.amount}',
        ]))
          d,
    ];
    final filtrees = [
      for (final d in trouvees)
        if (_rubrique == null || d.category == _rubrique) d,
    ];
    // Les rubriques du mois seulement, chacune avec son nombre : une pastille
    // vide n'apprend rien.
    final rubriques = <ExpenseCategory, int>{};
    for (final d in trouvees) {
      rubriques[d.category] = (rubriques[d.category] ?? 0) + 1;
    }
    final etroit = MediaQuery.sizeOf(context).width < 940;
    final marge = MediaQuery.sizeOf(context).width < 600 ? 18.0 : 32.0;

    final mois = Row(
      children: [
        IconButton(
          tooltip: 'Mois précédent',
          onPressed: () => _decaler(-1),
          icon: const Icon(PhosphorIconsLight.caretLeft, size: 20),
        ),
        SizedBox(
          width: 170,
          child: Text(
            _nomMois(_mois),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Mois suivant',
          // Pas de mois a venir : une depense ne se date pas du futur.
          onPressed: _moisCourant ? null : () => _decaler(1),
          icon: const Icon(PhosphorIconsLight.caretRight, size: 20),
        ),
      ],
    );

    final parRubrique = <ExpenseCategory, int>{};
    for (final d in valides) {
      parRubrique[d.category] = (parRubrique[d.category] ?? 0) + d.amount;
    }
    final repartition = _Cadre(
      titre: 'Où va l’argent',
      child: parRubrique.isEmpty
          ? Text(
              'Rien de saisi ce mois-ci.',
              style: TextStyle(fontSize: 14, color: p.textSecondary),
            )
          : BarresParts(
              couleur: p.primary,
              progres: kAlwaysCompleteAnimation,
              parts: [
                for (final e
                    in (parRubrique.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value))))
                  BarrePart(
                    libelleRubrique(e.key),
                    e.value,
                    formatAmount(e.value),
                    detail: '${(e.value * 100 / total).round()} %',
                  ),
              ],
            ),
    );

    final journal = depenses.isLoading && liste.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : liste.isEmpty
        ? EmptyState(
            icon: PhosphorIconsLight.wallet,
            title: 'Aucune dépense en ${_nomMois(_mois).toLowerCase()}',
            message: ecrit
                ? 'Salaires, électricité, eau, loyer : saisissez ce que '
                      'l’hôtel paie hors stock, le bénéfice des rapports en '
                      'tiendra compte.'
                : 'Seuls la direction, le comptable et l’administration '
                      'saisissent les dépenses.',
            action: ecrit
                ? PillButton(
                    label: 'Saisir une dépense',
                    icon: PhosphorIconsLight.plus,
                    onPressed: _saisir,
                  )
                : null,
          )
        : filtrees.isEmpty
        ? EmptyState(
            icon: PhosphorIconsLight.magnifyingGlass,
            title: 'Aucune dépense ne correspond',
            message: 'Cherchez un libellé, un fournisseur ou un montant.',
          )
        : _Journal(depenses: filtrees, onTap: ecrit ? _saisir : null);

    final outils = liste.isEmpty
        ? null
        : LayoutBuilder(
            builder: (context, c) {
              final champ = SearchPill(
                hint: 'Libellé, fournisseur, montant…',
                onChanged: (v) => setState(() => _recherche = v),
              );
              final pastilles = FilterPills<ExpenseCategory?>(
                selected: _rubrique,
                onChanged: (r) => setState(() => _rubrique = r),
                options: [
                  FilterOption(null, 'Toutes', count: trouvees.length),
                  for (final e in rubriques.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value)))
                    FilterOption(e.key, libelleRubrique(e.key), count: e.value),
                ],
              );
              if (c.maxWidth < 760) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [champ, const SizedBox(height: 10), pastilles],
                );
              }
              return Row(
                children: [
                  SizedBox(width: 300, child: champ),
                  const SizedBox(width: 12),
                  Expanded(child: pastilles),
                ],
              );
            },
          );

    return ModuleScaffold(
      title: 'Dépenses',
      subtitle: valides.isEmpty
          ? 'Ce que l’hôtel paie hors stock'
          : '${formatAmount(total)} en ${_nomMois(_mois).toLowerCase()}, '
                '${valides.length} dépense${valides.length > 1 ? 's' : ''}',
      action: ecrit
          ? PillButton(
              label: 'Nouvelle dépense',
              icon: PhosphorIconsLight.plus,
              onPressed: _saisir,
            )
          : null,
      body: Padding(
        padding: EdgeInsets.fromLTRB(marge, 0, marge, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(alignment: Alignment.centerLeft, child: mois),
            const SizedBox(height: 8),
            if (outils != null) ...[outils, const SizedBox(height: 14)],
            Expanded(
              child: etroit
                  ? ListView(
                      padding: const EdgeInsets.only(bottom: 32),
                      children: [
                        repartition,
                        const SizedBox(height: 16),
                        SizedBox(height: 520, child: journal),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: journal),
                        const SizedBox(width: 20),
                        SizedBox(
                          width: 340,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.only(bottom: 32),
                            child: repartition,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cadre extends StatelessWidget {
  const _Cadre({required this.titre, required this.child});

  final String titre;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(AtriumRadii.lg),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            titre,
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// La liste, jour par jour, la plus recente en haut.
class _Journal extends StatelessWidget {
  const _Journal({required this.depenses, required this.onTap});

  final List<ExpenseRow> depenses;
  final void Function(ExpenseRow)? onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final elements = <Widget>[];
    String? jour;
    for (final d in depenses) {
      if (d.businessDate != jour) {
        jour = d.businessDate;
        final date = DateTime.tryParse(jour);
        elements.add(
          Padding(
            padding: EdgeInsets.fromLTRB(4, elements.isEmpty ? 4 : 18, 0, 8),
            child: Text(
              date == null ? jour : formatLongDate(date),
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
          ),
        );
      }
      elements.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _LigneDepense(
            depense: d,
            onTap: onTap == null || d.isVoid ? null : () => onTap!(d),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: elements,
    );
  }
}

class _LigneDepense extends StatelessWidget {
  const _LigneDepense({required this.depense, required this.onTap});

  final ExpenseRow depense;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final d = depense;
    final details = [
      libelleRubrique(d.category),
      ?d.supplier,
      if (d.method case final m?) _libelleMoyen(m),
      if (d.reference case final r?) 'réf. $r',
      if (d.isVoid && d.voidReason != null) 'annulée : ${d.voidReason}',
    ].join(', ');
    final barre = d.isVoid ? TextDecoration.lineThrough : null;

    return Material(
      color: p.surface,
      borderRadius: BorderRadius.circular(AtriumRadii.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AtriumRadii.md),
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AtriumRadii.md),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: d.isVoid ? p.surfaceMuted : p.accentTint,
                ),
                child: Icon(
                  iconeRubrique(d.category),
                  size: 20,
                  color: d.isVoid ? p.textDisabled : p.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: d.isVoid ? p.textSecondary : p.text,
                        decoration: barre,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13,
                        color: p.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (d.isVoid) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: p.errorTint,
                    borderRadius: BorderRadius.circular(AtriumRadii.sm),
                  ),
                  child: Text(
                    'Annulée',
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.error,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Text(
                formatAmount(d.amount),
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: d.isVoid ? p.textSecondary : p.text,
                  decoration: barre,
                  fontFeatures: tabularFigures,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La fiche d'une depense : nouvelle, ou a corriger.
class _FicheDepense extends ConsumerStatefulWidget {
  const _FicheDepense({this.existante});

  final ExpenseRow? existante;

  @override
  ConsumerState<_FicheDepense> createState() => _FicheDepenseState();
}

class _FicheDepenseState extends ConsumerState<_FicheDepense> {
  late ExpenseCategory? _rubrique = widget.existante?.category;
  late PaymentMethod? _moyen = widget.existante?.method;
  late DateTime _jour =
      DateTime.tryParse(widget.existante?.businessDate ?? '') ??
      businessDayFor(DateTime.now());
  late final _libelle = TextEditingController(text: widget.existante?.label);
  late final _montant = TextEditingController(
    text: widget.existante == null ? '' : '${widget.existante!.amount}',
  );
  late final _fournisseur = TextEditingController(
    text: widget.existante?.supplier,
  );
  late final _reference = TextEditingController(
    text: widget.existante?.reference,
  );
  late final _note = TextEditingController(text: widget.existante?.notes);
  String? _erreur;
  bool _occupe = false;

  @override
  void dispose() {
    for (final c in [_libelle, _montant, _fournisseur, _reference, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _choisirJour() async {
    final aujourdhui = businessDayFor(DateTime.now());
    final choisi = await showDatePicker(
      context: context,
      initialDate: _jour.isAfter(aujourdhui) ? aujourdhui : _jour,
      firstDate: DateTime(aujourdhui.year - 2),
      lastDate: aujourdhui,
    );
    if (choisi != null) setState(() => _jour = choisi);
  }

  Future<void> _enregistrer() async {
    if (_rubrique == null) {
      setState(() => _erreur = 'Choisissez une rubrique.');
      return;
    }
    final saisie = SaisieDepense(
      businessDate: formatIsoDate(_jour),
      category: _rubrique!,
      label: _libelle.text,
      amount: int.tryParse(_montant.text) ?? 0,
      method: _moyen,
      supplier: _fournisseur.text,
      reference: _reference.text,
      notes: _note.text,
    );
    final depot = ref.read(expenseRepositoryProvider);
    final agent = ref.read(sessionProvider).agent?.id;
    setState(() {
      _occupe = true;
      _erreur = null;
    });
    try {
      if (widget.existante == null) {
        await depot.create(saisie, by: agent);
      } else {
        await depot.update(widget.existante!.id, saisie, by: agent);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      montrerSucces(
        context,
        widget.existante == null ? 'Dépense enregistrée.' : 'Dépense corrigée.',
      );
    } on StateError catch (e) {
      setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _occupe = false);
    }
  }

  Future<void> _annuler() async {
    final motif = TextEditingController();
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Annuler la dépense'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: motif,
            autofocus: true,
            maxLength: 255,
            decoration: const InputDecoration(
              labelText: 'Motif',
              hintText: 'Saisie en double, mauvais montant…',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Garder la dépense'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Annuler la dépense'),
          ),
        ],
      ),
    );
    if (confirme != true || !mounted) return;
    try {
      await ref
          .read(expenseRepositoryProvider)
          .annuler(
            widget.existante!.id,
            motif: motif.text,
            by: ref.read(sessionProvider).agent?.id,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      montrerSucces(context, 'Dépense annulée.');
    } on StateError catch (e) {
      if (mounted) montrerRefus(context, e.message);
    } finally {
      motif.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final nouvelle = widget.existante == null;
    final etroit = MediaQuery.sizeOf(context).width < 600;

    final rubriques = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final r in ExpenseCategory.values)
          ChoiceChip(
            showCheckmark: false,
            selected: _rubrique == r,
            onSelected: (_) => setState(() {
              _rubrique = r;
              _erreur = null;
            }),
            avatar: Icon(
              iconeRubrique(r),
              size: 18,
              color: _rubrique == r ? p.onAccent : p.primary,
            ),
            label: Text(libelleRubrique(r)),
            labelStyle: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: _rubrique == r ? p.onAccent : p.text,
            ),
            selectedColor: p.primary,
            backgroundColor: p.surface,
            side: BorderSide(color: _rubrique == r ? p.primary : p.border),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          ),
      ],
    );

    final montant = TextField(
      controller: _montant,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(
        labelText: 'Montant',
        suffixText: 'FCFA',
      ),
    );
    final date = InkWell(
      onTap: _choisirJour,
      borderRadius: BorderRadius.circular(AtriumRadii.md),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Payée le',
          suffixIcon: Icon(PhosphorIconsLight.calendarBlank, size: 20),
        ),
        child: Text(formatLongDate(_jour)),
      ),
    );

    return AlertDialog(
      icon: const Icon(PhosphorIconsLight.wallet, size: 30),
      title: Text(nouvelle ? 'Nouvelle dépense' : 'Dépense'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Rubrique',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              rubriques,
              const SizedBox(height: 18),
              TextField(
                controller: _libelle,
                maxLength: 160,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Libellé',
                  hintText: 'Facture ENEO de septembre, salaires d’octobre…',
                ),
              ),
              const SizedBox(height: 6),
              if (etroit) ...[
                montant,
                const SizedBox(height: 12),
                date,
              ] else
                Row(
                  children: [
                    Expanded(child: montant),
                    const SizedBox(width: 12),
                    Expanded(child: date),
                  ],
                ),
              const SizedBox(height: 16),
              Text(
                'Payée par',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<PaymentMethod>(
                  emptySelectionAllowed: true,
                  showSelectedIcon: false,
                  segments: [
                    for (final m in const [
                      PaymentMethod.CASH,
                      PaymentMethod.TRANSFER,
                      PaymentMethod.MOBILE_MONEY,
                      PaymentMethod.CARD,
                    ])
                      ButtonSegment(value: m, label: Text(_libelleMoyen(m))),
                  ],
                  selected: {?_moyen},
                  onSelectionChanged: (s) =>
                      setState(() => _moyen = s.isEmpty ? null : s.first),
                  style: SegmentedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _fournisseur,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: 'Fournisseur (facultatif)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _reference,
                      maxLength: 80,
                      decoration: const InputDecoration(
                        labelText: 'Référence (facultatif)',
                      ),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _note,
                maxLength: 255,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Note (facultatif)',
                ),
              ),
              if (_erreur != null) ...[
                const SizedBox(height: 8),
                Text(_erreur!, style: TextStyle(fontSize: 14, color: p.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!nouvelle)
          TextButton.icon(
            onPressed: _occupe ? null : _annuler,
            icon: Icon(PhosphorIconsLight.xCircle, size: 18, color: p.error),
            label: Text('Annuler la dépense', style: TextStyle(color: p.error)),
          ),
        TextButton(
          onPressed: _occupe ? null : () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
        FilledButton(
          onPressed: _occupe ? null : _enregistrer,
          child: Text(nouvelle ? 'Enregistrer' : 'Enregistrer la correction'),
        ),
      ],
    );
  }
}
