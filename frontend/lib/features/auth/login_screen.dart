/// Ecran de connexion.
///
/// Deux voies, comme le prevoit le paragraphe 6.2 :
///
/// - **le code PIN**, l'usage courant en service. Dix agents se succedent sur
///   la meme tablette de comptoir ; un pave numerique se tape vite, souvent
///   sans regarder, et parfois avec des gants.
/// - **le mot de passe**, pour l'administration et les ecrans de direction,
///   ou la session dure la journee et ou le secret doit etre plus solide que
///   quatre chiffres.
///
/// Le meme code agent sert aux deux : c'est le secret qui change, pas
/// l'identite.
///
/// Premier ecran de la charte violet, menthe, anthracite : il applique
/// `atriumBrandTheme()` a son propre sous-arbre, sans toucher aux autres. La
/// composition reprend la maquette validee : un bandeau de nuit ouvert sur une
/// chambre, des rubans menthe et violet qui viennent se poser sur le coin de la
/// carte, des vagues dans les coins bas.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/atrium_segmented_control.dart';
import '../../core/widgets/atrium_text_field.dart';
import '../../core/widgets/shake.dart';
import '../../data/repositories/auth_repository.dart';
import 'pin_input.dart';
import 'session.dart';

enum _Voie { pin, motDePasse }

/// Construit une fois : `ThemeData` n'est pas gratuit, et l'ecran se
/// reconstruit a chaque chiffre tape.
final _theme = atriumBrandTheme();

