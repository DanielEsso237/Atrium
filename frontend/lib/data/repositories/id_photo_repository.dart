/// Photos de piece d'identite d'un client : le recto et le verso.
///
/// Rangees dans `attachments`, rattachees au **client** et non au sejour : la
/// piece est la meme au sejour suivant, et la fiche client doit la montrer
/// sans chercher dans quel sejour elle a ete prise.
///
/// Ni la ligne ni le fichier ne passent par la file d'envoi : elle ne porte
/// que du JSON, et une ecriture que le serveur refuse la bloque toute
/// entiere. Chaque prise enfile sa remontee dans `file_uploads`, que vide
/// `FileUploader` -- ligne et fichier arrivent ensemble au serveur.
library;

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import '../local/files/photo_files.dart';

enum IdPhotoSide {
  front('ID_FRONT'),
  back('ID_BACK');

  const IdPhotoSide(this.kind);

  /// La valeur de `attachments.kind`.
  final String kind;
}

class IdPhotoRepository {
  IdPhotoRepository(this.db, this.files);

  final AtriumDatabase db;
  final PhotoFiles files;

  static const _entityTable = 'guests';

  SimpleSelectStatement<$AttachmentsTable, AttachmentRow> _query(
    String guestId, [
    IdPhotoSide? side,
  ]) => db.select(db.attachments)
    ..where(
      (a) =>
          a.entityTable.equals(_entityTable) &
          a.entityId.equals(guestId) &
          a.deletedAt.isNull() &
          (side == null
              ? a.kind.isIn([for (final s in IdPhotoSide.values) s.kind])
              : a.kind.equals(side.kind)),
    )
    ..orderBy([(a) => OrderingTerm.asc(a.capturedAt)]);

  /// Le recto et le verso d'un client, ceux qu'il a.
  ///
  /// La plus recente l'emporte s'il y en a deux d'un meme cote : ce sera le
  /// cas le jour ou deux tablettes photographieront le meme client.
  Stream<Map<IdPhotoSide, AttachmentRow>> watch(String guestId) =>
      _query(guestId).watch().map(
        (rows) => {
          for (final r in rows)
            IdPhotoSide.values.firstWhere((s) => s.kind == r.kind): r,
        },
      );

  Future<Uint8List?> read(AttachmentRow photo) async =>
      photo.filePathLocal == null ? null : files.read(photo.filePathLocal!);

  /// Range la photo d'un cote, en remplacant celle qui y etait.
  ///
  /// Le fichier s'ecrit d'abord : une ligne sans fichier montrerait une
  /// piece qui n'existe pas. Chaque prise a son propre nom, pour qu'une
  /// reprise n'ecrase jamais le fichier encore affiche.
  Future<void> save({
    required String guestId,
    required IdPhotoSide side,
    required Uint8List jpeg,
    String? by,
  }) async {
    final now = DateTime.now().toUtc();
    final id = newId();
    final path = 'pieces/$id.jpg';
    await files.write(path, jpeg);

    final previous = await db.transaction(() async {
      final previous = await _query(guestId, side).get();
      if (previous.isEmpty) {
        await db
            .into(db.attachments)
            .insert(
              AttachmentsCompanion.insert(
                id: id,
                createdAt: now,
                updatedAt: now,
                createdBy: Value(by),
                updatedBy: Value(by),
                entityTable: _entityTable,
                entityId: guestId,
                kind: Value(side.kind),
                filePathLocal: Value(path),
                mimeType: const Value('image/jpeg'),
                sizeBytes: Value(jpeg.length),
                capturedAt: Value(now),
                capturedBy: Value(by),
              ),
            );
        await _enfiler(id, path, jpeg.length, now);
        return null;
      }

      // Une reprise met a jour la ligne existante plutot que d'en ajouter
      // une : la remplacer exigerait de propager une suppression, que la
      // synchronisation ne sait pas encore faire. Le serveur, lui, remplace
      // le fichier sous le meme id.
      final current = previous.last;
      await (db.update(
        db.attachments,
      )..where((a) => a.id.equals(current.id))).write(
        AttachmentsCompanion(
          updatedAt: Value(now),
          updatedBy: Value(by),
          filePathLocal: Value(path),
          fileUrl: const Value(null),
          sizeBytes: Value(jpeg.length),
          uploadState: const Value(UploadState.PENDING),
          syncState: const Value(SyncState.pending),
          capturedAt: Value(now),
          capturedBy: Value(by),
        ),
      );
      await _enfiler(current.id, path, jpeg.length, now);
      return current;
    });

    if (previous?.filePathLocal != null) {
      await files.delete(previous!.filePathLocal!);
    }
  }

  /// Met la photo dans la file de televersement.
  ///
  /// Une remontee encore en attente pour la meme piece part avec : son
  /// fichier va etre efface, et l'envoyer ferait remonter une photo que
  /// l'agent vient justement de reprendre.
  Future<void> _enfiler(
    String attachmentId,
    String path,
    int size,
    DateTime now,
  ) async {
    await (db.delete(db.fileUploads)..where(
          (u) =>
              u.entityTable.equals('attachments') &
              u.entityId.equals(attachmentId) &
              u.status.equalsValue(UploadState.UPLOADED).not(),
        ))
        .go();
    await db
        .into(db.fileUploads)
        .insert(
          FileUploadsCompanion.insert(
            entityTable: 'attachments',
            entityId: attachmentId,
            localPath: path,
            mimeType: const Value('image/jpeg'),
            sizeBytes: Value(size),
            createdAt: now,
          ),
        );
  }
}
