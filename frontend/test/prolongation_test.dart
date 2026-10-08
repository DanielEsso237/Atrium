/// La nuitee de 12 h a 12 h et la prolongation.
///
/// Un client qui part a 14 h voit deux heures de prolongation sur sa facture.
/// Les cas limites sont ceux de la carte : 11 h 59, 12 h 30, et une
/// prolongation demandee d'avance de trois heures.
library;

import 'dart:convert';

import 'package:atrium/core/prolongation.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/room_detail_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/data/repositories/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('heures de depassement', () {
    final jour = DateTime(2026, 10, 15);
    final midi = limiteDeDepart(jour);

    test('11 h 59 : parti avant l\'heure, rien a facturer', () {
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 11, 59), midi), 0);
    });

    test('12 h 00 pile : parti a l\'heure', () {
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 12), midi), 0);
    });

    test('12 h 00 et quelques secondes : encore a l\'heure', () {
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 12, 0, 40), midi), 0);
    });

    test('12 h 30 : une heure entamee est due', () {
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 12, 30), midi), 1);
    });

    test('13 h 00 : une heure, 13 h 01 : deux', () {
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 13), midi), 1);
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 13, 1), midi), 2);
    });

    test('14 h 00 : deux heures de prolongation', () {
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 14), midi), 2);
    });

    test('une prolongation de 3 h repousse la limite a 15 h', () {
      final limite = limiteDeDepart(jour, heuresProlongees: 3);
      expect(limite, DateTime(2026, 10, 15, 15));
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 14, 59), limite), 0);
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 15), limite), 0);
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 15, 30), limite), 1);
    });

    test('l\'heure de depart est reglable', () {
      final limite = limiteDeDepart(jour, heureDepart: 11);
      expect(heuresDeDepassement(DateTime(2026, 10, 15, 12), limite), 1);
    });

    test('une limite qui passe minuit retombe le lendemain', () {
      final limite = limiteDeDepart(jour, heureDepart: 22, heuresProlongees: 4);
      expect(limite, DateTime(2026, 10, 16, 2));
    });

    test('le libelle porte le nombre d\'heures', () {
      expect(libelleDeProlongation(3), 'Prolongation 3 h');
      expect(formatHeure(DateTime(2026, 10, 15, 15)), '15 h');
    });
  });

  group('sur la tablette', () {
    late AtriumDatabase db;
    late ReservationRepository reservations;
    late FolioRepository folios;
    late SettingsRepository reglages;
    late String chambreId;
    late String ligneId;

    setUp(() async {
      db = AtriumDatabase.memory();
      await db.customStatement('PRAGMA foreign_keys = ON');
      await seedDemoData(db);
      reservations = ReservationRepository(db);
      folios = FolioRepository(db);
      reglages = SettingsRepository(db);
      chambreId = (await db
              .customSelect("SELECT id FROM rooms WHERE number = '101'")
              .getSingle())
          .read<String>('id');

      final client = await GuestRepository(
        db,
      ).create(firstName: 'Awa', lastName: 'Diallo');
      final dossier = await reservations.create(
        guestId: client.id,
        roomTypeId: roomTypeSeeds.first.id,
        arrival: DateTime(2026, 10, 1),
        departure: DateTime(2026, 10, 3),
        nightlyRate: 25000,
        roomId: chambreId,
      );
      ligneId = (await (db.select(
        db.reservationRooms,
      )..where((l) => l.reservationId.equals(dossier))).getSingle()).id;
      await reservations.checkIn(lineId: ligneId);
    });

    tearDown(() => db.close());

    Future<FolioRow> ardoise() async => (await folios.openFolioForStay(ligneId))!;

    test('les reglages : midi et rien de facture par defaut', () async {
      final regles = await reglages.stayRules();
      expect(regles.checkoutHour, 12);
      expect(regles.extraHourPrice, 0);
      expect(regles.billsExtraHours, isFalse);
    });

    test('les reglages se rangent et se relisent, sans doublon', () async {
      await reglages.setStayRules(
        const StayRules(checkoutHour: 11, extraHourPrice: 2000),
      );
      await reglages.setStayRules(
        const StayRules(checkoutHour: 11, extraHourPrice: 2500),
      );

      final regles = await reglages.stayRules();
      expect(regles, const StayRules(checkoutHour: 11, extraHourPrice: 2500));
      expect(regles.billsExtraHours, isTrue);

      final lignes = await (db.select(
        db.settings,
      )..where((s) => s.key.isIn([stayCheckoutHourKey, stayExtraHourPriceKey])))
          .get();
      expect(lignes, hasLength(2));
    });

    test('une heure de depart impossible est refusee', () async {
      await expectLater(
        reglages.setStayRules(const StayRules(checkoutHour: 25)),
        throwsStateError,
      );
      await expectLater(
        reglages.setStayRules(const StayRules(extraHourPrice: -1)),
        throwsStateError,
      );
    });

    test('la prolongation pose une ligne « Prolongation » sur l\'ardoise', () async {
      final avant = (await ardoise()).balance;

      await folios.addExtension(
        folioId: (await ardoise()).id,
        hours: 3,
        hourlyPrice: 2000,
        stayLineId: ligneId,
      );

      expect((await ardoise()).balance - avant, 6000);

      final lignes = (await db.select(db.folioItems).get())
          .where((i) => i.label.startsWith('Prolongation'))
          .toList();
      expect(lignes, hasLength(1));
      expect(lignes.single.label, 'Prolongation 3 h');
      expect(lignes.single.category, ChargeCategory.ROOM);
      expect(lignes.single.quantity, 3);
      expect(lignes.single.unitPrice, 2000);
      expect(lignes.single.amount, 6000);

      // Elle remonte par la file comme toute charge : le serveur la connait
      // deja (categorie ROOM, quantite, prix unitaire).
      final envoi = (await db.select(db.outboxEntries).get()).last;
      final p = jsonDecode(envoi.payload) as Map;
      expect(envoi.entityTable, 'folio_items');
      expect(p['category'], 'ROOM');
      expect(p['label'], 'Prolongation 3 h');
      expect(p['quantity'], 3);
      expect(p['unit_price'], 2000);
    });

    test('une prolongation sans heure ou sans prix est refusee', () async {
      final folioId = (await ardoise()).id;
      expect(
        () => folios.addExtension(
          folioId: folioId,
          hours: 0,
          hourlyPrice: 2000,
        ),
        throwsStateError,
      );
      expect(
        () => folios.addExtension(folioId: folioId, hours: 2, hourlyPrice: 0),
        throwsStateError,
      );
    });

    test('les heures deja portees s\'additionnent', () async {
      final folioId = (await ardoise()).id;
      expect(await folios.extensionHours(folioId), 0);

      await folios.addExtension(folioId: folioId, hours: 3, hourlyPrice: 2000);
      await folios.addExtension(folioId: folioId, hours: 2, hourlyPrice: 2000);

      expect(await folios.extensionHours(folioId), 5);
    });

    test('la fiche du sejour montre les heures prolongees', () async {
      var fiche = await db.watchRoomDetail(chambreId).first;
      expect(fiche.sejour!.prolongationHeures, 0);

      await folios.addExtension(
        folioId: (await ardoise()).id,
        hours: 3,
        hourlyPrice: 2000,
      );

      fiche = await db.watchRoomDetail(chambreId).first;
      expect(fiche.sejour!.prolongationHeures, 3);
    });

    test('le jour de depart se relit depuis la ligne', () async {
      expect(
        await reservations.departureDayOfLine(ligneId),
        DateTime(2026, 10, 3),
      );
    });

    test('la chambre prolongee reste prise le jour de son depart', () async {
      Future<List<String>> libres(DateTime arrivee) async {
        final chambres = await reservations.availableRooms(
          roomTypeId: roomTypeSeeds.first.id,
          arrival: arrivee,
          departure: arrivee.add(const Duration(days: 1)),
        );
        return chambres.map((c) => c.number).toList();
      }

      // Sans prolongation, la chambre qui se libere le 3 est reservable le 3.
      expect(await libres(DateTime(2026, 10, 3)), contains('101'));

      await folios.addExtension(
        folioId: (await ardoise()).id,
        hours: 3,
        hourlyPrice: 2000,
      );

      // Prolongee, le client est encore la : pas pour une arrivee le 3...
      expect(await libres(DateTime(2026, 10, 3)), isNot(contains('101')));
      // ...mais le lendemain elle est bien libre.
      expect(await libres(DateTime(2026, 10, 4)), contains('101'));
    });

    test('la chambre reste occupee sur le plan jusqu\'au depart', () async {
      await folios.addExtension(
        folioId: (await ardoise()).id,
        hours: 3,
        hourlyPrice: 2000,
      );

      final chambre = await (db.select(
        db.rooms,
      )..where((r) => r.id.equals(chambreId))).getSingle();
      expect(chambre.occupancyStatus, OccupancyStatus.OCCUPIED);

      await reservations.checkOut(lineId: ligneId);

      final apres = await (db.select(
        db.rooms,
      )..where((r) => r.id.equals(chambreId))).getSingle();
      expect(apres.occupancyStatus, OccupancyStatus.VACANT);
    });
  });
}