const _photoChambre = 'assets/images/chambre.jpg';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _codeAgent = TextEditingController(text: 'ADMIN01');
  final _motDePasse = TextEditingController();
  String _pin = '';
  _Voie _voie = _Voie.pin;
  bool _motDePasseVisible = false;

  /// Compteurs de refus : chaque increment rejoue la secousse du champ fautif.
  /// Deux compteurs et non un, pour que ce soit le code agent qui tremble
  /// quand c'est lui qui est en cause, et le secret sinon.
  int _refusAgent = 0;
  int _refusSecret = 0;

  /// Le seul mouvement que l'agent ne declenche pas : l'arrivee de l'ecran,
  /// en une sequence. La chambre se pose, les rubans glissent jusqu'a la
  /// carte, l'embleme puis le nom apparaissent, le point menthe du « i » tombe
  /// en dernier.
  late final _entree = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  // Crees une fois : une `CurvedAnimation` s'abonne a son parent, et l'ecran
  // se reconstruit a chaque chiffre tape.
  late final _phases = _Phases(_entree);

  static const _longueurPin = 4;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // La photo est decodee pendant que la sequence d'entree demarre : sans
    // cela, elle arrivait apres le zoom, d'un coup, sur un bandeau deja pose.
    precacheImage(const AssetImage(_photoChambre), context);
    if (_entree.isAnimating || _entree.isCompleted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _entree.value = 1;
    } else {
      _entree.forward();
    }
  }

  @override
  void dispose() {
    _phases.dispose();
    _entree.dispose();
    _codeAgent.dispose();
    _motDePasse.dispose();
    super.dispose();
  }

  void _chiffre(String c) {
    if (_pin.length >= _longueurPin) return;
    setState(() => _pin += c);
    if (_pin.length == _longueurPin) _valider();
  }

  void _effacer() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _valider() async {
    final secret = _voie == _Voie.pin ? _pin : _motDePasse.text;
    if (secret.isEmpty) return;

    final ok = await ref
        .read(sessionProvider.notifier)
        .connecter(codeAgent: _codeAgent.text, secret: secret);

    // Le secret se vide apres un echec : reessayer ne doit pas demander
    // d'effacer quatre fois.
    if (!ok && mounted) {
      setState(() {
        _pin = '';
        _motDePasse.clear();
      });
    }
  }

  void _changerDeVoie(_Voie voie) {
    if (voie == _voie) return;
    setState(() {
      _voie = voie;
      _pin = '';
      _motDePasse.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);

    // Un refus fait trembler le champ en cause et vibrer la tablette : l'agent
    // qui tape sans regarder doit le sentir avant de le lire.
    ref.listen<SessionState>(sessionProvider, (avant, apres) {
      final echec = apres.echec;
      if (!(avant?.enCours ?? false) || echec == null) return;
      HapticFeedback.mediumImpact();
      setState(() {
        if (echec == LoginFailure.wrongSecret) {
          _refusSecret++;
        } else {
          _refusAgent++;
        }
      });
    });

    final g = _Gabarit.pour(
      MediaQuery.sizeOf(context),
      MediaQuery.paddingOf(context),
    );
    // Le clavier tactile ne redimensionne pas la page (voir le Scaffold) :
    // il ajoute seulement de quoi faire defiler le champ au-dessus de lui.
    final clavier = MediaQuery.viewInsetsOf(context).bottom;

    return Theme(
      data: _theme,
      // Icones de la barre d'etat en blanc : elles sont posees sur la nuit du
      // bandeau, pas sur un fond clair.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
        ),
        child: Scaffold(
          backgroundColor: AtriumColors.background,
          // Sans cela, le clavier tasserait toute la page : le bandeau et les
          // vagues remonteraient sous les doigts de l'agent.
          resizeToAvoidBottomInset: false,
          body: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: clavier),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: g.ecran.height),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ExcludeSemantics(
                      child: _Decor(g: g, phases: _phases),
                    ),
                  ),
                  Column(
                    children: [
                      SizedBox(height: g.hautCarte),
                      Center(
                        child: _Monte(
                          animation: _phases.carte,
                          child: SizedBox(
                            width: g.largeurCarte,
                            child: _carte(session, g),
                          ),
                        ),
                      ),
                      SizedBox(height: g.espaceBas),
                      _BarreMenthe(
                        animation: _phases.barres,
                        largeur: g.largeurBarreBas,
                      ),
                      SizedBox(height: g.margeBas),
                    ],
                  ),
                  Positioned(
                    left: g.gaucheMarque,
                    top: g.hautMarque,
                    child: _Marque(g: g, phases: _phases),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Le formulaire -------------------------------------------------------

  Widget _carte(SessionState session, _Gabarit g) {
    final echec = session.echec;
    final echecAgent = echec != null && echec != LoginFailure.wrongSecret
        ? _messageEchec(echec)
        : null;
    final echecSecret = echec == LoginFailure.wrongSecret
        ? _messageEchec(echec!)
        : null;

    return Container(
      padding: EdgeInsets.fromLTRB(
        g.paddingCarte,
        g.paddingCarteVertical,
        g.paddingCarte,
        g.paddingCarteVertical,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AtriumColors.surface, AtriumColors.background],
          stops: [0.6, 1],
        ),
        borderRadius: BorderRadius.circular(AtriumRadii.xl),
        // Un filet blanc : invisible sur le fond clair, il detoure
        // nettement la carte la ou elle chevauche le bandeau.
        border: Border.all(color: AtriumColors.white),
        boxShadow: AtriumShadows.card,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Shake(
            trigger: _refusAgent,
            child: AtriumTextField(
              label: 'Code agent',
              labelIcon: Icons.person_outline_rounded,
              controller: _codeAgent,
              icon: Icons.badge_outlined,
              textCapitalization: TextCapitalization.characters,
              errorText: echecAgent,
              valueStyle: const TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 18,
                fontWeight: FontWeight.w500,
                letterSpacing: 1,
                color: AtriumColors.ink,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          SizedBox(height: g.espace),
          AtriumSegmentedControl<_Voie>(
            segments: const [
              AtriumSegment(
                value: _Voie.pin,
                label: 'Code PIN',
                icon: Icons.dialpad_rounded,
              ),
              AtriumSegment(
                value: _Voie.motDePasse,
                label: 'Mot de passe',
                icon: Icons.password_rounded,
              ),
            ],
            selected: _voie,
            onChanged: _changerDeVoie,
          ),
          SizedBox(height: g.espace + AtriumSpacing.xxs),
          AnimatedSize(
            duration: AtriumMotion.of(context, AtriumMotion.slow),
            curve: AtriumMotion.standard,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: AtriumMotion.of(context, AtriumMotion.slow),
              switchInCurve: AtriumMotion.standard,
              switchOutCurve: Curves.easeIn,
              layoutBuilder: (actuel, precedents) => Stack(
                alignment: Alignment.topCenter,
                children: [...precedents, ?actuel],
              ),
              child: _voie == _Voie.pin
                  ? KeyedSubtree(
                      key: const ValueKey(_Voie.pin),
                      child: _saisiePin(session, echecSecret, g),
                    )
                  : KeyedSubtree(
                      key: const ValueKey(_Voie.motDePasse),
                      child: _saisieMotDePasse(session, echecSecret),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _saisiePin(SessionState session, String? echecSecret, _Gabarit g) {
    // L'erreur s'efface des que l'agent retape : elle concernait le code
    // precedent, pas celui qu'il est en train de saisir.
    final refuse = echecSecret != null && _pin.isEmpty;

    final _Statut statut;
    if (refuse) {
      statut = _Statut.erreur(echecSecret);
    } else if (session.enCours) {
      statut = const _Statut.attente('Vérification…');
    } else {
      // Il n'y a pas de bouton en mode PIN : sans cette ligne, rien ne dit a
      // un nouvel agent que la saisie part toute seule.
      statut = const _Statut.aide('Vérifié dès le quatrième chiffre.');
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Shake(
          trigger: _refusSecret,
          child: PinCells(
            filled: _pin.length,
            length: _longueurPin,
            error: refuse,
            busy: session.enCours,
          ),
        ),
        const SizedBox(height: AtriumSpacing.sm),
        SizedBox(
          height: 22,
          child: AnimatedSwitcher(
            duration: AtriumMotion.of(context, AtriumMotion.base),
            // Cle sur le texte : le fondu ne se joue que si le message change,
            // pas a chaque chiffre tape.
            child: KeyedSubtree(key: ValueKey(statut.texte), child: statut),
          ),
        ),
        SizedBox(height: g.espace - AtriumSpacing.xxs),
        PinKeypad(
          onDigit: _chiffre,
          onDelete: _effacer,
          enabled: !session.enCours,
          keyHeight: g.hauteurTouche,
          spacing: g.ecartTouches,
        ),
      ],
    );
  }

  Widget _saisieMotDePasse(SessionState session, String? echecSecret) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Shake(
          trigger: _refusSecret,
          child: AtriumTextField(
            label: 'Mot de passe',
            labelIcon: Icons.key_rounded,
            controller: _motDePasse,
            icon: Icons.lock_outline_rounded,
            obscureText: !_motDePasseVisible,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _valider(),
            errorText: echecSecret,
            suffix: Padding(
              padding: const EdgeInsets.only(right: AtriumSpacing.xxs),
              child: IconButton(
                iconSize: 22,
                tooltip: _motDePasseVisible ? 'Masquer' : 'Afficher',
                icon: Icon(
                  _motDePasseVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () =>
                    setState(() => _motDePasseVisible = !_motDePasseVisible),
              ),
            ),
          ),
        ),
        const SizedBox(height: AtriumSpacing.xl),
        SizedBox(
          height: cibleTactile + 8,
          child: FilledButton(
            onPressed: session.enCours ? null : _valider,
            // Le liseré menthe reprend celui du mode selectionne : l'action
            // principale et le choix en cours parlent la meme langue.
            style: FilledButton.styleFrom(
              side: const BorderSide(
                color: AtriumColors.mintStrong,
                width: 1.5,
              ),
              // Pendant la verification le bouton est inactif, mais il garde
              // sa couleur : grise, il se lirait comme un refus.
              disabledBackgroundColor: AtriumColors.purple,
              disabledForegroundColor: AtriumColors.white,
            ),
            child: AnimatedSwitcher(
              duration: AtriumMotion.of(context, AtriumMotion.base),
              child: session.enCours
                  ? const Row(
                      key: ValueKey('attente'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: AtriumColors.mint,
                          ),
                        ),
                        SizedBox(width: AtriumSpacing.sm),
                        Text('Connexion…'),
                      ],
                    )
                  : const Text('Se connecter', key: ValueKey('action')),
            ),
          ),
        ),
      ],
    );
  }

  String _messageEchec(LoginFailure echec) => switch (echec) {
    LoginFailure.unknownUser => 'Code agent inconnu.',
    LoginFailure.disabledAccount => 'Ce compte est désactivé.',
    LoginFailure.locked =>
      'Compte verrouillé après cinq échecs. Réessayez dans quinze minutes.',
    LoginFailure.wrongSecret =>
      _voie == _Voie.pin ? 'Code incorrect.' : 'Mot de passe incorrect.',
    // Cas propre au mode hors connexion : le serveur ne repond pas, et cet
    // agent ne s'est jamais connecte sur cette tablette. Le dire, plutot que
    // de laisser croire a un mauvais mot de passe.
    LoginFailure.offlineAndUnknown =>
      'Serveur injoignable, et cet agent est inconnu de cette tablette.',
  };
}

