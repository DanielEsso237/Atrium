/// Les depenses de l'hotel hors stock : salaires, electricite, eau, loyer...
///
/// Elles font du benefice le vrai benefice (voir `report_queries.dart`). Une
/// depense se saisit hors ligne comme le reste, et remonte par la file
/// (`POST /expenses`, `PATCH /expenses/{id}`, `POST /expenses/{id}/void`).
///
/// **Les refus du serveur sont recopies ici, a la lettre**, avant toute
/// ecriture : un montant nul ou demesure, un libelle vide, une date future,
/// une depense annulee qu'on corrigerait. Un refus qui n'arriverait que par
/// la file la bloquerait, avec tout ce qui attend derriere.
library;

import 'package:drift/drift.dart';

import '../../core/business_day.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// Au-dela, c'est une faute de frappe (un zero de trop). La meme borne que
/// `MONTANT_MAX` du serveur (`schemas/expenses.py`).
const montantMaxDepense = 1000000000;

/// Le nom d'une rubrique, tel qu'on le lit a l'ecran et dans les exports.
String libelleRubrique(ExpenseCategory c) => switch (c) {
  ExpenseCategory.SALARIES => 'Salaires',
  ExpenseCategory.ELECTRICITY => 'Électricité',
  ExpenseCategory.WATER => 'Eau',
  ExpenseCategory.RENT => 'Loyer',
  ExpenseCategory.FUEL => 'Carburant',
  ExpenseCategory.REPAIRS => 'Réparations',
  ExpenseCategory.TELECOM => 'Internet et téléphone',
  ExpenseCategory.TAXES => 'Impôts et taxes',
  ExpenseCategory.MARKETING => 'Publicité',
  ExpenseCategory.BANK_FEES => 'Frais bancaires',
  ExpenseCategory.OTHER => 'Autres dépenses',
};

/// Ce qu'on saisit d'une depense, a la creation comme a la correction.
class SaisieDepense {
  const SaisieDepense({
    required this.businessDate,
    required this.category,
    required this.label,
    required this.amount,
    this.method,
    this.supplier,
    this.reference,
    this.notes,
  });

  /// Date seule, AAAA-MM-JJ.
  final String businessDate;
  final ExpenseCategory category;
  final String label;
  final int amount;
  final PaymentMethod? method;
  final String? supplier;
  final String? reference;
  final String? notes;

  /// Le corps envoye au serveur : le meme a la creation et a la correction,
  /// pour qu'un renvoi soit reconnu.
  Map<String, Object?> toJson() => {
    'business_date': businessDate,
    'category': category.name,
    'label': label.trim(),
    'amount': amount,
    'method': method?.name,
    'supplier': _vide(supplier),
    'reference': _vide(reference),
    'notes': _vide(notes),
  };

  static String? _vide(String? v) {
    final t = v?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}

class ExpenseRepository with OutboxWriter {
  ExpenseRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  /// Les depenses d'une periode, la plus recente d'abord ; les annulees
  /// comprises, pour qu'on voie ce qui a bouge.
  Stream<List<ExpenseRow>> watch({required String du, required String au}) {
    return (db.select(db.expenses)
          ..where(
            (e) =>
                e.deletedAt.isNull() &
                e.businessDate.isBiggerOrEqualValue(du) &
                e.businessDate.isSmallerOrEqualValue(au),
          )
          ..orderBy([
            (e) => OrderingTerm.desc(e.businessDate),
            (e) => OrderingTerm.desc(e.createdAt),
          ]))
        .watch();
  }

