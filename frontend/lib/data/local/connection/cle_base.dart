/// La cle de la base, dans le magasin securise de la tablette.
///
/// Elle est tiree au hasard au premier lancement et ne quitte jamais la
/// tablette : ni le serveur ni la base ne la connaissent. Perdue, la base est
/// illisible -- c'est le but face a un voleur, et le danger face a un
/// magasin defaillant.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'chiffrement.dart';

class CleBase {
  const CleBase([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static const _cle = 'atrium.db_key';

  /// La cle de la base, creee si elle manque.
  ///
  /// `null` quand le magasin ne garde pas ce qu'on lui confie : le Keystore
  /// d'Android 8.1 a deja perdu des ecritures sans erreur (`TokenStore`).
  /// Chiffrer avec une cle que le prochain lancement ne retrouvera pas
  /// rendrait la base illisible, ecritures en attente comprises. La base
  /// reste alors en clair, et l'essai recommence au lancement suivant.
  ///
  /// Une lecture qui echoue leve [MagasinIndisponible] : ce n'est pas une cle
  /// perdue, et une base deja chiffree ne doit pas etre mise de cote pour
  /// une panne passagere du Keystore.
  Future<String?> obtenir() async {
    final String? existante;
    try {
      existante = await _storage.read(key: _cle);
    } catch (e) {
      throw MagasinIndisponible('$e');
    }
    if (existante != null) return existante;
    try {
      final cle = nouvelleCle();
      await _storage.write(key: _cle, value: cle);
      // Relire plutot que croire l'ecriture : c'est la relecture au
      // prochain demarrage qui compte.
      if (await _storage.read(key: _cle) == cle) return cle;
      debugPrint(
        'Atrium : le magasin securise ne garde pas la cle de la base ; '
        'la base reste en clair.',
      );
    } catch (e) {
      debugPrint(
        'Atrium : magasin securise indisponible ($e) ; la base reste en '
        'clair.',
      );
    }
    return null;
  }

  /// La tablette est revoquee : sans sa cle, ce qui reste du fichier ne se
  /// lit plus. Le lancement suivant en tire une neuve.
  Future<void> effacer() async {
    try {
      await _storage.delete(key: _cle);
    } catch (e) {
      debugPrint('Atrium : la cle de la base ne s\'efface pas : $e');
    }
  }
}

class MagasinIndisponible implements Exception {
  const MagasinIndisponible(this.cause);

  final String cause;

  @override
  String toString() => 'Magasin securise indisponible : $cause';
}
