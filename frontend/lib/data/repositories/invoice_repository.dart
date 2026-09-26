/// Editer la facture d'une ardoise (cahier des charges, F1.4).
///
/// « La facture n'est qu'un gel du folio » : elle recopie les lignes telles
/// qu'elles sont a cet instant, et ne bouge plus ensuite. Modifier une
/// consommation apres coup ne doit pas changer un document deja remis au
/// client.
///
/// **Le numero est le point delicat.** Un numero de facture est une donnee
/// legale : il doit etre unique, continu, et attribue par une seule autorite.
/// Une tablette hors ligne ne peut pas le savoir -- deux tablettes qui
/// numeroteraient chacune de leur cote produiraient des doublons sur des
/// documents comptables.
///
/// D'ou les deux colonnes du modele. Hors ligne, la tablette pose un
/// **numero provisoire** derive de l'identifiant, donc unique sans rien
/// demander a personne, et marque la facture `isProvisional`. A la remontee,
/// le serveur attribue le numero legal definitif et la tablette le recopie :
/// voir `OutboxSender`, qui applique la reponse.
library;

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'guest_repository.dart' show codeFromId;
import 'outbox.dart';

/// Une facture telle qu'affichee, avec ses lignes.
class InvoiceView {
  const InvoiceView({required this.invoice, required this.lines});

  final InvoiceRow invoice;
  final List<InvoiceLineRow> lines;

  /// Le numero a montrer : le legal s'il existe, le provisoire sinon.
  String get displayNumber =>
      invoice.number ?? invoice.provisionalNumber ?? invoice.id;

  /// Le numero n'est pas encore definitif.
  ///
  /// A dire au client : une facture provisoire n'a pas de valeur comptable
  /// tant qu'elle n'est pas remontee.
  bool get provisional => invoice.isProvisional;
}

class InvoiceRepository with OutboxWriter {
  InvoiceRepository(this.db);

  @override
  final AtriumDatabase db;

  static const hotelId = '01920000-0000-7000-8000-000000000001';

  /// La facture d'une ardoise, si elle a ete editee.
  Stream<InvoiceView?> watchForFolio(String folioId) {
    return (db.select(db.invoices)
          ..where(
            (i) =>
                i.folioId.equals(folioId) &
                i.status.equalsValue(InvoiceStatus.CANCELLED).not() &
                i.deletedAt.isNull(),
          )
          ..limit(1))
        .watchSingleOrNull()
        .asyncMap((facture) async {
          if (facture == null) return null;
          final lignes =
              await (db.select(db.invoiceLines)
                    ..where((l) => l.invoiceId.equals(facture.id))
                    ..orderBy([(l) => OrderingTerm(expression: l.sortOrder)]))
                  .get();
          return InvoiceView(invoice: facture, lines: lignes);
        });
  }

  /// Gele l'ardoise en une facture.
  ///
  /// Idempotent sur l'ardoise : une ardoise n'a qu'une facture. Rappuyer sur
  /// le bouton rend celle qui existe plutot que d'en emettre une seconde --
  /// deux documents comptables pour les memes prestations serait une faute,
  /// pas une simple duplication. Le serveur applique exactement la meme regle.
  ///
  /// Leve une [StateError] dont le message est fait pour etre montre tel quel.
  Future<String> issue(String folioId, {String? by}) async {
    final existante =
        await (db.select(db.invoices)..where(
              (i) =>
                  i.folioId.equals(folioId) &
                  i.status.equalsValue(InvoiceStatus.CANCELLED).not() &
                  i.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    if (existante != null) return existante.id;

    final lignes = await (db.select(db.folioItems)..where(
          (i) => i.folioId.equals(folioId) & i.deletedAt.isNull(),
        ))
        .get();
    if (lignes.isEmpty) {
      throw StateError(
        'Cette ardoise n\'a aucune consommation : il n\'y a rien a facturer.',
      );
    }

    final folio = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(folioId))).getSingleOrNull();
    if (folio == null) throw StateError('Ardoise introuvable.');

    final id = newId();
    final now = DateTime.now().toUtc();

    final taxTotal = lignes.fold<int>(0, (s, l) => s + l.taxAmount);
    final total = lignes.fold<int>(0, (s, l) => s + l.amount);

    await db.transaction(() async {
      await db
          .into(db.invoices)
          .insert(
            InvoicesCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              // Derive de l'identifiant, donc unique sans rien demander a
              // personne : deux tablettes hors ligne ne peuvent pas tomber
              // sur le meme.
              provisionalNumber: Value(codeFromId(id, 'PROV')),
              isProvisional: const Value(true),
              folioId: folioId,
              guestId: Value(folio.guestId),
              status: const Value(InvoiceStatus.ISSUED),
              issuedAt: Value(now),
              subtotal: Value(total - taxTotal),
              taxTotal: Value(taxTotal),
              total: Value(total),
              createdBy: Value(by),
              syncState: const Value(SyncState.pending),
            ),
          );

      for (var i = 0; i < lignes.length; i++) {
        final l = lignes[i];
        await db
            .into(db.invoiceLines)
            .insert(
              InvoiceLinesCompanion.insert(
                id: newId(),
                createdAt: now,
                updatedAt: now,
                invoiceId: id,
                folioItemId: Value(l.id),
                label: l.label,
                quantity: Value(l.quantity),
                unitPrice: Value(l.unitPrice),
                taxRate: Value(l.taxRate),
                taxAmount: Value(l.taxAmount),
                amount: Value(l.amount),
                sortOrder: Value(i),
                syncState: const Value(SyncState.pending),
              ),
            );
      }

      // Seule l'en-tete part dans la file : le serveur recopie les lignes
      // depuis le folio lui-meme, il n'a pas besoin des notres. Les envoyer
      // risquerait de les faire diverger de ce qu'il calcule.
      await enqueue(
        table: 'invoices',
        id: id,
        operation: SyncOp.INSERT,
        payload: {'id': id, 'folio_id': folioId},
      );
    });

    return id;
  }

  /// Recopie le numero legal attribue par le serveur.
  ///
  /// Appele par le moteur de synchronisation avec la reponse du serveur. Tant
  /// que ce n'est pas fait, la facture porte son numero provisoire et le dit.
  Future<void> applyServerNumber(
    String invoiceId,
    Map<String, dynamic> reponse,
  ) async {
    final numero = reponse['number'] as String?;
    if (numero == null) return;

    await (db.update(db.invoices)..where((i) => i.id.equals(invoiceId))).write(
      InvoicesCompanion(
        number: Value(numero),
        isProvisional: const Value(false),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }
}
