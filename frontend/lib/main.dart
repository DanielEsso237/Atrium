/// Point d'entree d'Atrium.
///
/// L'application ouvre sa base locale, s'assure que le parametrage et le jeu
/// de demonstration sont en place, puis affiche l'interface. **Aucun appel
/// reseau** : le produit est hors ligne d'abord, et tout ce qui s'affiche vient
/// de SQLite. La couche distante viendra se brancher derriere les depots, sans
/// que ces ecrans changent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme.dart';
import 'data/local/database.dart';
import 'data/local/database_provider.dart';
import 'data/local/seed.dart';
import 'data/local/seed_accounts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = AtriumDatabase();

  // Les deux jeux sont idempotents (`insertOnConflictUpdate`) : les rejouer a
  // chaque demarrage rafraichit le parametrage sans rien dupliquer.
  await seedDemoData(db);
  await seedAccounts(db);

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
    return MaterialApp.router(
      title: 'Atrium',
      debugShowCheckedModeBanner: false,
      theme: themeAtrium(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
