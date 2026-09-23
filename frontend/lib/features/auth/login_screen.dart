/// Ecran de connexion.
///
/// Deux voies, comme le prevoit le paragraphe 6.2 : le code agent avec un
/// pave numerique pour le PIN (l'usage courant en service, gants ou mains
/// occupees), et la saisie classique pour l'administration.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/local/seed_activity.dart';
import 'auth_locale.dart';
import 'session.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _codeAgent = TextEditingController(text: 'ADMIN01');
  String _pin = '';

  static const _longueurPin = 4;

  @override
  void dispose() {
    _codeAgent.dispose();
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
    final ok = await ref.read(sessionProvider.notifier).connecter(
          codeAgent: _codeAgent.text,
          secret: _pin,
        );
    // Le PIN se vide apres un echec : reessayer ne doit pas demander
    // d'effacer quatre fois.
    if (!ok && mounted) setState(() => _pin = '');
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final schema = Theme.of(context).colorScheme;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.hotel_rounded, size: 64, color: schema.primary),
                const SizedBox(height: 16),
                Text(
                  'Atrium',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Hotel Atrium',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, color: schema.outline),
                ),
                const SizedBox(height: 32),

                TextField(
                  controller: _codeAgent,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Code agent',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  style: const TextStyle(fontSize: 20, letterSpacing: 1.5),
                ),
                const SizedBox(height: 24),

                _Pastilles(saisis: _pin.length, total: _longueurPin),
                const SizedBox(height: 8),

                if (session.echec != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _messageEchec(session.echec!),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: schema.error,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                _PaveNumerique(
                  onChiffre: _chiffre,
                  onEffacer: _effacer,
                  actif: !session.enCours,
                ),

                const SizedBox(height: 24),
                // Rappel du jeu de demonstration. Disparaitra avec la vraie
                // authentification : il n'a de sens que tant qu'aucun serveur
                // ne delivre de jeton.
                Text(
                  'Demonstration — ADMIN01 ou RECEP01, code $pinDemo',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: schema.outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _messageEchec(EchecConnexion echec) => switch (echec) {
        EchecConnexion.utilisateurInconnu => 'Code agent inconnu.',
        EchecConnexion.compteDesactive => 'Ce compte est desactive.',
        EchecConnexion.secretInvalide => 'Code incorrect.',
      };
}

class _Pastilles extends StatelessWidget {
  const _Pastilles({required this.saisis, required this.total});

  final int saisis;
  final int total;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final rempli = i < saisis;
        return Container(
          width: 20,
          height: 20,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: rempli ? schema.primary : Colors.transparent,
            border: Border.all(color: schema.primary, width: 2),
          ),
        );
      }),
    );
  }
}

class _PaveNumerique extends StatelessWidget {
  const _PaveNumerique({
    required this.onChiffre,
    required this.onEffacer,
    required this.actif,
  });

  final void Function(String) onChiffre;
  final VoidCallback onEffacer;
  final bool actif;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      // Touches nettement plus hautes que la cible minimale : on tape vite,
      // souvent sans regarder.
      childAspectRatio: 1.6,
      children: [
        for (final c in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
          _Touche(label: c, onTap: actif ? () => onChiffre(c) : null),
        const SizedBox.shrink(),
        _Touche(label: '0', onTap: actif ? () => onChiffre('0') : null),
        _Touche(
          icone: Icons.backspace_outlined,
          onTap: actif ? onEffacer : null,
        ),
      ],
    );
  }
}

class _Touche extends StatelessWidget {
  const _Touche({this.label, this.icone, this.onTap});

  final String? label;
  final IconData? icone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: Container(
          constraints: const BoxConstraints(minHeight: cibleTactile + 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: schema.outlineVariant),
          ),
          alignment: Alignment.center,
          child: icone != null
              ? Icon(icone, size: 26)
              : Text(
                  label!,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }
}
