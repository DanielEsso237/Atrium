/// La caisse du jour (F1.4).
///
/// Ce qui est rentre aujourd'hui, par quel moyen, par qui, et l'etat des
/// tiroirs. Tout vient de la base locale : les encaissements y sont deja,
/// rattaches a leur caisse et a leur journee hoteliere.
///
/// **L'attendu du tiroir n'apparait toujours pas avant le comptage** (voir
/// `cash_dialog.dart`) : on montre ce qui est rentre tous moyens confondus, et
/// l'ecart des caisses deja fermees, jamais « vous devriez avoir tant ».
///
/// **La reception est la caisse centrale.** Qui la tient voit ici le rapport
/// du soir : ce que chaque point de vente lui doit, ce qu'il a verse, ce qui
/// attend encore et les ecarts. C'est le seul endroit ou l'attendu d'un
/// tiroir se lit avant son comptage -- et c'est celui d'un autre : la
/// reception controle, elle ne compte pas a la place du point de vente.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/enums.dart';
import '../../data/repositories/cash_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import 'cash_dialog.dart';
import 'charge_labels.dart';
import 'payment_dialog.dart' show iconePaiement;

final _encaissementsProvider = StreamProvider.family<List<DayPayment>, String>(
  (ref, jour) => ref.watch(cashRepositoryProvider).watchDayPayments(jour),
);

final _caissesProvider = StreamProvider<List<CashSessionSummary>>(
  (ref) => ref.watch(cashRepositoryProvider).watchSessions(),
);

final _rapportDuSoirProvider = StreamProvider.family<EveningReport, String>(
  (ref, jour) => ref.watch(cashRepositoryProvider).watchEveningReport(jour),
);

class CashScreen extends ConsumerWidget {
  const CashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jour = businessDayFor(DateTime.now());
    final iso = formatIsoDate(jour);
    final paiements = ref.watch(_encaissementsProvider(iso));
    final liste = paiements.value ?? const <DayPayment>[];
    final total = liste.fold<int>(0, (t, p) => t + p.amount);
    final etroit = MediaQuery.sizeOf(context).width < 600;
    final marge = etroit ? 18.0 : 32.0;
    // Le rapport du soir est celui de la caisse centrale.
    final centrale = ref.watch(sessionProvider).acces.peut('cash.central');

    return ModuleScaffold(
      title: 'Caisse du jour',
      subtitle:
          '${formatLongDate(jour)}, ${liste.length} '
          'encaissement${liste.length > 1 ? 's' : ''}',
      action: const CashButton(),
      body: LayoutBuilder(
        builder: (context, c) {
          final large = c.maxWidth >= 900;
          final gauche = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FadeUp(
                child: _Total(total: total, nombre: liste.length),
              ),
              const SizedBox(height: 14),
              FadeUp(index: 1, child: _ParMoyen(paiements: liste)),
              const SizedBox(height: 14),
              const FadeUp(index: 2, child: _MaCaisse()),
            ],
          );
          final droite = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (centrale) ...[
                FadeUp(index: 1, child: _RapportDuSoir(jour: iso)),
                const SizedBox(height: 14),
              ],
              FadeUp(index: 1, child: _Encaissements(paiements: paiements)),
              const SizedBox(height: 14),
              const FadeUp(index: 2, child: _Historique()),
            ],
          );
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(marge, 0, marge, 36),
            child: large
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 360, child: gauche),
                      const SizedBox(width: 16),
                      Expanded(child: droite),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [gauche, const SizedBox(height: 14), droite],
                  ),
          );
        },
      ),
    );
  }
}

TextStyle _st(double taille, FontWeight poids, Color couleur) => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: taille,
  fontWeight: poids,
  color: couleur,
  fontFeatures: tabularFigures,
);

class _Total extends StatelessWidget {
  const _Total({required this.total, required this.nombre});

  final int total;
  final int nombre;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      core: p.hero,
      radius: 26,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                PhosphorIconsLight.cashRegister,
                size: 20,
                color: p.heroAccent,
              ),
              const SizedBox(width: 8),
              Text(
                "Encaissé aujourd'hui",
                style: _st(14, FontWeight.w600, p.onHeroSoft),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TweenAnimationBuilder<double>(
            tween: Tween(end: total.toDouble()),
            duration: AtriumMotion.of(
              context,
              const Duration(milliseconds: 800),
            ),
            curve: atriumSpring,
            builder: (_, v, _) => FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatAmount(v.round()),
                style: _st(
                  38,
                  FontWeight.w700,
                  p.heroAccent,
                ).copyWith(letterSpacing: -1.4),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'tous moyens confondus, $nombre opération${nombre > 1 ? 's' : ''}',
            style: _st(13, FontWeight.w500, p.onHeroSoft),
          ),
        ],
      ),
    );
  }
}

