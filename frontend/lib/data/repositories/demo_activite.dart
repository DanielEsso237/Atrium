/// Une activite de demonstration autour de la journee en cours.
///
/// Le jeu de `seed.dart` installe un hotel vide : des chambres, aucun client.
/// Le tableau de bord n'y montre que des zeros et des courbes plates. Celui-ci
/// y ajoute une quinzaine de sejours etales sur deux semaines -- departs
/// passes, clients dans les murs, arrivees du jour, reservations a venir --
/// pour voir les ecrans vivre pendant le developpement.
///
/// **Jamais vers le serveur.** Les sejours sont crees par les vrais depots,
/// pour que folios, nuitees et taches de menage soient coherents avec le
/// reste de l'application ; mais les ecritures qu'ils mettent dans la file
/// d'envoi en sont retirees aussitot, et les lignes marquees `synced`. Un
/// serveur qui recevrait ces clients inventes les garderait pour de bon.
///
/// **Toujours d'actualite.** Cree une fois, le jeu est ensuite decale jour
/// apres jour pour rester centre sur la journee en cours -- tant que personne
/// n'y a touche. Un sejour de demonstration modifie a la main n'est plus
/// deplace : on ne bouge pas une donnee sous les doigts de celui qui s'en
/// sert.
///
/// Appele au demarrage, en mode developpement seulement (voir `main.dart`).
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart';
import '../local/database.dart';
import '../local/enums.dart';
import '../local/seed.dart';
import 'reservation_repository.dart';

const _hotel = ReservationRepository.defaultHotelId;
const _idMarqueur = '01920000-0000-7000-8000-000000009000';

String _idClient(int i) =>
    '01920000-0000-7000-8000-0000000091${i.toString().padLeft(2, '0')}';
String _idNotification(int i) =>
    '01920000-0000-7000-8000-0000000092${i.toString().padLeft(2, '0')}';

const _clients = [
  ('Awa', 'Traoré'),
  ('Kofi', 'Mensah'),
  ('Fatou', 'Diallo'),
  ('Yao', 'Kouamé'),
  ('Mariam', 'Sow'),
  ('Ibrahim', 'Keïta'),
  ('Aminata', 'Coulibaly'),
  ('Serge', 'Koné'),
  ('Nadia', 'Bamba'),
  ('Paul', 'Ouattara'),
  ('Rokia', 'Touré'),
  ('Éric', 'Yéo'),
  ('Salif', 'Cissé'),
  ('Grâce', 'Kra'),
  ('Moussa', 'Sangaré'),
];

enum _Etape {
  /// Reservee, sans chambre attribuee.
  sansChambre,

  /// Chambre attribuee, client pas encore arrive.
  attendue,

  /// Client dans les murs.
  arrivee,

  /// Client reparti.
  repartie,
}

/// Les sejours, en jours relatifs a la journee en cours.
const _sejours = <(int arrivee, int depart, _Etape etape)>[
  (-9, -5, _Etape.repartie),
  (-8, -3, _Etape.repartie),
  (-7, -1, _Etape.repartie),
  (-6, 1, _Etape.arrivee),
  (-5, 2, _Etape.arrivee),
  (-4, 0, _Etape.repartie),
  (-4, 3, _Etape.arrivee),
  (-3, 0, _Etape.arrivee),
  (-2, 2, _Etape.arrivee),
  (-1, 3, _Etape.arrivee),
  (0, 2, _Etape.arrivee),
  (0, 1, _Etape.arrivee),
  (0, 3, _Etape.attendue),
  (0, 2, _Etape.sansChambre),
  (1, 4, _Etape.attendue),
];

