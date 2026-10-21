/// « Code oublié ? » : un responsable débloque l'agent sur place (21 octobre).
///
/// Deux temps, dans l'ordre où ils se passent au comptoir : l'agent dit qui
/// il est et choisit son nouveau code, puis va chercher un responsable, qui
/// tape le sien. La fenêtre marche hors ligne
/// (`ReinitialisationRepository`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import '../../data/repositories/repository_providers.dart';
import 'pin_input.dart';

/// Ce que l'agent remplace.
enum _Remplace { pin, motDePasse, lesDeux }

/// Ouvre la fenêtre. Rend le code agent réinitialisé, `null` si l'agent
/// renonce.
Future<String?> demanderCodeOublie(BuildContext context, {String? codeAgent}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FenetreCodeOublie(codeAgent: codeAgent),
  );
}

class _FenetreCodeOublie extends ConsumerStatefulWidget {
  const _FenetreCodeOublie({this.codeAgent});

  final String? codeAgent;

  @override
  ConsumerState<_FenetreCodeOublie> createState() => _FenetreCodeOublieState();
}

class _FenetreCodeOublieState extends ConsumerState<_FenetreCodeOublie> {
  /// La longueur du pavé de connexion : un PIN plus long ne s'y taperait pas.
  static const _longueurPin = 4;

  late final _codeAgent = TextEditingController(text: widget.codeAgent);
  final _pin = TextEditingController();
  final _pinBis = TextEditingController();
  final _motDePasse = TextEditingController();
  final _motDePasseBis = TextEditingController();
  final _codeResponsable = TextEditingController();
  String _pinResponsable = '';

  _Remplace _remplace = _Remplace.pin;

  /// Second temps : le responsable valide.
  bool _auResponsable = false;
  bool _verification = false;
  String? _erreur;

