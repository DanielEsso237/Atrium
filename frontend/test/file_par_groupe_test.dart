/// Un refus ne retient que son groupe (correction 7).
///
/// Un refus du serveur arretait toute la file : l'encaissement en double
/// d'une chambre retenait le menage, les stocks et les autres dossiers de la
/// tablette jusqu'a la decision d'un responsable.
library;

import 'dart:async';
import 'dart:io';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/groupes_de_la_file.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/outbox.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/features/sync/sync_status.dart';
import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/schema_ancien.dart';

/// Un serveur qui note ce qu'il recoit, et refuse les noms qu'on lui designe.
class _Serveur extends ApiClient {
  _Serveur() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final recus = <String>[];
  final refuses = <String>{};

  Map<String, dynamic> _recevoir(String path, Object? body) {
    final corps = (body as Map?) ?? const {};
    final nom = corps['last_name'] as String? ?? path;
    if (refuses.contains(nom) || refuses.any(path.endsWith)) {
      throw const ApiException(ApiFailure.conflict, 'Refuse');
    }
    recus.add(nom);
    return {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async => _recevoir(path, body);

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async =>
      _recevoir(path, body);
}

void main() {
  group('le passage', () {
    late AtriumDatabase db;
    late GuestRepository clients;
    late _Serveur serveur;

    setUp(() async {
      db = AtriumDatabase.memory();
      await seedDemoData(db);
      clients = GuestRepository(db);
      serveur = _Serveur();
    });

    tearDown(() => db.close());

    OutboxSender envoi() => OutboxSender(db: db, api: serveur);

    Future<OutboxEntryRow> entree(int rang) async => (await (db.select(
      db.outboxEntries,
    )..orderBy([(o) => OrderingTerm(expression: o.id)])).get())[rang];

    test('un refus ne retient pas un autre dossier', () async {
      serveur.refuses.add('Kone');
      await clients.create(firstName: 'Awa', lastName: 'Kone');
      await clients.create(firstName: 'Ali', lastName: 'Diallo');

      final rapport = await envoi().drain();

      expect(serveur.recus, ['Diallo']);
      expect(rapport.arret, DrainStop.bloque);
      expect(rapport.detail, 'Refuse');
      expect(rapport.envoyees, 1);
      expect((await entree(0)).status, OutboxStatus.FAILED);
      expect((await entree(1)).status, OutboxStatus.ACKED);
    });

    test('ce qui partage son groupe attend, sans partir', () async {
      serveur.refuses.add('Kone');
      final awa = await clients.create(firstName: 'Awa', lastName: 'Kone');
      await clients.update(id: awa.id, firstName: 'Awa', lastName: 'Kone2');

      final rapport = await envoi().drain();

      expect(serveur.recus, isEmpty, reason: 'la modification attend');
      expect(rapport.arret, DrainStop.bloque);
      expect((await entree(1)).status, OutboxStatus.PENDING);
      expect((await entree(1)).attempts, 0);
    });

    test('de proche en proche : la reservation du client refuse attend, '
        'et ce qui partage son dossier aussi', () async {
      serveur.refuses.add('Kone');
      final awa = await clients.create(firstName: 'Awa', lastName: 'Kone');
      final dossier = await ReservationRepository(db).create(
        guestId: awa.id,
        roomTypeId: roomTypeSeeds.first.id,
        arrival: DateTime.utc(2026, 11, 2),
        departure: DateTime.utc(2026, 11, 4),
        nightlyRate: 25000,
      );
      await clients.create(firstName: 'Ali', lastName: 'Diallo');

      final reservation = await entree(1);
      expect(reservation.entityTable, 'reservations');
      expect(reservation.groupKeys, 'dossier:$dossier client:${awa.id}');

      final rapport = await envoi().drain();

      expect(serveur.recus, ['Diallo']);
      expect(rapport.arret, DrainStop.bloque);
      expect(reservation.id, (await entree(1)).id);
      expect((await entree(1)).status, OutboxStatus.PENDING);
    });

    test('une entree sans cle garde l ancienne regle', () async {
      serveur.refuses.add('Kone');
      await clients.create(firstName: 'Awa', lastName: 'Kone');
      await clients.create(firstName: 'Ali', lastName: 'Diallo');
      await clients.create(firstName: 'Ida', lastName: 'Sow');
      // La deuxieme vient d'avant le schema 20 : on ne sait pas ce dont elle
      // depend.
      final sansCle = await entree(1);
      await (db.update(db.outboxEntries)..where((o) => o.id.equals(sansCle.id)))
          .write(const OutboxEntriesCompanion(groupKeys: Value(null)));

      await envoi().drain();

      expect(serveur.recus, isEmpty, reason: 'elle attend, et retient tout');
    });

    test('le refus deja connu se retente, et ce qui l attendait part '
        'derriere lui', () async {
      serveur.refuses.add('Kone');
      final awa = await clients.create(firstName: 'Awa', lastName: 'Kone');
      await envoi().drain();
      expect((await entree(0)).status, OutboxStatus.FAILED);

      await clients.update(id: awa.id, firstName: 'Awa', lastName: 'Kone2');
      await clients.create(firstName: 'Ali', lastName: 'Diallo');
      serveur.refuses.clear();

      final rapport = await envoi().drain();

      // Le refus d'hier passe ; ce qui l'attendait part derriere lui.
      expect(serveur.recus, ['Kone', 'Kone2', 'Diallo']);
      expect(rapport.arret, DrainStop.termine);
    });

    test('ce que le refus retient est ce qui attend derriere lui', () async {
      serveur.refuses.add('Kone');
      final awa = await clients.create(firstName: 'Awa', lastName: 'Kone');
      await clients.update(id: awa.id, firstName: 'Awa', lastName: 'Kone2');
      await clients.create(firstName: 'Ali', lastName: 'Diallo');
      await clients.create(firstName: 'Ida', lastName: 'Sow');
      serveur.refuses.add('Diallo');

      await envoi().drain();

      final file =
          await (db.select(db.outboxEntries)
                ..where(
                  (o) => o.status.isInValues([
                    OutboxStatus.PENDING,
                    OutboxStatus.FAILED,
                  ]),
                )
                ..orderBy([(o) => OrderingTerm(expression: o.id)]))
              .get();
      expect(retenuesDerriere(file, file.first), 1);
    });
  });

  group('les ecritures d un collegue', () {
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

    test('retiennent leur groupe, pas le reste', () async {
      await db.declarerAuteur(recep);
      final awa = await clients.create(firstName: 'Awa', lastName: 'Kone');
      await db.declarerAuteur(menage);
      await clients.update(id: awa.id, firstName: 'Awa', lastName: 'Kone2');
      await clients.create(firstName: 'Ali', lastName: 'Diallo');

      final rapport = await OutboxSender(db: db, api: serveur).drain();

      // La modification attend la creation du receptionniste, sans partir
      // en 404 ; le reste part.
      expect(serveur.recus, ['Diallo']);
      expect(rapport.arret, DrainStop.attenteAutrui);
    });
  });

  group('un sejour', () {
    late AtriumDatabase db;
    late _Serveur serveur;
    late String recep;

    setUp(() async {
      db = AtriumDatabase.memory();
      await db.customStatement('PRAGMA foreign_keys = ON');
      await seedDemoData(db);
      await seedAccounts(db);
      serveur = _Serveur();
      recep = (await (db.select(
        db.users,
      )..where((u) => u.employeeCode.equals('RECEP01'))).getSingle()).id;
      await db.declarerAuteur(recep);
    });

    tearDown(() => db.close());

    /// Arrivee, consommation, encaissement, cloture de caisse.
    Future<({String dossier, String chambre})> sejour() async {
      final client = await GuestRepository(
        db,
      ).create(firstName: 'Awa', lastName: 'Diallo');
      final chambre =
          (await db
                  .customSelect("SELECT id FROM rooms WHERE number = '101'")
                  .getSingle())
              .read<String>('id');
      final reservations = ReservationRepository(db);
      final dossier = await reservations.create(
        guestId: client.id,
        roomTypeId: roomTypeSeeds.first.id,
        arrival: DateTime(2026, 10, 27),
        departure: DateTime(2026, 10, 28),
        nightlyRate: 25000,
        roomId: chambre,
      );
      final ligne = await (db.select(
        db.reservationRooms,
      )..where((rr) => rr.reservationId.equals(dossier))).getSingle();
      await reservations.checkIn(lineId: ligne.id);
      final folios = FolioRepository(db);
      final ardoise = (await folios.openFolioForStay(ligne.id))!;
      await folios.addCharge(
        folioId: ardoise.id,
        category: ChargeCategory.MINIBAR,
        label: 'Biere',
        unitPrice: 1500,
      );
      final caisse = CashRepository(db);
      final session = await caisse.open(userId: recep, openingFloat: 0);
      await folios.addPayment(
        folioId: ardoise.id,
        method: PaymentMethod.CASH,
        amount: 1500,
        receivedBy: recep,
      );
      await caisse.close(sessionId: session, countedAmount: 1500);
      return (dossier: dossier, chambre: chambre);
    }

    test('chaque ecriture connait son dossier', () async {
      final s = await sejour();
      final file = await (db.select(
        db.outboxEntries,
      )..orderBy([(o) => OrderingTerm(expression: o.id)])).get();
      final cles = {
        for (final e in file)
          '${e.entityTable}/${e.op.name}/${e.payload.contains('"CHECKED_IN"')}':
              e.groupKeys,
      };

      expect(file.where((e) => e.groupKeys == null), isEmpty);
      expect(
        cles['reservation_rooms/UPDATE/true'],
        'dossier:${s.dossier} chambre:${s.chambre}',
      );
      expect(cles['folio_items/INSERT/false'], 'dossier:${s.dossier}');
      expect(
        cles['payments/INSERT/false'],
        'dossier:${s.dossier} >caisse:$recep',
      );
      expect(file.last.entityTable, 'cash_sessions');
      expect(file.last.groupKeys, 'caisse:$recep');
    });

    test('un encaissement refuse retient la cloture, pas le reste', () async {
      await sejour();
      await GuestRepository(db).create(firstName: 'Ali', lastName: 'Sow');
      serveur.refuses.add('/payments');

      final rapport = await OutboxSender(db: db, api: serveur).drain();

      expect(rapport.arret, DrainStop.bloque);
      expect(serveur.recus.where((r) => r.endsWith('/close')), isEmpty);
      expect(serveur.recus, contains('Sow'));
    });
  });

  group('la retenue', () {
    test('une caisse se nourrit sans retenir les autres encaissements', () {
      final r = Retenue()..retenir('dossier:R1 >caisse:U');
      expect(r.retient('dossier:R2 >caisse:U'), isFalse);
      expect(r.retient('caisse:U'), isTrue, reason: 'la cloture attend');
      expect(r.retient('dossier:R1'), isTrue);
    });

    test('un point de vente se suppose sans se nourrir', () {
      final r = Retenue()..retenir('ardoise:A <pdv:O');
      expect(r.retient('ardoise:B <pdv:O'), isFalse);
      final creation = Retenue()..retenir('pdv:O');
      expect(creation.retient('ardoise:B <pdv:O'), isTrue);
    });

    test('sans cle : attend si quoi que ce soit attend, et retient tout', () {
      final r = Retenue();
      expect(r.retient(null), isFalse);
      r.retenir('client:G');
      expect(r.retient(null), isTrue);
      r.retenir(null);
      expect(r.retient('client:H'), isTrue);
    });
  });

  group('la relance automatique', () {
    late AtriumDatabase db;

    setUp(() => db = AtriumDatabase.memory());
    tearDown(() => db.close());

    Future<({_Envoi envoi, StreamController<int> file})> monter(
      DrainStop arret,
    ) async {
      final envoi = _Envoi(db, arret);
      final file = StreamController<int>();
      addTearDown(file.close);
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          outboxSenderProvider.overrideWithValue(envoi),
          pendingWritesProvider.overrideWith((ref) => file.stream),
        ],
      );
      addTearDown(c.dispose);
      c.listen(syncSchedulerProvider, (_, _) {});
      c.listen(pendingWritesProvider, (_, _) {});
      return (envoi: envoi, file: file);
    }

    Future<void> attendre() =>
        Future<void>.delayed(const Duration(milliseconds: 800));

    test('apres un refus, une ecriture neuve relance la file', () async {
      final m = await monter(DrainStop.bloque);
      m.file.add(1);
      await attendre();
      expect(m.envoi.passages, 1);

      m.file.add(1);
      await attendre();
      expect(m.envoi.passages, 1, reason: 'rien de neuf : il ne retente pas');

      m.file.add(2);
      await attendre();
      expect(m.envoi.passages, 2);
    });

    test('sans session, une ecriture neuve n y change rien', () async {
      final m = await monter(DrainStop.sessionInvalide);
      m.file.add(1);
      await attendre();
      m.file.add(2);
      await attendre();
      expect(m.envoi.passages, 1);
    });
  });

