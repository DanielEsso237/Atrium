/// Les alertes : les bonnes situations, aux bonnes personnes, et un signal
/// qui sonne, se rappelle, puis se tait quand l'agent a vu -- au niveau
/// choisi pour l'evenement, sans son pour l'agent qui l'a coupe, et par le
/// volet de notifications quand l'application est en arriere-plan.
library;

import 'package:atrium/core/business_day.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/queries/alert_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:atrium/data/repositories/settings_repository.dart';
import 'package:atrium/features/alerts/alert_center.dart';
import 'package:atrium/features/alerts/alert_signal.dart';
import 'package:atrium/features/alerts/system_notifications.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _moi = '01920000-0000-7000-8000-00000000a001';

class _SignalNote implements SignalAlerte {
  final emis = <NiveauAlerte>[];
  final sons = <bool>[];
  final vibrations = <bool>[];
  var arrets = 0;

  @override
  Future<void> emettre(
    NiveauAlerte niveau, {
    bool son = true,
    bool vibration = true,
  }) async {
    emis.add(niveau);
    sons.add(son);
    vibrations.add(vibration);
  }

  @override
  Future<void> arreter() async => arrets++;
}

class _VoletNote implements NotificationsSysteme {
  final montrees = <(String, SignalVoulu)>[];
  final retirees = <String>[];
  var veille = false;
  var effacements = 0;

  @override
  Future<void> preparer(void Function(String, String?) surTouche) async {}

  @override
  Future<void> veiller(bool actif) async => veille = actif;

  @override
  Future<void> montrer(Alerte alerte, SignalVoulu signal) async =>
      montrees.add((alerte.cle, signal));

  @override
  Future<void> retirer(String cle) async => retirees.add(cle);

  @override
  Future<void> effacer() async => effacements++;
}

class _PremierPlan extends PremierPlan {
  _PremierPlan(this._devant);

  final bool _devant;

  @override
  bool build() => _devant;

  void basculer(bool devant) => state = devant;
}

class _Session extends SessionNotifier {
  _Session(this._etat);

  final SessionState _etat;

  @override
  SessionState build() => _etat;
}