  @override
  void dispose() {
    for (final c in [
      _codeAgent,
      _pin,
      _pinBis,
      _motDePasse,
      _motDePasseBis,
      _codeResponsable,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _pinVoulu => _remplace != _Remplace.motDePasse;
  bool get _motDePasseVoulu => _remplace != _Remplace.pin;

  /// Ce qui empêche de passer au responsable, ou `null`.
  String? get _defautDuNouveauCode {
    if (_codeAgent.text.trim().isEmpty) return 'Votre code agent.';
    if (_pinVoulu) {
      if (!RegExp(r'^\d{4}$').hasMatch(_pin.text)) {
        return 'Le code PIN compte 4 chiffres.';
      }
      if (_pin.text != _pinBis.text) return 'Les deux codes PIN diffèrent.';
    }
    if (_motDePasseVoulu) {
      if (_motDePasse.text.length < 8) {
        return 'Le mot de passe compte au moins 8 caractères.';
      }
      if (_motDePasse.text != _motDePasseBis.text) {
        return 'Les deux mots de passe diffèrent.';
      }
    }
    return null;
  }

  void _versResponsable() {
    final defaut = _defautDuNouveauCode;
    setState(() {
      _erreur = defaut;
      _auResponsable = defaut == null;
    });
  }

  Future<void> _valider() async {
    if (_verification ||
        _codeResponsable.text.trim().isEmpty ||
        _pinResponsable.length != _longueurPin) {
      return;
    }
    setState(() {
      _verification = true;
      _erreur = null;
    });
    try {
      await ref
          .read(reinitialisationRepositoryProvider)
          .reinitialiser(
            codeAgent: _codeAgent.text,
            codeResponsable: _codeResponsable.text,
            secretResponsable: _pinResponsable,
            nouveauPin: _pinVoulu ? _pin.text : null,
            nouveauMotDePasse: _motDePasseVoulu ? _motDePasse.text : null,
          );
      if (!mounted) return;
      Navigator.of(context).pop(_codeAgent.text.trim().toUpperCase());
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() {
        _verification = false;
        _erreur = e.message;
        _pinResponsable = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Un Dialog et non un AlertDialog : les cases du PIN reposent sur un
    // LayoutBuilder, qu'un AlertDialog ne sait pas mesurer.
    final titre = Theme.of(context).textTheme.headlineSmall;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 468),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                PhosphorIconsLight.password,
                size: 32,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(height: 16),
              Text(
                _auResponsable ? 'Un responsable valide' : 'Code oublié',
                textAlign: TextAlign.center,
                style: titre,
              ),
              const SizedBox(height: 16),
              if (_auResponsable) _responsable(context) else _nouveauCode(),
              if (_erreur != null) ...[
                const SizedBox(height: 8),
                Text(
                  _erreur!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _actions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nouveauCode() {
    void effacer(String _) => setState(() => _erreur = null);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Choisissez votre nouveau code, puis allez chercher un responsable : '
          'il le validera avec le sien.',
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeAgent,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Votre code agent'),
          onChanged: effacer,
        ),
        const SizedBox(height: 16),
        SegmentedButton<_Remplace>(
          segments: const [
            ButtonSegment(value: _Remplace.pin, label: Text('Code PIN')),
            ButtonSegment(
              value: _Remplace.motDePasse,
              label: Text('Mot de passe'),
            ),
            ButtonSegment(value: _Remplace.lesDeux, label: Text('Les deux')),
          ],
          selected: {_remplace},
          onSelectionChanged: (s) => setState(() {
            _remplace = s.first;
            _erreur = null;
          }),
        ),
        if (_pinVoulu) ...[
          const SizedBox(height: 16),
          _champ(
            _pin,
            'Nouveau code PIN (4 chiffres)',
            pin: true,
            onChanged: effacer,
          ),
          const SizedBox(height: 12),
          _champ(_pinBis, 'Encore une fois', pin: true, onChanged: effacer),
        ],
        if (_motDePasseVoulu) ...[
          const SizedBox(height: 16),
          _champ(
            _motDePasse,
            'Nouveau mot de passe (8 caractères ou plus)',
            onChanged: effacer,
          ),
          const SizedBox(height: 12),
          _champ(_motDePasseBis, 'Encore une fois', onChanged: effacer),
        ],
      ],
    );
  }

  Widget _champ(
    TextEditingController c,
    String libelle, {
    bool pin = false,
    required ValueChanged<String> onChanged,
  }) => TextField(
    controller: c,
    obscureText: true,
    keyboardType: pin ? TextInputType.number : TextInputType.visiblePassword,
    maxLength: pin ? _longueurPin : null,
    decoration: InputDecoration(labelText: libelle, counterText: ''),
    onChanged: onChanged,
  );

  Widget _responsable(BuildContext context) {
    final p = AtriumPalette.current;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.accentSoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            'Le code de ${_codeAgent.text.trim().toUpperCase()} sera remplacé '
            'et son compte débloqué. Un responsable saisit son propre code.',
            style: TextStyle(fontSize: 14, color: p.text),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeResponsable,
          enabled: !_verification,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Code agent du responsable',
            hintText: 'ADMIN01',
          ),
          onChanged: (_) => setState(() => _erreur = null),
        ),
        const SizedBox(height: 16),
        Text(
          'Son code PIN',
          style: TextStyle(fontSize: 14, color: p.textSecondary),
        ),
        const SizedBox(height: 8),
        PinCells(
          filled: _pinResponsable.length,
          length: _longueurPin,
          error: _erreur != null,
          busy: _verification,
        ),
        const SizedBox(height: 12),
        PinKeypad(
          enabled: !_verification,
          keyHeight: 52,
          onDigit: (c) {
            if (_pinResponsable.length >= _longueurPin) return;
            setState(() {
              _pinResponsable += c;
              _erreur = null;
            });
          },
          onDelete: () {
            if (_pinResponsable.isEmpty) return;
            setState(
              () => _pinResponsable = _pinResponsable.substring(
                0,
                _pinResponsable.length - 1,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        TextButton(
          onPressed: _verification
              ? null
              : _auResponsable
              ? () => setState(() {
                  _auResponsable = false;
                  _erreur = null;
                  _pinResponsable = '';
                })
              : () => Navigator.of(context).pop(),
          child: Text(_auResponsable ? 'Retour' : 'Renoncer'),
        ),
        if (_auResponsable)
          FilledButton(
            onPressed:
                !_verification &&
                    _codeResponsable.text.trim().isNotEmpty &&
                    _pinResponsable.length == _longueurPin
                ? _valider
                : null,
            child: Text(_verification ? 'Vérification…' : 'Valider'),
          )
        else
          FilledButton(
            onPressed: _versResponsable,
            child: const Text('Appeler un responsable'),
          ),
      ],
    );
  }
}
