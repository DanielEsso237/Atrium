/// Jeu de donnees de demonstration.
///
/// Sert a faire tourner l'application avant que le serveur n'existe, et a
/// donner aux tests un etablissement realiste. Les vrais types de chambres et
/// les vrais numeros viendront du parametrage de l'hotel.
///
/// Les identifiants sont **fixes** et non generes : le jeu est ainsi
/// idempotent, et surtout identique a celui du serveur
/// (`backend/app/db/seed.py`). Rejouer la fonction ne cree pas de doublon.
library;

import 'package:drift/drift.dart';

import 'database.dart';
import 'enums.dart';

// Identifiants deterministes, au format UUID v7.
// Le prefixe 01920000 correspond a un horodatage figé : ces lignes ne sont pas
// nees d'une saisie, elles font partie du parametrage livre.
const _hotel = '01920000-0000-7000-8000-000000000001';

const _floor1 = '01920000-0000-7000-8000-000000000101';
const _floor2 = '01920000-0000-7000-8000-000000000102';
const _floor3 = '01920000-0000-7000-8000-000000000103';
const _floor4 = '01920000-0000-7000-8000-000000000104';
const _floor5 = '01920000-0000-7000-8000-000000000105';

const _typeStandard = '01920000-0000-7000-8000-000000000201';
const _typeClassic = '01920000-0000-7000-8000-000000000202';
const _typeVip = '01920000-0000-7000-8000-000000000203';
const _typeSuite = '01920000-0000-7000-8000-000000000204';

/// Un type de chambre du jeu de demonstration.
class _RoomTypeSeed {
  const _RoomTypeSeed(
    this.id,
    this.code,
    this.label,
    this.baseCapacity,
    this.maxCapacity,
    this.rate,
  );

  final String id;
  final String code;
  final String label;
  final int baseCapacity;
  final int maxCapacity;

  /// Tarif de reference, en francs CFA entiers.
  final int rate;
}

/// Les quatre categories. Le prix est porte par le **type**, jamais par la
/// chambre : deux chambres de meme categorie se vendent au meme tarif, et une
/// revalorisation se fait en une seule ecriture.
const roomTypeSeeds = <_RoomTypeSeed>[
  _RoomTypeSeed(_typeStandard, 'STD', 'Standard', 2, 2, 25000),
  _RoomTypeSeed(_typeClassic, 'CLS', 'Classic', 2, 3, 35000),
  _RoomTypeSeed(_typeVip, 'VIP', 'VIP', 2, 3, 60000),
  _RoomTypeSeed(_typeSuite, 'SUI', 'Suite', 2, 4, 90000),
];

/// Une chambre : un numero, un type, un etage.
class _RoomSeed {
  const _RoomSeed(this.number, this.typeId, this.floorId);

  final String number;
  final String typeId;
  final String floorId;
}

/// Vingt chambres reparties sur cinq etages.
///
/// Les numeros sont arbitraires — ils illustrent le principe : le numero
/// identifie la chambre, le type porte la categorie et le prix. Deux chambres
/// d'etages differents peuvent parfaitement appartenir au meme type.
const roomSeeds = <_RoomSeed>[
  // Etage 1 — entree de gamme
  _RoomSeed('101', _typeStandard, _floor1),
  _RoomSeed('102', _typeStandard, _floor1),
  _RoomSeed('103', _typeClassic, _floor1),
  _RoomSeed('123', _typeStandard, _floor1),

  // Etage 2
  _RoomSeed('201', _typeClassic, _floor2),
  _RoomSeed('202', _typeClassic, _floor2),
  _RoomSeed('203', _typeVip, _floor2),
  _RoomSeed('204', _typeStandard, _floor2),

  // Etage 3
  _RoomSeed('301', _typeClassic, _floor3),
  _RoomSeed('302', _typeStandard, _floor3),
  _RoomSeed('309', _typeVip, _floor3),

  // Etage 4
  _RoomSeed('401', _typeStandard, _floor4),
  _RoomSeed('402', _typeClassic, _floor4),
  _RoomSeed('403', _typeVip, _floor4),

  // Etage 5 — haut de gamme
  _RoomSeed('501', _typeSuite, _floor5),
  _RoomSeed('502', _typeSuite, _floor5),
  _RoomSeed('510', _typeVip, _floor5),
  _RoomSeed('567', _typeStandard, _floor5),
];

const _floorSeeds = <(String, String, String, int)>[
  (_floor1, 'E1', 'Rez-de-chaussee', 1),
  (_floor2, 'E2', 'Premier etage', 2),
  (_floor3, 'E3', 'Deuxieme etage', 3),
  (_floor4, 'E4', 'Troisieme etage', 4),
  (_floor5, 'E5', 'Quatrieme etage', 5),
];

/// Insere le jeu de demonstration s'il n'est pas deja present.
///
/// `insertOnConflictUpdate` rend l'appel rejouable : relancer l'application ne
/// duplique rien et rafraichit le parametrage.
Future<void> seedDemoData(AtriumDatabase db) async {
  final now = DateTime.now().toUtc();

  await db.transaction(() async {
    await db.into(db.hotels).insertOnConflictUpdate(
          HotelsCompanion.insert(
            id: _hotel,
            createdAt: now,
            updatedAt: now,
            code: 'ATR',
            name: 'Hotel Atrium',
            city: const Value('Abidjan'),
            country: const Value("Cote d'Ivoire"),
            syncState: const Value(SyncState.synced),
          ),
        );

    for (final (id, code, label, order) in _floorSeeds) {
      await db.into(db.floors).insertOnConflictUpdate(
            FloorsCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: _hotel,
              code: code,
              label: label,
              sortOrder: Value(order),
              syncState: const Value(SyncState.synced),
            ),
          );
    }

    for (final t in roomTypeSeeds) {
      await db.into(db.roomTypes).insertOnConflictUpdate(
            RoomTypesCompanion.insert(
              id: t.id,
              createdAt: now,
              updatedAt: now,
              hotelId: _hotel,
              code: t.code,
              label: t.label,
              baseCapacity: Value(t.baseCapacity),
              maxCapacity: Value(t.maxCapacity),
              defaultRate: Value(t.rate),
              syncState: const Value(SyncState.synced),
            ),
          );
    }

    for (final r in roomSeeds) {
      await db.into(db.rooms).insertOnConflictUpdate(
            RoomsCompanion.insert(
              // Identifiant derive du numero : stable d'une execution a
              // l'autre, donc rejouable. Le segment `03` distingue les
              // chambres des etages (`01`) et des types (`02`).
              id: '01920000-0000-7000-8000-00000003${r.number.padLeft(4, '0')}',
              createdAt: now,
              updatedAt: now,
              hotelId: _hotel,
              number: r.number,
              roomTypeId: r.typeId,
              floorId: Value(r.floorId),
              syncState: const Value(SyncState.synced),
            ),
          );
    }
  });
}
