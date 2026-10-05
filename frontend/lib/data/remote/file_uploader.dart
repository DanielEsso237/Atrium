/// Le moteur qui remonte les fichiers : les photos de piece d'identite.
///
/// La file d'envoi (`OutboxSender`) ne porte que du JSON, et s'arrete net au
/// premier refus. Une photo n'a rien a y faire : elle pese des centaines de
/// kilo-octets, peut attendre un meilleur reseau, et **ne doit jamais retenir
/// un check-in**. Elle a donc sa propre file, `file_uploads`, et ce moteur a
/// ses propres regles, presque inverses.
///
/// **L'ordre ne compte pas.** Deux photos ne dependent pas l'une de l'autre :
/// une photo refusee est marquee et on passe a la suivante, au lieu de tout
/// bloquer derriere elle.
///
/// **Une photo attend son client.** Tant que la creation du client n'est pas
/// remontee, le serveur ne le connait pas et repondrait 404. La photo reste
/// en file sans etre tentee ; elle partira au passage suivant.
///
/// **Rien ne sort d'ici.** Aucune exception ne remonte jusqu'a la
/// synchronisation : un fichier illisible ou une reponse inattendue se notent
/// sur la ligne de la file, et la file d'envoi n'en sait jamais rien.
library;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';
import '../local/files/photo_files.dart';
import 'api_client.dart';

/// Pourquoi un passage s'est arrete.
enum UploadStop {
  /// Tout ce qui pouvait partir est parti, ou a ete refuse.
  termine,

  /// Serveur injoignable : on reessaiera plus tard, sans rien marquer.
  horsLigne,

  /// Session expiree : la prochaine connexion relancera.
  sessionInvalide,
}

/// Ce qu'un passage a donne.
class UploadReport {
  const UploadReport({
    required this.envoyees,
    required this.refusees,
    required this.arret,
    this.lotPlein = false,
  });

  final int envoyees;
  final int refusees;
  final UploadStop arret;

  /// Le passage a atteint sa borne : il en reste peut-etre.
  final bool lotPlein;

  @override
  String toString() =>
      'UploadReport($envoyees envoyees, $refusees refusees, $arret)';
}

/// Vide `file_uploads` vers `PUT /attachments/{id}`.
class FileUploader {
  FileUploader({required this.db, required this.api, required this.files});

  final AtriumDatabase db;
  final ApiClient api;
  final PhotoFiles files;

  Future<UploadReport>? _enCours;

  /// Remonte les photos pretes a partir, au plus `max` par passage.
  ///
  /// Un seul passage a la fois : deux passages simultanes enverraient deux
  /// fois la meme photo.
  Future<UploadReport> drain({int max = 20}) =>
      _enCours ??= _drain(max).whenComplete(() => _enCours = null);

  Future<UploadReport> _drain(int max) async {
    var envoyees = 0;
    var refusees = 0;
    final lot = await _pretes(max);

    for (final (envoi, piece) in lot) {
      try {
        final octets = await files.read(envoi.localPath);
        if (octets == null) {
          await _refuser(envoi, 'Photo absente de la tablette.');
          refusees++;
          continue;
        }
        final reponse = await api.putFile(
          '/attachments/${piece.id}',
          _formulaire(envoi, piece, octets),
        );
        await _acquitter(envoi, reponse['file_url'] as String?);
        envoyees++;
      } on ApiException catch (e) {
        switch (e.failure) {
          case ApiFailure.offline:
          case ApiFailure.server:
            await _compterTentative(envoi, e.message);
            return UploadReport(
              envoyees: envoyees,
              refusees: refusees,
              arret: UploadStop.horsLigne,
            );
          case ApiFailure.unauthorized:
          case ApiFailure.locked:
            await _compterTentative(envoi, e.message);
            return UploadReport(
              envoyees: envoyees,
              refusees: refusees,
              arret: UploadStop.sessionInvalide,
            );
          // Refus de fond : renvoyer la meme photo ne changera rien. Elle est
          // marquee, et les suivantes partent quand meme.
          case ApiFailure.forbidden:
          case ApiFailure.notFound:
          case ApiFailure.conflict:
          case ApiFailure.invalid:
            await _refuser(envoi, e.message);
            refusees++;
        }
      } catch (e) {
        await _refuser(envoi, 'Echec inattendu : $e');
        refusees++;
      }
    }

    return UploadReport(
      envoyees: envoyees,
      refusees: refusees,
      arret: UploadStop.termine,
      lotPlein: lot.length == max,
    );
  }