  test(
    'une tablette deployee garde ses envois, sans cle : l ordre strict',
    () async {
      final dossier = Directory.systemTemp.createTempSync('atrium_groupes');
      addTearDown(() => dossier.deleteSync(recursive: true));
      final fichier = File('${dossier.path}/atrium.sqlite');

      var base = AtriumDatabase(NativeDatabase(fichier));
      await base.customSelect('SELECT 1').get();
      await retirerColonnesApres(base, 19);
      await base.customStatement(
        "INSERT INTO outbox_entries (entity_table, entity_id, op, payload, "
        "created_at, status) VALUES ('guests', "
        "'01a1692b-ac12-70ef-b38e-c807dc4f3505', 'INSERT', '{}', "
        "'2026-10-27T10:00:00Z', 'FAILED')",
      );
      await base.customStatement('PRAGMA user_version = 19');
      await base.close();

      base = AtriumDatabase(NativeDatabase(fichier));
      final e = await base.select(base.outboxEntries).getSingle();
      expect(e.status, OutboxStatus.FAILED);
      expect(e.groupKeys, isNull);
      await base.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Un envoi qui rend toujours le meme arret, et compte ses passages.
class _Envoi extends OutboxSender {
  _Envoi(AtriumDatabase db, this.arret)
    : super(
        db: db,
        api: ApiClient(
          baseUrl: 'http://serveur.invalide',
          tokens: const TokenStore(),
        ),
      );

  final DrainStop arret;
  var passages = 0;

  @override
  Future<DrainReport> drain({int max = 200, String? pour}) async {
    passages++;
    return DrainReport(envoyees: 0, restantes: 1, arret: arret);
  }
}
