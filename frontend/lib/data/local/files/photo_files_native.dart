/// Les photos sur une tablette : des fichiers dans le dossier de l'application.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'photo_files.dart';

PhotoFiles platformPhotoFiles() => const _DevicePhotoFiles();

class _DevicePhotoFiles implements PhotoFiles {
  const _DevicePhotoFiles();

  @override
  bool get available => true;

  // Le dossier Documents et non le cache : Android vide le cache quand la
  // place manque, et la piece d'un client partirait avec.
  Future<File> _file(String relativePath) async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, relativePath));
  }

  @override
  Future<void> write(String relativePath, Uint8List bytes) async {
    final file = await _file(relativePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> read(String relativePath) async {
    final file = await _file(relativePath);
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<void> delete(String relativePath) async {
    final file = await _file(relativePath);
    if (await file.exists()) await file.delete();
  }
}