/// La repartition par moyen de paiement, en barres proportionnelles.
class _ParMoyen extends StatelessWidget {
  const _ParMoyen({required this.paiements});

  final List<DayPayment> paiements;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final parMoyen = <PaymentMethod, int>{};
    for (final x in paiements) {
      parMoyen.update(x.method, (n) => n + x.amount, ifAbsent: () => x.amount);
    }
    final lignes = parMoyen.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    // Pas de `clamp(1, 1 << 62)` : sur le web les entiers sont des doubles
    // JavaScript, et la borne deborde.
    final max = lignes.isEmpty || lignes.first.value.abs() < 1
        ? 1
        : lignes.first.value.abs();

    return Bezel(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Par moyen de paiement'),
          const SizedBox(height: 12),
          if (lignes.isEmpty)
            Text(
              "Rien d'encaissé pour le moment.",
              style: _st(14, FontWeight.w500, p.textSecondary),
            )
          else
            for (final e in lignes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(iconePaiement(e.key), size: 18, color: p.text),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            paymentMethodLabel(e.key),
                            style: _st(14, FontWeight.w600, p.text),
                          ),
                        ),
                        Text(
                          formatAmount(e.value),
                          style: _st(14, FontWeight.w700, p.text),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: e.value.abs() / max),
                        duration: AtriumMotion.of(
                          context,
                          const Duration(milliseconds: 700),
                        ),
                        curve: atriumSpring,
                        builder: (_, v, _) => LinearProgressIndicator(
                          value: v,
                          minHeight: 7,
                          backgroundColor: p.surfaceMuted,
                          color: p.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// La caisse de l'agent connecte : ouverte depuis quand, avec quel fond.
class _MaCaisse extends ConsumerWidget {
  const _MaCaisse();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final agent = ref.watch(sessionProvider).agent?.id;
    final vue = agent == null
        ? null
        : ref.watch(currentCashProvider(agent)).value;
    final ouverte = vue?.open ?? false;
    final depuis = vue?.session.openedAt?.toLocal();

    return Bezel(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Ma caisse'),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: ouverte ? p.success : p.textSecondary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  ouverte
                      ? 'Ouverte${depuis == null ? '' : ' depuis ${_hm(depuis)}'}'
                      : "Pas de caisse ouverte",
                  style: _st(15, FontWeight.w700, p.text),
                ),
              ),
            ],
          ),
          if (ouverte) ...[
            const SizedBox(height: 8),
            Text(
              'Fond de caisse : ${formatAmount(vue!.session.openingFloat)}',
              style: _st(13.5, FontWeight.w500, p.textSecondary),
            ),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              'Ouvrez-la en prenant votre poste : les encaissements en espèces '
              's’y rattachent.',
              style: _st(13.5, FontWeight.w500, p.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Le rapport du soir : ce que chaque point de vente doit a la reception, ce
/// qu'il a verse, ce qui attend encore, et les ecarts.
class _RapportDuSoir extends ConsumerWidget {
  const _RapportDuSoir({required this.jour});

  final String jour;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final rapport = ref.watch(_rapportDuSoirProvider(jour)).value;
    final points = rapport?.outlets ?? const <OutletEvening>[];
    final aConfirmer = rapport?.toConfirm ?? 0;

    return Bezel(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(
            'Versements des points de vente',
            trailing: aConfirmer == 0
                ? null
                : Tag('$aConfirmer à confirmer', color: p.warning),
          ),
          const SizedBox(height: 10),
          if (rapport == null || points.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Aucun point de vente n’a ouvert de caisse. Leurs recettes '
                's’afficheront ici, avec ce qu’ils ont versé.',
                style: _st(14, FontWeight.w500, p.textSecondary),
              ),
            )
          else ...[
            Wrap(
              spacing: 22,
              runSpacing: 10,
              children: [
                _Chiffre(label: 'Attendu', montant: rapport.expected),
                _Chiffre(label: 'Versé', montant: rapport.paid),
                _Chiffre(label: 'En attente', montant: rapport.pending),
                _Chiffre(
                  label: 'Écart',
                  montant: rapport.variance,
                  signe: true,
                  couleur: rapport.variance == 0 ? p.success : p.error,
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final point in points) ...[
              Divider(height: 22, color: p.border),
              _PointDuSoir(point: point),
            ],
            if (rapport.centralTakings != 0) ...[
              Divider(height: 22, color: p.border),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Réception, encaissé sur place',
                      style: _st(13.5, FontWeight.w600, p.textSecondary),
                    ),
                  ),
                  Text(
                    formatAmount(rapport.centralTakings),
                    style: _st(13.5, FontWeight.w700, p.text),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _Chiffre extends StatelessWidget {
  const _Chiffre({
    required this.label,
    required this.montant,
    this.signe = false,
    this.couleur,
  });

  final String label;
  final int montant;

  /// Un ecart : le signe se lit, un excedent n'est pas un manque.
  final bool signe;
  final Color? couleur;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: _st(12.5, FontWeight.w600, p.textSecondary)),
        const SizedBox(height: 2),
        Text(
          '${signe && montant > 0 ? '+' : ''}${formatAmount(montant)}',
          style: _st(17, FontWeight.w700, couleur ?? p.text),
        ),
      ],
    );
  }
}

/// Un point de vente dans le rapport du soir : sa recette, puis ses caisses.
class _PointDuSoir extends StatelessWidget {
  const _PointDuSoir({required this.point});

  final OutletEvening point;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final autres = point.takings - point.cashTakings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                point.outletLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _st(15.5, FontWeight.w700, p.text),
              ),
            ),
            Text(
              'Recette ${formatAmount(point.takings)}',
              style: _st(13.5, FontWeight.w700, p.text),
            ),
          ],
        ),
        Text(
          autres == 0
              ? 'dont ${formatAmount(point.cashTakings)} en espèces'
              : 'dont ${formatAmount(point.cashTakings)} en espèces, '
                    '${formatAmount(autres)} par d’autres moyens',
          style: _st(12.5, FontWeight.w500, p.textSecondary),
        ),
        for (final v in point.remittances) _LigneVersement(versement: v),
      ],
    );
  }
}

