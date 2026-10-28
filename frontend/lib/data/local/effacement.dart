/// Effacer la tablette, sur ordre du serveur (correction 9).
///
/// Une tablette revoquee -- perdue, volee -- recoit un 410 a son prochain
/// contact : sa base (clients, ardoises, empreintes des codes) ne doit plus
/// se lire. Ce qu'elle n'avait pas remonte est perdu, et c'est voulu.
library;

import 'connection/connection.dart';
import 'database.dart';

/// Vide toutes les tables, compacte le fichier, puis oublie la cle.
///
/// Vider plutot que supprimer le fichier : la base reste ouverte tant que
/// l'application tourne, et l'effacement doit valoir tout de suite. Le
/// `VACUUM` reecrit le fichier sans les pages liberees ; sans la cle, le
/// lancement suivant met de cote ce qui reste et repart d'une base neuve.
Future<void> effacerLaBase(
  AtriumDatabase db, {
  Future<void> Function() oublierCle = oublierCleDeLaBase,
}) async {
  await db.customStatement('PRAGMA foreign_keys = OFF');
  try {
    await db.transaction(() async {
      for (final table in db.allTables) {
        await db.delete(table).go();
      }
    });
  } finally {
    await db.customStatement('PRAGMA foreign_keys = ON');
  }
  await db.customStatement('VACUUM');
  await oublierCle();
}