/// Installe ou recale l'activite de demonstration.
///
/// `maintenant` sert aux tests ; l'application laisse l'horloge.
Future<void> seedDemoActivity(AtriumDatabase db, {DateTime? maintenant}) async {
  final instant = maintenant ?? DateTime.now();
  final jour = businessDayFor(instant);

  final marqueur = await (db.select(
    db.settings,
  )..where((s) => s.id.equals(_idMarqueur))).getSingleOrNull();

  if (marqueur == null) {
    final taches = await _creer(db, jour, instant);
    await _noter(db, jour, taches);
    return;
  }

  final etat = jsonDecode(marqueur.value ?? '{}') as Map<String, dynamic>;
  final deja = parseIsoDate(etat['jour'] as String?);
  if (deja == null) return;
  final ecart = DateTime.utc(
    jour.year,
    jour.month,
    jour.day,
  ).difference(DateTime.utc(deja.year, deja.month, deja.day)).inDays;
  if (ecart <= 0) return;
  if (await _touchee(db)) return;

  final taches = [for (final t in etat['taches'] as List? ?? []) '$t'];
  await _decaler(db, ecart, taches);
  await _noter(db, jour, taches);
}

/// Cree les clients, les sejours et deux notifications. Rend les
/// identifiants des taches de menage ouvertes par les departs.
Future<List<String>> _creer(
  AtriumDatabase db,
  DateTime jour,
  DateTime instant,
) async {
  // L'horloge reelle, et non `instant` : c'est elle qui date les entrees de
  // la file d'envoi que les depots vont ecrire, et qu'il faudra retirer.
  final debut = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
  final depot = ReservationRepository(db);

  DateTime date(int d) => DateTime.utc(jour.year, jour.month, jour.day + d);
  DateTime heure(int d, int h, int mn) =>
      DateTime(jour.year, jour.month, jour.day + d, h, mn);

  // Les evenements du jour se placent entre l'ouverture de la journee et
  // maintenant : une arrivee « a venir » dans le fil des dernieres activites
  // n'aurait pas de sens.
  final ouverture = DateTime(
    jour.year,
    jour.month,
    jour.day,
    heureBasculeParDefaut,
  );
  final fin = instant.isAfter(ouverture.add(const Duration(minutes: 30)))
      ? instant
      : ouverture.add(const Duration(minutes: 30));
  DateTime duJour(double part) =>
      ouverture.add(fin.difference(ouverture) * part);

  final now = DateTime.now().toUtc();
  for (var i = 0; i < _clients.length; i++) {
    final (prenom, nom) = _clients[i];
    await db
        .into(db.guests)
        .insertOnConflictUpdate(
          GuestsCompanion.insert(
            id: _idClient(i),
            createdAt: now,
            updatedAt: now,
            hotelId: _hotel,
            code: 'DEMO-${(i + 1).toString().padLeft(3, '0')}',
            firstName: prenom,
            lastName: nom,
            syncState: const Value(SyncState.synced),
          ),
        );
  }

  final chambres = <String>{};
  // Chambre liberee avant aujourd'hui -> jour du depart : leur menage est
  // fait depuis, seules les chambres liberees aujourd'hui restent sales.
  final departsPasses = <String, int>{};
  var arriveesDuJour = 0;
  var departsDuJour = 0;

  for (var i = 0; i < _sejours.length; i++) {
    final (a, d, etape) = _sejours[i];
    final type = roomTypeSeeds[i % roomTypeSeeds.length];

    String? chambre;
    if (etape != _Etape.sansChambre) {
      final libres = await depot.availableRooms(
        roomTypeId: type.id,
        arrival: date(a),
        departure: date(d),
      );
      // Une chambre deja prise par un sejour de demonstration ou occupee
      // aujourd'hui par un vrai client ne sert pas deux fois.
      final candidates = [
        for (final l in libres)
          if (!chambres.contains(l.id)) l.id,
      ];
      if (candidates.isEmpty) continue;
      chambre = candidates.first;
      chambres.add(chambre);
    }

    final reservationId = await depot.create(
      guestId: _idClient(i),
      roomTypeId: type.id,
      arrival: date(a),
      departure: date(d),
      nightlyRate: type.rate,
      adults: 1 + i % 2,
      roomId: chambre,
    );
    final ligne =
        (await db
                .customSelect(
                  'SELECT id FROM reservation_rooms WHERE reservation_id = ?',
                  variables: [Variable.withString(reservationId)],
                )
                .getSingle())
            .read<String>('id');

    // Reservee quelques jours avant l'arrivee ; celle sans chambre l'a ete
    // ce matin, au telephone.
    final prise = etape == _Etape.sansChambre
        ? duJour(0.35)
        : heure(a - 3 - i % 3, 10 + i % 6, (i * 7) % 60);
    await _dater(db, 'reservations', reservationId, 'created_at', prise);

    if (etape == _Etape.arrivee || etape == _Etape.repartie) {
      await depot.checkIn(lineId: ligne);
      final arrivee = a == 0
          ? duJour(0.25 + 0.3 * arriveesDuJour++)
          : heure(a, 13 + i % 5, (i * 11) % 60);
      await _dater(db, 'reservation_rooms', ligne, 'checked_in_at', arrivee);
    }
    if (etape == _Etape.repartie) {
      await depot.checkOut(lineId: ligne);
      final depart = d == 0
          ? duJour(0.15 + 0.25 * departsDuJour++)
          : heure(d, 9 + i % 3, (i * 13) % 60);
      await _dater(db, 'reservation_rooms', ligne, 'checked_out_at', depart);
      if (d < 0) departsPasses[chambre!] = d;
    }
  }

  final notifications = [
    (
      'arrivee',
      "Arrivées attendues aujourd'hui",
      'Des clients doivent encore arriver : préparer les clés et les '
          'fiches.',
      duJour(0.1),
    ),
    (
      'menage',
      'Chambres à préparer',
      'Des chambres libérées ce matin attendent le ménage.',
      duJour(0.6),
    ),
  ];
  for (var i = 0; i < notifications.length; i++) {
    final (genre, titre, corps, quand) = notifications[i];
    await db
        .into(db.notifications)
        .insertOnConflictUpdate(
          NotificationsCompanion.insert(
            id: _idNotification(i),
            createdAt: quand.toUtc(),
            updatedAt: quand.toUtc(),
            hotelId: _hotel,
            kind: genre,
            title: titre,
            body: Value(corps),
            syncState: const Value(SyncState.synced),
          ),
        );
  }

  final taches = await _retirerDeLaFile(db, debut, chambres);

  for (final tache in taches) {
    final ligne = await (db.select(
      db.housekeepingTasks,
    )..where((t) => t.id.equals(tache))).getSingleOrNull();
    final jourDepart = ligne == null ? null : departsPasses[ligne.roomId];
    if (jourDepart == null) continue;
    await db.customUpdate(
      "UPDATE housekeeping_tasks SET status = 'DONE', business_date = ?, "
      "finished_at = ?, sync_state = 'synced' WHERE id = ?",
      variables: [
        Variable.withString(formatIsoDate(date(jourDepart))),
        Variable.withString(
          heure(jourDepart, 12, 30).toUtc().toIso8601String(),
        ),
        Variable.withString(tache),
      ],
      updates: {db.housekeepingTasks},
    );
    await db.customUpdate(
      "UPDATE rooms SET housekeeping_status = 'CLEAN', sync_state = 'synced' "
      'WHERE id = ?',
      variables: [Variable.withString(ligne!.roomId)],
      updates: {db.rooms},
    );
  }
  return taches;
}

