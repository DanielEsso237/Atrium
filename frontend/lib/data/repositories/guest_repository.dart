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
    this.roomNumber,
    this.roomType,
    this.hourly = false,
  });

  final String reference;
  final String arrival;
  final String departure;
  final String status;

  /// Nul tant qu'aucune chambre n'est attribuee : une reservation a venir
  /// n'a souvent que sa categorie.
  final String? roomNumber;
  final String? roomType;

  /// Un sejour en heures : sa `departure` vaut le lendemain parce que le
  /// schema l'exige, elle ne dit rien de la duree.
  final bool hourly;

  int get nights {
    if (hourly) return 0;
    final a = DateTime.tryParse(arrival);
    final d = DateTime.tryParse(departure);
    if (a == null || d == null) return 0;
    return d.difference(a).inDays;
  }
}

/// Ce que l'hotel sait d'un client au-dela de sa fiche : sa fidelite, ou il
/// dort ce soir, ce qu'il doit encore.
class GuestStats {
  const GuestStats({
    this.stays = 0,
    this.nights = 0,
    this.lastArrival,
    this.currentRoom,
    this.nextArrival,
    this.openBalance = 0,
  });

  /// Sejours commences : en cours ou termines. Une reservation annulee ou
  /// jamais honoree n'est pas un passage.
  final int stays;
  final int nights;

  /// Dates seules (`AAAA-MM-JJ`) : jamais de fuseau dessus.
  final String? lastArrival;
  final String? currentRoom;
  final String? nextArrival;

  /// Reste du sur ses ardoises ouvertes, chambre et comptoirs, en francs CFA.
  final int openBalance;

  static const vide = GuestStats();
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

  /// Une fiche, suivie : modifiee depuis la page, elle s'y redessine seule.
  Stream<GuestRow?> watchGuest(String id) =>
      (db.select(db.guests)..where((g) => g.id.equals(id)))
          .watchSingleOrNull();

  /// Les chiffres de chaque client, en une requete pour tout le fichier.
  ///
  /// [businessDate] borne la prochaine arrivee : une reservation confirmee
  /// d'avant-hier, pas encore passee en non-presentation, n'est pas « a
  /// venir ». Une date d'exploitation, jamais le calendrier.
  Stream<Map<String, GuestStats>> watchGuestStats({
    required String businessDate,
  }) {
    return db
        .customSelect(
          '''
      WITH s AS (
        SELECT r.guest_id AS guest_id,
               SUM(CASE WHEN rr.status IN ('CHECKED_IN', 'CHECKED_OUT')
                        THEN 1 ELSE 0 END) AS sejours,
               SUM(CASE WHEN rr.status IN ('CHECKED_IN', 'CHECKED_OUT')
                         AND COALESCE(rr.stay_unit, 'NIGHTS') = 'NIGHTS'
                        THEN CAST(julianday(rr.departure_date)
                                  - julianday(rr.arrival_date) AS INTEGER)
                        ELSE 0 END) AS nuits,
               MAX(CASE WHEN rr.status IN ('CHECKED_IN', 'CHECKED_OUT')
                        THEN rr.arrival_date END) AS dernier,
               MAX(CASE WHEN rr.status = 'CHECKED_IN'
                        THEN ro.number END) AS chambre,
               MIN(CASE WHEN rr.status IN ('PENDING', 'CONFIRMED')
                         AND rr.arrival_date >= ?2
                        THEN rr.arrival_date END) AS prochaine
          FROM reservations r
          JOIN reservation_rooms rr
            ON rr.reservation_id = r.id AND rr.deleted_at IS NULL
          LEFT JOIN rooms ro ON ro.id = rr.room_id
         WHERE r.deleted_at IS NULL
         GROUP BY r.guest_id
      ),
      f AS (
        SELECT guest_id, SUM(balance) AS solde
          FROM folios
         WHERE deleted_at IS NULL AND status = 'OPEN' AND guest_id IS NOT NULL
         GROUP BY guest_id
      )
      SELECT g.id AS guest_id,
             COALESCE(s.sejours, 0) AS sejours,
             COALESCE(s.nuits, 0) AS nuits,
             s.dernier, s.chambre, s.prochaine,
             COALESCE(f.solde, 0) AS solde
        FROM guests g
        LEFT JOIN s ON s.guest_id = g.id
        LEFT JOIN f ON f.guest_id = g.id
       WHERE g.deleted_at IS NULL AND g.hotel_id = ?1
      ''',
          variables: [
            Variable.withString(hotelId),
            Variable.withString(businessDate),
          ],
          readsFrom: {
            db.guests,
            db.reservations,
            db.reservationRooms,
            db.rooms,
            db.folios,
          },
        )
        .watch()
        .map(
          (rows) => {
            for (final r in rows)
              r.read<String>('guest_id'): GuestStats(
                stays: r.read<int>('sejours'),
                nights: r.read<int>('nuits'),
                lastArrival: r.readNullable<String>('dernier'),
                currentRoom: r.readNullable<String>('chambre'),
                nextArrival: r.readNullable<String>('prochaine'),
                openBalance: r.read<int>('solde'),
              ),
          },
        );
  }

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

