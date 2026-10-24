/// Revenir en arriere, sur le code d'un responsable (demande du 16 octobre).
///
/// Une arrivee, un depart, un encaissement saisis par erreur se defont, mais
/// jamais d'un geste de l'agent seul : un superieur tape son code sur la
/// tablette, **meme quand c'est lui qui est connecte**. L'agent doit donc
/// aller le chercher, et le responsable voit ce qu'il autorise.
///
/// La fenetre demande trois choses : le code agent du responsable, son PIN,
/// et le motif -- qui reste sur les lignes annulees et dans le journal du
/// serveur.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/confirmation.dart';
import '../../core/ui/icons.dart';
import '../../data/repositories/autorisation_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../../data/repositories/reservation_repository.dart'
    show EncaissementsAAnnuler;
import '../auth/pin_input.dart';
import '../auth/session.dart';
import '../billing/cash_dialog.dart' show avecCaisse;

/// Ce que le responsable a accorde.
class Accord {
  const Accord(this.responsable, this.motif);

  final Responsable responsable;
  final String motif;
}

/// Demande le code d'un responsable. `null` si l'agent renonce.
Future<Accord?> demanderAccordResponsable(
  BuildContext context, {
  required String titre,
  required String explication,
}) {
  return showDialog<Accord>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FenetreAccord(titre: titre, explication: explication),
  );
}

class _FenetreAccord extends ConsumerStatefulWidget {
  const _FenetreAccord({required this.titre, required this.explication});

  final String titre;
  final String explication;

  @override
  ConsumerState<_FenetreAccord> createState() => _FenetreAccordState();
}

class _FenetreAccordState extends ConsumerState<_FenetreAccord> {
  static const _longueurPin = 4;

  final _code = TextEditingController();
  final _motif = TextEditingController();
  String _pin = '';
  bool _verification = false;
  String? _erreur;

  @override
  void dispose() {
    _code.dispose();
    _motif.dispose();
    super.dispose();
  }

  bool get _complet =>
      _code.text.trim().isNotEmpty &&
      _pin.length == _longueurPin &&
      _motif.text.trim().isNotEmpty;

