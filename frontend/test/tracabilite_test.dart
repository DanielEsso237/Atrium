/// Tracabilite (exigence 6.2 du cahier des charges) : chaque ecriture garde
/// l'agent qui l'a faite.
///
/// Deux endroits a verifier, parce qu'ils peuvent diverger : la ligne locale
/// (Drift) et la charge envoyee au serveur (outbox). Une valeur presente en
/// local mais absente du payload n'arrive jamais au serveur.
///
/// Et le cas inverse : sans session (mode kiosque, session expiree au milieu
/// d'une action), `by` est nul. L'ecriture doit reussir et garder un auteur
/// nul, jamais un faux auteur.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/housekeeping_repository.dart';
import 'package:atrium/data/repositories/invoice_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 36 caracteres : la colonne cash_sessions.user_id l'exige.
  const agent = '01920000-0000-7000-8000-00000000a001';
  const hotel = '01920000-0000-7000-8000-000000000001';
  const folioId = '01920000-0000-7000-8000-000000009001';

  late AtriumDatabase db;
  late GuestRepository guests;
  late ReservationRepository reservations;
  late FolioRepository folios;
  late HousekeepingRepository menage;
  late InvoiceRepository factures;
  late CashRepository caisse;

  final typeStandard = roomTypeSeeds.first.id;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    guests = GuestRepository(db);
    reservations = ReservationRepository(db);
    folios = FolioRepository(db);
    menage = HousekeepingRepository(db);
    factures = InvoiceRepository(db);
    caisse = CashRepository(db);
  });

  tearDown(() => db.close());

  /// Les payloads enfiles pour une table, dans l'ordre d'enfilage.
  Future<List<Map<String, dynamic>>> payloads(String table) async {
    final lignes = (await db.select(db.outboxEntries).get())
        .where((e) => e.entityTable == table)
        .toList();
    lignes.sort((a, b) => a.id.compareTo(b.id));
    return lignes
        .map((e) => jsonDecode(e.payload) as Map<String, dynamic>)
        .toList();
  }

  Future<String> uneChambre() async {
    final l = await db
        .customSelect('SELECT id FROM rooms ORDER BY number LIMIT 1')
        .getSingle();
    return l.read<String>('id');
  }

  Future<String> reserver({String? by, bool avecChambre = true}) async {
    final client = await guests.create(firstName: 'Amadou', lastName: 'Kone');
    return reservations.create(
      guestId: client.id,
      roomTypeId: typeStandard,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 3),
      nightlyRate: 25000,
      roomId: avecChambre ? await uneChambre() : null,
      createdBy: by,
    );
  }

  Future<void> ouvrirArdoise() async {
    final now = DateTime.now().toUtc();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: folioId,
            createdAt: now,
            updatedAt: now,
            hotelId: hotel,
            number: 'FOL-000001',
            type: const Value(FolioType.GUEST),
            status: const Value(FolioStatus.OPEN),
          ),
        );
  }

  Future<void> porterUneCharge() => folios.addCharge(
    folioId: folioId,
    category: ChargeCategory.FNB,
    label: 'Room service',
    unitPrice: 18500,
  );

  group('guest', () {
    test('create : agent en local et dans la file', () async {
      final g = await guests.create(
        firstName: 'Awa',
        lastName: 'Diallo',
        createdBy: agent,
      );

      expect(g.createdBy, agent);
      expect((await payloads('guests')).single['created_by'], agent);
    });

    test('create sans agent : auteur nul, rien ne plante', () async {
      final g = await guests.create(firstName: 'Awa', lastName: 'Diallo');

      expect(g.createdBy, isNull);
      expect(
        (await payloads('guests')).single,
        containsPair('created_by', isNull),
      );
    });
  });

  group('reservation', () {
    test('create : agent sur la reservation, la ligne et le payload', () async {
      await reserver(by: agent);

      final res = await db.select(db.reservations).getSingle();
      final ligne = await db.select(db.reservationRooms).getSingle();
      expect(res.createdBy, agent);
      expect(ligne.createdBy, agent);

      final p = (await payloads('reservations')).single;
      expect(p['created_by'], agent);
      expect((p['rooms'] as List).first['created_by'], agent);
    });

    test('create sans agent : auteur nul partout', () async {
      await reserver();

      final res = await db.select(db.reservations).getSingle();
      final ligne = await db.select(db.reservationRooms).getSingle();
      expect(res.createdBy, isNull);
      expect(ligne.createdBy, isNull);

      final p = (await payloads('reservations')).single;
      expect(p, containsPair('created_by', isNull));
      expect((p['rooms'] as List).first, containsPair('created_by', isNull));
    });

    test('assignRoom : agent en local et dans la file', () async {
      await reserver(avecChambre: false);
      final ligne = await db.select(db.reservationRooms).getSingle();

      await reservations.assignRoom(
        lineId: ligne.id,
        roomId: await uneChambre(),
        by: agent,
      );

      final apres = await db.select(db.reservationRooms).getSingle();
      expect(apres.updatedBy, agent);
      expect((await payloads('reservation_rooms')).single['updated_by'], agent);
    });

    test('assignRoom sans agent : auteur nul', () async {
      await reserver(avecChambre: false);
      final ligne = await db.select(db.reservationRooms).getSingle();

      await reservations.assignRoom(
        lineId: ligne.id,
        roomId: await uneChambre(),
      );

      final apres = await db.select(db.reservationRooms).getSingle();
      expect(apres.updatedBy, isNull);
      expect(
        (await payloads('reservation_rooms')).single,
        containsPair('updated_by', isNull),
      );
    });

    test('checkIn : agent sur la ligne, le payload et les nuits', () async {
      await reserver();
      final ligne = await db.select(db.reservationRooms).getSingle();

      await reservations.checkIn(lineId: ligne.id, by: agent);

      final apres = await db.select(db.reservationRooms).getSingle();
      expect(apres.checkedInBy, agent);

      final p = (await payloads(
        'reservation_rooms',
      )).firstWhere((p) => p['status'] == 'CHECKED_IN');
      expect(p['checked_in_by'], agent);

      // Les nuits portees a l'ardoise par le check-in gardent le meme agent.
      final nuits = await db.select(db.folioItems).get();
      expect(nuits, isNotEmpty);
      expect(nuits.every((n) => n.postedBy == agent), isTrue);
    });

    test('checkIn sans agent : auteur nul, le sejour demarre', () async {
      await reserver();
      final ligne = await db.select(db.reservationRooms).getSingle();

      await reservations.checkIn(lineId: ligne.id);

      final apres = await db.select(db.reservationRooms).getSingle();
      expect(apres.status, ReservationStatus.CHECKED_IN);
      expect(apres.checkedInBy, isNull);

      final p = (await payloads(
        'reservation_rooms',
      )).firstWhere((p) => p['status'] == 'CHECKED_IN');
      expect(p, containsPair('checked_in_by', isNull));
    });

    test('checkOut : agent sur la ligne, le payload et le menage', () async {
      await reserver();
      final ligne = await db.select(db.reservationRooms).getSingle();
      await reservations.checkIn(lineId: ligne.id, by: agent);

      await reservations.checkOut(lineId: ligne.id, by: agent);

      final apres = await db.select(db.reservationRooms).getSingle();
      expect(apres.checkedOutBy, agent);

      final p = (await payloads(
        'reservation_rooms',
      )).firstWhere((p) => p['status'] == 'CHECKED_OUT');
      expect(p['checked_out_by'], agent);

      // Le depart ouvre une tache de menage, qui garde le meme agent.
      final tache = await db.select(db.housekeepingTasks).getSingle();
      expect(tache.createdBy, agent);
    });

    test('checkOut sans agent : auteur nul, le depart aboutit', () async {
      await reserver();
      final ligne = await db.select(db.reservationRooms).getSingle();
      await reservations.checkIn(lineId: ligne.id);

      await reservations.checkOut(lineId: ligne.id);

      final apres = await db.select(db.reservationRooms).getSingle();
      expect(apres.status, ReservationStatus.CHECKED_OUT);
      expect(apres.checkedOutBy, isNull);

      final p = (await payloads(
        'reservation_rooms',
      )).firstWhere((p) => p['status'] == 'CHECKED_OUT');
      expect(p, containsPair('checked_out_by', isNull));
    });
  });

  group('folio', () {
    test('addCharge : agent en local et dans la file', () async {
      await ouvrirArdoise();
      await folios.addCharge(
        folioId: folioId,
        category: ChargeCategory.FNB,
        label: 'Room service',
        unitPrice: 18500,
        postedBy: agent,
      );

      final ligne = await db.select(db.folioItems).getSingle();
      expect(ligne.postedBy, agent);
      expect((await payloads('folio_items')).single['posted_by'], agent);
    });

    test('addCharge sans agent : auteur nul', () async {
      await ouvrirArdoise();
      await porterUneCharge();

      final ligne = await db.select(db.folioItems).getSingle();
      expect(ligne.postedBy, isNull);
      expect(
        (await payloads('folio_items')).single,
        containsPair('posted_by', isNull),
      );
    });

    test('addPayment : agent en local et dans la file', () async {
      await ouvrirArdoise();
      await porterUneCharge();

      await folios.addPayment(
        folioId: folioId,
        method: PaymentMethod.CASH,
        amount: 18500,
        receivedBy: agent,
      );

      final paiement = await db.select(db.payments).getSingle();
      expect(paiement.receivedBy, agent);
      expect((await payloads('payments')).single['received_by'], agent);
    });

    test('addPayment sans agent : auteur nul, encaissement accepte', () async {
      await ouvrirArdoise();
      await porterUneCharge();

      await folios.addPayment(
        folioId: folioId,
        method: PaymentMethod.CASH,
        amount: 18500,
      );

      final paiement = await db.select(db.payments).getSingle();
      expect(paiement.receivedBy, isNull);
      expect(
        (await payloads('payments')).single,
        containsPair('received_by', isNull),
      );
    });

    test('close : agent en local et dans la file', () async {
      await ouvrirArdoise();
      await porterUneCharge();
      await folios.addPayment(
        folioId: folioId,
        method: PaymentMethod.CASH,
        amount: 18500,
      );

      await folios.close(folioId, by: agent);

      final folio = await db.select(db.folios).getSingle();
      expect(folio.updatedBy, agent);
      expect((await payloads('folios')).single['updated_by'], agent);
    });

    test('close sans agent : auteur nul, l\'ardoise se ferme', () async {
      await ouvrirArdoise();
      await porterUneCharge();
      await folios.addPayment(
        folioId: folioId,
        method: PaymentMethod.CASH,
        amount: 18500,
      );

      await folios.close(folioId);

      final folio = await db.select(db.folios).getSingle();
      expect(folio.status, FolioStatus.CLOSED);
      expect(folio.updatedBy, isNull);
      expect(
        (await payloads('folios')).single,
        containsPair('updated_by', isNull),
      );
    });
  });

  group('housekeeping', () {
    test('openTask : agent en local et dans la file', () async {
      await menage.openTask(roomId: await uneChambre(), by: agent);

      final tache = await db.select(db.housekeepingTasks).getSingle();
      expect(tache.createdBy, agent);
      expect((await payloads('housekeeping_tasks')).single['created_by'], agent);
    });

    test('openTask sans agent : auteur nul', () async {
      await menage.openTask(roomId: await uneChambre());

      final tache = await db.select(db.housekeepingTasks).getSingle();
      expect(tache.createdBy, isNull);
      expect(
        (await payloads('housekeeping_tasks')).single,
        containsPair('created_by', isNull),
      );
    });

    test('startRoom puis finish : agent sur chaque transition', () async {
      final taskId = await menage.startRoom(await uneChambre(), by: agent);
      await menage.finish(taskId, by: agent);

      final tache = await db.select(db.housekeepingTasks).getSingle();
      expect(tache.assignedTo, agent);

      // Le premier payload est l'INSERT ; les deux suivants sont les
      // transitions (demarrage, fin), qui portent toutes un statut.
      final transitions = (await payloads(
        'housekeeping_tasks',
      )).where((p) => p.containsKey('status')).toList();
      expect(transitions, hasLength(2));
      expect(transitions.every((p) => p['assigned_to'] == agent), isTrue);
    });

    test('startRoom sans agent : auteur nul, le menage avance', () async {
      final taskId = await menage.startRoom(await uneChambre());
      await menage.finish(taskId);

      final tache = await db.select(db.housekeepingTasks).getSingle();
      expect(tache.status, TaskStatus.DONE);
      expect(tache.assignedTo, isNull);

      final transitions = (await payloads(
        'housekeeping_tasks',
      )).where((p) => p.containsKey('status')).toList();
      expect(transitions, hasLength(2));
      expect(
        transitions.every((p) => p.containsKey('assigned_to')),
        isTrue,
        reason: 'la cle doit etre presente meme quand elle est nulle',
      );
      expect(transitions.every((p) => p['assigned_to'] == null), isTrue);
    });
  });

  group('invoice', () {
    test('issue : agent en local et dans la file', () async {
      await ouvrirArdoise();
      await porterUneCharge();

      await factures.issue(folioId, by: agent);

      final facture = await db.select(db.invoices).getSingle();
      expect(facture.createdBy, agent);
      expect((await payloads('invoices')).single['created_by'], agent);
    });

    test('issue sans agent : auteur nul, facture emise', () async {
      await ouvrirArdoise();
      await porterUneCharge();

      await factures.issue(folioId);

      final facture = await db.select(db.invoices).getSingle();
      expect(facture.createdBy, isNull);
      expect(
        (await payloads('invoices')).single,
        containsPair('created_by', isNull),
      );
    });
  });

  group('cash', () {
    test('open puis close : agent en local et dans la file', () async {
      final id = await caisse.open(
        userId: agent,
        openingFloat: 50000,
        by: agent,
      );

      var session = await db.select(db.cashSessions).getSingle();
      expect(session.createdBy, agent);
      expect((await payloads('cash_sessions')).single['created_by'], agent);

      await caisse.close(sessionId: id, countedAmount: 50000, by: agent);

      session = await db.select(db.cashSessions).getSingle();
      expect(session.updatedBy, agent);
      expect((await payloads('cash_sessions')).last['updated_by'], agent);
    });

    test('open puis close sans agent : auteur nul, caisse fermee', () async {
      final id = await caisse.open(userId: agent, openingFloat: 50000);
      await caisse.close(sessionId: id, countedAmount: 50000);

      final session = await db.select(db.cashSessions).getSingle();
      expect(session.status, CashSessionStatus.CLOSED);
      expect(session.createdBy, isNull);
      expect(session.updatedBy, isNull);

      final envois = await payloads('cash_sessions');
      expect(envois.first, containsPair('created_by', isNull));
      expect(envois.last, containsPair('updated_by', isNull));
    });
  });
}