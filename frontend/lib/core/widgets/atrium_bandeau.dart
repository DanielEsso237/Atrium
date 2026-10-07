/// Le fond des bandeaux d'en-tete : celui de la page, uni.
///
/// Il portait une photo de chambre, une courbe translucide et une vague :
/// trois decors pour un en-tete de travail, qui faisaient du plan des
/// chambres un ecran a part. Il prend maintenant le fond de toutes les
/// autres pages ; le titre en serif suffit a dire ou l'on est.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// La photo de la connexion.
const photoChambre = 'assets/images/chambre.jpg';

class AtriumBandeauFond extends StatelessWidget {
  const AtriumBandeauFond({super.key});

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: AtriumDashColors.page);
}
