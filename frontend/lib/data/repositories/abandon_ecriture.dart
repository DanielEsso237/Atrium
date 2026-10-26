/// Abandonner une ecriture que le serveur refuse, sur decision d'un
/// responsable (correction 6).
///
/// Une file bloquee se voit d'un autre poste (`signalement_blocages.dart`),
/// mais rien ne la debloquait : seul un encaissement se retirait, et sur la
/// tablette elle-meme. Le responsable decide maintenant de l'ecran Tablettes ;
/// la tablette bloquee applique la decision a son passage suivant.
///
/// **C'est la tablette bloquee qui dit ce qui s'abandonne** : elle seule voit
/// ce qui attend derriere. Elle le dit dans son rapport, et le reverifie au
/// moment d'appliquer -- une saisie a pu arriver entre-temps.
///
/// Deux familles seulement :
///
/// - **la modification d'une ligne que le serveur a deja** (fiche client,
///   point de vente, depense, nom d'une ardoise) : l'entree quitte la file,
///   la ligne n'est plus protegee, et la descente suivante remet la version
///   du serveur ;
/// - **une creation isolee** (encaissement, consommation, depense) : la ligne
///   disparait de la tablette, l'ardoise et le stock se recalculent.
///
/// Le reste ne s'abandonne pas : un sejour, une caisse, un mouvement de stock,
/// une fiche client neuve entrainent d'autres lignes, et les retirer
/// laisserait la tablette et le serveur en desaccord durable. Une ecriture
/// dont une saisie suivante depend non plus : elle la laisserait sans objet,
/// et c'est elle qui bloquerait la file a son tour.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';
import 'folio_repository.dart';

/// Ce que la tablette bloquee dit d'une ecriture refusee.
class Abandonnabilite {
  const Abandonnabilite.possible() : possible = true, note = null;
  const Abandonnabilite.refusee(this.note) : possible = false;

  final bool possible;

  /// Pourquoi elle ne s'abandonne pas, dit au responsable.
  final String? note;
}

enum _Famille {
  /// La modification d'une ligne que le serveur a deja.
  retour,

  /// Une creation dont rien d'autre ne depend.
  creation,
}

_Famille? _famille(OutboxEntryRow e, Map<String, dynamic> p) {
  final action = p['action'];
  return switch ((e.entityTable, e.op)) {
    ('guests', SyncOp.UPDATE) => _Famille.retour,
    ('outlets', SyncOp.UPDATE) => _Famille.retour,
    ('expenses', SyncOp.UPDATE) => _Famille.retour,
    ('folios', _) when action == 'TAB_RENAME' => _Famille.retour,
    ('payments', SyncOp.INSERT) when action == null => _Famille.creation,
    ('folio_items', SyncOp.INSERT) => _Famille.creation,
    ('expenses', SyncOp.INSERT) => _Famille.creation,
    _ => null,
  };
}

const _noteEnchainement =
    'Cette saisie en entraîne d’autres sur la tablette : l’abandonner les '
    'laisserait en désaccord avec le serveur. Elle se corrige sur le serveur.';

Map<String, dynamic> _contenu(OutboxEntryRow e) {
  try {
    final p = jsonDecode(e.payload);
    return p is Map<String, dynamic> ? p : const {};
  } on FormatException {
    return const {};
  }
}

/// [e] peut-elle s'abandonner sans rien laisser sans objet ?
Future<Abandonnabilite> abandonnabilite(
  AtriumDatabase db,
  OutboxEntryRow e,
) async {
  final p = _contenu(e);
  final famille = _famille(e, p);
  if (famille == null) return const Abandonnabilite.refusee(_noteEnchainement);

  final suivantes = await (db.select(db.outboxEntries)
        ..where(
          (o) =>
              o.id.isBiggerThanValue(e.id) &
              o.status.isInValues([OutboxStatus.PENDING, OutboxStatus.FAILED]),
        ))
      .get();
  final n = suivantes.where((s) => _depend(s, e, p, famille)).length;
  if (n == 0) return const Abandonnabilite.possible();
  return Abandonnabilite.refusee(
    n == 1
        ? 'Une saisie suivante en dépend : l’abandonner la laisserait sans '
              'objet.'
        : '$n saisies suivantes en dépendent : l’abandonner les laisserait '
              'sans objet.',
  );
}

