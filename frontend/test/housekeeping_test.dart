/// Le menage, du depart du client a la chambre redevenue disponible.
///
/// La boucle complete est ce qui compte ici : un depart doit produire du
/// travail visible pour la femme de chambre, et son geste doit se voir sur le
/// plan de la reception. Une rupture au milieu ne fait rien planter -- elle
/// laisse juste une chambre sale que personne ne nettoie, ou une chambre
/// propre que personne ne peut vendre.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/housekeeping_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late HousekeepingRepository menage;
  late ReservationRepository reservations;

  final typeStandard = roomTypeSeeds.first.id;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    menage = HousekeepingRepository(db);
    reservations = ReservationRepository(db);
  });

  tearDown(() => db.close());

  Future<String> premiereChambre() async {
    final l = await db
        .customSelect('SELECT id FROM rooms ORDER BY number LIMIT 1')
        .getSingle();
    return l.read<String>('id');
  }

  Future<HousekeepingStatus> etatChambre(String roomId) async {
    final r = await (db.select(
      db.rooms,
    )..where((r) => r.id.equals(roomId))).getSingle();
    return r.housekeepingStatus;
  }

  Future<int> enFile(String table) async {
    final r = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM outbox_entries WHERE entity_table = ?',
          variables: [Variable.withString(table)],
        )
        .getSingle();
    return r.read<int>('n');
  }

  test('ouvrir une tache la rend visible et met la chambre a faire', () async {
    final roomId = await premiereChambre();
    final taskId = await menage.openTask(roomId: roomId);

    final jobs = await menage.watchJobs().first;
    expect(jobs, hasLength(1));
    expect(jobs.single.taskId, taskId);
    expect(jobs.single.status, TaskStatus.PENDING);
    expect(jobs.single.faite, isFalse);
  });

  test('deux ouvertures le meme jour ne font qu une tache', () async {
    // Un depart enregistre deux fois, ou un ecran rejoue : la femme de chambre
    // verrait la meme chambre deux fois dans sa liste et croirait a une
    // erreur. Pire, le second passage serait compte comme du travail fait.
    final roomId = await premiereChambre();
    final a = await menage.openTask(roomId: roomId);
    final b = await menage.openTask(roomId: roomId);

    expect(a, b);
    expect(await menage.watchJobs().first, hasLength(1));
    expect(await enFile('housekeeping_tasks'), 1);
  });

  test('commencer puis terminer fait le tour complet', () async {
    final roomId = await premiereChambre();
    final taskId = await menage.openTask(roomId: roomId);

    await menage.start(taskId);
    expect(await etatChambre(roomId), HousekeepingStatus.IN_PROGRESS);
    expect((await menage.watchJobs().first).single.enCours, isTrue);

    await menage.finish(taskId);
    expect(await etatChambre(roomId), HousekeepingStatus.CLEAN);
    expect((await menage.watchJobs().first).single.faite, isTrue);
  });

  test('terminer sans avoir commence est refuse', () async {
    final roomId = await premiereChambre();
    // Etat reel apres un depart : la chambre est sale. Sans cette mise en
    // place, elle est propre des le depart et l'assertion de fin passerait
    // toute seule -- le test aurait l'air vert sans rien verifier.
    await db.customStatement(
      "UPDATE rooms SET housekeeping_status = 'DIRTY' WHERE id = ?",
      [roomId],
    );
    final taskId = await menage.openTask(roomId: roomId);

    await expectLater(menage.finish(taskId), throwsA(isA<StateError>()));

    // Ni la chambre ni la tache n'ont bouge, et rien n'est parti au serveur :
    // un refus qui laisserait une trace serait pire que pas de refus du tout.
    expect(await etatChambre(roomId), HousekeepingStatus.DIRTY);
    expect((await menage.watchJobs().first).single.status, TaskStatus.PENDING);
    expect(await enFile('housekeeping_tasks'), 1); // la creation, rien d'autre
  });

  test('rejouer une transition deja faite ne change rien', () async {
    final roomId = await premiereChambre();
    final taskId = await menage.openTask(roomId: roomId);

    await menage.start(taskId);
    await menage.start(taskId); // double appui, ou ecran rejoue

    // Une seule entree de transition en file : sinon le serveur recevrait
    // deux fois `/start` et la duree de menage repartirait de zero.
    expect(await enFile('housekeeping_tasks'), 2); // 1 creation + 1 demarrage
  });

  test('chaque geste alimente la file d envoi', () async {
    final roomId = await premiereChambre();
    final taskId = await menage.openTask(roomId: roomId);
    await menage.start(taskId);
    await menage.finish(taskId);

    // Creation, demarrage, fin : rien ne doit se perdre si la tablette est
    // hors ligne pendant tout le service.
    expect(await enFile('housekeeping_tasks'), 3);
  });

  test('un depart ouvre le menage de la chambre liberee', () async {
    // La boucle qui compte : sans elle, la chambre serait sale sur le plan et
    // invisible pour la femme de chambre.
    final roomId = await premiereChambre();
    final guestId = await _client(db);

    await reservations.create(
      guestId: guestId,
      roomTypeId: typeStandard,
      arrival: DateTime.utc(2026, 9, 20),
      departure: DateTime.utc(2026, 9, 22),
      nightlyRate: 25000,
      roomId: roomId,
    );
    final ligne = await db
        .customSelect('SELECT id FROM reservation_rooms LIMIT 1')
        .getSingle();
    final lineId = ligne.read<String>('id');

    await reservations.checkIn(lineId: lineId);
    expect(await menage.watchJobs().first, isEmpty);

    await reservations.checkOut(lineId: lineId);

    final jobs = await menage.watchJobs().first;
    expect(jobs, hasLength(1));
    expect(jobs.single.roomId, roomId);
    expect(jobs.single.type, HousekeepingTaskType.DEPARTURE);
    expect(await etatChambre(roomId), HousekeepingStatus.DIRTY);
  });
}

Future<String> _client(AtriumDatabase db) async {
  final repo = GuestRepositoryStub(db);
  return repo.creer();
}

/// Un client minimal, sans passer par le depot complet : ce test ne parle pas
/// des clients, il a juste besoin qu'il en existe un.
class GuestRepositoryStub {
  GuestRepositoryStub(this.db);
  final AtriumDatabase db;

  Future<String> creer() async {
    const id = '01920000-0000-7000-8000-000000009901';
    final now = DateTime.now().toUtc();
    await db
        .into(db.guests)
        .insert(
          GuestsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            hotelId: '01920000-0000-7000-8000-000000000001',
            code: 'CLI-09901',
            firstName: 'Amadou',
            lastName: 'Kone',
          ),
        );
    return id;
  }
}
