/// La fenetre qui confirme un geste et demande son motif : annuler une
/// reservation, une depense, valider ou refuser un transfert.
///
/// Le champ du motif appartient a la fenetre, et meurt avec elle. Avant, la
/// fonction appelante creait le controleur et le detruisait des que la
/// fenetre rendait sa reponse, alors qu'elle etait encore a l'ecran le temps
/// de son animation de sortie : le champ lisait un controleur detruit. Au
/// retour d'Android, l'application levait alors `_dependents.isEmpty`
/// (16 octobre, ecran Reservations).
library;

import 'package:flutter/material.dart';

/// Rend le motif saisi si l'agent confirme, `null` s'il renonce — par le
/// bouton, en touchant a cote ou par le retour d'Android.
Future<String?> demanderMotif(
  BuildContext context, {
  required String titre,
  required String libelleConfirmer,
  required String libelleRenoncer,
  Widget? contenu,
  IconData? icone,
  String libelleMotif = 'Motif (facultatif)',
  String? indice,
  bool danger = false,
  bool autofocus = false,
  double largeur = 440,
  String? valeurInitiale,
  bool obligatoire = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _FenetreMotif(
      titre: titre,
      libelleConfirmer: libelleConfirmer,
      libelleRenoncer: libelleRenoncer,
      contenu: contenu,
      icone: icone,
      libelleMotif: libelleMotif,
      indice: indice,
      danger: danger,
      autofocus: autofocus,
      largeur: largeur,
      valeurInitiale: valeurInitiale,
      obligatoire: obligatoire,
    ),
  );
}

class _FenetreMotif extends StatefulWidget {
  const _FenetreMotif({
    required this.titre,
    required this.libelleConfirmer,
    required this.libelleRenoncer,
    required this.contenu,
    required this.icone,
    required this.libelleMotif,
    required this.indice,
    required this.danger,
    required this.autofocus,
    required this.largeur,
    this.valeurInitiale,
    this.obligatoire = false,
  });

  final String titre;
  final String libelleConfirmer;
  final String libelleRenoncer;
  final Widget? contenu;
  final IconData? icone;
  final String libelleMotif;
  final String? indice;
  final bool danger;
  final bool autofocus;
  final double largeur;

  /// Le motif deja saisi, pour le corriger plutot que le retaper.
  final String? valeurInitiale;

  /// Pas de confirmation sans trois caracteres de motif : le serveur refuse
  /// un motif plus court, et une saisie perdue a dessein doit dire pourquoi.
  final bool obligatoire;

  @override
  State<_FenetreMotif> createState() => _FenetreMotifState();
}

class _FenetreMotifState extends State<_FenetreMotif> {
  late final _motif = TextEditingController(text: widget.valeurInitiale);

  @override
  void dispose() {
    _motif.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: widget.icone == null ? null : Icon(widget.icone, size: 32),
      title: Text(widget.titre),
      scrollable: true,
      content: SizedBox(
        width: widget.largeur,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.contenu != null) ...[
              widget.contenu!,
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _motif,
              autofocus: widget.autofocus,
              maxLength: 255,
              decoration: InputDecoration(
                labelText: widget.libelleMotif,
                hintText: widget.indice,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.libelleRenoncer),
        ),
        ValueListenableBuilder(
          valueListenable: _motif,
          builder: (context, valeur, _) => FilledButton(
            onPressed: widget.obligatoire && valeur.text.trim().length < 3
                ? null
                : () => Navigator.of(context).pop(_motif.text),
            style: widget.danger
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(widget.libelleConfirmer),
          ),
        ),
      ],
    );
  }
}
