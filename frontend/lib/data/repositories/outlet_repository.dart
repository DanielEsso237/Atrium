/// Les points de vente, tels que l'administration les gere (F3.1).
///
/// Creer, modifier, desactiver -- jamais supprimer : les commandes passees
/// renvoient a leur point de vente, et un point de vente disparu laisserait
/// ces commandes sans origine. Desactive, il sort simplement des onglets de
/// l'ecran Commande (`OrderRepository.watchOutlets`).
library;

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

class OutletRepository with OutboxWriter {
  OutletRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  /// Tous les points de vente, desactives compris : c'est ici qu'on les
  /// reactive.
  Stream<List<OutletRow>> watchAll() {
    return (db.select(db.outlets)
          ..where((o) => o.deletedAt.isNull())
          ..orderBy([
            (o) => OrderingTerm(expression: o.sortOrder),
            (o) => OrderingTerm(expression: o.label),
          ]))
        .watch();
  }

  /// Cree un point de vente. Sans `code`, il se deduit du libelle (« Boite
  /// de nuit » -> `BOITE_DE_NUIT`), rendu unique ; sans `sortOrder`, il se
  /// range apres les autres.
  ///
  /// `id` fixe un identifiant connu d'avance (les donnees de test) : le
  /// serveur reconnait alors un renvoi au lieu de refuser un code deja pris.
  Future<OutletRow> create({
    String? id,
    String? code,
    required String label,
    String? opensAt,
    String? closesAt,
    bool allowsRoomCharge = true,
    int? sortOrder,
    OutletKind kind = OutletKind.OUTLET,
  }) async {
    final ident = id ?? newId();
    final choisi = (code == null || code.trim().isEmpty)
        ? await codeLibre(label)
        : code;
    final ordre = sortOrder ?? await _ordreSuivant();
    final propre = await _verifier(
      code: choisi,
      label: label,
      opensAt: opensAt,
      closesAt: closesAt,
    );
    final now = DateTime.now().toUtc();

    return writeAndEnqueue(
      table: 'outlets',
      id: ident,
      operation: SyncOp.INSERT,
      payload: {
        'id': ident,
        'code': propre,
        'label': label.trim(),
        'opens_at': opensAt,
        'closes_at': closesAt,
        'allows_room_charge': allowsRoomCharge,
        'sort_order': ordre,
        'kind': kind.name,
      },
      action: () async {
        await db
            .into(db.outlets)
            .insert(
              OutletsCompanion.insert(
                id: ident,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                code: propre,
                label: label.trim(),
                opensAt: Value(opensAt),
                closesAt: Value(closesAt),
                allowsRoomCharge: Value(allowsRoomCharge),
                sortOrder: Value(ordre),
                kind: Value(kind),
                syncState: const Value(SyncState.pending),
              ),
            );
        return _byId(ident);
      },
    );
  }