// --- Gabarit -----------------------------------------------------------------

/// Les dimensions de la page selon l'ecran.
///
/// Calculees sur la taille de l'**ecran** et non sur la place restante : quand
/// le clavier tactile monte pour le code agent, la place restante fond de
/// moitie, et la page changeait de disposition sous les doigts de l'agent.
///
/// Les proportions viennent de la maquette (un telephone de 1024 points de
/// large) : marges de la carte, position de la marque, pointe des rubans. Les
/// hauteurs, elles, sont celles d'un ecran tactile reel : la maquette a des
/// touches de 38 points, sous la cible minimale de 48.
class _Gabarit {
  _Gabarit._({
    required this.ecran,
    required this.niveau,
    required this.largeurCarte,
    required this.gaucheCarte,
    required this.hautCarte,
    required this.hautMarque,
    required this.gaucheMarque,
  });

  factory _Gabarit.pour(Size ecran, EdgeInsets systeme) {
    final w = ecran.width;
    final h = ecran.height;
    // Trois niveaux de confort vertical. Le plus serre garde des touches a
    // la cible minimale plutot que de faire defiler le pave.
    final niveau = h >= 920 ? 2 : (h >= 860 ? 1 : 0);

    final marge = (w * 0.08).clamp(16.0, 40.0);
    final largeurCarte = math.min(460.0, w - 2 * marge);
    final gaucheCarte = (w - largeurCarte) / 2;

    // Sans barre d'etat (navigateur, ordinateur), la marque garderait tout de
    // meme la respiration qu'elle a sous l'heure et les icones du telephone.
    var hautMarque =
        math.max(systeme.top, 20.0) + const [12.0, 18.0, 24.0][niveau];
    final hauteurMarque = niveau == 0 ? 96.0 : 112.0;
    var hautCarte =
        hautMarque + hauteurMarque + const [16.0, 22.0, 28.0][niveau];

    final brouillon = _Gabarit._(
      ecran: ecran,
      niveau: niveau,
      largeurCarte: largeurCarte,
      gaucheCarte: gaucheCarte,
      hautCarte: hautCarte,
      hautMarque: hautMarque,
      gaucheMarque: 0,
    );

    // Sur un ecran haut (tablette en portrait), la composition collee en haut
    // laissait un tiers de page vide sous la carte. Une partie du surplus
    // descend l'ensemble : le bandeau s'agrandit, comme dans la maquette ou
    // la carte ne commence qu'au quart de l'ecran.
    final surplus = h - brouillon.hauteurPage;
    if (surplus > 0) {
      final decalage = math.min(surplus * 0.4, h * 0.1);
      hautMarque += decalage;
      hautCarte += decalage;
    }

    return _Gabarit._(
      ecran: ecran,
      niveau: niveau,
      largeurCarte: largeurCarte,
      gaucheCarte: gaucheCarte,
      hautCarte: hautCarte,
      hautMarque: hautMarque,
      // Dans la maquette, la marque commence a un dixieme de la carte, en
      // retrait de son bord : elle appartient au bandeau, pas a la carte.
      gaucheMarque: gaucheCarte + largeurCarte * 0.095,
    );
  }

