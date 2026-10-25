import 'dart:io';

import 'package:atrium/data/local/connection/chiffrement.dart';
import 'package:atrium/data/local/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dossier;
  late File fichier;

  setUp(() {
    dossier = Directory.systemTemp.createTempSync('atrium_chiffrement');
    fichier = File('${dossier.path}/atrium.sqlite');
  });
  tearDown(() => dossier.deleteSync(recursive: true));

  /// Une base comme celle d'une tablette d'avant le chiffrement : en clair,
  /// en WAL, une ligne encore dans le journal.
  void baseEnClair() {
    final db = sqlite3.open(fichier.path)
      ..execute('PRAGMA journal_mode = WAL')
      ..execute('CREATE TABLE t (v TEXT)')
      ..execute("INSERT INTO t VALUES ('vente du bar')");
    db.close();
  }

  bool lisibleSansCle() {
    final db = sqlite3.open(fichier.path);
    try {
      db.select('SELECT count(*) FROM sqlite_master');
      return true;
    } on SqliteException {
      return false;
    } finally {
      db.close();
    }
  }

  test('SQLite3MultipleCiphers est bien embarque', () {
    final db = sqlite3.openInMemory();
    final r = db.select('SELECT sqlite3mc_version() AS v');
    expect(r.first['v'], isNotEmpty);
    db.close();
  });

  test('une base neuve est chiffree des sa creation', () async {
    final cle = nouvelleCle();
    final r = await preparerFichier(fichier, () async => cle);
    expect(r.cle, cle);

    final db = sqlite3.open(fichier.path);
    appliquerCle(db, cle);
    db.execute('CREATE TABLE t (v TEXT)');
    db.close();

    expect(estEnClair(fichier), isFalse);
    expect(lisibleSansCle(), isFalse);
    expect(cleOuvre(fichier, cle), isTrue);
    expect(cleOuvre(fichier, nouvelleCle()), isFalse);
  });

  test("la base d'avant est chiffree sur place, sans rien perdre", () async {
    baseEnClair();
    expect(estEnClair(fichier), isTrue);
    final cle = nouvelleCle();

    final r = await preparerFichier(fichier, () async => cle);

    expect(r.cle, cle);
    expect(r.misDeCote, isNull);
    expect(estEnClair(fichier), isFalse);
    final db = sqlite3.open(fichier.path);
    appliquerCle(db, cle);
    expect(db.select('SELECT v FROM t').single['v'], 'vente du bar');
    db.close();
  });

  test('une cle perdue met la base de cote, sans l\'effacer', () async {
    final ancienne = nouvelleCle();
    await preparerFichier(fichier, () async => ancienne);
    final db = sqlite3.open(fichier.path);
    appliquerCle(db, ancienne);
    db.execute('CREATE TABLE t (v TEXT)');
    db.close();

    final r = await preparerFichier(fichier, () async => nouvelleCle());

    expect(r.misDeCote, isNotNull);
    expect(r.misDeCote!.existsSync(), isTrue);
    expect(fichier.existsSync(), isFalse);
    expect(cleOuvre(r.misDeCote!, ancienne), isTrue);
  });

  test('un magasin en panne ne met pas une base chiffree de cote', () async {
    final cle = nouvelleCle();
    await preparerFichier(fichier, () async => cle);
    final db = sqlite3.open(fichier.path);
    appliquerCle(db, cle);
    db.execute('CREATE TABLE t (v TEXT)');
    db.close();

    await expectLater(
      preparerFichier(fichier, () async => throw Exception('Keystore')),
      throwsException,
    );
    expect(cleOuvre(fichier, cle), isTrue);
  });

  test('un magasin en panne laisse une base en clair telle quelle', () async {
    baseEnClair();
    final r = await preparerFichier(
      fichier,
      () async => throw Exception('Keystore'),
    );
    expect(r.cle, isNull);
    expect(estEnClair(fichier), isTrue);
  });

  test('sans cle fiable, la base reste en clair', () async {
    baseEnClair();
    final r = await preparerFichier(fichier, () async => null);
    expect(r.cle, isNull);
    expect(r.misDeCote, isNull);
    expect(lisibleSansCle(), isTrue);
  });

  test('la base Atrium se cree, se migre et se rouvre chiffree', () async {
    final cle = nouvelleCle();
    await preparerFichier(fichier, () async => cle);
    QueryExecutor ouvrir() => NativeDatabase(
      fichier,
      setup: (db) {
        appliquerCle(db, cle);
        db.execute('PRAGMA journal_mode = WAL');
      },
    );

    var db = AtriumDatabase(ouvrir());
    final tables = await db
        .customSelect("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table'")
        .getSingle();
    expect(tables.read<int>('n'), greaterThan(20));
    await db.close();

    db = AtriumDatabase(ouvrir());
    await db.customSelect('SELECT 1').get();
    await db.close();

    expect(estEnClair(fichier), isFalse);
    expect(lisibleSansCle(), isFalse);
  });
}
