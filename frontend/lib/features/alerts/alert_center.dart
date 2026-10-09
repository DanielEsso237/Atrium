/// Le centre d'alertes : ce qui est en cours, ce que l'agent a deja vu, et
/// quand la tablette doit sonner.
///
/// Une alerte sonne a son apparition, puis se rappelle tant que personne ne
/// l'a acquittee : toutes les vingt secondes si elle est critique, toutes les
/// deux minutes si elle est urgente. C'est ce qui la rend impossible a
/// manquer -- une sonnerie unique se perd dans le bruit d'un hall.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database_provider.dart';
import '../../data/local/queries/alert_queries.dart';
import '../auth/session.dart';
import 'alert_signal.dart';

class EtatAlertes {
  const EtatAlertes({this.actives = const [], this.vues = const {}});

  final List<Alerte> actives;

  /// Les cles acquittees par l'agent pendant cette session.
  final Set<String> vues;

  /// Les alertes du bandeau : urgentes ou critiques, pas encore vues.
  List<Alerte> get bandeau => [
    for (final a in actives)
      if (a.niveau != NiveauAlerte.info && !vues.contains(a.cle)) a,
  ];

  int get nonVues => actives.where((a) => !vues.contains(a.cle)).length;
}

class CentreAlertes extends Notifier<EtatAlertes> {
  StreamSubscription<void>? _changements;
  Timer? _minute;
  Timer? _rappel;
  NiveauAlerte? _niveauRappel;
  bool _premiere = true;
  bool _enCours = false;
  bool _encore = false;

  SignalAlerte get _signal => ref.read(signalAlerteProvider);

  @override
  EtatAlertes build() {
    final session = ref.watch(sessionProvider);
    ref.onDispose(_couper);
    _premiere = true;
    if (!session.estConnecte) return const EtatAlertes();

    final db = ref.watch(databaseProvider);
    _changements = db.changementsAlertes().listen((_) => _evaluer());
    // Le temps fait naitre des alertes sans qu'aucune table ne bouge : un
    // depart devient en retard a midi.
    _minute = Timer.periodic(const Duration(minutes: 1), (_) => _evaluer());
    scheduleMicrotask(_evaluer);
    return const EtatAlertes();
  }

  /// L'agent a vu l'alerte : elle quitte le bandeau et cesse de sonner.
  void acquitter(String cle) {
    state = EtatAlertes(actives: state.actives, vues: {...state.vues, cle});
    _ajusterRappel();
  }

  void acquitterTout() {
    state = EtatAlertes(
      actives: state.actives,
      vues: {...state.vues, for (final a in state.actives) a.cle},
    );
    _ajusterRappel();
  }

  Future<void> _evaluer() async {
    // Une evaluation a la fois : une rafale d'ecritures (une descente) ne
    // doit pas lancer dix lectures concurrentes.
    if (_enCours) {
      _encore = true;
      return;
    }
    _enCours = true;
    try {
      do {
        _encore = false;
        await _une();
      } while (_encore && ref.mounted);
    } finally {
      _enCours = false;
    }
  }

  Future<void> _une() async {
    final session = ref.read(sessionProvider);
    if (!session.estConnecte) return;
    final alertes = await ref
        .read(databaseProvider)
        .chargerAlertes(
          ContexteAlertes(
            agentId: session.agent?.id,
            peut: session.acces.peut,
            accueil: session.acces.homeRoute,
            maintenant: DateTime.now(),
          ),
        );
    if (!ref.mounted) return;

    final avant = {for (final a in state.actives) a.cle};
    final cles = {for (final a in alertes) a.cle};
    // Une alerte reglee puis revenue sonne de nouveau : on oublie ce qui
    // n'est plus en cours.
    var vues = state.vues.intersection(cles);
    final nouvelles = [
      for (final a in alertes)
        if (!avant.contains(a.cle) && !vues.contains(a.cle)) a,
    ];

    // A la connexion, les ruptures de stock deja connues ne vibrent pas :
    // l'agent les trouvera dans la cloche. Le reste sonne, meme deja ancien.
    if (_premiere) {
      _premiere = false;
      vues = {
        ...vues,
        for (final a in nouvelles)
          if (a.niveau == NiveauAlerte.info) a.cle,
      };
      nouvelles.removeWhere((a) => a.niveau == NiveauAlerte.info);
    }

    state = EtatAlertes(actives: alertes, vues: vues);

    if (nouvelles.isNotEmpty) {
      final plusForte = nouvelles
          .map((a) => a.niveau)
          .reduce((a, b) => a.index >= b.index ? a : b);
      unawaited(_signal.emettre(plusForte));
    }
    _ajusterRappel();
  }

  /// Le rappel suit l'alerte non vue la plus forte ; il s'arrete quand il
  /// n'y en a plus.
  void _ajusterRappel() {
    final restantes = state.bandeau;
    final niveau = restantes.isEmpty
        ? null
        : restantes
              .map((a) => a.niveau)
              .reduce((a, b) => a.index >= b.index ? a : b);
    if (niveau == _niveauRappel && (_rappel != null) == (niveau != null)) {
      return;
    }
    _rappel?.cancel();
    _rappel = null;
    _niveauRappel = niveau;
    if (niveau == null) {
      unawaited(_signal.arreter());
      return;
    }
    final delais = ref.read(delaisRappelProvider);
    _rappel = Timer.periodic(
      niveau == NiveauAlerte.critique ? delais.critique : delais.urgente,
      (_) => unawaited(_signal.emettre(niveau)),
    );
  }

  void _couper() {
    _changements?.cancel();
    _changements = null;
    _minute?.cancel();
    _minute = null;
    _rappel?.cancel();
    _rappel = null;
    _niveauRappel = null;
  }
}

/// Tous les combien une alerte non vue sonne de nouveau ; raccourcis dans
/// les tests.
final delaisRappelProvider =
    Provider<({Duration critique, Duration urgente})>(
      (ref) => (
        critique: const Duration(seconds: 20),
        urgente: const Duration(minutes: 2),
      ),
    );

final centreAlertesProvider = NotifierProvider<CentreAlertes, EtatAlertes>(
  CentreAlertes.new,
);
