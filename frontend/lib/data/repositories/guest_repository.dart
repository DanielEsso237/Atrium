/// Ecritures et lectures du fichier clients (F1.6).
library;

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// Derive un code lisible depuis un UUID deja genere.
///
/// Remplace un comptage (`COUNT(*) + 1`) : deux creations simultanees sur
/// deux tablettes differentes ne peuvent jamais produire le meme UUID, donc
/// jamais le meme code, sans avoir besoin d'interroger la base.
String codeFromId(String id, String prefix) {
  final hex = id.replaceAll('-', '');
  final suffix = hex.substring(hex.length - 8);
  return '$prefix-$suffix'.toUpperCase();
}

/// Un sejour passe, tel qu'affiche dans l'historique d'une fiche client.
class GuestStay {
  const GuestStay({
    required this.reference,
    required this.arrival,
    required this.departure,
    required this.status,
  });

  final String reference;
  final String arrival;
  final String departure;
  final String status;
}

class GuestRepository with OutboxWriter {
  GuestRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  /// Mono-etablissement au demarrage. Le jour ou l'application servira
  /// plusieurs hotels, cette valeur viendra de la session.
  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  /// Les clients, filtres sur une recherche libre.
  ///
  /// La recherche porte sur le nom, le prenom, le code, le telephone et le
  /// courriel : au comptoir, on cherche avec ce que le client donne, qui
  /// n'est presque jamais son numero de fiche.
  Stream<List<GuestRow>> watchGuests({String search = ''}) {
    final q = search.trim().toLowerCase();
    final query = db.select(db.guests)
      ..where((g) => g.deletedAt.isNull() & g.hotelId.equals(hotelId))
      ..orderBy([(g) => OrderingTerm.asc(g.lastName)]);

    if (q.isEmpty) return query.watch();

    return query.watch().map(
      (rows) => rows.where((g) {
        final champs = [
          g.lastName,
          g.firstName,
          g.code,
          g.phone ?? '',
          g.email ?? '',
        ].join(' ').toLowerCase();
        return champs.contains(q);
      }).toList(),
    );
  }

  Future<GuestRow?> byId(String id) =>
      (db.select(db.guests)..where((g) => g.id.equals(id))).getSingleOrNull();

  /// Cree une fiche client et enfile l'ecriture.
  ///
  /// Le code est derive localement de l'UUID deja genere pour la ligne, sans
  /// requete de comptage : acceptable pour une reference interne, mais
  /// **pas** pour un numero de facture. La vraie sequence sans trou vit cote
  /// serveur, dans `number_sequences`.
  Future<GuestRow> create({
    required String firstName,
    required String lastName,
    String? phone,
    String? email,
    String? nationality,
    IdDocumentType? documentType,
    String? documentNumber,
    String? notes,
    String? createdBy,
  }) async {
    final id = newId();
    final now = DateTime.now().toUtc();
    final code = codeFromId(id, 'CLI');

    return writeAndEnqueue(
      table: 'guests',
      id: id,
      operation: SyncOp.INSERT,
      payload: {
        'id': id,
        'hotel_id': hotelId,
        'code': code,
        'first_name': firstName.trim(),
        'last_name': lastName.trim(),
        'phone': phone,
        'email': email,
        'nationality': nationality,
        'id_document_type': documentType?.name,
        'id_document_number': documentNumber,
        'notes': notes,
        'created_at': now.toIso8601String(),
        'created_by': createdBy,
      },
      action: () async {
        await db
            .into(db.guests)
            .insert(
              GuestsCompanion.insert(
                id: id,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                code: code,
                firstName: firstName.trim(),
                lastName: lastName.trim(),
                phone: Value(phone),
                email: Value(email),
                nationality: Value(nationality),
                idDocumentType: Value(documentType),
                idDocumentNumber: Value(documentNumber),
                notes: Value(notes),
                createdBy: Value(createdBy),
                // L'ecriture n'est pas encore remontee : c'est precisement ce
                // que dit `pending`, et c'est ce qu'affiche l'indicateur.
                syncState: const Value(SyncState.pending),
              ),
            );
        return (await byId(id))!;
      },
    );
  }

  /// Les sejours d'un client, du plus recent au plus ancien.
  Future<List<GuestStay>> stays(String guestId) async {
    final rows = await db
        .customSelect(
          '''
      SELECT r.reference, rr.arrival_date, rr.departure_date, rr.status
        FROM reservations r
        JOIN reservation_rooms rr ON rr.reservation_id = r.id
       WHERE r.guest_id = ?1 AND r.deleted_at IS NULL
       ORDER BY rr.arrival_date DESC
       LIMIT 20
      ''',
          variables: [Variable.withString(guestId)],
          readsFrom: {db.reservations, db.reservationRooms},
        )
        .get();

    return rows
        .map(
          (r) => GuestStay(
            reference: r.read<String>('reference'),
            arrival: r.read<String>('arrival_date'),
            departure: r.read<String>('departure_date'),
            status: r.read<String>('status'),
          ),
        )
        .toList();
  }
}