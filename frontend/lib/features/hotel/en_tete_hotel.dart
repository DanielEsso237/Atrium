/// L'en-tete des factures et des recus : le logo de l'hotel, son nom et ses
/// coordonnees.
///
/// Un seul dessin pour l'apercu de l'administration et la facture a
/// l'ecran : ce que l'administrateur regle est exactement ce que le client
/// recoit. Les PDF reprennent les memes lignes (`lignesCoordonnees`).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/tokens.dart';
import '../../data/local/database.dart';

/// Les coordonnees imprimees sous le nom, dans l'ordre ou on les cherche.
List<String> lignesCoordonnees(HotelRow? h) {
  if (h == null) return const [];
  String? net(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
  final lieu = [net(h.address), net(h.city), net(h.country)]
      .whereType<String>()
      .join(', ');
  final raison = net(h.legalName);
  return [
    // La raison sociale, seulement quand elle differe du nom affiche.
    if (raison != null && raison != h.name.trim()) raison,
    if (lieu.isNotEmpty) lieu,
    if (net(h.phone) case final tel?) 'Tél. $tel',
    ?net(h.email),
    if (net(h.taxId) case final nif?) 'N° contribuable $nif',
  ];
}

/// L'en-tete d'une facture sur papier blanc, en couleur.
class EnTeteFacture extends StatelessWidget {
  const EnTeteFacture({
    super.key,
    required this.hotel,
    required this.titre,
    this.numero,
    this.logo,
  });

  final HotelRow? hotel;

  /// « Facture », « Reçu ».
  final String titre;
  final String? numero;

  /// Le logo a afficher ; par defaut celui de l'hotel. L'apercu de
  /// l'administration y passe une image pas encore enregistree.
  final Uint8List? logo;

  static const encre = Color(0xFF1C2333);
  static const gris = Color(0xFF5E6880);

  @override
  Widget build(BuildContext context) {
    final image = logo ?? hotel?.logoData;
    final nom = hotel?.name ?? 'Hôtel';
    TextStyle st(double t, FontWeight w, Color c) => TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: t,
      fontWeight: w,
      color: c,
      height: 1.35,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (image != null) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 64, maxWidth: 200),
                  child: Image.memory(
                    image,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                    gaplessPlayback: true,
                    semanticLabel: 'Logo de $nom',
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Text(nom, style: st(image == null ? 19 : 15, FontWeight.w700, encre)),
              for (final l in lignesCoordonnees(hotel))
                Text(l, style: st(12, FontWeight.w400, gris)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(titre, style: st(12.5, FontWeight.w600, gris)),
            if (numero != null)
              Text(
                numero!,
                style: st(15, FontWeight.w700, encre).copyWith(
                  fontFeatures: tabularFigures,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// L'en-tete d'un ticket de caisse : noir sur blanc, centre, comme il sort
/// d'une imprimante thermique.
class EnTeteTicket extends StatelessWidget {
  const EnTeteTicket({super.key, required this.hotel, this.logoNoirBlanc});

  final HotelRow? hotel;
  final Uint8List? logoNoirBlanc;

  @override
  Widget build(BuildContext context) {
    TextStyle st(double t, FontWeight w) => TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: t,
      fontWeight: w,
      color: Colors.black,
      height: 1.3,
    );
    return Column(
      children: [
        if (logoNoirBlanc != null) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 72, maxWidth: 180),
            child: Image.memory(
              logoNoirBlanc!,
              fit: BoxFit.contain,
              // Les points du tramage restent nets, comme a l'impression.
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
              semanticLabel: 'Logo en noir et blanc',
            ),
          ),
          const SizedBox(height: 6),
        ],
        Text(
          hotel?.name ?? 'Hôtel',
          textAlign: TextAlign.center,
          style: st(14, FontWeight.w800),
        ),
        for (final l in lignesCoordonnees(hotel))
          Text(l, textAlign: TextAlign.center, style: st(10.5, FontWeight.w500)),
      ],
    );
  }
}