  final Size ecran;
  final int niveau;
  final double largeurCarte;
  final double gaucheCarte;
  final double hautCarte;
  final double hautMarque;
  final double gaucheMarque;

  /// Hauteur de la page en mode PIN, sans le decalage des grands ecrans.
  double get hauteurPage {
    final interieur = largeurCarte - 2 * paddingCarte;
    final hauteurCase = (interieur * 0.148).clamp(46.0, 62.0) * 0.92;
    final pave = 4 * hauteurTouche + 3 * ecartTouches;
    final carte =
        2 * paddingCarteVertical +
        104 + // pastille, libelle et champ du code agent
        espace +
        cibleTactile +
        6 + // selecteur
        espace +
        AtriumSpacing.xxs +
        hauteurCase +
        AtriumSpacing.sm +
        22 + // ligne d'aide
        espace -
        AtriumSpacing.xxs +
        pave;
    return hautCarte + carte + espaceBas + 4 + margeBas;
  }

  double get paddingCarte => (largeurCarte * 0.058).clamp(16.0, 26.0);
  double get paddingCarteVertical => const [16.0, 20.0, 24.0][niveau];
  double get espace => const [12.0, 16.0, 20.0][niveau];
  double get hauteurTouche => const [48.0, 54.0, 58.0][niveau];
  double get ecartTouches => niveau == 0 ? AtriumSpacing.xs : AtriumSpacing.sm;

  double get tailleEmbleme => niveau == 0 ? 48 : 56;
  double get tailleNom => niveau == 0 ? 30 : 36;
  double get tailleSousTitre => niveau == 0 ? 15 : 17;

  double get espaceBas => const [14.0, 18.0, 22.0][niveau];
  double get margeBas => const [20.0, 24.0, 28.0][niveau];
  double get largeurBarreBas => (ecran.width * 0.208).clamp(64.0, 120.0);

