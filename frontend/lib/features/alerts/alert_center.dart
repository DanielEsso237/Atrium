/// Le centre d'alertes : ce qui est en cours, ce que l'agent a deja vu, et
/// quand la tablette doit sonner.
///
/// Une alerte sonne a son apparition, puis se rappelle tant que personne ne
/// l'a acquittee : toutes les vingt secondes si elle est critique, toutes les
/// deux minutes sinon. C'est ce qui la rend impossible a manquer -- une
/// sonnerie unique se perd dans le bruit d'un hall.
///
/// Le niveau de chaque evenement (discret, sonore, sonore et vibration) vient
/// de l'administration ; l'agent peut couper le son pour lui-meme. Quand
/// l'application n'est pas devant lui, l'alerte passe par le volet de
/// notifications du systeme, avec le meme niveau.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/alert_queries.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../auth/session.dart';
import 'alert_signal.dart';
import 'system_notifications.dart';

class EtatAlertes {
  const EtatAlertes({
    this.actives = const [],
    this.vues = const {},
    this.niveaux = const NiveauxAlertes(),
  });

  final List<Alerte> actives;

  /// Les cles acquittees par l'agent pendant cette session.
  final Set<String> vues;

  final NiveauxAlertes niveaux;

  /// Les alertes du bandeau : celles d'un evenement qui sonne, pas encore
  /// vues. Un evenement regle « discret » reste dans la cloche.
  List<Alerte> get bandeau => [
    for (final a in actives)
      if (niveaux.de(a.type).sonne && !vues.contains(a.cle)) a,
  ];

  int get nonVues => actives.where((a) => !vues.contains(a.cle)).length;

  EtatAlertes copier({
    List<Alerte>? actives,
    Set<String>? vues,
    NiveauxAlertes? niveaux,
  }) => EtatAlertes(
    actives: actives ?? this.actives,
    vues: vues ?? this.vues,
    niveaux: niveaux ?? this.niveaux,
  );
}

class CentreAlertes extends Notifier<EtatAlertes> {
  StreamSubscription<void>? _changements;
  Timer? _minute;
  Timer? _rappel;
  NiveauAlerte? _niveauRappel;
  bool _premiere = true;
  bool _enCours = false;
  bool _encore = false;
  bool _sonCoupe = false;
  bool _premierPlan = true;

  SignalAlerte get _signal => ref.read(signalAlerteProvider);
  NotificationsSysteme get _systeme => ref.read(notificationsSystemeProvider);

  @override
  EtatAlertes build() {
    final session = ref.watch(sessionProvider);
    ref.onDispose(_couper);
    _premiere = true;
    final systeme = _systeme;
    if (!session.estConnecte) {
      // L'agent est parti : plus de veille, plus rien dans le volet. Le
      // suivant ne doit pas heriter des alertes du precedent.
      unawaited(systeme.effacer().then((_) => systeme.veiller(false)));
      return const EtatAlertes();
    }
    unawaited(systeme.preparer(_surTouche).then((_) => systeme.veiller(true)));

    // `listen` et non `watch` : un changement de reglage ne doit pas
    // reconstruire le centre, qui oublierait ce que l'agent a deja vu.
    ref.listen(premierPlanProvider, (_, devant) {
      _premierPlan = devant;
      if (devant) unawaited(_systeme.effacer());
    });
    ref.listen(preferencesAlertesProvider, (_, p) {
      _sonCoupe = p.value?.sonCoupe ?? false;
      if (_sonCoupe) unawaited(_signal.arreter());
    });
    ref.listen(niveauxAlertesProvider, (_, n) {
      if (n.value case final niveaux?) {
        state = state.copier(niveaux: niveaux);
        _ajusterRappel();
      }
    });
    _premierPlan = ref.read(premierPlanProvider);
    _sonCoupe = ref.read(preferencesAlertesProvider).value?.sonCoupe ?? false;

    final db = ref.watch(databaseProvider);
    _changements = db.changementsAlertes().listen((_) => _evaluer());
    // Le temps fait naitre des alertes sans qu'aucune table ne bouge : un
    // depart devient en retard a midi.
    _minute = Timer.periodic(const Duration(minutes: 1), (_) => _evaluer());
    scheduleMicrotask(_evaluer);
    return EtatAlertes(
      niveaux: ref.read(niveauxAlertesProvider).value ?? const NiveauxAlertes(),
    );
  }

  /// L'agent a vu l'alerte : elle quitte le bandeau et cesse de sonner.
  void acquitter(String cle) {
    state = state.copier(vues: {...state.vues, cle});
    _ajusterRappel();
  }

  void acquitterTout() {
    state = state.copier(
      vues: {...state.vues, for (final a in state.actives) a.cle},
    );
    _ajusterRappel();
  }

