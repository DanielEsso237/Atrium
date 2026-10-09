/// L'hotel : son nom, ses coordonnees et son logo, en tete des factures.
///
/// Le nom et les coordonnees suivent le chemin de toute ecriture : Drift et
/// la file d'envoi, dans la meme transaction (`PATCH /hotel`).
///
/// Le logo, lui, ne peut pas emprunter la file : elle ne porte que du JSON.
/// Il est range tout de suite sur la tablette -- les factures le portent
/// meme hors ligne -- et sa version commence par `local-` tant qu'il n'est
/// pas remonte. `synchroniser` l'envoie au passage suivant, puis rapatrie
/// celui du serveur s'il a change ailleurs. Une version `local-` n'est
/// jamais ecrasee par la descente : la tablette fait foi tant que son logo
/// n'est pas parti.
library;


import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../local/database.dart';
import '../local/enums.dart';
import '../remote/api_client.dart';
import '../remote/catalog_api.dart';
import 'outbox.dart';

/// Les memes limites que le serveur (`LOGO_MAX_OCTETS`) : ce qu'il refuse,
/// la tablette le refuse avant.
const logoMaxOctets = 512 * 1024;

/// Un logo importe ici et pas encore remonte.
const _prefixeLocal = 'local-';

/// Un retrait de logo pas encore remonte.
const _retraitLocal = 'local-retire';

/// PNG ou JPEG, reconnu a ses premiers octets.
bool estImageLogo(Uint8List o) =>
    (o.length > 8 &&
        o[0] == 0x89 &&
        o[1] == 0x50 &&
        o[2] == 0x4E &&
        o[3] == 0x47) ||
    (o.length > 3 && o[0] == 0xFF && o[1] == 0xD8 && o[2] == 0xFF);

class HotelRepository with OutboxWriter {
  HotelRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  Stream<HotelRow?> watch() => (db.select(
    db.hotels,
  )..where((h) => h.id.equals(hotelId))).watchSingleOrNull();

  Future<HotelRow?> lire() => (db.select(
    db.hotels,
  )..where((h) => h.id.equals(hotelId))).getSingleOrNull();

  /// `true` tant qu'un logo importe ou retire ici n'est pas remonte.
  static bool logoEnAttente(HotelRow? h) =>
      h?.logoVersion?.startsWith(_prefixeLocal) ?? false;