  // --- Geometrie des rubans et du bandeau ----------------------------------
  //
  // Dans la maquette, les rubans naissent dans le coin haut gauche et se
  // rejoignent en une pointe cachee sous le coin de la carte (x = 165,
  // y = 347 sur 1024 de large, la carte commencant a y = 352). Les points
  // ci-dessous sont ceux de la maquette, remis a l'echelle pour que la pointe
  // tombe toujours sous le coin de la carte, quelle que soit sa position.

  Offset get pointe =>
      Offset(gaucheCarte + largeurCarte * 0.077, hautCarte - 4);

  /// Point de la maquette vers l'ecran, pour la zone des rubans.
  Offset m(double x, double y) =>
      Offset(x * pointe.dx / 165, y * pointe.dy / 347);

  /// Bas du bandeau cote droit, sous la carte : le bandeau descend en pente
  /// douce de la pointe des rubans vers la droite.
  double get basBandeau => hautCarte * 1.335;
}

/// Les intervalles de la sequence d'entree, crees une fois.
class _Phases {
  _Phases(AnimationController c)
    : photo = CurvedAnimation(
        parent: c,
        curve: const Interval(0, 0.85, curve: Curves.easeOutCubic),
      ),
      rubans = CurvedAnimation(
        parent: c,
        curve: const Interval(0.05, 0.5, curve: Curves.easeInOutCubic),
      ),
      vagues = CurvedAnimation(
        parent: c,
        curve: const Interval(0.2, 0.65, curve: Curves.easeOutCubic),
      ),
      embleme = CurvedAnimation(
        parent: c,
        curve: const Interval(0.15, 0.5, curve: Curves.easeOutBack),
      ),
      nom = CurvedAnimation(
        parent: c,
        curve: const Interval(0.25, 0.6, curve: Curves.easeOutCubic),
      ),
      point = CurvedAnimation(
        parent: c,
        curve: const Interval(0.55, 0.9, curve: Curves.bounceOut),
      ),
      devise = CurvedAnimation(
        parent: c,
        curve: const Interval(0.4, 0.75, curve: Curves.easeOut),
      ),
      barres = CurvedAnimation(
        parent: c,
        curve: const Interval(0.6, 1, curve: Curves.easeOutCubic),
      ),
      carte = CurvedAnimation(
        parent: c,
        curve: const Interval(0.3, 0.8, curve: Curves.easeOutCubic),
      );

  final CurvedAnimation photo;
  final CurvedAnimation rubans;
  final CurvedAnimation vagues;
  final CurvedAnimation embleme;
  final CurvedAnimation nom;
  final CurvedAnimation point;
  final CurvedAnimation devise;
  final CurvedAnimation barres;
  final CurvedAnimation carte;

  void dispose() {
    for (final a in [
      photo,
      rubans,
      vagues,
      embleme,
      nom,
      point,
      devise,
      barres,
      carte,
    ]) {
      a.dispose();
    }
  }
}

// --- Decor -------------------------------------------------------------------

/// Tout ce qui est derriere la carte : le bandeau et sa photo, les rubans, les
/// vagues du bas. Purement decoratif, donc exclu du lecteur d'ecran.
class _Decor extends StatelessWidget {
  const _Decor({required this.g, required this.phases});

  final _Gabarit g;
  final _Phases phases;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          right: 0,
          height: g.basBandeau + 2,
          child: ClipPath(
            clipper: _FormeBandeau(g),
            child: _Bandeau(g: g, animation: phases.photo),
          ),
        ),
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(painter: _Rubans(g, phases.rubans)),
          ),
        ),
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(painter: _Vagues(g, phases.vagues)),
          ),
        ),
      ],
    );
  }
}

/// Le bandeau : la nuit a gauche, la chambre qui s'ouvre a droite.
class _Bandeau extends StatelessWidget {
  const _Bandeau({required this.g, required this.animation});

  final _Gabarit g;
  final Animation<double> animation;

  static final _zoom = Tween<double>(begin: 1.12, end: 1);

