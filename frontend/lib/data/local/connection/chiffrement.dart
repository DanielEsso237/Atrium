/// Le chiffrement du fichier de la base, sur appareil.
///
/// Une tablette se vole. Sans chiffrement, le fichier `atrium.sqlite` se lit
/// avec n'importe quel lecteur SQLite : clients, pieces d'identite, caisses,
/// et les empreintes des codes de tous les agents. La base est chiffree par
/// SQLite3MultipleCiphers, que `package:sqlite3` embarque a la place de SQLite
/// (`hooks.user_defines` dans `pubspec.yaml`).
///
/// Fonctions pures sur un fichier et une cle : elles se testent sur la
/// machine de developpement, sans tablette ni magasin securise.
library;

import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

/// Les 16 premiers octets d'un fichier SQLite en clair. Un fichier chiffre
/// commence par des octets aleatoires.
const _enTeteEnClair = 'SQLite format 3\u0000';

/// Une cle de 256 bits, en hexadecimal, tiree au hasard.
String nouvelleCle() {
  final hasard = Random.secure();
  return [
    for (var i = 0; i < 32; i++)
      hasard.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Vrai si le fichier est une base SQLite lisible sans cle. Un fichier vide
/// ou trop court n'est ni l'un ni l'autre : SQLite le traite comme une base
/// neuve.
bool estEnClair(File fichier) {
  if (!fichier.existsSync() || fichier.lengthSync() < 16) return false;
  final acces = fichier.openSync();
  try {
    return String.fromCharCodes(acces.readSync(16)) == _enTeteEnClair;
  } finally {
    acces.closeSync();
  }
}

/// Donne la cle a une connexion qui vient de s'ouvrir, puis verifie qu'elle
/// est la bonne : SQLite n'essaie la cle qu'a la premiere lecture, et une
/// mauvaise cle se decouvrirait sinon au milieu d'une migration.
///
/// Leve [SqliteException] (« file is not a database ») si la cle ne convient
/// pas.
void appliquerCle(Database db, String cleHex) {
  db.execute("PRAGMA hexkey = '$cleHex'");
  db.select('SELECT count(*) FROM sqlite_master');
}

/// Chiffre sur place une base restee en clair : celle d'une tablette
/// installee avant le chiffrement.
///
/// `rekey` refuse le journal WAL : on vide le journal dans le fichier, on
/// repasse en journal classique le temps de chiffrer, et l'ouverture normale
/// remet le WAL. Une coupure de courant pendant `rekey` laisse la base en
/// clair, jamais a moitie chiffree : SQLite l'ecrit dans une transaction.
void chiffrerEnPlace(File fichier, String cleHex) {
  final db = sqlite3.open(fichier.path);
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    db.execute('PRAGMA journal_mode = DELETE');
    db.execute("PRAGMA hexrekey = '$cleHex'");
  } finally {
    db.close();
  }
}

/// Vrai si la cle ouvre la base du fichier.
bool cleOuvre(File fichier, String cleHex) {
  final db = sqlite3.open(fichier.path);
  try {
    appliquerCle(db, cleHex);
    return true;
  } on SqliteException {
    return false;
  } finally {
    db.close();
  }
}

/// Met de cote une base que la cle n'ouvre plus, avec son journal, pour
/// repartir d'une base neuve que la descente remplira. Le fichier est garde,
/// pas efface : il reste la seule trace des ecritures qui n'etaient pas
/// remontees.
File mettreDeCote(File fichier) {
  final horodatage = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp('[^0-9]'),
    '',
  );
  final cible = File('${fichier.path}.illisible-$horodatage');
  fichier.renameSync(cible.path);
  for (final suffixe in ['-wal', '-shm']) {
    final annexe = File('${fichier.path}$suffixe');
    if (annexe.existsSync()) annexe.renameSync('${cible.path}$suffixe');
  }
  return cible;
}

/// Prepare le fichier avant son ouverture et dit avec quelle cle l'ouvrir
/// (`cle` nulle : en clair).
///
/// - base neuve : chiffree des sa creation ;
/// - base en clair, d'avant le chiffrement : chiffree sur place ;
/// - base chiffree que la cle n'ouvre pas (cle perdue) : mise de cote
///   (`misDeCote`), et une base neuve la remplace ;
/// - pas de cle fiable : en clair, comme avant, jusqu'au prochain essai ;
/// - magasin en panne devant une base chiffree : l'erreur remonte. Mettre de
///   cote pour une panne passagere perdrait les ecritures en attente.
Future<({String? cle, File? misDeCote})> preparerFichier(
  File fichier,
  Future<String?> Function() obtenirCle,
) async {
  final existe = fichier.existsSync() && fichier.lengthSync() > 0;
  final enClair = estEnClair(fichier);
  final chiffree = existe && !enClair;

  final String? cle;
  try {
    cle = await obtenirCle();
  } catch (_) {
    if (chiffree) rethrow;
    return (cle: null, misDeCote: null);
  }

  if (cle == null) {
    return (cle: null, misDeCote: chiffree ? mettreDeCote(fichier) : null);
  }
  if (enClair) {
    chiffrerEnPlace(fichier, cle);
    return (cle: cle, misDeCote: null);
  }
  if (chiffree && !cleOuvre(fichier, cle)) {
    return (cle: cle, misDeCote: mettreDeCote(fichier));
  }
  return (cle: cle, misDeCote: null);
}
