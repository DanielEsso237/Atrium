/// Remettre un fichier exporte a l'agent.
///
/// Sur la tablette, la feuille de partage d'Android : enregistrer dans les
/// fichiers, envoyer par courriel ou WhatsApp, imprimer. Dans le navigateur,
/// un telechargement quand le partage n'existe pas -- le cas des postes de
/// bureau.
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

enum FormatExport {
  pdf('PDF', 'pdf', 'application/pdf'),
  excel(
    'Excel',
    'xlsx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  );

  const FormatExport(this.libelle, this.extension, this.mime);

  final String libelle;
  final String extension;
  final String mime;
}

/// Rend `true` si le fichier a ete partage ou telecharge, `false` si
/// l'agent a ferme la feuille sans rien choisir.
Future<bool> partagerFichier({
  required Uint8List octets,
  required String nom,
  required FormatExport format,
  required String sujet,
  Rect? origine,
}) async {
  final fichier = '$nom.${format.extension}';
  final resultat = await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(octets, mimeType: format.mime, name: fichier)],
      // `name` est ignore hors du web : sans ce renommage, le fichier
      // partait sous un nom tire au hasard.
      fileNameOverrides: [fichier],
      subject: sujet,
      title: sujet,
      sharePositionOrigin: origine,
    ),
  );
  return resultat.status != ShareResultStatus.dismissed;
}
