/// Le navigateur n'a pas de disque ou ranger une photo.
///
/// Le web n'est qu'un outil de developpement (voir `connection.dart`) : les
/// ecrans y affichent que la prise de vue se fait sur la tablette, au lieu
/// d'ouvrir un appareil photo dont on ne saurait que faire du resultat.
library;

import 'dart:typed_data';

import 'photo_files.dart';

PhotoFiles platformPhotoFiles() => const _NoPhotoFiles();

class _NoPhotoFiles implements PhotoFiles {
  const _NoPhotoFiles();

  @override
  bool get available => false;

  @override
  Future<void> write(String relativePath, Uint8List bytes) =>
      throw UnsupportedError('Les photos se prennent sur la tablette.');

  @override
  Future<Uint8List?> read(String relativePath) async => null;

  @override
  Future<void> delete(String relativePath) async {}
}
