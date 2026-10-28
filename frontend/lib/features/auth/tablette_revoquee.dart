/// Ce que montre une tablette revoquee (correction 9).
///
/// Un responsable l'a retiree du parc d'un autre poste ; a son contact avec
/// le serveur, elle a efface sa base et sa cle. Plus aucun ecran n'a de quoi
/// s'afficher : celui-ci le dit, et ferme l'application. Au lancement
/// suivant, elle repart comme une tablette neuve, sous un autre identifiant.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/tokens.dart';

class TabletteRevoqueeScreen extends StatelessWidget {
  const TabletteRevoqueeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.phonelink_erase_outlined,
                  size: 56,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 20),
                Text(
                  'Tablette révoquée',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Un responsable a retiré cette tablette du parc. Ses données '
                  'viennent d’être effacées : clients, ardoises, codes des '
                  'agents, et les écritures qui n’étaient pas remontées.',
                  style: TextStyle(fontSize: 16, color: p.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: () => SystemNavigator.pop(),
                  child: const Text('Fermer l’application'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
