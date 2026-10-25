/// Le PIN passe a 6 chiffres : l'agent connecte avec un ancien code de 4 en
/// choisit un nouveau avant d'aller plus loin (decision du 25 octobre).
///
/// Le routeur n'ouvre que cet ecran tant que `SessionState.pinAChanger` est
/// vrai. Le nouveau code se tape deux fois ; il part au serveur, ou dans la
/// file hors ligne (`ReinitialisationRepository.changerPin`). L'agent peut
/// aussi se deconnecter : il retrouvera cet ecran a sa prochaine connexion.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import 'pin_input.dart';
import 'session.dart';

class NouveauCodeScreen extends ConsumerStatefulWidget {
  const NouveauCodeScreen({super.key});

  @override
  ConsumerState<NouveauCodeScreen> createState() => _NouveauCodeScreenState();
}

class _NouveauCodeScreenState extends ConsumerState<NouveauCodeScreen> {
  String _saisie = '';

  /// Le code de la premiere saisie, en attente de sa confirmation.
  String? _premier;
  bool _envoi = false;
  String? _erreur;

  void _chiffre(String c) {
    if (_envoi || _saisie.length >= longueurPin) return;
    HapticFeedback.selectionClick();
    setState(() {
      _saisie += c;
      _erreur = null;
    });
    if (_saisie.length == longueurPin) _suite();
  }

  void _effacer() {
    if (_envoi || _saisie.isEmpty) return;
    setState(() => _saisie = _saisie.substring(0, _saisie.length - 1));
  }

  Future<void> _suite() async {
    final premier = _premier;
    if (premier == null) {
      setState(() {
        _premier = _saisie;
        _saisie = '';
      });
      return;
    }
    if (premier != _saisie) {
      HapticFeedback.mediumImpact();
      setState(() {
        _premier = null;
        _saisie = '';
        _erreur = 'Les deux codes diffèrent. Recommencez.';
      });
      return;
    }
    setState(() => _envoi = true);
    try {
      // Le routeur quitte l'ecran tout seul quand la session n'a plus de
      // code a changer.
      await ref.read(sessionProvider.notifier).changerPin(_saisie);
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() {
        _envoi = false;
        _premier = null;
        _saisie = '';
        _erreur = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final session = ref.watch(sessionProvider);
    final confirmation = _premier != null;
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(PhosphorIconsLight.lockSimple, size: 40, color: p.accent),
                  const SizedBox(height: 16),
                  Text(
                    confirmation
                        ? 'Encore une fois'
                        : 'Votre code passe à 6 chiffres',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    confirmation
                        ? 'Retapez votre nouveau code pour le confirmer.'
                        : '${session.nomAffiche}, choisissez un nouveau code '
                              'PIN de 6 chiffres. Il remplace votre code à 4 '
                              'chiffres sur toutes les tablettes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, color: p.textSecondary),
                  ),
                  const SizedBox(height: 24),
                  PinCells(
                    filled: _saisie.length,
                    length: longueurPin,
                    error: _erreur != null,
                    busy: _envoi,
                  ),
                  SizedBox(
                    height: 40,
                    child: Center(
                      child: Text(
                        _envoi ? 'Enregistrement…' : (_erreur ?? ''),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: _erreur != null
                              ? Theme.of(context).colorScheme.error
                              : p.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  PinKeypad(
                    enabled: !_envoi,
                    onDigit: _chiffre,
                    onDelete: _effacer,
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _envoi
                        ? null
                        : () => ref.read(sessionProvider.notifier).deconnecter(),
                    child: const Text('Plus tard : se déconnecter'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
