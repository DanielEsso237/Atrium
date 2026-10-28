/// Chaque agent remonte ses ecritures, et seulement les siennes.
///
/// Vecu le 25 octobre : un encaissement du receptionniste, reste dans la
/// file de la tablette, partait avec le jeton de l'agent du menage connecte
/// apres lui. Le serveur le refusait (403, `folio.write`) et toute la file
/// du menage se bloquait derriere.
library;

import 'dart:io';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/ecriture_refusee.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outbox.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un serveur qui note les clients recus, et refuse ceux qu'on lui designe.
class _Serveur extends ApiClient {
  _Serveur() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final recus = <String>[];
  final refuses = <String>{};

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final nom = (body as Map)['last_name'] as String;
    if (refuses.contains(nom)) {
      throw const ApiException(ApiFailure.forbidden, 'Permission manquante');
    }
    recus.add(nom);
    return {};
  }
}

void main() {
  late AtriumDatabase db;
  late GuestRepository clients;
  late _Serveur serveur;
  late String recep;
  late String menage;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    await seedAccounts(db);
    clients = GuestRepository(db);
    serveur = _Serveur();
    Future<String> id(String code) async => (await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals(code))).getSingle()).id;
    recep = await id('RECEP01');
    menage = await id('MENAGE01');
  });

  tearDown(() => db.close());

  Future<void> ecrirePar(String agent, String nom) async {
    await db.declarerAuteur(agent);
    await clients.create(firstName: 'Client', lastName: nom);
  }

  OutboxSender envoi() => OutboxSender(db: db, api: serveur);

  test("l'ecriture porte l'agent de la session", () async {
    await ecrirePar(recep, 'Kone');

    final e = await db.select(db.outboxEntries).getSingle();
    expect(e.authorId, recep);
  });

  test("les ecritures d'un collegue attendent leur auteur", () async {
    await ecrirePar(recep, 'Kone');
    await ecrirePar(menage, 'Diallo');

    final rapport = await envoi().drain();

    expect(serveur.recus, ['Diallo']);
    expect(rapport.arret, DrainStop.termine);
    // Pour le menage, la file est vide : rien ne doit la relancer en boucle.
    expect(rapport.restantes, 0);
    expect(await db.watchPendingCount().first, 0);
    expect(await db.watchEnvoisDAutrui().first, [(agent: 'RECEP01', n: 1)]);

    // Le receptionniste revient : la sienne part.
    await db.declarerAuteur(recep);
    await envoi().drain();
    expect(serveur.recus, ['Diallo', 'Kone']);
    expect(await db.watchEnvoisDAutrui().first, isEmpty);
  });

  test("le refus d'une ecriture de collegue ne bloque plus personne", () async {
    // Ce que le serveur refuserait au menage, il ne le recoit jamais de lui.
    serveur.refuses.add('Kone');
    await ecrirePar(recep, 'Kone');
    await ecrirePar(menage, 'Diallo');

    final rapport = await envoi().drain();

    expect(rapport.arret, DrainStop.termine);
    expect(serveur.recus, ['Diallo']);
    expect(await ecritureRefusee(db), isNull);
  });

  test(
    "un refus derriere l'ecriture d'un collegue attend, sans bloquer",
    () async {
      // La consommation du menage depend peut-etre de l'arrivee que le
      // receptionniste n'a pas encore remontee.
      serveur.refuses.add('Diallo');
      await ecrirePar(recep, 'Kone');
      await ecrirePar(menage, 'Diallo');

      final rapport = await envoi().drain();

      expect(rapport.arret, DrainStop.attenteAutrui);
      final e = await (db.select(
        db.outboxEntries,
      )..where((o) => o.authorId.equals(menage))).getSingle();
      expect(e.status, OutboxStatus.PENDING);
      expect(await ecritureRefusee(db), isNull);
    },
  );

  test('sans collegue en attente, un refus bloque comme avant', () async {
    serveur.refuses.add('Diallo');
    await ecrirePar(menage, 'Diallo');

    final rapport = await envoi().drain();

    expect(rapport.arret, DrainStop.bloque);
    expect((await ecritureRefusee(db))?.raison, 'Permission manquante');
  });

  test("une ecriture sans auteur part avec n'importe quelle session", () async {
    await ecrirePar(recep, 'Kone');
    await (db.update(
      db.outboxEntries,
    )).write(const OutboxEntriesCompanion(authorId: Value(null)));
    await db.declarerAuteur(menage);

    await envoi().drain();

    expect(serveur.recus, ['Kone']);
  });

  test(
    "une tablette deja deployee retrouve l'auteur des envois en attente",
    () async {
      final dossier = Directory.systemTemp.createTempSync('atrium_file');
      addTearDown(() => dossier.deleteSync(recursive: true));
      final fichier = File('${dossier.path}/atrium.sqlite');

      // Une base en version 15 : pas de colonne d'auteur, un encaissement en
      // attente qui dit qui l'a recu.
      var base = AtriumDatabase(NativeDatabase(fichier));
      await base.customSelect('SELECT 1').get();
      await base.customStatement(
        'ALTER TABLE outbox_entries DROP COLUMN author_id',
      );
      await base.customStatement(
        "INSERT INTO outbox_entries (entity_table, entity_id, op, payload, "
        "created_at, status) VALUES ('payments', "
        "'01a1692b-ac12-70ef-b38e-c807dc4f3505', 'INSERT', "
        "'{\"received_by\": \"$recep\"}', '2026-10-25T10:00:00Z', 'FAILED')",
      );
      // Une tablette d'avant le schema 20 n'a pas les cles de regroupement.
      await base.customStatement(
        'ALTER TABLE outbox_entries DROP COLUMN group_keys',
      );
      await base.customStatement('PRAGMA user_version = 15');
      await base.close();

      base = AtriumDatabase(NativeDatabase(fichier));
      final e = await base.select(base.outboxEntries).getSingle();
      expect(e.authorId, recep);
      await base.close();
    },
  );
}