  /// Une alerte touchee dans le volet : vue, et son ecran ouvert.
  void _surTouche(String cle, String? route) {
    if (!ref.mounted) return;
    acquitter(cle);
    if (route != null) ref.read(routerProvider).go(route);
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

    // A la connexion, les arrivees et les stocks bas deja connus vont dans la
    // cloche sans bandeau ni rappel. Le reste sonne, meme deja ancien.
    //
    // Mais toute alerte non lue sonne a la connexion (decision du 11
    // octobre) : les arrivees et les stocks bas aussi, une seule sonnerie
    // pour tout -- `_signaler` n'en emet qu'une --, chacune a son niveau
    // regle (un type « Discret » reste muet), et sans rappel ensuite.
    final aLaConnexion = <Alerte>[];
    if (_premiere) {
      _premiere = false;
      vues = {
        ...vues,
        for (final a in nouvelles)
          if (a.niveau == NiveauAlerte.info) a.cle,
      };
      aLaConnexion.addAll(
        nouvelles.where((a) => a.niveau == NiveauAlerte.info),
      );
      nouvelles.removeWhere((a) => a.niveau == NiveauAlerte.info);
    }

    state = state.copier(actives: alertes, vues: vues);

    // Reglee pendant que la tablette dormait : sa notification n'a plus de
    // raison de sonner.
    if (!_premierPlan) {
      for (final cle in avant.difference(cles)) {
        unawaited(_systeme.retirer(cle));
      }
    }
    _signaler([...nouvelles, ...aLaConnexion]);
    _ajusterRappel();
  }

  /// Fait sonner ces alertes, selon le niveau de leur evenement et le choix
  /// de l'agent : par le haut-parleur devant l'ecran, par le volet de
  /// notifications sinon.
  void _signaler(List<Alerte> alertes, {bool rappel = false}) {
    if (alertes.isEmpty) return;
    final niveaux = state.niveaux;

    if (!_premierPlan) {
      // Un rappel ne repete que la plus forte : dix notifications qui
      // sonnent ensemble ne se distinguent plus.
      for (final a in rappel ? alertes.take(1) : alertes) {
        final niveau = niveaux.de(a.type);
        unawaited(
          _systeme.montrer(
            a,
            SignalVoulu(
              gravite: a.niveau,
              son: niveau.sonne && !_sonCoupe,
              vibration: niveau.vibre,
              discret: !niveau.sonne,
            ),
          ),
        );
      }
      return;
    }

    final bruyantes = [
      for (final a in alertes)
        if (niveaux.de(a.type).sonne) a,
    ];
    if (bruyantes.isEmpty) return;
    final gravite = bruyantes
        .map((a) => a.niveau)
        .reduce((a, b) => a.index >= b.index ? a : b);
    final vibre = bruyantes.any((a) => niveaux.de(a.type).vibre);
    if (_sonCoupe && !vibre) return;
    unawaited(_signal.emettre(gravite, son: !_sonCoupe, vibration: vibre));
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
      (_) => _signaler(state.bandeau, rappel: true),
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

/// Au premier plan ou non. En arriere-plan, une alerte passe par le volet de
/// notifications : le haut-parleur de l'application ne s'entend plus quand
/// l'ecran est eteint, et l'agent n'a pas le bandeau sous les yeux.
class PremierPlan extends Notifier<bool> {
  @override
  bool build() {
    final ecoute = AppLifecycleListener(
      onStateChange: (e) => state = _devant(e),
    );
    ref.onDispose(ecoute.dispose);
    final etat = WidgetsBinding.instance.lifecycleState;
    return etat == null || _devant(etat);
  }

  /// `inactive` : un volet ou une boite systeme passe devant, l'application
  /// reste visible derriere.
  static bool _devant(AppLifecycleState e) =>
      e == AppLifecycleState.resumed || e == AppLifecycleState.inactive;
}

final premierPlanProvider = NotifierProvider<PremierPlan, bool>(
  PremierPlan.new,
);

/// Ce que l'agent connecte a choisi pour lui-meme sur cette tablette.
final preferencesAlertesProvider = StreamProvider<PreferencesAlertes>((ref) {
  final agent = ref.watch(sessionProvider.select((s) => s.agent?.id));
  if (agent == null) return Stream.value(const PreferencesAlertes());
  return ref.watch(settingsRepositoryProvider).watchPreferencesAlertes(agent);
});

/// Tous les combien une alerte non vue sonne de nouveau ; raccourcis dans
/// les tests.
final delaisRappelProvider = Provider<({Duration critique, Duration urgente})>(
  (ref) => (
    critique: const Duration(seconds: 20),
    urgente: const Duration(minutes: 2),
  ),
);

final centreAlertesProvider = NotifierProvider<CentreAlertes, EtatAlertes>(
  CentreAlertes.new,
);