  /// Modifie un point de vente ; `isActive: false` le desactive.
  ///
  /// L'entree de file porte l'etat complet de l'ecran, horaires vides
  /// compris : un horaire retire doit l'etre aussi sur le serveur.
  Future<OutletRow> update({
    required String id,
    required String code,
    required String label,
    String? opensAt,
    String? closesAt,
    required bool allowsRoomCharge,
    required int sortOrder,
    required bool isActive,
  }) async {
    // Le Restaurant par defaut : ni desactive, ni recode -- le serveur les
    // refuse (409), et un refus par la file la bloquerait.
    final actuel = await _byId(id);
    if (actuel.code == defaultOutletCode) {
      if (!isActive) {
        throw StateError(
          'Le point de vente par défaut ne peut pas être désactivé.',
        );
      }
      if (code.trim() != defaultOutletCode) {
        throw StateError(
          'Le code du point de vente par défaut ne peut pas être modifié.',
        );
      }
    }
    final propre = await _verifier(
      code: code,
      label: label,
      opensAt: opensAt,
      closesAt: closesAt,
      sauf: id,
    );
    final now = DateTime.now().toUtc();

    return writeAndEnqueue(
      table: 'outlets',
      id: id,
      operation: SyncOp.UPDATE,
      payload: {
        'id': id,
        'code': propre,
        'label': label.trim(),
        'opens_at': opensAt,
        'closes_at': closesAt,
        'allows_room_charge': allowsRoomCharge,
        'sort_order': sortOrder,
        'is_active': isActive,
      },
      action: () async {
        await (db.update(db.outlets)..where((o) => o.id.equals(id))).write(
          OutletsCompanion(
            code: Value(propre),
            label: Value(label.trim()),
            opensAt: Value(opensAt),
            closesAt: Value(closesAt),
            allowsRoomCharge: Value(allowsRoomCharge),
            sortOrder: Value(sortOrder),
            isActive: Value(isActive),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
        return _byId(id);
      },
    );
  }

  /// Refuse ici ce que le serveur refuserait : un refus arrive par la file
  /// la bloquerait, avec tout ce qui attend derriere.
  ///
  /// Renvoie le code nettoye.
  Future<String> _verifier({
    required String code,
    required String label,
    String? opensAt,
    String? closesAt,
    String? sauf,
  }) async {
    final propre = code.trim();
    if (propre.isEmpty || propre.length > 32) {
      throw StateError('Le code est obligatoire (32 caractères au plus).');
    }
    if (label.trim().isEmpty || label.trim().length > 80) {
      throw StateError('Le libellé est obligatoire (80 caractères au plus).');
    }
    for (final h in [opensAt, closesAt]) {
      if (h != null && !heureValide(h)) {
        throw StateError('Horaire invalide : « $h ». Format attendu : 08:30.');
      }
    }
    final pris =
        await (db.select(db.outlets)..where(
              (o) =>
                  o.code.equals(propre) &
                  (sauf == null
                      ? const Constant(true)
                      : o.id.equals(sauf).not()),
            ))
            .get();
    if (pris.isNotEmpty) {
      throw StateError('Le code « $propre » est déjà utilisé.');
    }
    return propre;
  }

  /// Range les points de vente dans l'ordre donne (glisser-deposer). Seuls
  /// ceux dont la position change sont modifies, et donc renvoyes.
  Future<void> reorder(List<String> ids) async {
    for (var i = 0; i < ids.length; i++) {
      final o = await _byId(ids[i]);
      if (o.sortOrder == i) continue;
      await update(
        id: o.id,
        code: o.code,
        label: o.label,
        opensAt: o.opensAt,
        closesAt: o.closesAt,
        allowsRoomCharge: o.allowsRoomCharge,
        sortOrder: i,
        isActive: o.isActive,
      );
    }
  }

  /// Un code libre, deduit du libelle : `BAR`, puis `BAR_2` s'il est pris.
  Future<String> codeLibre(String label) async {
    final base = codeDepuisLibelle(label);
    final pris = {for (final o in await db.select(db.outlets).get()) o.code};
    if (!pris.contains(base)) return base;
    for (var n = 2; ; n++) {
      final suffixe = '_$n';
      final candidat =
          '${base.substring(0, base.length.clamp(0, 32 - suffixe.length))}$suffixe';
      if (!pris.contains(candidat)) return candidat;
    }
  }

  Future<int> _ordreSuivant() async {
    final r = await db
        .customSelect('SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM outlets')
        .getSingle();
    return r.read<int>('n');
  }

  Future<OutletRow> _byId(String id) =>
      (db.select(db.outlets)..where((o) => o.id.equals(id))).getSingle();
}

/// « Boîte de nuit » -> `BOITE_DE_NUIT` : sans accents, en majuscules,
/// 32 caracteres au plus.
String codeDepuisLibelle(String label) {
  const accents = {
    'À': 'A', 'Â': 'A', 'Ä': 'A', 'Ç': 'C', 'É': 'E', 'È': 'E', 'Ê': 'E',
    'Ë': 'E', 'Î': 'I', 'Ï': 'I', 'Ô': 'O', 'Ö': 'O', 'Ù': 'U', 'Û': 'U',
    'Ü': 'U', 'Œ': 'OE', 'Æ': 'AE',
  };
  final sansAccents = label
      .toUpperCase()
      .split('')
      .map((c) => accents[c] ?? c)
      .join();
  final code = sansAccents
      .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (code.isEmpty) return 'PDV';
  return code.length <= 32 ? code : code.substring(0, 32);
}

/// Le point de vente « Restaurant » que chaque hotel a d'office
/// (`DEFAULT_OUTLET_CODE` cote serveur). La carte s'y rattache.
const defaultOutletCode = 'RESTO';

/// Une heure HH:MM valide, de 00:00 a 23:59.
bool heureValide(String h) {
  final m = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').firstMatch(h);
  return m != null;
}
