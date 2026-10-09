/// Le gabarit des fiches qui s'ouvrent au clic : la fiche d'une chambre sur
/// le plan, la commande d'un client au point de vente.
///
/// Meme ouverture, meme en-tete, memes cartes : l'agent qui passe du plan au
/// comptoir retrouve ses reperes, et une retouche de l'une vaut pour l'autre.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'atrium_bandeau.dart' show photoChambre;

/// Ouvre la fiche : en panneau lateral sur une tablette couchee, pour garder
/// l'ecran sous les yeux et enchainer les clients ; en feuille qui monte du
/// bas sur un telephone, ou la place manque pour les deux.
///
/// `fiche` recoit `true` en panneau. Ce que la fiche rend en se fermant
/// (`Navigator.pop(resultat)`) revient ici.
Future<T?> afficherFicheLaterale<T>(
  BuildContext context, {
  required Widget Function(bool panneau) fiche,
  String libelleFermer = 'Fermer la fiche',
}) {
  final theme = Theme.of(context);
  final large = MediaQuery.sizeOf(context).width >= 900;

  if (large) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: libelleFermer,
      barrierColor: AtriumDashColors.title.withValues(alpha: 0.35),
      transitionDuration: AtriumMotion.of(
        context,
        const Duration(milliseconds: 320),
      ),
      pageBuilder: (_, _, _) => Theme(
        data: theme,
        child: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 500,
            height: double.infinity,
            child: fiche(true),
          ),
        ),
      ),
      transitionBuilder: (_, animation, _, enfant) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: enfant,
      ),
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Theme(
      data: theme,
      child: FractionallySizedBox(heightFactor: 0.94, child: fiche(false)),
    ),
  );
}

/// Le fond de la fiche, arrondi du cote ou elle s'ouvre.
class FicheSurface extends StatelessWidget {
  const FicheSurface({super.key, required this.panneau, required this.child});

  final bool panneau;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: AtriumDashColors.page,
    clipBehavior: Clip.antiAlias,
    borderRadius: panneau
        ? const BorderRadius.horizontal(left: Radius.circular(28))
        : const BorderRadius.vertical(top: Radius.circular(28)),
    child: child,
  );
}

/// La chambre de nuit en fond, le titre comme sur la plaque de la porte.
///
/// `badge` se pose en haut a gauche (l'etat de la chambre, le point de
/// vente), `actions` avant le bouton de fermeture. `valeur` et sa legende
/// s'alignent en bas a droite : le prix de la nuit, le solde de l'ardoise.
class FicheEnTete extends StatelessWidget {
  const FicheEnTete({
    super.key,
    required this.panneau,
    required this.titre,
    required this.sousTitre,
    this.badge,
    this.actions = const [],
    this.valeur,
    this.legendeValeur,
    this.libelleFermer = 'Fermer la fiche',
  });

  final bool panneau;
  final String titre;
  final String sousTitre;
  final Widget? badge;
  final List<Widget> actions;
  final String? valeur;
  final String? legendeValeur;
  final String libelleFermer;

  @override
  Widget build(BuildContext context) {
    final haut = panneau ? MediaQuery.paddingOf(context).top : 0.0;

    return SizedBox(
      height: 200 + haut,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            photoChambre,
            fit: BoxFit.cover,
            alignment: const Alignment(0.4, 0.2),
            color: AtriumColors.photoTint,
            colorBlendMode: BlendMode.multiply,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
          ),
          // La nuit monte du bas : le titre et le montant se lisent en blanc
          // sans ombre portee.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AtriumColors.purpleNight.withValues(alpha: 0.35),
                  AtriumColors.purpleNight.withValues(alpha: 0.6),
                  AtriumColors.purpleNight.withValues(alpha: 0.94),
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(22, haut + 14, 14, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!panneau)
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: AtriumColors.white.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    ?badge,
                    const Spacer(),
                    for (final a in actions)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: a,
                      ),
                    FicheBoutonRond(
                      icone: Icons.close_rounded,
                      libelle: libelleFermer,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            titre,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                              color: AtriumColors.white,
                              height: 1.1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            sousTitre,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: AtriumColors.onPurpleSoft,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (valeur != null)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            valeur!,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: AtriumColors.white,
                              fontFeatures: tabularFigures,
                            ),
                          ),
                          if (legendeValeur != null)
                            Text(
                              legendeValeur!,
                              style: TextStyle(
                                fontSize: 13,
                                color: AtriumColors.onPurpleSoft,
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Un bouton rond, translucide sur la photo : fermer, signaler un probleme.
class FicheBoutonRond extends StatelessWidget {
  const FicheBoutonRond({
    super.key,
    required this.icone,
    required this.libelle,
    required this.onTap,
  });

  final IconData icone;
  final String libelle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: libelle,
    excludeSemantics: true,
    child: Material(
      color: AtriumColors.white.withValues(alpha: 0.16),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: libelle,
          child: SizedBox.square(
            dimension: 44,
            child: Icon(icone, color: AtriumColors.white),
          ),
        ),
      ),
    ),
  );
}

/// Une carte de la fiche, avec son titre.
class FicheCarte extends StatelessWidget {
  const FicheCarte({super.key, required this.child, this.titre, this.suffixe});

  final String? titre;

  /// En bout de ligne du titre : un total, un compteur.
  final Widget? suffixe;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AtriumDashColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AtriumDashColors.cardBorder),
        boxShadow: AtriumShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (titre != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    titre!,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AtriumDashColors.title,
                    ),
                  ),
                ),
                ?suffixe,
              ],
            ),
            const SizedBox(height: 14),
          ],
          child,
        ],
      ),
    );
  }
}