  /// Les photos en attente dont le client est deja connu du serveur.
  Future<List<(FileUploadRow, AttachmentRow)>> _pretes(int max) {
    final u = db.fileUploads;
    final a = db.attachments;
    final o = db.outboxEntries;

    final creationEnAttente = db.selectOnly(o)
      ..addColumns([o.id])
      ..where(
        o.entityTable.equalsExp(a.entityTable) &
            o.entityId.equalsExp(a.entityId) &
            o.op.equalsValue(SyncOp.INSERT) &
            o.status.isInValues([OutboxStatus.PENDING, OutboxStatus.FAILED]),
      );

    final query = db.select(u).join([innerJoin(a, a.id.equalsExp(u.entityId))])
      ..where(
        u.entityTable.equals('attachments') &
            u.status.equalsValue(UploadState.PENDING) &
            notExistsQuery(creationEnAttente),
      )
      ..orderBy([OrderingTerm.asc(u.id)])
      ..limit(max);

    return query.map((r) => (r.readTable(u), r.readTable(a))).get();
  }

  FormData _formulaire(
    FileUploadRow envoi,
    AttachmentRow piece,
    Uint8List octets,
  ) {
    return FormData.fromMap({
      'entity_table': piece.entityTable,
      'entity_id': piece.entityId,
      'kind': piece.kind,
      // L'instant de la prise, pas celui de l'envoi : c'est lui qui departage
      // deux photos du meme cote sur le serveur.
      if (piece.capturedAt != null)
        'captured_at': piece.capturedAt!.toUtc().toIso8601String(),
      if (piece.capturedBy != null) 'captured_by': piece.capturedBy,
      'file': MultipartFile.fromBytes(
        octets,
        filename: envoi.localPath.split('/').last,
        contentType: DioMediaType.parse(envoi.mimeType ?? 'image/jpeg'),
      ),
    });
  }

  /// La piece n'est marquee que si elle montre encore **cette** photo : une
  /// reprise faite pendant l'envoi a sa propre remontee en file, et la
  /// declarer remontee mentirait.
  Expression<bool> _toujoursCettePhoto(
    $AttachmentsTable a,
    FileUploadRow envoi,
  ) => a.id.equals(envoi.entityId) & a.filePathLocal.equals(envoi.localPath);

  Future<void> _acquitter(FileUploadRow envoi, String? url) {
    return db.transaction(() async {
      await (db.update(
        db.fileUploads,
      )..where((u) => u.id.equals(envoi.id))).write(
        FileUploadsCompanion(
          status: const Value(UploadState.UPLOADED),
          attempts: Value(envoi.attempts + 1),
          lastError: const Value(null),
          remoteUrl: Value(url),
        ),
      );
      await (db.update(
        db.attachments,
      )..where((a) => _toujoursCettePhoto(a, envoi))).write(
        AttachmentsCompanion(
          fileUrl: Value(url),
          uploadState: const Value(UploadState.UPLOADED),
          syncState: const Value(SyncState.synced),
        ),
      );
    });
  }

  Future<void> _refuser(FileUploadRow envoi, String raison) {
    return db.transaction(() async {
      await (db.update(
        db.fileUploads,
      )..where((u) => u.id.equals(envoi.id))).write(
        FileUploadsCompanion(
          status: const Value(UploadState.FAILED),
          attempts: Value(envoi.attempts + 1),
          lastError: Value(_borne(raison)),
        ),
      );
      await (db.update(
        db.attachments,
      )..where((a) => _toujoursCettePhoto(a, envoi))).write(
        const AttachmentsCompanion(uploadState: Value(UploadState.FAILED)),
      );
    });
  }

  /// Compte la tentative sans condamner la photo : elle reste en attente.
  Future<void> _compterTentative(FileUploadRow envoi, String raison) {
    return (db.update(
      db.fileUploads,
    )..where((u) => u.id.equals(envoi.id))).write(
      FileUploadsCompanion(
        attempts: Value(envoi.attempts + 1),
        lastError: Value(_borne(raison)),
      ),
    );
  }

  // `last_error` est borne a 512 caracteres par la table.
  String _borne(String s) => s.length <= 512 ? s : s.substring(0, 512);
}
