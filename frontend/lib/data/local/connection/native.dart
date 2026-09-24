/// Ouverture de la base sur un appareil : un fichier SQLite.
///
/// C'est le chemin de production — les tablettes du parc passent par ici.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

QueryExecutor ouvrirBase() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'atrium.sqlite'));

    // package:sqlite3 3.x embarque lui-meme la bibliotheque native via les
    // hooks de build Dart : toutes les tablettes du parc utilisent la meme
    // version de SQLite, quel que soit leur constructeur ou leur version
    // d'Android. C'est ce qui remplace l'ancien paquet sqlite3_flutter_libs.
    sqlite3.tempDirectory = (await getTemporaryDirectory()).path;

    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        // WAL : indispensable en kiosque. Une tablette debranchee ou eteinte
        // brutalement ne doit pas corrompre la base, et la lecture reste
        // possible pendant qu'une ecriture est en cours.
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA foreign_keys = ON');
        db.execute('PRAGMA busy_timeout = 5000');
      },
    );
  });
}

/// Base en memoire, jetee a la fin : utilisee par les tests, qui tournent sur
/// la machine de developpement et jamais dans un navigateur.
QueryExecutor ouvrirBaseMemoire() => NativeDatabase.memory();
