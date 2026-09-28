/// Les chiffres qui mettent le tableau de bord en perspective : historique,
/// repartition, activite de la journee, derniers evenements.
///
/// Ce qui compte ici, c'est que chaque graphique raconte la meme journee que
/// les tuiles. Une courbe qui compte une nuit de trop ou une arrivee rangee
/// dans la mauvaise tranche ne fait rien planter : elle ment, tranquillement,
/// sur l'ecran que la direction regarde en premier.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/queries/dashboard_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late ReservationRepository reservations;

  final typeStandard = roomTypeSeeds.first.id;
  final aujourdhui = businessDayFor(DateTime.now());
  DateTime jour(int decalage) =>
      DateTime(aujourdhui.year, aujourdhui.month, aujourdhui.day + decalage);
  DateTime utc(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    reservations = ReservationRepository(db);
  });

  tearDown(() => db.close());

  Future<String> chambre() async {
    final l = await db
        .customSelect('SELECT id FROM rooms ORDER BY number LIMIT 1')
        .getSingle();
    return l.read<String>('id');
  }

  /// Un sejour Standard pour Awa Traore ; rend l'identifiant de la ligne.
  Future<String> sejour({
    required DateTime arrivee,
    required DateTime depart,
    String? roomId,
  }) async {
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Traore');
    final id = await reservations.create(
      guestId: client.id,
      roomTypeId: typeStandard,
      arrival: utc(arrivee),
      departure: utc(depart),
      nightlyRate: 25000,
      roomId: roomId,
    );
    final ligne = await db
        .customSelect(
          'SELECT id FROM reservation_rooms WHERE reservation_id = ?',
          variables: [Variable.withString(id)],
        )
        .getSingle();
    return ligne.read<String>('id');
  }

  group('historique', () {
    test('une ligne par jour, meme sans activite', () async {
      final jours = await db.watchHistorique(jours: 7).first;

      expect(jours, hasLength(7));
      expect(jours.first.jour, jour(-6));
      expect(jours.last.jour, aujourdhui);
      expect(jours.every((j) => j.occupees == 0 && j.arrivees == 0), isTrue);
    });

    test('un sejour en cours occupe sa chambre chaque nuit', () async {
      final ligne = await sejour(
        arrivee: jour(-2),
        depart: jour(1),
        roomId: await chambre(),
      );
      await reservations.checkIn(lineId: ligne);

      final jours = await db.watchHistorique(jours: 7).first;
      final occupees = [for (final j in jours) j.occupees];
      final arrivees = [for (final j in jours) j.arrivees];

      // Nuits du J-2, J-1 et du jour ; rien avant l'arrivee.
      expect(occupees, [0, 0, 0, 0, 1, 1, 1]);
      expect(arrivees, [0, 0, 0, 0, 1, 0, 0]);
      expect(jours.last.reservations, 1);
    });

    test('une reservation annulee ne compte nulle part', () async {
      final ligne = await sejour(arrivee: jour(0), depart: jour(2));
      await db.customStatement(
        "UPDATE reservation_rooms SET status = 'CANCELLED' WHERE id = '$ligne'",
      );
      await db.customStatement("UPDATE reservations SET status = 'CANCELLED'");

      final jours = await db.watchHistorique(jours: 1).first;
      expect(jours.single.arrivees, 0);
      expect(jours.single.reservations, 0);
    });
  });

  group('repartition', () {
    test('toutes les chambres du parametrage, aucune occupee', () async {
      final types = await db.watchRepartition().first;

      expect(types, isNotEmpty);
      final total = await db
          .customSelect(
            'SELECT COUNT(*) AS n FROM rooms '
            'WHERE deleted_at IS NULL AND is_active = 1',
          )
          .getSingle();
      expect(types.fold<int>(0, (s, t) => s + t.total), total.read<int>('n'));
      expect(types.every((t) => t.occupees == 0), isTrue);
    });

    test('un check-in se voit dans le type de la chambre', () async {
      final ligne = await sejour(
        arrivee: jour(0),
        depart: jour(1),
        roomId: await chambre(),
      );
      await reservations.checkIn(lineId: ligne);

      final types = await db.watchRepartition().first;
      expect(types.fold<int>(0, (s, t) => s + t.occupees), 1);
    });
  });

  group('activite du jour', () {
    test('les tranches suivent la journee hoteliere', () {
      expect(trancheHoraire(6), 0);
      expect(trancheHoraire(8), 0);
      expect(trancheHoraire(9), 1);
      expect(trancheHoraire(20), 4);
      expect(trancheHoraire(21), 5);
      expect(trancheHoraire(23), 5);
      // La nuit appartient encore a la journee de la veille, derniere tranche.
      expect(trancheHoraire(2), 5);
      expect(trancheHoraire(5), 5);
    });

    test('une arrivee tombe dans la tranche de son heure locale', () async {
      final ligne = await sejour(
        arrivee: jour(0),
        depart: jour(1),
        roomId: await chambre(),
      );
      await reservations.checkIn(lineId: ligne);

      final activite = await db.watchActiviteDuJour().first;
      final attendue = trancheHoraire(DateTime.now().hour);
      expect(activite.arrivees[attendue], 1);
      expect(activite.arrivees.fold<int>(0, (s, n) => s + n), 1);
      expect(activite.departs.every((n) => n == 0), isTrue);
    });

    test('une journee sans mouvement est vide', () async {
      final activite = await db.watchActiviteDuJour().first;
      expect(activite.estVide, isTrue);
    });
  });

  group('dernieres activites', () {
    test('du plus recent au plus ancien, avec chambre et client', () async {
      final ligne = await sejour(
        arrivee: jour(0),
        depart: jour(1),
        roomId: await chambre(),
      );
      // Des instants distincts : trois ecritures dans la meme milliseconde
      // n'auraient pas d'ordre a verifier.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await reservations.checkIn(lineId: ligne);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await reservations.checkOut(lineId: ligne);

      final fil = await db.watchDernieresActivites().first;

      expect(
        [for (final a in fil) a.genre],
        [
          GenreActivite.depart,
          GenreActivite.arrivee,
          GenreActivite.reservation,
        ],
      );
      expect(fil.every((a) => a.client == 'Awa Traore'), isTrue);
      expect(fil.first.chambre, isNotNull);
      expect(fil.last.typeChambre, 'Standard');
    });

    test('la limite est respectee', () async {
      for (var i = 0; i < 3; i++) {
        await sejour(arrivee: jour(i), depart: jour(i + 1));
      }
      final fil = await db.watchDernieresActivites(limite: 2).first;
      expect(fil, hasLength(2));
    });
  });
}