/// Retire de la file d'envoi tout ce que les depots viennent d'y mettre, et
/// marque les lignes concernees comme deja synchronisees.
///
/// Rien d'autre n'a pu ecrire dans la file depuis `debut` : ce jeu tourne au
/// demarrage, avant que l'agent ne touche a quoi que ce soit.
Future<List<String>> _retirerDeLaFile(
  AtriumDatabase db,
  DateTime debut,
  Set<String> chambres,
) async {
  final entrees = await db.select(db.outboxEntries).get();
  final notres = [
    for (final e in entrees)
      if (!e.createdAt.toUtc().isBefore(debut)) e,
  ];
  final parTable = <String, Set<String>>{};
  for (final e in notres) {
    parTable.putIfAbsent(e.entityTable, () => {}).add(e.entityId);
  }

  // Les depots marquent aussi `pending` des lignes qu'ils n'envoient pas
  // eux-memes (la reservation au check-in, la chambre) : on les retrouve par
  // les clients de demonstration.
  final clients = [for (var i = 0; i < _clients.length; i++) _idClient(i)];
  final marques = List.filled(clients.length, '?').join(', ');
  final variables = [for (final c in clients) Variable.withString(c)];

  await db.transaction(() async {
    for (final MapEntry(key: table, value: ids) in parTable.entries) {
      final info = db.allTables.firstWhere((t) => t.actualTableName == table);
      await db.customUpdate(
        "UPDATE $table SET sync_state = 'synced' "
        'WHERE id IN (${List.filled(ids.length, '?').join(', ')})',
        variables: [for (final id in ids) Variable.withString(id)],
        updates: {info},
      );
    }
    await db.customUpdate(
      "UPDATE reservations SET sync_state = 'synced' "
      'WHERE guest_id IN ($marques)',
      variables: variables,
      updates: {db.reservations},
    );
    await db.customUpdate(
      "UPDATE reservation_rooms SET sync_state = 'synced' "
      'WHERE reservation_id IN '
      '(SELECT id FROM reservations WHERE guest_id IN ($marques))',
      variables: variables,
      updates: {db.reservationRooms},
    );
    await db.customUpdate(
      "UPDATE folios SET sync_state = 'synced' WHERE reservation_room_id IN "
      '(SELECT rr.id FROM reservation_rooms rr JOIN reservations r '
      'ON r.id = rr.reservation_id WHERE r.guest_id IN ($marques))',
      variables: variables,
      updates: {db.folios},
    );
    if (chambres.isNotEmpty) {
      await db.customUpdate(
        "UPDATE rooms SET sync_state = 'synced' "
        'WHERE id IN (${List.filled(chambres.length, '?').join(', ')})',
        variables: [for (final c in chambres) Variable.withString(c)],
        updates: {db.rooms},
      );
    }
    await (db.delete(
      db.outboxEntries,
    )..where((o) => o.id.isIn([for (final e in notres) e.id]))).go();
  });

  return [...?parTable['housekeeping_tasks']];
}

