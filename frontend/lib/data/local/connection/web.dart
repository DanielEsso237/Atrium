/// Ouverture de la base dans un navigateur : SQLite en WebAssembly.
///
/// Uniquement pour le developpement — voir `connection.dart`. Les deux
/// fichiers necessaires sont versionnes dans `web/` :
///
/// - `sqlite3.wasm` — SQLite compile en WebAssembly
/// - `drift_worker.js` — le travailleur qui l'execute hors du fil principal
///
/// Ils viennent des versions publiees de `sqlite3.dart` et de `drift`, et
/// doivent etre remis a jour si ces paquets changent de version majeure.
library;

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:flutter/foundation.dart';

QueryExecutor ouvrirBase() {
  return LazyDatabase(() async {
    final resultat = await WasmDatabase.open(
      databaseName: 'atrium',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );

    // Le navigateur ne garantit pas le meilleur mode de stockage : selon le
    // navigateur et le mode de navigation, drift retombe parfois sur un
    // stockage en memoire, perdu au rechargement. Le dire plutot que de
    // laisser croire a une persistance qui n'existe pas.
    if (resultat.missingFeatures.isNotEmpty) {
      debugPrint(
        'Drift web : stockage degrade, fonctions manquantes '
        '${resultat.missingFeatures}. Les donnees peuvent ne pas survivre au '
        'rechargement. Sans consequence : le web est un outil de mise en page, '
        'pas une cible de production.',
      );
    }

    return resultat.resolvedExecutor;
  });
}

/// Pas de base en memoire sur le web : les tests tournent sur la VM Dart, pas
/// dans un navigateur. Echouer ici plutot que de charger un second moteur
/// WebAssembly pour un cas d'usage qui n'existe pas.
QueryExecutor ouvrirBaseMemoire() => throw UnsupportedError(
  "AtriumDatabase.memory() n'est pas disponible sur le web.",
);
