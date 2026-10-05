/// La remontee des photos de piece d'identite.
///
/// Deux promesses du ticket : la photo prise au comptoir n'est jamais perdue,
/// meme si la tablette redemarre avant d'avoir trouve le reseau ; et une
/// photo qui echoue ne retient rien -- ni le check-in, ni les ecritures qui
/// suivent, ni les autres photos.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/files/photo_files.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/file_uploader.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/id_photo_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un vrai dossier sur le disque, comme `Documents/` sur la tablette.
class _Dossier implements PhotoFiles {
  _Dossier(this.racine);

  final Directory racine;

  File _f(String chemin) => File('${racine.path}/$chemin');

  @override
  bool get available => true;

  @override
  Future<void> write(String relativePath, Uint8List bytes) async {
    final f = _f(relativePath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> read(String relativePath) async {
    final f = _f(relativePath);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> delete(String relativePath) async {
    final f = _f(relativePath);
    if (await f.exists()) await f.delete();
  }
}

/// Un serveur de papier : les ecritures JSON passent, les photos passent ou
/// non selon ce qu'on lui a dit.
class _Serveur extends ApiClient {
  _Serveur() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final ecritures = <String>[];
  final photos = <String, FormData>{};

  /// Refus du serveur, par id de piece jointe.
  final refus = <String, ApiException>{};

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    ecritures.add(path);
    return {};
  }

  @override
  Future<Map<String, dynamic>> putFile(String path, FormData form) async {
    final refuse = refus[path.split('/').last];
    if (refuse != null) throw refuse;
    photos[path] = form;
    return {'file_url': '/api/v1$path/file'};
  }
}

Uint8List _jpeg(int marque) => Uint8List.fromList([0xFF, 0xD8, marque]);

Future<List<int>> _octets(FormData form) =>
    form.files.single.value.finalize().expand((c) => c).toList();

String _champ(FormData form, String nom) =>
    form.fields.firstWhere((f) => f.key == nom).value;

void main() {
  late Directory dossier;
  late _Dossier disque;
  late _Serveur serveur;

  setUp(() {
    dossier = Directory.systemTemp.createTempSync('atrium_photos_');
    disque = _Dossier(dossier);
    serveur = _Serveur();
  });

  tearDown(() => dossier.deleteSync(recursive: true));

  test('la reference de la photo survit a un redemarrage', () async {
    final fichier = File('${dossier.path}/atrium.sqlite');

    // Avant le redemarrage : un client remonte, puis sa piece est
    // photographiee, et la tablette s'eteint avant d'avoir pu l'envoyer.
    var db = AtriumDatabase(NativeDatabase(fichier));
    await seedDemoData(db);
    final clientId = (await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo')).id;
    await OutboxSender(db: db, api: serveur).drain();
    await IdPhotoRepository(
      db,
      disque,
    ).save(guestId: clientId, side: IdPhotoSide.front, jpeg: _jpeg(7));
    await db.close();

    // Apres : une nouvelle base sur le meme fichier.
    db = AtriumDatabase(NativeDatabase(fichier));
    addTearDown(db.close);
    final photos = IdPhotoRepository(db, disque);

    final recto = (await photos.watch(clientId).first)[IdPhotoSide.front]!;
    expect(recto.filePathLocal, startsWith('pieces/'));
    expect(await photos.read(recto), _jpeg(7));
    expect(recto.uploadState, UploadState.PENDING);

    // La remontee n'a pas ete oubliee : elle part au premier passage.
    final rapport = await FileUploader(
      db: db,
      api: serveur,
      files: disque,
    ).drain();
    expect(rapport.envoyees, 1);

    final envoi = serveur.photos['/attachments/${recto.id}']!;
    expect(_champ(envoi, 'entity_table'), 'guests');
    expect(_champ(envoi, 'entity_id'), clientId);
    expect(_champ(envoi, 'kind'), 'ID_FRONT');
    expect(await _octets(envoi), _jpeg(7));

    final apres = await (db.select(
      db.attachments,
    )..where((a) => a.id.equals(recto.id))).getSingle();
    expect(apres.uploadState, UploadState.UPLOADED);
    expect(apres.fileUrl, '/api/v1/attachments/${recto.id}/file');
  });

  group('une photo en echec', () {
    late AtriumDatabase db;
    late GuestRepository guests;
    late ReservationRepository reservations;
    late IdPhotoRepository photos;
    late OutboxSender file;
    late FileUploader televerseur;

    setUp(() async {
      db = AtriumDatabase.memory();
      await db.customStatement('PRAGMA foreign_keys = ON');
      await seedDemoData(db);
      guests = GuestRepository(db);
      reservations = ReservationRepository(db);
      photos = IdPhotoRepository(db, disque);
      file = OutboxSender(db: db, api: serveur);
      televerseur = FileUploader(db: db, api: serveur, files: disque);
    });

    tearDown(() => db.close());

    Future<AttachmentRow> photographier(
      String clientId,
      IdPhotoSide cote,
    ) async {
      await photos.save(guestId: clientId, side: cote, jpeg: _jpeg(cote.index));
      return (await photos.watch(clientId).first)[cote]!;
    }

    test('ne bloque pas les ecritures suivantes', () async {
      final client = await guests.create(firstName: 'Awa', lastName: 'Diallo');
      final type = roomTypeSeeds.first.id;
      final chambre =
          await (db.select(db.rooms)
                ..where((r) => r.roomTypeId.equals(type))
                ..limit(1))
              .getSingle();
      final resId = await reservations.create(
        guestId: client.id,
        roomTypeId: type,
        arrival: DateTime(2026, 10, 1),
        departure: DateTime(2026, 10, 3),
        nightlyRate: 25000,
        roomId: chambre.id,
      );
      expect((await file.drain()).arret, DrainStop.termine);

      // Au comptoir : le recto est refuse par le serveur, le verso non.
      final recto = await photographier(client.id, IdPhotoSide.front);
      await photographier(client.id, IdPhotoSide.back);
      serveur.refus[recto.id] = const ApiException(
        ApiFailure.invalid,
        'Type de fichier refuse.',
      );

      final rapport = await televerseur.drain();
      expect(rapport.arret, UploadStop.termine);
      expect(rapport.refusees, 1);
      // Le refus du recto n'a pas retenu le verso.
      expect(rapport.envoyees, 1);

      final etats = {
        for (final a in await db.select(db.attachments).get())
          a.kind: a.uploadState,
      };
      expect(etats, {
        'ID_FRONT': UploadState.FAILED,
        'ID_BACK': UploadState.UPLOADED,
      });

      // L'arrivee, puis tout ce qui suit, remonte comme si de rien n'etait.
      final ligne = await (db.select(
        db.reservationRooms,
      )..where((rr) => rr.reservationId.equals(resId))).getSingle();
      await reservations.checkIn(lineId: ligne.id);

      final apres = await file.drain();
      expect(apres.arret, DrainStop.termine);
      expect(apres.restantes, 0);
      expect(serveur.ecritures, contains(endsWith('/check-in')));

      // Et la photo n'est jamais entree dans la file d'envoi.
      final tables = await db.select(db.outboxEntries).get();
      expect(tables.map((e) => e.entityTable), isNot(contains('attachments')));
    });

    test("hors ligne, elle attend sans rien retenir", () async {
      final client = await guests.create(firstName: 'Awa', lastName: 'Diallo');
      await file.drain();
      final recto = await photographier(client.id, IdPhotoSide.front);
      serveur.refus[recto.id] = const ApiException(
        ApiFailure.offline,
        'Serveur injoignable.',
      );

      expect((await televerseur.drain()).arret, UploadStop.horsLigne);

      // La photo reste a envoyer : rien n'est perdu ni condamne.
      final envoi = await db.select(db.fileUploads).getSingle();
      expect(envoi.status, UploadState.PENDING);
      expect(envoi.attempts, 1);

      await guests.create(firstName: 'Ibrahim', lastName: 'Sow');
      expect((await file.drain()).envoyees, 1);

      serveur.refus.clear();
      expect((await televerseur.drain()).envoyees, 1);
    });
  });

  test('une photo attend que son client soit remonte', () async {
    final db = AtriumDatabase.memory();
    addTearDown(db.close);
    await seedDemoData(db);
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    await IdPhotoRepository(
      db,
      disque,
    ).save(guestId: client.id, side: IdPhotoSide.front, jpeg: _jpeg(1));
    final televerseur = FileUploader(db: db, api: serveur, files: disque);

    // Le serveur ne connait pas encore le client : il repondrait 404.
    expect((await televerseur.drain()).envoyees, 0);
    expect(serveur.photos, isEmpty);

    await OutboxSender(db: db, api: serveur).drain();
    expect((await televerseur.drain()).envoyees, 1);
  });
}