/// [suivante] a-t-elle besoin de [e] ?
///
/// Une saisie sur la meme ligne, toujours. Une saisie qui la nomme dans son
/// contenu (l'annulation d'un encaissement, une reservation sur un client),
/// aussi. Et pour l'ardoise, ce qui repose sur son solde : un encaissement
/// suppose les consommations, une cloture suppose les encaissements.
bool _depend(
  OutboxEntryRow suivante,
  OutboxEntryRow e,
  Map<String, dynamic> p,
  _Famille famille,
) {
  if (suivante.entityTable == e.entityTable &&
      suivante.entityId == e.entityId) {
    return true;
  }
  if (famille == _Famille.retour) return false;
  if (suivante.payload.contains('"${e.entityId}"')) return true;

  final ardoise = p['folio_id'];
  if (ardoise is! String || !suivante.payload.contains('"$ardoise"')) {
    return false;
  }
  final action = _contenu(suivante)['action'];
  // Une consommation de plus ne repose sur rien de ce qui la precede ; un
  // encaissement de plus non plus quand c'est un encaissement qu'on retire
  // -- le solde ne fait que remonter.
  if (suivante.entityTable == 'folio_items') return false;
  if (e.entityTable == 'payments' &&
      suivante.entityTable == 'payments' &&
      action == null) {
    return false;
  }
  return true;
}

/// Abandonne l'entree [entreeId] de la file, ou leve une [StateError] si
/// elle ne s'abandonne plus. Tout ou rien, dans une transaction.
Future<void> abandonnerEcriture(AtriumDatabase db, int entreeId) {
  return db.transaction(() async {
    final e = await (db.select(
      db.outboxEntries,
    )..where((o) => o.id.equals(entreeId))).getSingleOrNull();
    if (e == null || e.status == OutboxStatus.ACKED) {
      throw StateError('Cette saisie n’est plus dans la file.');
    }
    final verdict = await abandonnabilite(db, e);
    if (!verdict.possible) throw StateError(verdict.note!);
    final p = _contenu(e);

    await (db.delete(
      db.outboxEntries,
    )..where((o) => o.id.equals(e.id))).go();

    switch (_famille(e, p)!) {
      case _Famille.retour:
        // Plus protegee : la descente suivante remet la version du serveur.
        final table = _tablesRetour[e.entityTable]!(db);
        await db.customUpdate(
          'UPDATE ${table.actualTableName} SET sync_state = ? WHERE id = ?',
          variables: [
            Variable.withString(SyncState.synced.name),
            Variable.withString(e.entityId),
          ],
          updates: {table},
        );
      case _Famille.creation:
        switch (e.entityTable) {
          case 'payments':
            await _retirerEncaissement(db, e.entityId);
          case 'folio_items':
            await _retirerConsommation(db, e.entityId);
          case 'expenses':
            await (db.delete(
              db.expenses,
            )..where((x) => x.id.equals(e.entityId))).go();
        }
    }
  });
}

final _tablesRetour = <String, TableInfo Function(AtriumDatabase)>{
  'guests': (db) => db.guests,
  'outlets': (db) => db.outlets,
  'expenses': (db) => db.expenses,
  'folios': (db) => db.folios,
};

Future<void> _retirerEncaissement(AtriumDatabase db, String id) async {
  final paiement = await (db.select(
    db.payments,
  )..where((p) => p.id.equals(id))).getSingleOrNull();
  await (db.delete(db.payments)..where((p) => p.id.equals(id))).go();
  final ardoise = paiement?.folioId;
  if (ardoise != null) await FolioRepository(db).recalculer(ardoise);
}

/// La consommation disparait, et ce qu'elle avait fait sortir du stock du
/// point de vente y revient.
Future<void> _retirerConsommation(AtriumDatabase db, String id) async {
  final ligne = await (db.select(
    db.folioItems,
  )..where((i) => i.id.equals(id))).getSingleOrNull();
  final sorties =
      await (db.select(db.stockMovements)..where(
            (m) => m.sourceTable.equals('folio_items') & m.sourceId.equals(id),
          ))
          .get();
  for (final m in sorties) {
    await db.customUpdate(
      'UPDATE stock_levels SET quantity = quantity + ? '
      'WHERE product_id = ? AND stock_location_id = ?',
      variables: [
        Variable.withInt(m.quantity),
        Variable.withString(m.productId),
        Variable.withString(m.stockLocationId),
      ],
      updates: {db.stockLevels},
    );
  }
  await (db.delete(db.stockMovements)..where(
        (m) => m.sourceTable.equals('folio_items') & m.sourceId.equals(id),
      ))
      .go();
  await (db.delete(db.folioItems)..where((i) => i.id.equals(id))).go();
  if (ligne != null) await FolioRepository(db).recalculer(ligne.folioId);
}
