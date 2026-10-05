/// Photos de piece d'identite : rangees sur la tablette, lisibles hors ligne.
///
/// Elles ne doivent jamais entrer dans la file d'envoi, qui ne porte que du
/// JSON et qu'un refus bloquerait toute entiere : elles remontent par leur
/// propre file, `file_uploads`.
library;

import 'dart:typed_data';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/files/photo_files.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/id_photo_repository.dart';
import 'package:atrium/data/repositories/reservation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un disque de papier : ce qui a ete ecrit, et ce qui a ete efface.
class _Disque implements PhotoFiles {
  final fichiers = <String, Uint8List>{};

  @override
  bool get available => true;

  @override
  Future<void> write(String relativePath, Uint8List bytes) async =>
      fichiers[relativePath] = bytes;

  @override
  Future<Uint8List?> read(String relativePath) async => fichiers[relativePath];

  @override
  Future<void> delete(String relativePath) async =>
      fichiers.remove(relativePath);
}

Uint8List _jpeg(int marque) => Uint8List.fromList([0xFF, 0xD8, marque]);

void main() {
  late AtriumDatabase db;
  late _Disque disque;
  late IdPhotoRepository photos;
  late String clientId;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    disque = _Disque();
    photos = IdPhotoRepository(db, disque);
    clientId = (await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo')).id;
  });

  tearDown(() => db.close());

  Future<List<AttachmentRow>> lignes() => db.select(db.attachments).get();

  test(
    'une photo va sur le disque et dans attachments, pas dans la file',
    () async {
      final fileAvant = await db.select(db.outboxEntries).get();

      await photos.save(
        guestId: clientId,
        side: IdPhotoSide.front,
        jpeg: _jpeg(1),
      );

      final rangees = await lignes();
      expect(rangees, hasLength(1));
      final recto = rangees.single;
      expect(recto.entityTable, 'guests');
      expect(recto.entityId, clientId);
      expect(recto.kind, 'ID_FRONT');
      expect(recto.mimeType, 'image/jpeg');
      expect(recto.sizeBytes, 3);
      expect(recto.uploadState, UploadState.PENDING);
      // Relatif au dossier de l'application, qui change de nom sur iOS.
      expect(recto.filePathLocal, startsWith('pieces/'));
      expect(disque.fichiers.keys, [recto.filePathLocal]);

      expect(
        await db.select(db.outboxEntries).get(),
        hasLength(fileAvant.length),
      );

      final envoi = await db.select(db.fileUploads).getSingle();
      expect(envoi.entityTable, 'attachments');
      expect(envoi.entityId, recto.id);
      expect(envoi.localPath, recto.filePathLocal);
      expect(envoi.status, UploadState.PENDING);
    },
  );

  test('reprendre le recto remplace la photo, sans seconde ligne', () async {
    await photos.save(
      guestId: clientId,
      side: IdPhotoSide.front,
      jpeg: _jpeg(1),
    );
    final premiere = (await lignes()).single.filePathLocal;

    await photos.save(
      guestId: clientId,
      side: IdPhotoSide.front,
      jpeg: _jpeg(2),
    );

    final rangees = await lignes();
    expect(rangees, hasLength(1));
    expect(rangees.single.filePathLocal, isNot(premiere));
    // L'ancien fichier ne reste pas sur le disque de la tablette.
    expect(disque.fichiers.keys, [rangees.single.filePathLocal]);
    expect(await photos.read(rangees.single), _jpeg(2));

    // Une seule remontee, celle de la nouvelle photo : l'ancienne n'est plus
    // sur le disque.
    final envoi = await db.select(db.fileUploads).getSingle();
    expect(envoi.localPath, rangees.single.filePathLocal);
  });

  test('le recto et le verso se relisent depuis la fiche', () async {
    await photos.save(
      guestId: clientId,
      side: IdPhotoSide.front,
      jpeg: _jpeg(1),
    );
    await photos.save(
      guestId: clientId,
      side: IdPhotoSide.back,
      jpeg: _jpeg(2),
    );

    final vues = await photos.watch(clientId).first;
    expect(vues.keys, unorderedEquals(IdPhotoSide.values));
    expect(await photos.read(vues[IdPhotoSide.front]!), _jpeg(1));
    expect(await photos.read(vues[IdPhotoSide.back]!), _jpeg(2));

    // Un autre client ne voit rien de ces photos.
    expect(
      await photos.watch('01920000-0000-7000-8000-0000000000aa').first,
      isEmpty,
    );
  });

  test("le client d'une ligne est retrouve a l'arrivee", () async {
    final reservations = ReservationRepository(db);
    final resId = await reservations.create(
      guestId: clientId,
      roomTypeId: roomTypeSeeds.first.id,
      arrival: DateTime(2026, 10, 1),
      departure: DateTime(2026, 10, 2),
      nightlyRate: 25000,
    );
    final ligne = await (db.select(
      db.reservationRooms,
    )..where((rr) => rr.reservationId.equals(resId))).getSingle();

    expect(await reservations.guestIdOfLine(ligne.id), clientId);
    expect(
      await reservations.guestIdOfLine('01920000-0000-7000-8000-0000000000bb'),
      isNull,
    );
  });
}