/// La caisse d'un point de vente : ce qu'elle doit, ce qu'elle a verse, et
/// le bouton pour confirmer ce que la reception recoit.
class _LigneVersement extends ConsumerWidget {
  const _LigneVersement({required this.versement});

  final Remittance versement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final v = versement;
    final ecart = v.variance;

    final String detail;
    final Widget etat;
    switch (v.status) {
      case RemittanceStatus.pending:
        detail = 'Caisse ouverte, doit verser ${formatAmount(v.expected)}';
        etat = const Tag('En attente');
      case RemittanceStatus.declared:
        detail =
            'A déclaré ${formatAmount(v.declared!)} '
            'pour ${formatAmount(v.expected)} attendus';
        etat = Tag('À confirmer', color: p.warning);
      case RemittanceStatus.received:
        detail =
            'Reçu ${formatAmount(v.received!)} '
            'pour ${formatAmount(v.expected)} attendus'
            '${v.declared != null && v.declared != v.received ? ', déclaré ${formatAmount(v.declared!)}' : ''}';
        etat = ecart == 0
            ? Tag('Juste', color: p.success)
            : Tag(
                '${ecart! > 0 ? '+' : ''}${formatAmount(ecart)}',
                color: p.error,
              );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Monogram(v.agentName, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.agentName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _st(14, FontWeight.w700, p.text),
                ),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _st(12.5, FontWeight.w500, p.textSecondary),
                ),
                // Un ecart des la declaration : la reception le voit avant
                // de compter ce qu'on lui tend.
                if (v.status == RemittanceStatus.declared && ecart != 0)
                  Text(
                    'Écart déclaré : ${ecart! > 0 ? '+' : ''}'
                    '${formatAmount(ecart)}',
                    style: _st(12.5, FontWeight.w700, p.error),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (v.status == RemittanceStatus.declared)
            PillButton(
              label: 'Confirmer',
              icon: PhosphorIconsLight.check,
              tone: PillTone.accent,
              compact: true,
              onPressed: () => _confirmer(context, ref),
            )
          else
            etat,
        ],
      ),
    );
  }

  Future<void> _confirmer(BuildContext context, WidgetRef ref) async {
    final v = versement;
    final agent = ref.read(sessionProvider).agent?.id;
    if (agent == null) return;

    final recu = await demanderMontant(
      context,
      titre: 'Versement de ${v.outletLabel}',
      question:
          '${v.agentName} déclare vous remettre ${formatAmount(v.declared!)}. '
          'Comptez ce que vous recevez et saisissez-le.',
      champ: 'Montant reçu (FCFA)',
      action: 'Confirmer',
    );
    if (recu == null || !context.mounted) return;

    final int ecart;
    try {
      ecart = await ref
          .read(cashRepositoryProvider)
          .confirmRemittance(
            sessionId: v.sessionId,
            receivedAmount: recu,
            by: agent,
          );
    } on StateError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ecart == 0
              ? 'Versement de ${v.outletLabel} reçu, juste.'
              : 'Versement de ${v.outletLabel} reçu, écart de '
                    '${ecart > 0 ? '+' : ''}${formatAmount(ecart)}.',
        ),
      ),
    );
  }
}

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _Encaissements extends StatelessWidget {
  const _Encaissements({required this.paiements});

  final AsyncValue<List<DayPayment>> paiements;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(
            'Encaissements',
            trailing: Text(
              '${paiements.value?.length ?? 0}',
              style: _st(12.5, FontWeight.w700, p.textSecondary),
            ),
          ),
          const SizedBox(height: 6),
          paiements.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('$e'),
            data: (liste) => liste.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Les encaissements de la journée s’afficheront ici.',
                      style: _st(14, FontWeight.w500, p.textSecondary),
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < liste.length; i++) ...[
                        if (i > 0) Divider(height: 1, color: p.border),
                        _LigneEncaissement(paiement: liste[i]),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _LigneEncaissement extends StatelessWidget {
  const _LigneEncaissement({required this.paiement});

  final DayPayment paiement;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final x = paiement;
    final qui = [
      x.guestName ?? 'Client de passage',
      if (x.roomNumber != null) 'chambre ${x.roomNumber}',
    ].join(', ');
    final detail = [
      paymentMethodLabel(x.method),
      if (x.agentName != null) 'par ${x.agentName}',
      if (x.reference != null && x.reference!.isNotEmpty) x.reference!,
    ].join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              x.receivedAt == null ? '—' : _hm(x.receivedAt!.toLocal()),
              style: _st(13, FontWeight.w700, p.textSecondary),
            ),
          ),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: p.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(iconePaiement(x.method), size: 18, color: p.text),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  qui,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _st(14.5, FontWeight.w700, p.text),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _st(12.5, FontWeight.w500, p.textSecondary),
                ),
              ],
            ),
          ),
          Text(
            '${x.amount < 0 ? '' : '+'}${formatAmount(x.amount)}',
            style: _st(15, FontWeight.w700, x.amount < 0 ? p.error : p.success),
          ),
        ],
      ),
    );
  }
}

