/// La tuile d'un mini tableau de bord : Entretien (16 octobre), puis
/// Finances. Partagee pour que les deux se ressemblent.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';
import '../ui/atrium_ui.dart';
import '../ui/icons.dart';

/// La tuile d'un metier : une phrase qui dit l'essentiel, une jauge, les
/// chiffres, et le bouton qui ouvre l'ecran.
class TuileMetier extends StatelessWidget {
  const TuileMetier({
    super.key,
    required this.titre,
    required this.icone,
    required this.phrase,
    required this.chiffres,
    required this.bouton,
    required this.onOuvrir,
    this.alerte = false,
    this.progression,
    this.legende,
    this.etiree = false,
  });

  /// Posee dans une rangee de hauteur fixe (cote a cote).
  final bool etiree;

  final String titre;
  final IconData icone;
  final String phrase;
  final bool alerte;

  /// Entre 0 et 1 ; `null` : pas de jauge.
  final double? progression;
  final String? legende;

  /// Libelle, valeur, a surveiller.
  final List<(String, String, bool)> chiffres;
  final String bouton;
  final VoidCallback onOuvrir;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: p.accentTint,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: p.accentSoft),
                ),
                child: Icon(icone, size: 24, color: p.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titre, style: atriumDisplay(26, color: p.text)),
                    Text(
                      phrase,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: alerte ? p.error : p.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (progression != null) ...[
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progression!.clamp(0, 1),
                minHeight: 10,
                backgroundColor: p.surfaceMuted,
                color: p.success,
              ),
            ),
            if (legende != null) ...[
              const SizedBox(height: 6),
              Text(
                legende!,
                style: TextStyle(
                  fontSize: 13,
                  color: p.textSecondary,
                  fontFeatures: tabularFigures,
                ),
              ),
            ],
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final (libelle, valeur, aSurveiller) in chiffres)
                Container(
                  constraints: const BoxConstraints(minWidth: 118),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: aSurveiller
                        ? p.error.withValues(alpha: 0.08)
                        : p.surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        valeur,
                        style: atriumDisplay(
                          22,
                          color: aSurveiller ? p.error : p.text,
                        ).copyWith(fontFeatures: tabularFigures),
                      ),
                      Text(
                        libelle,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: p.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          // Cote a cote, les deux boutons s'alignent en bas ; empilees, la
          // tuile n'a pas de hauteur imposee et le bouton suit les chiffres.
          if (etiree) const Spacer(),
          const SizedBox(height: 20),
          PillButton(
            label: bouton,
            icon: PhosphorIconsLight.arrowRight,
            tone: PillTone.accent,
            expand: true,
            onPressed: onOuvrir,
          ),
        ],
      ),
    );
  }
}