  @override
  Widget build(BuildContext context) {
    final w = g.ecran.width;
    // La photo couvre au moins les trois quarts droits du bandeau : sur un
    // ecran large, etiree sur toute la largeur, elle ne montrerait plus qu'une
    // bande de rideau.
    final largeurPhoto = math.max(w * 0.78, g.basBandeau * 1.5);
    final nuit = AtriumColors.purpleNight;

    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AtriumColors.purpleNight, AtriumColors.purpleDeep],
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: largeurPhoto,
          child: FadeTransition(
            opacity: animation,
            // La chambre se pose : un recul lent, comme une camera qui
            // s'eloigne, joue une seule fois a l'arrivee.
            child: ScaleTransition(
              scale: _zoom.animate(animation),
              alignment: const Alignment(0.5, 0),
              child: Image.asset(
                _photoChambre,
                fit: BoxFit.cover,
                // Si le decodage est plus lent que l'entree (premier
                // lancement), la chambre apparait en fondu, pas d'un bloc.
                frameBuilder: (context, enfant, image, synchrone) => synchrone
                    ? enfant
                    : AnimatedOpacity(
                        opacity: image == null ? 0 : 1,
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeOut,
                        child: enfant,
                      ),
                alignment: const Alignment(0.4, 0.1),
                color: AtriumColors.photoTint,
                colorBlendMode: BlendMode.multiply,
                filterQuality: FilterQuality.medium,
                excludeFromSemantics: true,
              ),
            ),
          ),
        ),
        // La nuit mange la photo par la gauche, la ou se pose la marque : le
        // blanc du nom doit se lire sur un fond uni, pas sur un rideau.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                nuit,
                nuit.withValues(alpha: 0.94),
                nuit.withValues(alpha: 0.55),
                AtriumColors.purple.withValues(alpha: 0.18),
                AtriumColors.purple.withValues(alpha: 0.10),
              ],
              stops: const [0, 0.28, 0.52, 0.8, 1],
            ),
          ),
        ),
        // Et par le haut, sous la barre d'etat.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                nuit.withValues(alpha: 0.55),
                nuit.withValues(alpha: 0),
                nuit.withValues(alpha: 0),
                AtriumColors.purple.withValues(alpha: 0.30),
              ],
              stops: const [0, 0.3, 0.7, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// La silhouette du bandeau : le bord gauche suit le bas du ruban violet, le
/// bas descend en pente douce vers la droite, sous la carte.
class _FormeBandeau extends CustomClipper<Path> {
  const _FormeBandeau(this.g);

  final _Gabarit g;

  @override
  Path getClip(Size taille) {
    final w = taille.width;
    final p = g.pointe;
    final bas = g.basBandeau;
    final gauche = g.m(0, 305);
    return Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w, bas)
      ..cubicTo(
        p.dx + (w - p.dx) * 0.6,
        bas * 0.99,
        p.dx + (w - p.dx) * 0.2,
        p.dy + (bas - p.dy) * 0.25,
        p.dx,
        p.dy,
      )
      ..cubicTo(
        g.m(120, 335).dx,
        g.m(120, 335).dy,
        g.m(60, 322).dx,
        g.m(60, 322).dy,
        gauche.dx,
        gauche.dy,
      )
      ..close();
  }

  @override
  bool shouldReclip(_FormeBandeau ancien) =>
      ancien.g.pointe != g.pointe || ancien.g.basBandeau != g.basBandeau;
}

/// Les deux rubans du coin haut gauche : la menthe dessus, le violet dessous.
/// Ils se revelent depuis le coin, comme s'ils glissaient vers la carte.
class _Rubans extends CustomPainter {
  _Rubans(this.g, this.progres) : super(repaint: progres);

  final _Gabarit g;
  final Animation<double> progres;

  @override
  void paint(Canvas canvas, Size taille) {
    final t = progres.value;
    if (t <= 0) return;

    Offset m(double x, double y) => g.m(x, y);
    final p = g.pointe;

    canvas.save();
    // Revelation en quart de cercle depuis le coin : les rubans « poussent »
    // vers la pointe au lieu d'apparaitre d'un bloc.
    final portee = p.distance * 1.15 * t;
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: portee)),
    );

    final violet = Path()
      ..moveTo(0, m(0, 210).dy)
      ..cubicTo(
        m(50, 240).dx,
        m(50, 240).dy,
        m(110, 300).dx,
        m(110, 300).dy,
        p.dx,
        p.dy,
      )
      ..cubicTo(
        m(120, 335).dx,
        m(120, 335).dy,
        m(60, 322).dx,
        m(60, 322).dy,
        0,
        m(0, 305).dy,
      )
      ..close();
    canvas.drawPath(
      violet,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AtriumColors.purple, AtriumColors.purpleDeep],
        ).createShader(violet.getBounds()),
    );

    final menthe = Path()
      ..moveTo(0, 0)
      ..lineTo(m(37, 0).dx, 0)
      ..cubicTo(
        m(40, 110).dx,
        m(40, 110).dy,
        m(70, 230).dx,
        m(70, 230).dy,
        p.dx,
        p.dy,
      )
      ..cubicTo(
        m(110, 300).dx,
        m(110, 300).dy,
        m(50, 240).dx,
        m(50, 240).dy,
        0,
        m(0, 210).dy,
      )
      ..close();
    canvas.drawPath(
      menthe,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AtriumColors.mint,
            Color.lerp(AtriumColors.mint, AtriumColors.mintStrong, 0.25)!,
          ],
        ).createShader(menthe.getBounds()),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Rubans ancien) =>
      ancien.g.pointe != g.pointe || ancien.progres != progres;
}