/// Vrai si l'agent a modifie un sejour de demonstration : il a alors une
/// ecriture en attente, et on ne deplace plus rien.
Future<bool> _touchee(AtriumDatabase db) async {
  final clients = [for (var i = 0; i < _clients.length; i++) _idClient(i)];
  final marques = List.filled(clients.length, '?').join(', ');
  final l = await db
      .customSelect(
        '''
        SELECT
          (SELECT COUNT(*) FROM reservations
            WHERE guest_id IN ($marques) AND sync_state <> 'synced')
        + (SELECT COUNT(*) FROM reservation_rooms rr
             JOIN reservations r ON r.id = rr.reservation_id
            WHERE r.guest_id IN ($marques) AND rr.sync_state <> 'synced')
        + (SELECT COUNT(*) FROM folio_items fi
             JOIN folios f ON f.id = fi.folio_id
             JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
             JOIN reservations r ON r.id = rr.reservation_id
            WHERE r.guest_id IN ($marques) AND fi.sync_state <> 'synced')
          AS n
        ''',
        variables: [
          for (var k = 0; k < 3; k++)
            for (final c in clients) Variable.withString(c),
        ],
      )
      .getSingle();
  return l.read<int>('n') > 0;
}

/// Avance tout le jeu de `jours` jours : dates de sejour, instants, nuitees,
/// taches de menage, notifications.
Future<void> _decaler(AtriumDatabase db, int jours, List<String> taches) async {
  final d = "'+$jours days'";
  String date(String colonne) => '$colonne = date($colonne, $d)';
  // Meme forme que celle qu'ecrit Drift, pour que la relecture reste exacte.
  String instant(String colonne) =>
      "$colonne = CASE WHEN $colonne IS NULL THEN NULL ELSE "
      "strftime('%Y-%m-%dT%H:%M:%fZ', $colonne, $d) END";

  final clients = [for (var i = 0; i < _clients.length; i++) _idClient(i)];
  final marques = List.filled(clients.length, '?').join(', ');
  final variables = [for (final c in clients) Variable.withString(c)];
  const reservationsDemo = 'SELECT id FROM reservations WHERE guest_id IN';
  final lignesDemo =
      'SELECT rr.id FROM reservation_rooms rr JOIN reservations r '
      'ON r.id = rr.reservation_id WHERE r.guest_id IN ($marques)';

  await db.transaction(() async {
    await db.customUpdate(
      'UPDATE reservations SET ${date('arrival_date')}, '
      '${date('departure_date')}, ${instant('created_at')} '
      'WHERE guest_id IN ($marques)',
      variables: variables,
      updates: {db.reservations},
    );
    await db.customUpdate(
      'UPDATE reservation_rooms SET ${date('arrival_date')}, '
      '${date('departure_date')}, ${instant('checked_in_at')}, '
      '${instant('checked_out_at')} '
      'WHERE reservation_id IN ($reservationsDemo ($marques))',
      variables: variables,
      updates: {db.reservationRooms},
    );
    // Les nuitees gardent leur libelle et leur cle d'idempotence d'accord
    // avec leur nouvelle date (voir `postStayNights`).
    await db.customUpdate(
      'UPDATE folio_items SET ${date('business_date')}, '
      "label = CASE WHEN source_table = 'stay_nights' "
      "THEN 'Nuitee du ' || strftime('%d/%m/%Y', date(business_date, $d)) "
      'ELSE label END, '
      "source_id = CASE WHEN source_table = 'stay_nights' "
      "THEN substr(source_id, 1, 37) || date(business_date, $d) "
      'ELSE source_id END '
      'WHERE folio_id IN (SELECT id FROM folios '
      'WHERE reservation_room_id IN ($lignesDemo))',
      variables: variables,
      updates: {db.folioItems},
    );
    if (taches.isNotEmpty) {
      await db.customUpdate(
        'UPDATE housekeeping_tasks SET ${date('business_date')}, '
        '${instant('created_at')} '
        'WHERE id IN (${List.filled(taches.length, '?').join(', ')})',
        variables: [for (final t in taches) Variable.withString(t)],
        updates: {db.housekeepingTasks},
      );
    }
    await db.customUpdate(
      'UPDATE notifications SET ${instant('created_at')} '
      'WHERE id IN (?, ?)',
      variables: [
        Variable.withString(_idNotification(0)),
        Variable.withString(_idNotification(1)),
      ],
      updates: {db.notifications},
    );
  });
}

Future<void> _dater(
  AtriumDatabase db,
  String table,
  String id,
  String colonne,
  DateTime quand,
) {
  final info = db.allTables.firstWhere((t) => t.actualTableName == table);
  return db.customUpdate(
    'UPDATE $table SET $colonne = ? WHERE id = ?',
    variables: [
      Variable.withString(quand.toUtc().toIso8601String()),
      Variable.withString(id),
    ],
    updates: {info},
  );
}

Future<void> _noter(
  AtriumDatabase db,
  DateTime jour,
  List<String> taches,
) async {
  final now = DateTime.now().toUtc();
  await db
      .into(db.settings)
      .insertOnConflictUpdate(
        SettingsCompanion.insert(
          id: _idMarqueur,
          createdAt: now,
          updatedAt: now,
          hotelId: _hotel,
          key: 'demo.activite',
          value: Value(
            jsonEncode({'jour': formatIsoDate(jour), 'taches': taches}),
          ),
          scope: const Value(SettingScope.DEVICE),
          label: const Value('Activité de démonstration'),
          syncState: const Value(SyncState.synced),
        ),
      );
}