  /// Les refus du serveur, avant d'enfiler. `maintenant` : pour les tests.
  void verifier(SaisieDepense s, {DateTime? maintenant}) {
    final libelle = s.label.trim();
    if (libelle.isEmpty) {
      throw StateError('Donnez un libellé à la dépense.');
    }
    if (libelle.length > 160) {
      throw StateError('Le libellé est trop long (160 caractères au plus).');
    }
    if (s.amount <= 0) {
      throw StateError('Le montant doit être supérieur à zéro.');
    }
    if (s.amount > montantMaxDepense) {
      throw StateError(
        'Ce montant est démesuré : vérifiez qu’il n’y a pas un zéro de trop.',
      );
    }
    // Comparaison de textes AAAA-MM-JJ : l'ordre alphabetique est celui des
    // dates. Jamais `DateTime.now()` comme date d'exploitation.
    if (s.businessDate.compareTo(businessDateNow(at: maintenant)) > 0) {
      throw StateError('Une dépense ne peut pas être datée du futur.');
    }
    for (final (valeur, max, nom) in [
      (s.supplier, 120, 'Le fournisseur'),
      (s.reference, 80, 'La référence'),
      (s.notes, 255, 'La note'),
    ]) {
      if ((valeur?.trim().length ?? 0) > max) {
        throw StateError('$nom est trop long ($max caractères au plus).');
      }
    }
  }

  Future<String> create(SaisieDepense s, {String? by}) async {
    verifier(s);
    final id = newId();
    final now = DateTime.now().toUtc();
    final corps = s.toJson();
    await writeAndEnqueue(
      table: 'expenses',
      id: id,
      operation: SyncOp.INSERT,
      payload: {'id': id, ...corps},
      action: () async {
        await db
            .into(db.expenses)
            .insert(
              ExpensesCompanion.insert(
                id: id,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                businessDate: s.businessDate,
                category: s.category,
                label: corps['label']! as String,
                amount: s.amount,
                method: Value(s.method),
                supplier: Value(corps['supplier'] as String?),
                reference: Value(corps['reference'] as String?),
                notes: Value(corps['notes'] as String?),
                recordedBy: Value(by),
                createdBy: Value(by),
                syncState: const Value(SyncState.pending),
              ),
            );
      },
    );
    return id;
  }

  Future<void> update(String id, SaisieDepense s, {String? by}) async {
    verifier(s);
    final avant = await _depense(id);
    if (avant.isVoid) {
      throw StateError('Cette dépense est annulée : elle ne se corrige plus.');
    }
    final corps = s.toJson();
    await writeAndEnqueue(
      table: 'expenses',
      id: id,
      operation: SyncOp.UPDATE,
      payload: {'id': id, ...corps},
      action: () async {
        await (db.update(db.expenses)..where((e) => e.id.equals(id))).write(
          ExpensesCompanion(
            businessDate: Value(s.businessDate),
            category: Value(s.category),
            label: Value(corps['label']! as String),
            amount: Value(s.amount),
            method: Value(s.method),
            supplier: Value(corps['supplier'] as String?),
            reference: Value(corps['reference'] as String?),
            notes: Value(corps['notes'] as String?),
            updatedAt: Value(DateTime.now().toUtc()),
            updatedBy: Value(by),
            syncState: const Value(SyncState.pending),
          ),
        );
      },
    );
  }

  /// Annule une depense saisie par erreur. Elle reste, avec son motif.
  Future<void> annuler(String id, {required String motif, String? by}) async {
    final raison = motif.trim();
    if (raison.isEmpty) {
      throw StateError('Dites pourquoi la dépense est annulée.');
    }
    if (raison.length > 255) {
      throw StateError('Le motif est trop long (255 caractères au plus).');
    }
    final avant = await _depense(id);
    if (avant.isVoid) return;
    await writeAndEnqueue(
      table: 'expenses',
      id: id,
      operation: SyncOp.UPDATE,
      payload: {'id': id, 'action': 'VOID', 'reason': raison},
      action: () async {
        await (db.update(db.expenses)..where((e) => e.id.equals(id))).write(
          ExpensesCompanion(
            isVoid: const Value(true),
            voidReason: Value(raison),
            voidedBy: Value(by),
            updatedAt: Value(DateTime.now().toUtc()),
            updatedBy: Value(by),
            syncState: const Value(SyncState.pending),
          ),
        );
      },
    );
  }

  Future<ExpenseRow> _depense(String id) async {
    final d = await (db.select(
      db.expenses,
    )..where((e) => e.id.equals(id) & e.deletedAt.isNull())).getSingleOrNull();
    if (d == null) throw StateError('Dépense introuvable.');
    return d;
  }
}