void main() {
  late AtriumDatabase db;
  final t0 = DateTime.utc(2026, 10, 1);
  var n = 0;
  String id() =>
      '01920000-0000-7000-8000-${(0xb00000000000 + n++).toRadixString(16)}';
  late String chambre;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await seedDemoData(db);
    n = 0;
    chambre = (await db.select(db.rooms).get()).first.id;
  });

  tearDown(() => db.close());

  ContexteAlertes contexte(
    Set<String> droits, {
    String? accueil,
    DateTime? maintenant,
  }) => ContexteAlertes(
    agentId: _moi,
    peut: droits.contains,
    accueil: accueil,
    maintenant: maintenant ?? DateTime(2026, 10, 9, 15),
  );

  Future<void> panne(Priority priorite) => db
      .into(db.maintenanceTickets)
      .insert(
        MaintenanceTicketsCompanion.insert(
          id: id(),
          createdAt: t0,
          updatedAt: t0,
          hotelId: _hotel,
          number: 'T-$n',
          title: 'Fuite d’eau',
          roomId: Value(chambre),
          priority: Value(priorite),
          blocksRoom: const Value(true),
        ),
      );

  test('une saisie refusee bloque la file : alerte critique pour tous',
      () async {
    await db
        .into(db.outboxEntries)
        .insert(
          OutboxEntriesCompanion.insert(
            entityTable: 'payments',
            entityId: id(),
            op: SyncOp.INSERT,
            payload: '{}',
            createdAt: t0,
            status: const Value(OutboxStatus.FAILED),
            lastError: const Value('Caisse fermée'),
          ),
        );
    final alertes = await db.chargerAlertes(contexte(const {}));
    expect(alertes.single.niveau, NiveauAlerte.critique);
    expect(alertes.single.corps, startsWith('Caisse fermée.'));
  });

  test('une panne urgente sonne pour la maintenance seulement', () async {
    await panne(Priority.URGENT);
    await panne(Priority.HIGH);
    await panne(Priority.NORMAL);

    final maintenance = await db.chargerAlertes(
      contexte(const {'maintenance.read'}),
    );
    expect(maintenance.map((a) => a.niveau), [
      NiveauAlerte.critique,
      NiveauAlerte.urgente,
    ]);
    expect(maintenance.first.corps, contains('ne peut pas être louée'));
    expect(await db.chargerAlertes(contexte(const {})), isEmpty);
  });

  test('une chambre a faire alerte la femme de chambre, pas la reception',
      () async {
    await db
        .into(db.housekeepingTasks)
        .insert(
          HousekeepingTasksCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            roomId: chambre,
            type: HousekeepingTaskType.DEPARTURE,
            businessDate: '2026-10-09',
          ),
        );
    final menage = await db.chargerAlertes(
      contexte(const {'housekeeping.read'}, accueil: '/menage'),
    );
    expect(menage.single.titre, startsWith('Chambre '));
    expect(menage.single.route, '/menage');
    // Non attribuee : la reception ne la recoit pas.
    expect(
      await db.chargerAlertes(contexte(const {'housekeeping.read'})),
      isEmpty,
    );
  });

  test('un depart depasse alerte la reception, prolongation comprise',
      () async {
    final sejour = id();
    await db
        .into(db.reservationRooms)
        .insert(
          ReservationRoomsCompanion.insert(
            id: sejour,
            createdAt: t0,
            updatedAt: t0,
            reservationId: id(),
            roomTypeId: roomTypeSeeds.first.id,
            roomId: Value(chambre),
            arrivalDate: '2026-10-07',
            departureDate: '2026-10-09',
            status: const Value(ReservationStatus.CHECKED_IN),
          ),
        );
    final droits = {'reservation.read'};

    final midi = await db.chargerAlertes(
      contexte(droits, maintenant: DateTime(2026, 10, 9, 12)),
    );
    expect(midi, isEmpty, reason: 'partir a 12 h 00 est partir a l heure');

    final apres = await db.chargerAlertes(
      contexte(droits, maintenant: DateTime(2026, 10, 9, 12, 30)),
    );
    expect(apres.single.titre, startsWith('Départ dépassé'));

    // Trois heures de prolongation : plus d'alerte avant 15 h.
    final ardoise = id();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: ardoise,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            number: 'F1',
            reservationRoomId: Value(sejour),
          ),
        );
    await db
        .into(db.folioItems)
        .insert(
          FolioItemsCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            folioId: ardoise,
            category: ChargeCategory.ROOM,
            label: 'Prolongation 3 h',
            quantity: const Value(3),
            businessDate: '2026-10-09',
          ),
        );
    expect(
      await db.chargerAlertes(
        contexte(droits, maintenant: DateTime(2026, 10, 9, 14)),
      ),
      isEmpty,
    );
  });

  test('l heure de depart reglee compte, et un depart oublie devient critique',
      () async {
    await db
        .into(db.reservationRooms)
        .insert(
          ReservationRoomsCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            reservationId: id(),
            roomTypeId: roomTypeSeeds.first.id,
            roomId: Value(chambre),
            arrivalDate: '2026-10-01',
            departureDate: '2026-10-03',
            status: const Value(ReservationStatus.CHECKED_IN),
          ),
        );
    await SettingsRepository(db).setStayRules(
      const StayRules(checkoutHour: 11),
    );
    final droits = {'reservation.read'};

    // Depart a 11 h dans cet hotel : a 11 h 30, c'est deja depasse.
    final jour = await db.chargerAlertes(
      contexte(droits, maintenant: DateTime(2026, 10, 3, 11, 30)),
    );
    expect(jour.single.niveau, NiveauAlerte.urgente);

    // Six jours plus tard, personne n'a rien fait : la 401 du 9 octobre.
    final oublie = await db.chargerAlertes(
      contexte(droits, maintenant: DateTime(2026, 10, 9, 23)),
    );
    expect(oublie.single.niveau, NiveauAlerte.critique);
  });

  test('le centre sonne une fois, rappelle, et se tait quand on a vu',
      () async {
    final signal = _SignalNote();
    const rappel = Duration(milliseconds: 120);
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: _moi,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            employeeCode: 'TECH01',
            firstName: 'Ines',
            lastName: 'Test',
          ),
        );
    final agent = await (db.select(
      db.users,
    )..where((u) => u.id.equals(_moi))).getSingle();
    final conteneur = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        signalAlerteProvider.overrideWithValue(signal),
        notificationsSystemeProvider.overrideWithValue(_VoletNote()),
        premierPlanProvider.overrideWith(() => _PremierPlan(true)),
        delaisRappelProvider.overrideWithValue(
          (critique: rappel, urgente: rappel * 10),
        ),
        sessionProvider.overrideWith(
          () => _Session(
            SessionState(
              agent: agent,
              acces: const AccessProfile(permissions: {'maintenance.read'}),
            ),
          ),
        ),
      ],
    );
    addTearDown(conteneur.dispose);
    conteneur.listen(centreAlertesProvider, (_, _) {}, fireImmediately: true);
    Future<void> attendre(Duration d) => Future<void>.delayed(d);

    await attendre(const Duration(milliseconds: 50));
    expect(signal.emis, isEmpty, reason: 'rien a signaler');

    await panne(Priority.URGENT);
    await attendre(const Duration(milliseconds: 60));
    expect(signal.emis, [NiveauAlerte.critique]);
    expect(conteneur.read(centreAlertesProvider).bandeau, hasLength(1));

    await attendre(rappel * 1.5);
    expect(signal.emis.length, greaterThanOrEqualTo(2), reason: 'le rappel');

    final cle = conteneur.read(centreAlertesProvider).bandeau.single.cle;
    conteneur.read(centreAlertesProvider.notifier).acquitter(cle);
    final emis = signal.emis.length;
    expect(conteneur.read(centreAlertesProvider).bandeau, isEmpty);
    expect(signal.arrets, 1);

    await attendre(rappel * 3);
    expect(signal.emis, hasLength(emis), reason: 'vue : plus de rappel');
    // Toujours dans la cloche tant que la panne n'est pas reglee.
    expect(conteneur.read(centreAlertesProvider).actives, hasLength(1));
  });

  test(
    'une arrivee attendue alerte la reception jusqu a l enregistrement',
    () async {
      final client = id();
      final dossier = id();
      final sejour = id();
      await db
          .into(db.guests)
          .insert(
            GuestsCompanion.insert(
              id: client,
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              code: 'C-1',
              firstName: 'Awa',
              lastName: 'Ngono',
            ),
          );
      await db
          .into(db.reservations)
          .insert(
            ReservationsCompanion.insert(
              id: dossier,
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              reference: 'R-1',
              guestId: client,
              arrivalDate: '2026-10-09',
              departureDate: '2026-10-11',
            ),
          );
      await db
          .into(db.reservationRooms)
          .insert(
            ReservationRoomsCompanion.insert(
              id: sejour,
              createdAt: t0,
              updatedAt: t0,
              reservationId: dossier,
              roomTypeId: roomTypeSeeds.first.id,
              arrivalDate: '2026-10-09',
              departureDate: '2026-10-11',
              status: const Value(ReservationStatus.CONFIRMED),
            ),
          );

      final reception = await db.chargerAlertes(
        contexte(const {'reservation.read'}),
      );
      expect(reception.single.type, TypeEvenement.arriveeAttendue);
      expect(reception.single.titre, 'Arrivée attendue : Awa Ngono');
      expect(reception.single.corps, endsWith('2 nuits'));
      // La femme de chambre n'a pas a le savoir.
      expect(
        await db.chargerAlertes(
          contexte(const {'reservation.read'}, accueil: '/menage'),
        ),
        isEmpty,
      );
      // Avant 6 h, la journee d'exploitation est encore la veille.
      expect(
        await db.chargerAlertes(
          contexte(const {
            'reservation.read',
          }, maintenant: DateTime(2026, 10, 9, 5)),
        ),
        isEmpty,
      );

      await (db.update(
        db.reservationRooms,
      )..where((r) => r.id.equals(sejour))).write(
        const ReservationRoomsCompanion(
          status: Value(ReservationStatus.CHECKED_IN),
        ),
      );
      expect(
        await db.chargerAlertes(contexte(const {'reservation.read'})),
        isEmpty,
      );
    },
  );

  test('stock bas et transfert a valider, a qui suit les stocks', () async {
    final economat = id();
    final bar = id();
    final biere = id();
    for (final (lieu, code, central) in [
      (economat, 'ECO', true),
      (bar, 'BAR', false),
    ]) {
      await db
          .into(db.stockLocations)
          .insert(
            StockLocationsCompanion.insert(
              id: lieu,
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              code: code,
              label: code == 'ECO' ? 'Économat' : 'Bar',
              isCentral: Value(central),
            ),
          );
    }
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: biere,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            reference: 'B33',
            label: 'Bière 33 cl',
            minStock: const Value(12),
          ),
        );
    await db
        .into(db.stockLevels)
        .insert(
          StockLevelsCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            productId: biere,
            stockLocationId: bar,
            quantity: const Value(4),
          ),
        );
    await db
        .into(db.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: id(),
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            productId: biere,
            stockLocationId: economat,
            counterpartLocationId: Value(bar),
            type: StockMovementType.TRANSFER,
            quantity: 24,
            status: const Value(StockMovementStatus.PENDING),
          ),
        );

    final stock = await db.chargerAlertes(contexte(const {'stock.read'}));
    expect(
      stock.map((a) => a.titre),
      ['Rupture : Bière 33 cl', 'Stock bas : Bière 33 cl'],
      reason: 'l economat n a jamais rien recu ; le bar en a 4 sur 12',
    );
    expect(stock.every((a) => a.type == TypeEvenement.stockBas), isTrue);

    final valideur = await db.chargerAlertes(
      contexte(const {'stock.transfer.approve'}),
    );
    expect(valideur.single.type, TypeEvenement.transfertAValider);
    expect(valideur.single.titre, 'Transfert à valider : 24 Bière 33 cl');
  });

  test('les niveaux se relisent, un code inconnu garde le defaut', () {
    final niveaux = NiveauxAlertes.fromJson({
      'LOW_STOCK': 'SOUND_VIBRATION',
      'ARRIVAL_EXPECTED': 'FORT',
      'FUTURE_EVENT': 'SILENT',
    });
    expect(niveaux.de(TypeEvenement.stockBas), NiveauSignal.sonoreVibration);
    expect(
      niveaux.de(TypeEvenement.arriveeAttendue),
      TypeEvenement.arriveeAttendue.niveauParDefaut,
    );
    expect(niveaux.toJson().keys, hasLength(TypeEvenement.values.length));
    expect(NiveauxAlertes.fromJson(niveaux.toJson()), niveaux);
  });

  group('le centre applique niveaux, son coupe et arriere-plan', () {
    late _SignalNote signal;
    late _VoletNote volet;
    late _PremierPlan plan;

    Future<ProviderContainer> centre({
      bool devant = true,
      Set<String> droits = const {'maintenance.read'},
    }) async {
      signal = _SignalNote();
      volet = _VoletNote();
      plan = _PremierPlan(devant);
      await db
          .into(db.users)
          .insertOnConflictUpdate(
            UsersCompanion.insert(
              id: _moi,
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              employeeCode: 'TECH01',
              firstName: 'Ines',
              lastName: 'Test',
            ),
          );
      final agent = await (db.select(
        db.users,
      )..where((u) => u.id.equals(_moi))).getSingle();
      final conteneur = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          signalAlerteProvider.overrideWithValue(signal),
          notificationsSystemeProvider.overrideWithValue(volet),
          premierPlanProvider.overrideWith(() => plan),
          sessionProvider.overrideWith(
            () => _Session(
              SessionState(
                agent: agent,
                acces: AccessProfile(permissions: droits),
              ),
            ),
          ),
        ],
      );
      addTearDown(conteneur.dispose);
      conteneur.listen(centreAlertesProvider, (_, _) {}, fireImmediately: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return conteneur;
    }

    Future<void> attendre() =>
        Future<void>.delayed(const Duration(milliseconds: 60));

    test('le stock deja bas sonne une fois a la connexion, sans rappel',
        () async {
      // Deux produits sous leur minimum avant la connexion.
      final bar = id();
      await db
          .into(db.stockLocations)
          .insert(
            StockLocationsCompanion.insert(
              id: bar, createdAt: t0, updatedAt: t0, hotelId: _hotel,
              code: 'BAR', label: 'Bar',
            ),
          );
      for (final (ref, libelle) in [('B33', 'Bière'), ('JUS', 'Jus')]) {
        final produit = id();
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: produit, createdAt: t0, updatedAt: t0, hotelId: _hotel,
                reference: ref, label: libelle, minStock: const Value(12),
              ),
            );
        await db
            .into(db.stockLevels)
            .insert(
              StockLevelsCompanion.insert(
                id: id(), createdAt: t0, updatedAt: t0, productId: produit,
                stockLocationId: bar, quantity: const Value(4),
              ),
            );
      }
      await SettingsRepository(db).setNiveauxAlertes(
        const NiveauxAlertes().avec(
          TypeEvenement.stockBas,
          NiveauSignal.sonoreVibration,
        ),
      );

      final conteneur = await centre(droits: const {'stock.read'});
      await attendre();

      // Une seule sonnerie pour les deux, et rien dans le bandeau : pas de
      // rappel toutes les quelques minutes pour un stock deja connu.
      expect(signal.emis, [NiveauAlerte.info]);
      expect(signal.sons, [true]);
      expect(conteneur.read(centreAlertesProvider).bandeau, isEmpty);
      expect(conteneur.read(centreAlertesProvider).actives, hasLength(2));
    });

    test('une arrivee attendue non lue sonne aussi a la connexion', () async {
      final client = await GuestRepository(
        db,
      ).create(firstName: 'Awa', lastName: 'Diallo');
      await ReservationRepository(db).create(
        guestId: client.id,
        roomTypeId: roomTypeSeeds.first.id,
        // La journee hoteliere, pas le calendrier : avant 6 h, c'est encore
        // celle d'hier.
        arrival: businessDayFor(DateTime.now()),
        departure: businessDayFor(DateTime.now()).add(const Duration(days: 2)),
        nightlyRate: 25000,
      );

      final conteneur = await centre(droits: const {'reservation.read'});
      await attendre();

      // L'arrivee est reglee « sonore » par defaut : elle sonne une fois,
      // et reste dans la cloche sans rappel.
      expect(signal.emis, [NiveauAlerte.info]);
      expect(conteneur.read(centreAlertesProvider).bandeau, isEmpty);
      expect(conteneur.read(centreAlertesProvider).actives, hasLength(1));
    });
    test('discret : ni bandeau ni bruit, mais dans la cloche', () async {
      await SettingsRepository(db).setNiveauxAlertes(
        const NiveauxAlertes().avec(TypeEvenement.panne, NiveauSignal.discret),
      );
      final conteneur = await centre();

      await panne(Priority.HIGH);
      await attendre();
      expect(signal.emis, isEmpty);
      expect(conteneur.read(centreAlertesProvider).bandeau, isEmpty);
      expect(conteneur.read(centreAlertesProvider).actives, hasLength(1));
    });

    test('sonore sans vibration, et le son coupe par l agent', () async {
      await SettingsRepository(db).setNiveauxAlertes(
        const NiveauxAlertes().avec(TypeEvenement.panne, NiveauSignal.sonore),
      );
      await centre();

      await panne(Priority.HIGH);
      await attendre();
      expect(signal.sons, [true]);
      expect(signal.vibrations, [false]);

      // Son coupe, sans vibration au niveau de l'evenement : plus rien.
      await SettingsRepository(db).setSonCoupe(_moi, true);
      await attendre();
      await panne(Priority.HIGH);
      await attendre();
      expect(signal.emis, hasLength(1));
    });

    test('son coupe : la vibration reste', () async {
      await SettingsRepository(db).setSonCoupe(_moi, true);
      await centre();

      await panne(Priority.URGENT);
      await attendre();
      expect(signal.sons, [false]);
      expect(signal.vibrations, [true]);
    });

    test('en arriere-plan : le volet, pas le haut-parleur', () async {
      final conteneur = await centre(devant: false);
      expect(volet.veille, isTrue, reason: 'la veille demarre a la connexion');

      await panne(Priority.URGENT);
      await attendre();
      expect(signal.emis, isEmpty);
      final (cle, voulu) = volet.montrees.single;
      expect(voulu.gravite, NiveauAlerte.critique);
      expect(voulu.son && voulu.vibration, isTrue);

      // Reglee pendant la veille : la notification se retire.
      await db
          .update(db.maintenanceTickets)
          .write(
            const MaintenanceTicketsCompanion(
              status: Value(TicketStatus.RESOLVED),
            ),
          );
      await attendre();
      expect(volet.retirees, [cle]);

      plan.basculer(true);
      expect(volet.effacements, greaterThan(0));
      expect(conteneur.read(centreAlertesProvider).actives, isEmpty);
    });
  });
}