/// Les vagues des coins bas : violet a gauche, menthe puis violet a droite.
class _Vagues extends CustomPainter {
  _Vagues(this.g, this.progres) : super(repaint: progres);

  final _Gabarit g;
  final Animation<double> progres;

  @override
  void paint(Canvas canvas, Size taille) {
    final t = progres.value;
    if (t <= 0) return;

    final w = taille.width;
    final h = taille.height;
    // Meme echelle que la maquette, plafonnee : sur un ecran de bureau, des
    // vagues a l'echelle de la largeur envahiraient la moitie de la page.
    final s = math.min(w / 1024, h / 1100);
    // Elles montent du bas de l'ecran a l'arrivee.
    final monte = (1 - t) * 60 * s;
    Offset b(double x, double y) => Offset(x * s, h + y * s + monte);
    Offset d(double x, double y) =>
        Offset(w - (1024 - x) * s, h + y * s + monte);

    final gauche = Path()
      ..moveTo(0, b(0, -166).dy)
      ..cubicTo(
        b(140, -150).dx,
        b(140, -150).dy,
        b(260, -95).dx,
        b(260, -95).dy,
        b(370, 0).dx,
        h,
      )
      ..lineTo(0, h)
      ..close();

    final menthe = Path()
      ..moveTo(w, d(1024, -191).dy)
      ..cubicTo(
        d(930, -150).dx,
        d(930, -150).dy,
        d(820, -75).dx,
        d(820, -75).dy,
        d(715, 0).dx,
        h,
      )
      ..lineTo(w, h)
      ..close();

    final coin = Path()
      ..moveTo(w, d(1024, -90).dy)
      ..cubicTo(
        d(985, -60).dx,
        d(985, -60).dy,
        d(930, -25).dx,
        d(930, -25).dy,
        d(880, 0).dx,
        h,
      )
      ..lineTo(w, h)
      ..close();

    final opacite = t.clamp(0.0, 1.0);
    Paint peinture(Path forme, List<Color> couleurs) =>
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [for (final c in couleurs) c.withValues(alpha: opacite)],
          ).createShader(forme.getBounds());

    canvas.drawPath(
      gauche,
      peinture(gauche, const [AtriumColors.purple, AtriumColors.purpleBright]),
    );
    canvas.drawPath(
      menthe,
      peinture(menthe, [
        AtriumColors.mint,
        Color.lerp(AtriumColors.mint, AtriumColors.mintStrong, 0.3)!,
      ]),
    );
    canvas.drawPath(
      coin,
      peinture(coin, const [AtriumColors.purple, AtriumColors.purpleNight]),
    );
  }

  @override
  bool shouldRepaint(_Vagues ancien) => ancien.progres != progres;
}

// --- Marque ------------------------------------------------------------------

/// L'embleme, le nom, le sous-titre, la devise et son filet menthe.
class _Marque extends StatelessWidget {
  const _Marque({required this.g, required this.phases});

  final _Gabarit g;
  final _Phases phases;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      label: 'Atrium, Hotel Atrium. Votre séjour, notre priorité.',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ScaleTransition(
                  scale: phases.embleme,
                  child: FadeTransition(
                    opacity: phases.embleme,
                    child: _Embleme(taille: g.tailleEmbleme),
                  ),
                ),
                SizedBox(width: g.niveau == 0 ? 14 : 18),
                FadeTransition(
                  opacity: phases.nom,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Nom(taille: g.tailleNom, chute: phases.point),
                      const SizedBox(height: 2),
                      Text(
                        'Hotel Atrium',
                        style: TextStyle(
                          fontSize: g.tailleSousTitre,
                          height: 1.25,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 1.2,
                          color: AtriumColors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: g.niveau == 0 ? 12 : 16),
            FadeTransition(
              opacity: phases.devise,
              child: const Text(
                'Votre séjour, notre priorité',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 2.1,
                  color: AtriumColors.onPurpleSoft,
                ),
              ),
            ),
            SizedBox(height: g.niveau == 0 ? 8 : 10),
            _BarreMenthe(animation: phases.barres, largeur: 28, alignee: true),
          ],
        ),
      ),
    );
  }
}

