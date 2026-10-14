/// L'arrivee directe sur la tablette (ticket D7, 14 octobre).
///
/// Un voyageur sans reservation prend une chambre, en nuits ou en heures, au
/// prix du sejour entier. Ce que le serveur refuserait est refuse avant
/// d'ecrire : sinon le refus arrive par la file et la bloque.
library;

import 'dart:convert';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/queries/dashboard_queries.dart';
import 'package:atrium/data/local/queries/report_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late ReservationRepository reservations;
  late String clientId;
  const agent = '00000000-0000-0000-0000-0000000000a1';

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    reservations = ReservationRepository(db);
    clientId = (await GuestRepository(
      db,
    ).create(firstName: 'Kofi', lastName: 'Mensah')).id;
  });

  tearDown(() => db.close());

  Future<RoomRow> chambre(String numero) => (db.select(
    db.rooms,
  )..where((r) => r.number.equals(numero))).getSingle();

  Future<void> viderLaFile() => db.delete(db.outboxEntries).go();

  test('en heures : une charge, un depart a l\'heure dite, une seule '
      'entree de file', () async {
    final c = await chambre('101');
    await viderLaFile();
    final avant = DateTime.now().toUtc();

    final ligneId = await reservations.arriveeDirecte(
      guestId: clientId,
      roomId: c.id,
      unite: UniteSejour.HOURS,
      duree: 3,
      prix: 15000,
      by: agent,
    );

    final ligne = await (db.select(
      db.reservationRooms,
    )..where((l) => l.id.equals(ligneId))).getSingle();
    expect(ligne.status, ReservationStatus.CHECKED_IN);
    expect(ligne.isWalkIn, isTrue);
    expect(ligne.stayUnit, 'HOURS');
    expect(ligne.rateSetBy, agent);
    final ecart = ligne.departureAt!.difference(avant).inMinutes;
    expect(ecart, inInclusiveRange(179, 181));

    expect((await chambre('101')).occupancyStatus, OccupancyStatus.OCCUPIED);

    final ardoise = (await FolioRepository(db).openFolioForStay(ligneId))!;
    final lignes = await (db.select(
      db.folioItems,
    )..where((i) => i.folioId.equals(ardoise.id))).get();
    expect(lignes, hasLength(1));
    expect(lignes.single.label, 'Séjour 3 h');
    expect(lignes.single.amount, 15000);
    expect(lignes.single.category, ChargeCategory.ROOM);

    final file = await db.select(db.outboxEntries).get();
    expect(file, hasLength(1));
    final p = jsonDecode(file.single.payload) as Map<String, dynamic>;
    expect(p['action'], 'WALK_IN');
    expect(p['line_id'], ligneId);
    expect(p['folio_id'], ardoise.id);
    expect(p['charge_id'], lignes.single.id);
    expect(p['guest_id'], clientId);
    expect(p['room_id'], c.id);
    expect(p['unit'], 'HOURS');
    expect(p['duration'], 3);
    expect(p['price'], 15000);
  });

  test('en nuits : le prix du sejour entier, et les nuits ne se portent '
      'pas une a une', () async {
    final c = await chambre('101');
    final categorie = await (db.select(
      db.roomTypes,
    )..where((t) => t.id.equals(c.roomTypeId))).getSingle();

    final ligneId = await reservations.arriveeDirecte(
      guestId: clientId,
      roomId: c.id,
      unite: UniteSejour.NIGHTS,
      duree: 2,
      prix: categorie.defaultRate * 2,
      by: agent,
    );

    final ligne = await (db.select(
      db.reservationRooms,
    )..where((l) => l.id.equals(ligneId))).getSingle();
    expect(ligne.departureAt, isNull);
    // Au tarif : personne n'a fixe le prix.
    expect(ligne.rateSetBy, isNull);

    final folios = FolioRepository(db);
    final ardoise = (await folios.openFolioForStay(ligneId))!;
    final portees = await folios.postStayNights(
      folioId: ardoise.id,
      stayLineId: ligneId,
    );
    expect(portees, 0);
    final lignes = await (db.select(
      db.folioItems,
    )..where((i) => i.folioId.equals(ardoise.id))).get();
    expect(lignes.single.label, 'Séjour 2 nuits');
    expect(lignes.single.amount, categorie.defaultRate * 2);
  });

  test('un prix a zero passe ; un prix negatif est refuse', () async {
    final c = await chambre('101');
    await expectLater(
      reservations.verifierArriveeDirecte(
        roomId: c.id,
        unite: UniteSejour.NIGHTS,
        duree: 1,
        prix: -1,
      ),
      throwsStateError,
    );
    await reservations.arriveeDirecte(
      guestId: clientId,
      roomId: c.id,
      unite: UniteSejour.NIGHTS,
      duree: 1,
      prix: 0,
      by: agent,
    );
  });

  test('les bornes : 1 a 365 nuits, 1 a 24 heures', () async {
    final c = await chambre('101');
    for (final (unite, duree) in [
      (UniteSejour.NIGHTS, 0),
      (UniteSejour.NIGHTS, 366),
      (UniteSejour.HOURS, 0),
      (UniteSejour.HOURS, 25),
    ]) {
      await expectLater(
        reservations.verifierArriveeDirecte(
          roomId: c.id,
          unite: unite,
          duree: duree,
          prix: 1000,
        ),
        throwsStateError,
        reason: '$unite $duree',
      );
    }
  });

  test('une chambre occupee ou hors service est refusee, sans rien ecrire',
      () async {
    final c = await chambre('101');
    await reservations.arriveeDirecte(
      guestId: clientId,
      roomId: c.id,
      unite: UniteSejour.HOURS,
      duree: 2,
      prix: 10000,
      by: agent,
    );
    await viderLaFile();
    await expectLater(
      reservations.arriveeDirecte(
        guestId: clientId,
        roomId: c.id,
        unite: UniteSejour.HOURS,
        duree: 2,
        prix: 10000,
        by: agent,
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('occupée')),
      ),
    );

    final autre = await chambre('102');
    await (db.update(db.rooms)..where((r) => r.id.equals(autre.id))).write(
      const RoomsCompanion(isOutOfOrder: Value(true)),
    );
    await expectLater(
      reservations.arriveeDirecte(
        guestId: clientId,
        roomId: autre.id,
        unite: UniteSejour.NIGHTS,
        duree: 1,
        prix: 10000,
        by: agent,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('hors service'),
        ),
      ),
    );
    expect(await db.select(db.outboxEntries).get(), isEmpty);
  });

  test('le plafond du client compte ce qu\'il doit deja', () async {
    await (db.update(db.guests)..where((g) => g.id.equals(clientId))).write(
      const GuestsCompanion(creditLimit: Value(20000)),
    );
    final c = await chambre('101');
    await expectLater(
      reservations.verifierArriveeDirecte(
        roomId: c.id,
        unite: UniteSejour.HOURS,
        duree: 2,
        prix: 25000,
        guestId: clientId,
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('Seuil')),
      ),
    );
    await reservations.verifierArriveeDirecte(
      roomId: c.id,
      unite: UniteSejour.HOURS,
      duree: 2,
      prix: 15000,
      guestId: clientId,
    );
  });

  test('la chambre prise sort de la liste des chambres libres', () async {
    final c = await chambre('101');
    final avant = await reservations.watchChambresLibres().first;
    expect(avant.map((l) => l.id), contains(c.id));
    await reservations.arriveeDirecte(
      guestId: clientId,
      roomId: c.id,
      unite: UniteSejour.HOURS,
      duree: 2,
      prix: 10000,
      by: agent,
    );
    final apres = await reservations.watchChambresLibres().first;
    expect(apres.map((l) => l.id), isNot(contains(c.id)));
  });

  test('un sejour en heures compte dans les departs du jour, pas demain',
      () async {
    final avant = await db.watchDashboard().first;
    final c = await chambre('101');
    await reservations.arriveeDirecte(
      guestId: clientId,
      roomId: c.id,
      unite: UniteSejour.HOURS,
      duree: 1,
      prix: 8000,
      by: agent,
    );
    final apres = await db.watchDashboard().first;
    // Une heure plus tard reste dans la meme journee hoteliere, sauf a
    // lancer le test entre 5 h et 6 h : la bascule le range alors demain.
    final heure = DateTime.now().hour;
    if (heure != 5) {
      expect(apres.departsDuJour, avant.departsDuJour + 1);
      expect(apres.departsRestants, avant.departsRestants + 1);
    }
  });

  test('les rapports : un sejour en heures ne compte aucune nuit', () async {
    final jour = businessDayFor(DateTime.now());
    final filtres = FiltresRapport(du: jour, au: jour);
    final avant = await db.chargerRapport(filtres);
    final c = await chambre('101');
    await reservations.arriveeDirecte(
      guestId: clientId,
      roomId: c.id,
      unite: UniteSejour.HOURS,
      duree: 3,
      prix: 15000,
      by: agent,
    );

    final apres = await db.chargerRapport(filtres);
    expect(apres.activite.arrivees, avant.activite.arrivees + 1);
    expect(apres.activite.dureeMoyenneDixiemes, 0);
    expect(
      apres.occupation.single.occupees,
      avant.occupation.single.occupees,
    );
  });
}