/// Les dernieres caisses : qui, quand, et l'ecart constate a la fermeture.
class _Historique extends ConsumerWidget {
  const _Historique();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final caisses = ref.watch(_caissesProvider).value ?? const [];
    return Bezel(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Historique des caisses'),
          const SizedBox(height: 6),
          if (caisses.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Aucune caisse encore ouverte sur cette tablette.',
                style: _st(14, FontWeight.w500, p.textSecondary),
              ),
            )
          else
            for (var i = 0; i < caisses.length; i++) ...[
              if (i > 0) Divider(height: 1, color: p.border),
              _LigneCaisse(caisse: caisses[i]),
            ],
        ],
      ),
    );
  }
}

class _LigneCaisse extends StatelessWidget {
  const _LigneCaisse({required this.caisse});

  final CashSessionSummary caisse;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final s = caisse.session;
    final ouverte = s.status == CashSessionStatus.OPEN;
    final debut = s.openedAt?.toLocal();
    final fin = s.closedAt?.toLocal();
    String quand(DateTime? d) =>
        d == null ? '—' : '${formatDayMonth(d)} ${_hm(d)}';

    final Widget etat;
    if (ouverte) {
      etat = Tag('Ouverte', color: p.success);
    } else if (s.countedAmount == null) {
      etat = const Tag('Fermée');
    } else if (s.variance == 0) {
      etat = Tag('Juste', color: p.success);
    } else {
      etat = Tag(
        '${s.variance > 0 ? '+' : ''}${formatAmount(s.variance)}',
        color: p.error,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Monogram(caisse.agentName, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  caisse.agentName,
                  style: _st(14.5, FontWeight.w700, p.text),
                ),
                Text(
                  ouverte
                      ? 'depuis ${quand(debut)}'
                      : 'de ${quand(debut)} à ${quand(fin)}',
                  style: _st(12.5, FontWeight.w500, p.textSecondary),
                ),
              ],
            ),
          ),
          etat,
        ],
      ),
    );
  }
}
