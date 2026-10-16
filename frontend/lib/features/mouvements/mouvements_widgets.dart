/// Les pieces communes aux ecrans Mouvements, Historique et Entretien : la
/// tuile chiffree, la grille qui les range, et la ligne d'un mouvement.
library;

import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/queries/mouvements_queries.dart';
import '../billing/charge_labels.dart';

/// Un chiffre, son libelle, et une ligne qui dit ce qu'il veut dire.
class TuileChiffre extends StatelessWidget {
  const TuileChiffre({
    super.key,
    required this.libelle,
    required this.valeur,
    this.aide,
    this.icone,
    this.alerte = false,
    this.onTap,
  });

  final String libelle;
  final String valeur;
  final String? aide;
  final IconData? icone;

  /// Le chiffre demande une action : il passe a la couleur d'alerte.
  final bool alerte;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Bezel(
      padding: const EdgeInsets.all(18),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icone != null) ...[
                Icon(icone, size: 18, color: alerte ? p.error : p.accent),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  libelle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: p.textSecondary,
                  ),
                ),
              ),
              if (onTap != null)
                Icon(
                  PhosphorIconsLight.arrowUpRight,
                  size: 16,
                  color: p.textSecondary,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            valeur,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: atriumDisplay(
              28,
              color: alerte ? p.error : p.text,
            ).copyWith(fontFeatures: tabularFigures),
          ),
          if (aide != null) ...[
            const SizedBox(height: 6),
            Text(
              aide!,
              maxLines: 2,
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 12.5,
                color: p.textSecondary,
                fontFeatures: tabularFigures,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Une grille de tuiles qui suit la largeur : trois ou quatre colonnes sur
/// tablette paysage, deux en portrait, une sur telephone.
class GrilleTuiles extends StatelessWidget {
  const GrilleTuiles({super.key, required this.tuiles, this.max = 4});

  final List<Widget> tuiles;
  final int max;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, zone) {
        final colonnes = zone.maxWidth >= 1100
            ? max
            : zone.maxWidth >= 760
            ? (max < 3 ? max : 3)
            : zone.maxWidth >= 440
            ? 2
            : 1;
        const ecart = 12.0;
        final largeur = (zone.maxWidth - ecart * (colonnes - 1)) / colonnes;
        return Wrap(
          spacing: ecart,
          runSpacing: ecart,
          children: [
            for (final t in tuiles) SizedBox(width: largeur, child: t),
          ],
        );
      },
    );
  }
}

/// La couleur et l'icone de chaque genre de mouvement : la meme partout.
(IconData, Color) apparenceMouvement(GenreMouvement g) {
  final p = AtriumPalette.current;
  return switch (g) {
    GenreMouvement.arrivee => (PhosphorIconsLight.signIn, p.success),
    GenreMouvement.depart => (PhosphorIconsLight.signOut, p.accent),
    GenreMouvement.reservation => (PhosphorIconsLight.calendarPlus, p.accent),
    GenreMouvement.annulation => (PhosphorIconsLight.xCircle, p.error),
    GenreMouvement.encaissement => (PhosphorIconsLight.coins, p.success),
    GenreMouvement.remboursement => (
      PhosphorIconsLight.arrowCounterClockwise,
      p.error,
    ),
  };
}

/// Une ligne de la chronologie : l'heure, ce qui s'est passe, pour qui, et
/// de quoi le defaire quand c'est encore possible.
class LigneMouvement extends StatelessWidget {
  const LigneMouvement({
    super.key,
    required this.mouvement,
    this.onClient,
    this.onAnnuler,
    this.avecDate = false,
  });

  final Mouvement mouvement;
  final VoidCallback? onClient;

  /// `null` : pas d'annulation proposee (droit manquant, ou plus possible).
  final VoidCallback? onAnnuler;
  final bool avecDate;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final m = mouvement;
    final (icone, couleur) = apparenceMouvement(m.genre);
    final local = m.moment.toLocal();
    final heure =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final quoi = [
      m.genre.libelle,
      if (m.chambre != null) 'ch. ${m.chambre}',
      if (m.moyen != null) paymentMethodLabel(m.moyen!),
      if (m.detail != null && m.detail!.isNotEmpty) m.detail!,
    ].join(' · ');
    final qui = [
      if (m.reference != null) m.reference!,
      if (m.agent != null) 'par ${m.agent}',
    ].join(' · ');

    final montant = m.montant == null
        ? null
        : Text(
            '${m.genre == GenreMouvement.remboursement ? '−' : ''}'
            '${formatAmount(m.montant!)}',
            style: TextStyle(
              fontFamily: atriumFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: m.genre == GenreMouvement.remboursement
                  ? p.error
                  : p.text,
              fontFeatures: tabularFigures,
            ),
          );

    return HoverRow(
      onTap: onClient,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      // Sur telephone, le montant passe sous le texte et la date se
      // raccourcit : en ligne, ils poussaient la fleche d'annulation hors de
      // l'ecran.
      child: LayoutBuilder(
        builder: (context, zone) {
          final etroit = zone.maxWidth < 420;
          return Row(
            children: [
              SizedBox(
                width: avecDate ? (etroit ? 46 : 84) : 50,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      heure,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                    if (avecDate)
                      Text(
                        etroit
                            ? '${local.day.toString().padLeft(2, '0')}/'
                                  '${local.month.toString().padLeft(2, '0')}'
                            : formatShortDate(local),
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 12,
                          color: p.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                width: etroit ? 30 : 36,
                height: etroit ? 30 : 36,
                decoration: BoxDecoration(
                  color: couleur.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icone, size: etroit ? 15 : 18, color: couleur),
              ),
              SizedBox(width: etroit ? 8 : 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.client ?? 'Client de passage',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      quoi,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 13,
                        color: p.textSecondary,
                      ),
                    ),
                    if (qui.isNotEmpty)
                      Text(
                        qui,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: atriumFontFamily,
                          fontSize: 12,
                          color: p.textSecondary.withValues(alpha: 0.8),
                        ),
                      ),
                    if (etroit && montant != null) ...[
                      const SizedBox(height: 2),
                      montant,
                    ],
                  ],
                ),
              ),
              if (!etroit && montant != null) ...[
                const SizedBox(width: 12),
                montant,
              ],
              if (onAnnuler != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: switch (m.genre) {
                    GenreMouvement.arrivee => "Annuler l'arrivée",
                    GenreMouvement.depart => 'Annuler le départ',
                    _ => "Annuler l'encaissement",
                  },
                  icon: const Icon(PhosphorIconsLight.arrowCounterClockwise),
                  color: p.textSecondary,
                  onPressed: onAnnuler,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
