/// Ce qu'un refus retient dans la file d'envoi (correction 7).
///
/// Un refus du serveur arretait toute la file : l'encaissement en double
/// d'une chambre retenait le menage, les stocks et les autres dossiers de la
/// tablette jusqu'a ce qu'un responsable tranche. Chaque entree porte
/// maintenant ses **cles de regroupement** (`outbox_entries.group_keys`),
/// posees a l'ecriture : sur un refus, seules les entrees qui partagent une
/// cle avec elle attendent -- et, de proche en proche, celles qui partagent
/// une cle avec une entree qui attend. Le reste part.
///
/// Trois sortes de cles, separees par une espace :
///
/// - `dossier:R` -- l'entree **appartient** au groupe : elle attend s'il
///   attend, et le fait attendre si elle attend ;
/// - `>caisse:U` -- l'entree **nourrit** le groupe sans en dependre : un
///   encaissement refuse retient la cloture de la caisse (elle compterait un
///   attendu faux), mais un encaissement refuse n'en retient pas un autre ;
/// - `<pdv:O` -- l'entree **suppose** le groupe sans le nourrir : une ardoise
///   attend le point de vente qu'on vient de creer, mais une ardoise refusee
///   ne retient pas celles des autres clients du bar.
///
/// **Sans cle, l'ancienne regle** : une entree dont on ne sait rien
/// (`group_keys` vide -- une table nouvelle, une entree d'avant le schema 20)
/// attend des que quoi que ce soit attend avant elle, et retient tout ce qui
/// la suit. Le doute bloque, il ne laisse jamais passer.
library;

import '../local/database.dart';

/// Les cles d'une ecriture, ou `null` quand on ne sait pas les dire.
///
/// A appeler dans la transaction qui ecrit la ligne : l'ardoise d'une
/// consommation, le sejour d'une ardoise se lisent en base.
Future<String?> clesDeGroupe(
  AtriumDatabase db, {
  required String table,
  required String id,
  required Map<String, Object?> payload,
  required String? auteur,
}) async {
  final cles = await _cles(db, table, id, payload, auteur);
  if (cles == null || cles.contains(null)) return null;
  return cles.cast<String>().join(' ');
}

Future<List<String?>?> _cles(
  AtriumDatabase db,
  String table,
  String id,
  Map<String, Object?> p,
  String? auteur,
) async {
  String? texte(String cle) => p[cle] is String ? p[cle] as String : null;
  final caisse = auteur == null ? null : '>caisse:$auteur';

  switch (table) {
    case 'guests':
      return ['client:$id'];
    case 'reservations':
      return [
        'dossier:$id',
        if (texte('guest_id') case final client?) 'client:$client',
      ];
    case 'reservation_rooms':
      final ligne = await (db.select(
        db.reservationRooms,
      )..where((r) => r.id.equals(id))).getSingleOrNull();
      if (ligne == null) return null;
      // La chambre aussi : un depart refuse retient le menage de la chambre
      // et l'arrivee suivante qu'on y ferait.
      final chambre = texte('room_id') ?? ligne.roomId;
      return [
        'dossier:${ligne.reservationId}',
        if (chambre != null) 'chambre:$chambre',
      ];
    case 'folios':
      return [
        await _dossierDe(db, id),
        if (texte('room_folio_id') case final chambre?)
          await _dossierDe(db, chambre),
        if (texte('outlet_id') case final pdv?) '<pdv:$pdv',
        if (p['payment'] != null) ?caisse,
      ];
    case 'folio_items' || 'invoices':
      return [await _dossierDe(db, texte('folio_id'))];
    case 'payments':
      final encaisse = texte('received_by') ?? auteur;
      return [
        await _dossierDe(db, texte('folio_id')),
        if (encaisse != null) '>caisse:$encaisse',
      ];
    case 'orders':
      final ardoise = texte('folio_id');
      return [
        ardoise == null ? 'commande:$id' : await _dossierDe(db, ardoise),
        if (texte('outlet_id') case final pdv?) '<pdv:$pdv',
      ];
    case 'cash_sessions':
      final session = await (db.select(
        db.cashSessions,
      )..where((s) => s.id.equals(id))).getSingleOrNull();
      return session == null ? null : ['caisse:${session.userId}'];
    case 'housekeeping_tasks':
      final chambre =
          texte('room_id') ??
          (await (db.select(
            db.housekeepingTasks,
          )..where((t) => t.id.equals(id))).getSingleOrNull())?.roomId;
      return chambre == null ? null : ['chambre:$chambre'];
    case 'maintenance_tickets':
      final chambre =
          texte('room_id') ??
          (await (db.select(
            db.maintenanceTickets,
          )..where((t) => t.id.equals(id))).getSingleOrNull())?.roomId;
      return [chambre == null ? 'ticket:$id' : 'chambre:$chambre'];
    case 'stock_movements':
      final produit = texte('product_id');
      return produit == null ? null : ['produit:$produit'];
    case 'inventories':
      return ['inventaire:$id'];
    case 'outlets':
      return ['pdv:$id'];
    case 'expenses':
      return ['depense:$id'];
    case 'users':
      return ['agent:$id'];
    case 'roles':
      return ['role:$id'];
    case 'settings':
      return ['reglage:$id'];
    case 'hotels':
      return ['hotel:$id'];
  }
  return null;
}

