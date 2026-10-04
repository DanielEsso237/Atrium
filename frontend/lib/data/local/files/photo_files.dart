/// Les photos prises sur la tablette, rangees sur son disque.
///
/// La base ne garde que la reference (`attachments.file_path_local`) : une
/// photo de piece d'identite pese quelques centaines de kilo-octets, et la
/// mettre dans SQLite alourdirait chaque sauvegarde et chaque lecture de la
/// table.
///
/// Les chemins sont **relatifs** au dossier de l'application. Sur iOS ce
/// dossier change de nom a chaque mise a jour : un chemin absolu enregistre
/// en base pointerait dans le vide apres la premiere.
library;

import 'dart:typed_data';

export 'photo_files_native.dart'
    if (dart.library.js_interop) 'photo_files_web.dart';

abstract interface class PhotoFiles {
  /// Faux dans le navigateur, qui n'a pas de disque : la prise de vue se
  /// fait sur la tablette.
  bool get available;

  Future<void> write(String relativePath, Uint8List bytes);

  /// `null` si le fichier n'est pas (ou plus) sur cet appareil.
  Future<Uint8List?> read(String relativePath);

  Future<void> delete(String relativePath);
}