/// « Atrium », dont le point du i est une goutte menthe.
///
/// Le i est remplace par un i sans point (ı), et le point est pose par-dessus :
/// c'est ce qui permet de le colorer, de le grossir, et de le faire tomber a
/// l'arrivee de la page.
class _Nom extends StatelessWidget {
  const _Nom({required this.taille, required this.chute});

  final double taille;
  final Animation<double> chute;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: taille,
      height: 1.1,
      fontWeight: FontWeight.w600,
      color: AtriumColors.white,
    );
    final diametre = taille * 0.27;

    return Text.rich(
      TextSpan(
        style: style,
        children: [
          const TextSpan(text: 'Atr'),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Text('ı', style: style),
                Positioned(
                  left: 0,
                  right: 0,
                  top: taille * 0.005,
                  child: Center(
                    child: AnimatedBuilder(
                      animation: chute,
                      builder: (context, enfant) => Opacity(
                        opacity: chute.value.clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(0, -taille * 0.7 * (1 - chute.value)),
                          child: enfant,
                        ),
                      ),
                      child: Container(
                        width: diametre,
                        height: diametre,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AtriumColors.mintStrong,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const TextSpan(text: 'um'),
        ],
      ),
    );
  }
}

/// Le lit d'Atrium dans son ecrin violet cercle de menthe.
///
/// Le projet n'a pas de logo dessine : c'est l'icone qu'employait deja
/// l'ecran de connexion, reprise telle quelle.
class _Embleme extends StatelessWidget {
  const _Embleme({required this.taille});

  final double taille;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AtriumColors.purpleBright, AtriumColors.purple],
        ),
        borderRadius: BorderRadius.circular(taille * 0.26),
        border: Border.all(
          color: AtriumColors.mintStrong.withValues(alpha: 0.85),
          width: 1.5,
        ),
        boxShadow: AtriumShadows.emblem,
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.hotel_rounded,
        size: taille * 0.62,
        color: AtriumColors.mint,
      ),
    );
  }
}

/// Filet menthe arrondi, sous la devise et sous la carte. Il s'etire depuis
/// son centre (ou depuis la gauche sous la devise) a l'arrivee de la page.
class _BarreMenthe extends StatelessWidget {
  const _BarreMenthe({
    required this.animation,
    required this.largeur,
    this.alignee = false,
  });

  final Animation<double> animation;
  final double largeur;

  /// Vrai sous la devise : le filet part de la gauche, comme le texte.
  final bool alignee;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: largeur,
      height: 4,
      child: Align(
        alignment: alignee ? Alignment.centerLeft : Alignment.center,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) => Container(
            width: largeur * animation.value.clamp(0.0, 1.0),
            height: 4,
            decoration: BoxDecoration(
              color: AtriumColors.mintStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

/// La carte monte de quelques points en apparaissant.
class _Monte extends StatelessWidget {
  const _Monte({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, enfant) => Transform.translate(
        offset: Offset(0, 28 * (1 - animation.value)),
        child: Opacity(opacity: animation.value.clamp(0.0, 1.0), child: enfant),
      ),
    );
  }
}

// --- Petits elements ---------------------------------------------------------

/// La ligne sous les cases du PIN : aide, attente ou refus.
class _Statut extends StatelessWidget {
  const _Statut._(this.texte, this.couleur, this.icone, {this.attente = false});

  const _Statut.aide(String texte)
    : this._(texte, AtriumColors.textSecondary, null);

  const _Statut.attente(String texte)
    : this._(texte, AtriumColors.purple, null, attente: true);

  const _Statut.erreur(String texte)
    : this._(texte, AtriumColors.error, Icons.error_outline_rounded);

  final String texte;
  final Color couleur;
  final IconData? icone;
  final bool attente;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: icone != null,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (attente)
            const Padding(
              padding: EdgeInsets.only(right: AtriumSpacing.xs),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AtriumColors.mintStrong,
                ),
              ),
            ),
          if (icone != null)
            Padding(
              padding: const EdgeInsets.only(right: AtriumSpacing.xs - 2),
              child: Icon(icone, size: 17, color: couleur),
            ),
          Flexible(
            child: Text(
              texte,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: icone != null ? FontWeight.w600 : FontWeight.w500,
                color: couleur,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