/// Le dossier d'une ardoise : la reservation de son sejour, ou l'ardoise
/// elle-meme au comptoir. `null` si elle est introuvable.
Future<String?> _dossierDe(AtriumDatabase db, String? ardoiseId) async {
  if (ardoiseId == null) return null;
  final ardoise = await (db.select(
    db.folios,
  )..where((f) => f.id.equals(ardoiseId))).getSingleOrNull();
  if (ardoise == null) return null;
  final sejour = ardoise.reservationRoomId;
  if (sejour == null) return 'ardoise:$ardoiseId';
  final ligne = await (db.select(
    db.reservationRooms,
  )..where((r) => r.id.equals(sejour))).getSingleOrNull();
  return ligne == null ? null : 'dossier:${ligne.reservationId}';
}

/// Ce qui attend, au fil d'un passage de la file.
///
/// Les entrees se presentent par identifiant croissant ; une entree retenue
/// (refusee, ou qui attend elle-meme) l'annonce avec [retenir].
class Retenue {
  final _groupes = <String>{};
  var _toutAttend = false;

  bool get vide => !_toutAttend && _groupes.isEmpty;

  /// L'entree de cles [cles] doit-elle attendre ?
  bool retient(String? cles) {
    if (_toutAttend) return true;
    if (cles == null) return _groupes.isNotEmpty;
    for (final c in cles.split(' ')) {
      if (c.startsWith('>')) continue;
      if (_groupes.contains(c.startsWith('<') ? c.substring(1) : c)) {
        return true;
      }
    }
    return false;
  }

  /// L'entree de cles [cles] attend : ce qui partage ses groupes aussi.
  void retenir(String? cles) {
    if (cles == null) {
      _toutAttend = true;
      return;
    }
    for (final c in cles.split(' ')) {
      if (c.startsWith('<')) continue;
      _groupes.add(c.startsWith('>') ? c.substring(1) : c);
    }
  }
}

/// Combien d'entrees, apres [refusee], attendent a cause d'elle.
///
/// [file] : les entrees en attente ou refusees, par identifiant croissant.
int retenuesDerriere(List<OutboxEntryRow> file, OutboxEntryRow refusee) {
  final retenue = Retenue()..retenir(refusee.groupKeys);
  var n = 0;
  for (final e in file) {
    if (e.id <= refusee.id || !retenue.retient(e.groupKeys)) continue;
    retenue.retenir(e.groupKeys);
    n++;
  }
  return n;
}