  /// Modifie la fiche d'un client.
  ///
  /// Aucune des regles de creation ici (`guest_rules.dart`) : un client
  /// ancien, sans telephone ni piece, doit pouvoir etre corrige tel quel.
  /// Seuls nom et prenom restent exiges -- le serveur les refuse vides.
  ///
  /// L'entree de file porte les six champs de l'ecran, **vides compris** : un
  /// telephone efface doit s'effacer aussi sur le serveur. Ce sont exactement
  /// ceux que la descente rapatrie ; tout le reste de la fiche (adresse, date
  /// de naissance, plafond) n'est pas envoye, et le `PATCH` n'y touche pas.
  Future<GuestRow> update({
    required String id,
    required String firstName,
    required String lastName,
    String? phone,
    String? email,
    String? nationality,
    IdDocumentType? documentType,
    String? documentNumber,
    String? updatedBy,
  }) {
    if (firstName.trim().isEmpty || lastName.trim().isEmpty) {
      throw StateError('Le nom et le prenom sont obligatoires.');
    }
    final now = DateTime.now().toUtc();

    return writeAndEnqueue(
      table: 'guests',
      id: id,
      operation: SyncOp.UPDATE,
      payload: {
        'id': id,
        'first_name': firstName.trim(),
        'last_name': lastName.trim(),
        'phone': phone,
        'email': email,
        'nationality': nationality,
        'id_document_type': documentType?.name,
        'id_document_number': documentNumber,
        'updated_by': updatedBy,
      },
      action: () async {
        await (db.update(db.guests)..where((g) => g.id.equals(id))).write(
          GuestsCompanion(
            firstName: Value(firstName.trim()),
            lastName: Value(lastName.trim()),
            phone: Value(phone),
            email: Value(email),
            nationality: Value(nationality),
            idDocumentType: Value(documentType),
            idDocumentNumber: Value(documentNumber),
            updatedAt: Value(now),
            updatedBy: Value(updatedBy),
            syncState: const Value(SyncState.pending),
          ),
        );
        return (await byId(id))!;
      },
    );
  }

  /// Fixe le plafond de consommation a credit d'un client.
  ///
  /// C'est l'administration qui le fixe (decision du 29 septembre), et le
  /// serveur le refuse a tout autre agent. `0` veut dire **pas de limite**.
  /// La verification du seuil, elle, lit ce champ avant chaque consommation
  /// (`FolioRepository._verifierSeuil`).
  Future<GuestRow> setCreditLimit({
    required String id,
    required int creditLimit,
    String? updatedBy,
  }) async {
    if (creditLimit < 0) {
      throw StateError('Le plafond ne peut pas être négatif.');
    }
    final client = (await byId(id))!;
    final now = DateTime.now().toUtc();

    return writeAndEnqueue(
      table: 'guests',
      id: id,
      operation: SyncOp.UPDATE,
      // `action` : l'envoyeur n'envoie que le plafond, et pas les six
      // champs de la fiche -- ce n'est pas une modification de fiche.
      payload: {
        'id': id,
        'action': 'CREDIT_LIMIT',
        'first_name': client.firstName,
        'last_name': client.lastName,
        'credit_limit': creditLimit,
        'updated_by': updatedBy,
      },
      action: () async {
        await (db.update(db.guests)..where((g) => g.id.equals(id))).write(
          GuestsCompanion(
            creditLimit: Value(creditLimit),
            updatedAt: Value(now),
            updatedBy: Value(updatedBy),
            syncState: const Value(SyncState.pending),
          ),
        );
        return (await byId(id))!;
      },
    );
  }

  /// Les sejours d'un client, du plus recent au plus ancien.
  ///
  /// Suivis et non lus une fois : la fiche reste ouverte au comptoir pendant
  /// qu'on enregistre l'arrivee, elle doit montrer le sejour qui commence.
  Stream<List<GuestStay>> watchStays(String guestId) {
    return db
        .customSelect(
          '''
      SELECT r.reference, rr.arrival_date, rr.departure_date, rr.status,
             rr.stay_unit, ro.number AS room_number, rt.label AS room_type
        FROM reservations r
        JOIN reservation_rooms rr
          ON rr.reservation_id = r.id AND rr.deleted_at IS NULL
        LEFT JOIN rooms ro ON ro.id = rr.room_id
        LEFT JOIN room_types rt ON rt.id = rr.room_type_id
       WHERE r.guest_id = ?1 AND r.deleted_at IS NULL
       ORDER BY rr.arrival_date DESC
       LIMIT 50
      ''',
          variables: [Variable.withString(guestId)],
          readsFrom: {
            db.reservations,
            db.reservationRooms,
            db.rooms,
            db.roomTypes,
          },
        )
        .watch()
        .map(
          (rows) => [
            for (final r in rows)
              GuestStay(
                reference: r.read<String>('reference'),
                arrival: r.read<String>('arrival_date'),
                departure: r.read<String>('departure_date'),
                status: r.read<String>('status'),
                roomNumber: r.readNullable<String>('room_number'),
                roomType: r.readNullable<String>('room_type'),
                hourly: r.readNullable<String>('stay_unit') == 'HOURS',
              ),
          ],
        );
  }
}
