/// Connexion : le premier ecran de la journee, et de chaque releve.
///
/// Meme parcours qu'avant, entierement redessine :
///
/// - le code agent, puis le **PIN a quatre chiffres** qui part tout seul au
///   quatrieme, ou le **mot de passe** ;
/// - un refus fait trembler le champ en cause et vibrer la tablette, avec un
///   message precis (code inconnu, compte desactive, verrouille, serveur
///   injoignable et agent inconnu de cette tablette) ;
/// - la connexion marche hors ligne comme en ligne (voir `session.dart`).
///
/// Mise en page : sur tablette et PC, un panneau de marque a gauche (la
/// chambre, voilee de nuit, l'arche, l'heure) et le formulaire a droite ; sur
/// telephone, un bandeau de marque puis le formulaire.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/brand/atrium_logo.dart';
import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../core/widgets/shake.dart';
import '../../data/repositories/auth_repository.dart';
import 'session.dart';

const _photoChambre = 'assets/images/chambre.jpg';

enum _Voie { pin, motDePasse }

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _codeAgent = TextEditingController(text: 'ADMIN01');
  final _motDePasse = TextEditingController();
  String _pin = '';
  _Voie _voie = _Voie.pin;
  bool _motDePasseVisible = false;

  /// Compteurs de refus : chaque increment rejoue la secousse du champ
  /// fautif. Deux compteurs, pour que ce soit le code agent qui tremble quand
  /// c'est lui qui est en cause, et le secret sinon.
  int _refusAgent = 0;
  int _refusSecret = 0;

  static const _longueurPin = 4;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    precacheImage(const AssetImage(_photoChambre), context);
  }

  @override
  void dispose() {
    _codeAgent.dispose();
    _motDePasse.dispose();
    super.dispose();
  }

  void _chiffre(String c) {
    if (_pin.length >= _longueurPin) return;
    HapticFeedback.selectionClick();
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

  String _messageEchec(LoginFailure echec) => switch (echec) {
    LoginFailure.unknownUser => 'Code agent inconnu.',
    LoginFailure.disabledAccount => 'Ce compte est désactivé.',
    LoginFailure.locked =>
      'Compte verrouillé après cinq échecs. Réessayez dans quinze minutes.',
    LoginFailure.wrongSecret =>
      _voie == _Voie.pin ? 'Code incorrect.' : 'Mot de passe incorrect.',
    // Propre au hors connexion : le serveur ne repond pas, et cet agent ne
    // s'est jamais connecte sur cette tablette. Le dire, plutot que de
    // laisser croire a un mauvais secret.
    LoginFailure.offlineAndUnknown =>
      'Serveur injoignable, et cet agent est inconnu de cette tablette.',
  };

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

    final formulaire = _formulaire(session);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: AtriumColors.background,
        body: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth >= 900) {
              return Row(
                children: [
                  const Expanded(
                    flex: 11,
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: _PanneauMarque(),
                    ),
                  ),
                  Expanded(
                    flex: 9,
                    child: AmbientBackground(
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 40,
                            vertical: 32,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 440),
                            child: formulaire,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }
            return AmbientBackground(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
                ),
                child: Column(
                  children: [
                    const SizedBox(
                      height: 250,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(10, 10, 10, 0),
                        child: _PanneauMarque(compact: true),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: formulaire,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _formulaire(SessionState session) {
    final echec = session.echec;
    final echecAgent = echec != null && echec != LoginFailure.wrongSecret
        ? _messageEchec(echec)
        : null;
    final echecSecret = echec == LoginFailure.wrongSecret
        ? _messageEchec(echec!)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeUp(
          child: Text(
            'Prendre son service',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.2,
              height: 1.05,
              color: AtriumColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 8),
        FadeUp(
          index: 1,
          child: Text(
            _voie == _Voie.pin
                ? 'Votre code agent, puis votre code PIN.'
                : 'Votre code agent, puis votre mot de passe.',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 15.5,
              color: AtriumColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: 26),
        FadeUp(
          index: 2,
          child: Bezel(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Shake(
                  trigger: _refusAgent,
                  child: _ChampCodeAgent(
                    controller: _codeAgent,
                    erreur: echecAgent,
                  ),
                ),
                const SizedBox(height: 16),
                _Bascule(voie: _voie, onChanged: _changerDeVoie),
                const SizedBox(height: 20),
                AnimatedSize(
                  duration: AtriumMotion.of(
                    context,
                    const Duration(milliseconds: 420),
                  ),
                  curve: atriumSpring,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: AtriumMotion.of(
                      context,
                      const Duration(milliseconds: 320),
                    ),
                    switchInCurve: atriumSpring,
                    layoutBuilder: (actuel, precedents) => Stack(
                      alignment: Alignment.topCenter,
                      children: [...precedents, ?actuel],
                    ),
                    child: _voie == _Voie.pin
                        ? KeyedSubtree(
                            key: const ValueKey(_Voie.pin),
                            child: _saisiePin(session, echecSecret),
                          )
                        : KeyedSubtree(
                            key: const ValueKey(_Voie.motDePasse),
                            child: _saisieMotDePasse(session, echecSecret),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _saisiePin(SessionState session, String? echecSecret) {
    // L'erreur s'efface des que l'agent retape : elle concernait le code
    // precedent, pas celui qu'il est en train de saisir.
    final refuse = echecSecret != null && _pin.isEmpty;

    final (IconData? icone, String texte, Color couleur) = refuse
        ? (PhosphorIconsLight.warningCircle, echecSecret, AtriumColors.error)
        : session.enCours
        ? (null, 'Vérification…', AtriumColors.textSecondary)
        // Pas de bouton en mode PIN : sans cette ligne, rien ne dit a un
        // nouvel agent que la saisie part toute seule.
        : (
            null,
            'Vérifié dès le quatrième chiffre.',
            AtriumColors.textSecondary,
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Shake(
          trigger: _refusSecret,
          child: _Points(
            rempli: _pin.length,
            longueur: _longueurPin,
            erreur: refuse,
            attente: session.enCours,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 22,
          child: AnimatedSwitcher(
            duration: AtriumMotion.of(context, AtriumMotion.base),
            child: Row(
              key: ValueKey(texte),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icone != null) ...[
                  Icon(icone, size: 17, color: couleur),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    texte,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 13.5,
                      fontWeight: refuse ? FontWeight.w600 : FontWeight.w500,
                      color: couleur,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _Pave(
          actif: !session.enCours,
          onChiffre: _chiffre,
          onEffacer: _effacer,
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
          child: TextField(
            controller: _motDePasse,
            obscureText: !_motDePasseVisible,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _valider(),
            style: _styleSaisie,
            decoration: InputDecoration(
              labelText: 'Mot de passe',
              errorText: echecSecret,
              prefixIcon: const Icon(PhosphorIconsLight.lockSimple, size: 22),
              suffixIcon: IconButton(
                tooltip: _motDePasseVisible ? 'Masquer' : 'Afficher',
                icon: Icon(
                  _motDePasseVisible
                      ? PhosphorIconsLight.eyeSlash
                      : PhosphorIconsLight.eye,
                  size: 22,
                ),
                onPressed: () =>
                    setState(() => _motDePasseVisible = !_motDePasseVisible),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        PillButton(
          label: session.enCours ? 'Connexion…' : 'Se connecter',
          icon: PhosphorIconsLight.arrowRight,
          expand: true,
          onPressed: session.enCours ? null : _valider,
        ),
      ],
    );
  }
}

TextStyle get _styleSaisie => TextStyle(
  fontFamily: atriumFontFamily,
  fontSize: 18,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.6,
  color: AtriumColors.textPrimary,
  fontFeatures: tabularFigures,
);

class _ChampCodeAgent extends StatelessWidget {
  const _ChampCodeAgent({required this.controller, required this.erreur});

  final TextEditingController controller;
  final String? erreur;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      textCapitalization: TextCapitalization.characters,
      autocorrect: false,
      style: _styleSaisie,
      decoration: InputDecoration(
        labelText: 'Code agent',
        errorText: erreur,
        errorMaxLines: 2,
        prefixIcon: const Icon(PhosphorIconsLight.identificationCard, size: 22),
      ),
    );
  }
}

/// PIN ou mot de passe : une pilule dont l'indicateur glisse d'un choix a
/// l'autre.
class _Bascule extends StatelessWidget {
  const _Bascule({required this.voie, required this.onChanged});

  final _Voie voie;
  final ValueChanged<_Voie> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 480));
    Widget option(_Voie v, IconData icone, String libelle) {
      final actif = v == voie;
      return Expanded(
        child: Semantics(
          button: true,
          selected: actif,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(v),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icone,
                  size: 18,
                  color: actif ? p.onNight : p.textSecondary,
                ),
                const SizedBox(width: 8),
                AnimatedDefaultTextStyle(
                  duration: duree,
                  curve: atriumSpring,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: actif ? p.onNight : p.textSecondary,
                  ),
                  child: Text(libelle),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      height: 50,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.surfaceMuted,
        borderRadius: BorderRadius.circular(25),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: duree,
            curve: atriumSpring,
            alignment: voie == _Voie.pin
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.night,
                  borderRadius: BorderRadius.circular(21),
                  boxShadow: [
                    BoxShadow(
                      color: p.night.withValues(alpha: 0.3),
                      blurRadius: 12,
                      spreadRadius: -4,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Row(
              children: [
                option(_Voie.pin, PhosphorIconsLight.numpad, 'Code PIN'),
                option(
                  _Voie.motDePasse,
                  PhosphorIconsLight.password,
                  'Mot de passe',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Les quatre points du PIN : un point mangue par chiffre tape, qui gonfle a
/// son arrivee ; corail en cas de refus.
class _Points extends StatelessWidget {
  const _Points({
    required this.rempli,
    required this.longueur,
    required this.erreur,
    required this.attente,
  });

  final int rempli;
  final int longueur;
  final bool erreur;
  final bool attente;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 380));
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < longueur; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: AnimatedContainer(
              duration: duree,
              curve: atriumSpring,
              width: i < rempli ? 18 : 14,
              height: i < rempli ? 18 : 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: erreur
                    ? p.error.withValues(alpha: 0.85)
                    : (i < rempli
                          ? (attente ? p.textSecondary : p.accent)
                          : Colors.transparent),
                border: Border.all(
                  color: erreur
                      ? p.error
                      : (i < rempli ? Colors.transparent : p.placeholder),
                  width: 1.6,
                ),
                boxShadow: i < rempli && !erreur
                    ? [
                        BoxShadow(
                          color: p.accent.withValues(alpha: 0.45),
                          blurRadius: 12,
                          spreadRadius: -2,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// Le pave : douze touches en squircle, qui s'enfoncent sous le doigt.
class _Pave extends StatelessWidget {
  const _Pave({
    required this.actif,
    required this.onChiffre,
    required this.onEffacer,
  });

  final bool actif;
  final ValueChanged<String> onChiffre;
  final VoidCallback onEffacer;

  @override
  Widget build(BuildContext context) {
    Widget rangee(List<Widget> touches) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          for (var i = 0; i < touches.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(child: touches[i]),
          ],
        ],
      ),
    );
    _Touche chiffre(String c) => _Touche(
      semantique: c,
      onTap: actif ? () => onChiffre(c) : null,
      child: Text(
        c,
        style: TextStyle(
          fontFamily: atriumFontFamily,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: AtriumColors.textPrimary,
          fontFeatures: tabularFigures,
        ),
      ),
    );

    return Column(
      children: [
        rangee([chiffre('1'), chiffre('2'), chiffre('3')]),
        rangee([chiffre('4'), chiffre('5'), chiffre('6')]),
        rangee([chiffre('7'), chiffre('8'), chiffre('9')]),
        rangee([
          const SizedBox(),
          chiffre('0'),
          _Touche(
            semantique: 'Effacer',
            discrete: true,
            onTap: actif ? onEffacer : null,
            child: Icon(
              PhosphorIconsLight.backspace,
              size: 26,
              color: AtriumColors.textPrimary,
            ),
          ),
        ]),
      ],
    );
  }
}

class _Touche extends StatefulWidget {
  const _Touche({
    required this.semantique,
    required this.onTap,
    required this.child,
    this.discrete = false,
  });

  final String semantique;
  final VoidCallback? onTap;
  final Widget child;
  final bool discrete;

  @override
  State<_Touche> createState() => _ToucheState();
}

class _ToucheState extends State<_Touche> {
  bool _presse = false;
  bool _survol = false;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final duree = AtriumMotion.of(context, const Duration(milliseconds: 220));
    final fond = widget.discrete
        ? Colors.transparent
        : (_presse
              ? p.accent.withValues(alpha: 0.22)
              : (_survol ? p.surfaceMuted : p.surface));
    return Semantics(
      button: true,
      label: widget.semantique,
      child: MouseRegion(
        cursor: widget.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _survol = true),
        onExit: (_) => setState(() => _survol = false),
        child: GestureDetector(
          onTapDown: widget.onTap == null
              ? null
              : (_) => setState(() => _presse = true),
          onTapCancel: () => setState(() => _presse = false),
          onTapUp: (_) => setState(() => _presse = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _presse ? 0.94 : 1,
            duration: duree,
            curve: atriumSpring,
            child: AnimatedContainer(
              duration: duree,
              curve: atriumSpring,
              height: 60,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fond,
                borderRadius: BorderRadius.circular(20),
                border: widget.discrete
                    ? null
                    : Border.all(color: p.border.withValues(alpha: 0.7)),
              ),
              child: Opacity(
                opacity: widget.onTap == null ? 0.4 : 1,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le panneau de marque : la chambre voilee de nuit, l'arche, l'heure.
class _PanneauMarque extends StatelessWidget {
  const _PanneauMarque({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 26 : 32),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _PhotoLente(),
          // Le voile : nuit en bas et a gauche, ou se pose le texte ; la
          // chambre reste visible en haut a droite.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  Color(0x330A0F2E),
                  Color(0xE60A0F2E),
                  Color(0xFA05081A),
                ],
                stops: [0, 0.55, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(compact ? 22 : 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const FadeUp(
                  child: AtriumLockup(markSize: 46, hotelName: 'Hôtel Atrium'),
                ),
                const Spacer(),
                if (!compact) ...[
                  const FadeUp(index: 2, child: _Horloge()),
                  const SizedBox(height: 18),
                ],
                FadeUp(
                  index: 3,
                  child: Text(
                    'Chaque chambre,\nchaque client,\nsous la main.',
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: compact ? 24 : 40,
                      fontWeight: FontWeight.w800,
                      letterSpacing: compact ? -0.8 : -1.6,
                      height: 1.08,
                      color: const Color(0xFFFBF6EC),
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

/// La photo avance tres lentement : un seul mouvement ambiant, discret.
class _PhotoLente extends StatefulWidget {
  const _PhotoLente();

  @override
  State<_PhotoLente> createState() => _PhotoLenteState();
}

class _PhotoLenteState extends State<_PhotoLente>
    with SingleTickerProviderStateMixin {
  late final _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctrl.value = 0;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, enfant) => Transform.scale(
        scale: 1.04 + 0.06 * Curves.easeInOut.transform(_ctrl.value),
        child: enfant,
      ),
      child: Image.asset(_photoChambre, fit: BoxFit.cover),
    );
  }
}

/// L'heure et la date hoteliere, qui avancent toutes seules.
class _Horloge extends StatefulWidget {
  const _Horloge();

  @override
  State<_Horloge> createState() => _HorlogeState();
}

class _HorlogeState extends State<_Horloge> {
  late Timer _minuteur;
  DateTime _maintenant = DateTime.now();

  @override
  void initState() {
    super.initState();
    _minuteur = Timer.periodic(
      const Duration(seconds: 15),
      (_) => setState(() => _maintenant = DateTime.now()),
    );
  }

  @override
  void dispose() {
    _minuteur.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = _maintenant.hour.toString().padLeft(2, '0');
    final m = _maintenant.minute.toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$h:$m',
          style: const TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 72,
            height: 0.95,
            fontWeight: FontWeight.w800,
            letterSpacing: -3,
            color: Color(0xFFFFB020),
            fontFeatures: tabularFigures,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          formatLongDate(_maintenant),
          style: const TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFFC9CEE6),
          ),
        ),
      ],
    );
  }
}
