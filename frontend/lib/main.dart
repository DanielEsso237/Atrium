/// Point d'entree d'Atrium.
///
/// L'application ouvre sa base locale, s'assure que le parametrage et le jeu
/// de demonstration sont en place, puis affiche l'interface. **Aucun appel
/// reseau** : le produit est hors ligne d'abord, et tout ce qui s'affiche vient
/// de SQLite. La couche distante viendra se brancher derriere les depots, sans
/// que ces ecrans changent.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme.dart';
import 'core/tokens.dart';
import 'data/local/database.dart';
import 'data/local/database_provider.dart';
import 'data/local/seed.dart';
import 'data/local/seed_accounts.dart';
import 'data/repositories/demo_activite.dart';
import 'features/sync/sync_status.dart';

/// Activite de demonstration (sejours, arrivees, departs) autour de la
/// journee en cours : active par defaut en developpement, absente d'une
/// version installee a l'hotel. `--dart-define=ATRIUM_DEMO=false` la coupe en
/// developpement, `=true` la force pour une presentation.
const _activiteDemo = bool.fromEnvironment(
  'ATRIUM_DEMO',
  defaultValue: kDebugMode,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = AtriumDatabase();

  // Les deux jeux sont idempotents (`insertOnConflictUpdate`) : les rejouer a
  // chaque demarrage rafraichit le parametrage sans rien dupliquer.
  await seedDemoData(db);
  await seedAccounts(db);
  if (_activiteDemo) {
    // Un jeu de demonstration qui echoue ne doit jamais empecher
    // l'application de s'ouvrir.
    try {
      await seedDemoActivity(db);
    } catch (e, pile) {
      debugPrint('Activite de demonstration non installee : $e\n$pile');
    }
  }

  runApp(
    ProviderScope(
      // La base est ouverte avant `runApp` pour que le premier ecran ait deja
      // ses donnees : sur une tablette de comptoir, un ecran vide d'une demie
      // seconde se lit comme une panne.
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const AtriumApp(),
    ),
  );
}

class AtriumApp extends ConsumerWidget {
  const AtriumApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Surveille la file d'envoi pour toute la duree de vie de l'application.
    // Sans ce `watch`, Riverpod detruirait le planificateur faute d'auditeur,
    // et la remontee automatique n'aurait lieu que sur les ecrans qui
    // l'observent -- c'est-a-dire aucun.
    ref.watch(syncSchedulerProvider);

    return MaterialApp.router(
      title: 'Atrium',
      debugShowCheckedModeBanner: false,
      // Clair le jour, sombre le soir : l'appareil decide.
      theme: atriumTheme(AtriumPalette.light),
      darkTheme: atriumTheme(AtriumPalette.dark),
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        // Les ecrans lisent leurs couleurs dans `AtriumPalette.current` : on
        // la cale sur le theme retenu, et on reconstruit tout l'arbre quand
        // la luminosite change (rare : une bascule jour/nuit de l'appareil).
        final brightness = Theme.of(context).brightness;
        AtriumPalette.current = brightness == Brightness.dark
            ? AtriumPalette.dark
            : AtriumPalette.light;
        return KeyedSubtree(key: ValueKey(brightness), child: child!);
      },
    );
  }
}