  /// Le nom et les coordonnees imprimes sur les factures.
  Future<void> modifierIdentite({
    required String nom,
    String? raisonSociale,
    String? adresse,
    String? ville,
    String? pays,
    String? telephone,
    String? email,
    String? numeroFiscal,
    String? by,
  }) async {
    final propre = nom.trim();
    if (propre.isEmpty) throw StateError("Indiquez le nom de l'hôtel.");
    if (propre.length > 160) {
      throw StateError("Le nom de l'hôtel tient en 160 caractères.");
    }
    String? vide(String? v) {
      final t = v?.trim();
      return t == null || t.isEmpty ? null : t;
    }

    final champs = {
      'name': propre,
      'legal_name': vide(raisonSociale),
      'address': vide(adresse),
      'city': vide(ville),
      'country': vide(pays),
      'phone': vide(telephone),
      'email': vide(email),
      'tax_id': vide(numeroFiscal),
    };
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(db.hotels)..where((h) => h.id.equals(hotelId))).write(
        HotelsCompanion(
          name: Value(propre),
          legalName: Value(champs['legal_name']),
          address: Value(champs['address']),
          city: Value(champs['city']),
          country: Value(champs['country']),
          phone: Value(champs['phone']),
          email: Value(champs['email']),
          taxId: Value(champs['tax_id']),
          updatedAt: Value(now),
          updatedBy: Value(by),
          syncState: const Value(SyncState.pending),
        ),
      );
      await enqueue(
        table: 'hotels',
        id: hotelId,
        operation: SyncOp.UPDATE,
        payload: {'id': hotelId, ...champs},
      );
    });
  }

  /// Range un nouveau logo sur la tablette ; il remontera a la synchro.
  Future<void> importerLogo(Uint8List octets, {String? by}) async {
    if (octets.isEmpty) throw StateError('Ce fichier est vide.');
    if (!estImageLogo(octets)) {
      throw StateError('Le logo doit être une image PNG ou JPEG.');
    }
    if (octets.length > logoMaxOctets) {
      throw StateError(
        'Logo trop lourd (${(octets.length / 1024).round()} Ko) : '
        '512 Ko au plus. Choisissez une image plus petite.',
      );
    }
    await (db.update(db.hotels)..where((h) => h.id.equals(hotelId))).write(
      HotelsCompanion(
        logoData: Value(octets),
        logoVersion: Value(
          '$_prefixeLocal${DateTime.now().microsecondsSinceEpoch}',
        ),
        updatedBy: Value(by),
      ),
    );
  }

  /// Retire le logo : les factures reprennent le nom de l'hotel en tete.
  Future<void> retirerLogo({String? by}) async {
    await (db.update(db.hotels)..where((h) => h.id.equals(hotelId))).write(
      HotelsCompanion(
        logoData: const Value(null),
        logoVersion: const Value(_retraitLocal),
        updatedBy: Value(by),
      ),
    );
  }

  /// Remonte le logo en attente, puis rapatrie le parametrage du serveur.
  ///
  /// Hors ligne, s'arrete sans rien marquer : on reessaiera. Une ligne
  /// modifiee ici et pas encore remontee garde ses valeurs.
  Future<void> synchroniser(CatalogApi api) async {
    var ici = await lire();
    if (ici == null) return;

    if (logoEnAttente(ici)) {
      try {
        if (ici.logoVersion == _retraitLocal) {
          await api.deleteHotelLogo();
          await _poserVersion(null);
        } else if (ici.logoData != null) {
          final reponse = await api.putHotelLogo(ici.logoData!);
          await _poserVersion(reponse['logo_version'] as String?);
        }
      } on ApiException catch (e) {
        if (e.isOffline) return;
        // Un refus ne se reglera pas en reessayant a chaque passage, mais
        // la tablette garde son logo : il reste a l'ecran et sur les
        // factures, et l'administration dit qu'il n'est pas parti.
        debugPrint('[Hotel] logo refuse par le serveur : ${e.message}');
        return;
      }
      ici = await lire();
      if (ici == null) return;
    }

    final serveur = await api.fetchHotel();
    final enAttente = ici.syncState == SyncState.pending;
    final version = serveur['logo_version'] as String?;
    Uint8List? logo;
    final changer = !logoEnAttente(ici) && version != ici.logoVersion;
    if (changer && version != null) logo = await api.fetchHotelLogo();

    String? texte(String cle) => serveur[cle] as String?;
    await (db.update(db.hotels)..where((h) => h.id.equals(hotelId))).write(
      HotelsCompanion(
        // L'identite modifiee ici et pas encore remontee fait foi.
        name: enAttente || texte('name') == null
            ? const Value.absent()
            : Value(texte('name')!),
        legalName: enAttente ? const Value.absent() : Value(texte('legal_name')),
        address: enAttente ? const Value.absent() : Value(texte('address')),
        city: enAttente ? const Value.absent() : Value(texte('city')),
        postalCode: enAttente
            ? const Value.absent()
            : Value(texte('postal_code')),
        country: enAttente ? const Value.absent() : Value(texte('country')),
        phone: enAttente ? const Value.absent() : Value(texte('phone')),
        email: enAttente ? const Value.absent() : Value(texte('email')),
        website: enAttente ? const Value.absent() : Value(texte('website')),
        taxId: enAttente ? const Value.absent() : Value(texte('tax_id')),
        logoData: changer ? Value(logo) : const Value.absent(),
        logoVersion: changer ? Value(version) : const Value.absent(),
      ),
    );
  }

  Future<void> _poserVersion(String? version) =>
      (db.update(db.hotels)..where((h) => h.id.equals(hotelId))).write(
        HotelsCompanion(logoVersion: Value(version)),
      );
}
