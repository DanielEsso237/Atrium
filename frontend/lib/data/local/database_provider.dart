/// Acces a la base locale depuis l'arbre de widgets.
///
/// Une seule instance d'`AtriumDatabase` pour toute l'application : Drift
/// diffuse ses flux depuis la connexion qui a ecrit, donc deux instances
/// ouvertes sur le meme fichier ne se previendraient pas l'une l'autre et les
/// ecrans cesseraient de se rafraichir.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';

final databaseProvider = Provider<AtriumDatabase>((ref) {
  final db = AtriumDatabase();
  ref.onDispose(db.close);
  return db;
});