  Future<void> _valider() async {
    if (!_complet || _verification) return;
    setState(() {
      _verification = true;
      _erreur = null;
    });
    try {
      final responsable = await ref
          .read(autorisationRepositoryProvider)
          .verifier(code: _code.text, secret: _pin);
      if (!mounted) return;
      Navigator.of(context).pop(Accord(responsable, _motif.text.trim()));
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() {
        _verification = false;
        _erreur = e.message;
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    // Un Dialog et non un AlertDialog : celui-ci mesure la largeur
    // naturelle de son contenu (IntrinsicWidth), et les cases du PIN
    // reposent sur un LayoutBuilder, qui ne sait pas la donner. La fenetre
    // plantait avant de s'afficher.
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
                PhosphorIconsLight.shieldCheck,
                size: 32,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(height: 16),
              Text(widget.titre, textAlign: TextAlign.center, style: titre),
              const SizedBox(height: 16),
              _contenu(context, p),
              const SizedBox(height: 20),
              _actions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _contenu(BuildContext context, AtriumPalette p) {
    return SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.explication, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.accentSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              "Un responsable doit saisir son code, même s'il est déjà "
              'connecté sur cette tablette.',
              style: TextStyle(fontSize: 14, color: p.text),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
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
            filled: _pin.length,
            length: _longueurPin,
            error: _erreur != null,
            busy: _verification,
          ),
          const SizedBox(height: 12),
          PinKeypad(
            enabled: !_verification,
            keyHeight: 52,
            onDigit: (c) {
              if (_pin.length >= _longueurPin) return;
              setState(() {
                _pin += c;
                _erreur = null;
              });
            },
            onDelete: () {
              if (_pin.isEmpty) return;
              setState(() => _pin = _pin.substring(0, _pin.length - 1));
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _motif,
            enabled: !_verification,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'Motif (obligatoire)',
              hintText: 'Ex. : mauvaise chambre, saisie en double',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_erreur != null) ...[
            const SizedBox(height: 4),
            Text(
              _erreur!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        TextButton(
          onPressed: _verification ? null : () => Navigator.of(context).pop(),
          child: const Text('Renoncer'),
        ),
        FilledButton(
          onPressed: _complet && !_verification ? _valider : null,
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(_verification ? 'Vérification…' : 'Autoriser'),
        ),
      ],
    );
  }
}

/// Annule une arrivee, sur le code d'un responsable.
Future<bool> annulerArrivee(
  BuildContext context,
  WidgetRef ref, {
  required String lineId,
  required String guestName,
  required String? roomNumber,
}) async {
  // Les refus d'abord : le responsable ne vient pas taper son code pour un
  // geste impossible. Des encaissements a annuler : on propose d'aller les
  // annuler sur la fiche du client, ou chacun a sa fleche.
  try {
    await ref
        .read(reservationRepositoryProvider)
        .verifierAnnulationArrivee(lineId);
  } on EncaissementsAAnnuler catch (e) {
    if (context.mounted) {
      final routeur = GoRouter.of(context);
      montrerRefus(
        context,
        '${e.message} Ils s’annulent un par un sur la fiche du client.',
        remede: Remede(
          'Voir la fiche du client',
          () => routeur.push('/clients/${e.guestId}'),
        ),
      );
    }
    return false;
  } on StateError catch (e) {
    if (context.mounted) montrerRefus(context, e.message);
    return false;
  }
  if (!context.mounted) return false;
  final accord = await demanderAccordResponsable(
    context,
    titre: "Annuler l'arrivée",
    explication:
        "L'arrivée de $guestName${roomNumber == null ? '' : ', chambre $roomNumber,'} "
        "sera annulée : la chambre redevient libre et l'ardoise est retirée. "
        'La réservation reste, prête pour une nouvelle arrivée.',
  );
  if (accord == null || !context.mounted) return false;
  try {
    await ref
        .read(reservationRepositoryProvider)
        .annulerArrivee(
          lineId: lineId,
          approuvePar: accord.responsable.id,
          motif: accord.motif,
        );
  } on StateError catch (e) {
    if (context.mounted) montrerRefus(context, e.message);
    return false;
  }
  if (context.mounted) {
    montrerSucces(
      context,
      'Arrivée de $guestName annulée (autorisée par ${accord.responsable.nom}).',
    );
  }
  return true;
}

/// Annule un depart, sur le code d'un responsable.
Future<bool> annulerDepart(
  BuildContext context,
  WidgetRef ref, {
  required String lineId,
  required String guestName,
  required String? roomNumber,
}) async {
  final accord = await demanderAccordResponsable(
    context,
    titre: 'Annuler le départ',
    explication:
        '$guestName reprend sa chambre${roomNumber == null ? '' : ' $roomNumber'} '
        "et son ardoise se rouvre. La chambre doit être libre.",
  );
  if (accord == null || !context.mounted) return false;
  try {
    await ref
        .read(reservationRepositoryProvider)
        .annulerDepart(
          lineId: lineId,
          approuvePar: accord.responsable.id,
          motif: accord.motif,
        );
  } on StateError catch (e) {
    if (context.mounted) montrerRefus(context, e.message);
    return false;
  }
  if (context.mounted) {
    montrerSucces(
      context,
      'Départ de $guestName annulé (autorisé par ${accord.responsable.nom}).',
    );
  }
  return true;
}

/// Annule un encaissement, sur le code d'un responsable.
Future<bool> annulerEncaissement(
  BuildContext context,
  WidgetRef ref, {
  required String paymentId,
  required int amount,
  required String quoi,
}) async {
  final accord = await demanderAccordResponsable(
    context,
    titre: "Annuler l'encaissement",
    explication:
        "L'encaissement de ${formatAmount(amount)} ($quoi) sera annulé : "
        'la somme sort de votre caisse ouverte et redevient due sur '
        "l'ardoise.",
  );
  if (accord == null || !context.mounted) return false;
  try {
    // Caisse fermee : on propose de l'ouvrir, puis l'annulation repart avec
    // l'accord deja donne.
    await avecCaisse(
      context,
      ref,
      () => ref
          .read(folioRepositoryProvider)
          .annulerEncaissement(
            paymentId: paymentId,
            approuvePar: accord.responsable.id,
            motif: accord.motif,
            by: ref.read(sessionProvider).agent?.id,
          ),
    );
  } on StateError catch (e) {
    if (context.mounted) montrerRefus(context, e.message);
    return false;
  }
  if (context.mounted) {
    montrerSucces(
      context,
      'Encaissement de ${formatAmount(amount)} annulé '
      '(autorisé par ${accord.responsable.nom}).',
    );
  }
  return true;
}
