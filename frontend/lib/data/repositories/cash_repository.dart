/// La caisse d'un agent (cahier des charges, F1.4).
///
/// Un receptionniste prend son poste, compte son fond de caisse, encaisse
/// pendant son service, puis recompte en partant. L'ecart entre ce qu'il
/// compte et ce que l'application attend est le seul chiffre qui compte : il
/// dit si la journee est saine.
///
/// **Un agent n'a qu'une caisse ouverte a la fois.** C'est la regle qui rend
/// tout le reste possible -- le rattachement des encaissements, le calcul de
/// l'attendu, et le fait qu'un renvoi de la file ne puisse pas ouvrir une
/// seconde caisse. Le serveur applique la meme, avec un index unique partiel.
///
/// L'attendu se calcule **en especes seulement**. Une carte ou un paiement
/// mobile ne passe pas par le tiroir : les compter ferait constater un ecart
/// enorme a chaque fermeture.
///
/// **La reception est la caisse centrale.** La caisse d'un point de vente
/// porte son `outletId` ; la fermer, c'est verser : le montant compte est
/// celui que l'agent declare remettre a la reception, qui confirme ensuite ce
/// qu'elle recoit ([CashRepository.confirmRemittance]). Trois chiffres restent
/// -- l'attendu, le declare, le recu -- et le versement recu entre dans la
/// caisse de celui qui le recoit, comme un encaissement.
library;

import 'package:drift/drift.dart';

import '../../core/business_day.dart';
import '../../core/formats.dart' show formatIsoDate;
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'outbox.dart';

/// L'etat d'une caisse, tel qu'affiche.
class CashView {
  const CashView({
    required this.session,
    required this.expected,
    required this.cashCollected,
  });

  final CashSessionRow session;

  /// Ce que le tiroir devrait contenir : fond de caisse, especes encaissees
  /// et versements recus des points de vente.
  final int expected;

  /// Les especes encaissees pendant le service, sans le fond de caisse.
  final int cashCollected;

  bool get open => session.status == CashSessionStatus.OPEN;

  /// La caisse d'un point de vente : elle se ferme en versant a la reception.
  bool get ofOutlet => session.outletId != null;

  /// Ecart entre le comptage et l'attendu, une fois fermee.
  int? get variance =>
      session.countedAmount == null ? null : session.countedAmount! - expected;
}

/// Ou en est le versement d'un point de vente.
enum RemittanceStatus {
  /// La caisse est encore ouverte : rien n'a ete declare.
  pending,

  /// L'agent a declare son versement ; la reception n'a pas encore confirme.
  declared,

  /// La reception a confirme ce qu'elle a recu.
  received,
}

/// La caisse d'un point de vente, vue de la reception.
class Remittance {
  const Remittance({
    required this.sessionId,
    required this.outletId,
    required this.outletLabel,
    required this.agentName,
    required this.expected,
    required this.openedAt,
    this.closedAt,
    this.declared,
    this.received,
    this.receivedAt,
  });

  final String sessionId;
  final String outletId;
  final String outletLabel;
  final String agentName;

  /// Ce que le point de vente doit : son fond de caisse et ses ventes en
  /// especes. Fige a la fermeture, recalcule en continu avant.
  final int expected;
  final DateTime? openedAt;
  final DateTime? closedAt;

  /// Ce que l'agent a declare remettre ; nul tant que la caisse est ouverte.
  final int? declared;

  /// Ce que la reception a confirme ; nul tant qu'elle ne l'a pas fait.
  final int? received;
  final DateTime? receivedAt;

  RemittanceStatus get status => received != null
      ? RemittanceStatus.received
      : declared != null
      ? RemittanceStatus.declared
      : RemittanceStatus.pending;

  /// Ce qui a quitte le point de vente : le recu s'il est confirme, sinon le
  /// declare.
  int? get paid => received ?? declared;

  /// Ecart entre le verse et l'attendu. Nul tant que rien n'est verse.
  int? get variance => paid == null ? null : paid! - expected;
}

/// La soiree d'un point de vente : sa recette, ce qu'il a verse, ce qui reste.
class OutletEvening {
  const OutletEvening({
    required this.outletId,
    required this.outletLabel,
    required this.takings,
    required this.cashTakings,
    required this.remittances,
  });

  final String outletId;
  final String outletLabel;

  /// La recette de la journee, tous moyens confondus, ventes de passage
  /// comprises.
  final int takings;

  /// Dont especes : la seule part qui se verse de la main a la main.
  final int cashTakings;

  /// Ses caisses de la soiree, la plus recente d'abord.
  final List<Remittance> remittances;

  /// Ce que ce point de vente doit a la reception.
  int get expected => remittances.fold(0, (t, r) => t + r.expected);

  /// Ce qu'il a verse (recu, ou declare en attendant la confirmation).
  int get paid => remittances.fold(0, (t, r) => t + (r.paid ?? 0));

  /// Ce qui dort encore dans ses tiroirs ouverts.
  int get pending => remittances
      .where((r) => r.status == RemittanceStatus.pending)
      .fold(0, (t, r) => t + r.expected);

  /// La somme des ecarts de ses versements.
  int get variance => remittances.fold(0, (t, r) => t + (r.variance ?? 0));
}

/// Le rapport du soir : ce que la reception attend de chaque point de vente,
/// ce qu'elle a recu, et les ecarts.
class EveningReport {
  const EveningReport({required this.outlets, required this.centralTakings});

  final List<OutletEvening> outlets;

  /// Ce que la reception a encaisse elle-meme dans la journee : rien a
  /// verser, c'est deja la caisse centrale.
  final int centralTakings;

  int get expected => outlets.fold(0, (t, o) => t + o.expected);
  int get paid => outlets.fold(0, (t, o) => t + o.paid);
  int get pending => outlets.fold(0, (t, o) => t + o.pending);
  int get variance => outlets.fold(0, (t, o) => t + o.variance);

  /// Les versements declares que la reception doit encore confirmer.
  int get toConfirm => outlets
      .expand((o) => o.remittances)
      .where((r) => r.status == RemittanceStatus.declared)
      .length;
}

/// Un encaissement de la journee, tel que la caisse le liste.
class DayPayment {
  const DayPayment({
    required this.id,
    required this.amount,
    required this.method,
    required this.receivedAt,
    required this.guestName,
    required this.roomNumber,
    required this.folioNumber,
    required this.agentName,
    required this.reference,
  });

  final String id;

  /// Signe : un remboursement est negatif.
  final int amount;
  final PaymentMethod method;
  final DateTime? receivedAt;
  final String? guestName;
  final String? roomNumber;
  final String? folioNumber;
  final String? agentName;
  final String? reference;
}

/// Une caisse, ouverte ou fermee, pour l'historique.
class CashSessionSummary {
  const CashSessionSummary({required this.session, required this.agentName});

  final CashSessionRow session;
  final String agentName;
}

class CashRepository with OutboxWriter {
  CashRepository(this.db);

  @override
  final AtriumDatabase db;

  static const hotelId = '01920000-0000-7000-8000-000000000001';

  /// La caisse ouverte de cet agent, avec son attendu recalcule en continu.
  Stream<CashView?> watchCurrent(String userId) {
    return (db.select(db.cashSessions)
          ..where(
            (c) =>
                c.userId.equals(userId) &
                c.status.equalsValue(CashSessionStatus.OPEN) &
                c.deletedAt.isNull(),
          )
          ..orderBy([(c) => OrderingTerm.desc(c.openedAt)])
          ..limit(1))
        .watchSingleOrNull()
        .asyncMap((s) async => s == null ? null : _vue(s));
  }

  Future<CashView> _vue(CashSessionRow s) async {
    final especes = await _cashCollected(s.id);
    return CashView(
      session: s,
      expected: s.openingFloat + especes + await _remittedInto(s.id),
      cashCollected: especes,
    );
  }

  /// Les versements des points de vente confirmes dans cette caisse.
  ///
  /// Des especes entrees dans le tiroir, au meme titre qu'un encaissement :
  /// les oublier ferait constater un excedent a chaque fermeture de la
  /// reception. Le serveur fait le meme calcul.
  Future<int> _remittedInto(String sessionId) async {
    final r = await db
        .customSelect(
          '''
          SELECT COALESCE(SUM(received_amount), 0) AS n
            FROM cash_sessions
           WHERE received_session_id = ?
             AND deleted_at IS NULL
          ''',
          variables: [Variable.withString(sessionId)],
          readsFrom: {db.cashSessions},
        )
        .getSingle();
    return r.read<int>('n');
  }

  /// Les especes encaissees sur cette session.
  ///
  /// Les remboursements se soustraient : ils sortent bien du tiroir.
  Future<int> _cashCollected(String sessionId) async {
    final r = await db
        .customSelect(
          '''
          SELECT COALESCE(SUM(CASE WHEN is_refund = 1 THEN -amount ELSE amount END), 0) AS n
            FROM payments
           WHERE cash_session_id = ?
             AND method = 'CASH'
             AND deleted_at IS NULL
          ''',
          variables: [Variable.withString(sessionId)],
          readsFrom: {db.payments},
        )
        .getSingle();
    return r.read<int>('n');
  }

  /// Les encaissements d'une journee hoteliere, du plus recent au plus
  /// ancien, avec le client et l'agent : ce que la caisse du jour liste.
  Stream<List<DayPayment>> watchDayPayments(String businessDate) {
    return db
        .customSelect(
          '''
          SELECT p.id, p.amount, p.is_refund, p.method, p.received_at,
                 p.reference,
                 f.number AS folio_number,
                 g.first_name, g.last_name,
                 ch.number AS room_number,
                 u.first_name AS agent_first, u.last_name AS agent_last
            FROM payments p
            LEFT JOIN folios f             ON f.id = p.folio_id
            LEFT JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
            LEFT JOIN reservations res     ON res.id = rr.reservation_id
            LEFT JOIN guests g             ON g.id = COALESCE(f.guest_id, res.guest_id)
            LEFT JOIN rooms ch             ON ch.id = rr.room_id
            LEFT JOIN users u              ON u.id = p.received_by
           WHERE p.deleted_at IS NULL
             AND p.business_date = ?1
           ORDER BY p.received_at DESC
          ''',
          variables: [Variable.withString(businessDate)],
          readsFrom: {
            db.payments,
            db.folios,
            db.reservationRooms,
            db.reservations,
            db.guests,
            db.rooms,
            db.users,
          },
        )
        .watch()
        .map(
          (rows) => [
            for (final r in rows)
              DayPayment(
                id: r.read<String>('id'),
                amount: r.read<bool>('is_refund')
                    ? -r.read<int>('amount')
                    : r.read<int>('amount'),
                method: PaymentMethod.values.byName(r.read<String>('method')),
                receivedAt: r.readNullable<DateTime>('received_at'),
                reference: r.readNullable<String>('reference'),
                folioNumber: r.readNullable<String>('folio_number'),
                roomNumber: r.readNullable<String>('room_number'),
                guestName: _nom(
                  r.readNullable<String>('first_name'),
                  r.readNullable<String>('last_name'),
                ),
                agentName: _nom(
                  r.readNullable<String>('agent_first'),
                  r.readNullable<String>('agent_last'),
                ),
              ),
          ],
        );
  }

  /// Les dernieres caisses de l'hotel, la plus recente d'abord.
  Stream<List<CashSessionSummary>> watchSessions({int limit = 20}) {
    final requete =
        db.select(db.cashSessions).join([
            leftOuterJoin(
              db.users,
              db.users.id.equalsExp(db.cashSessions.userId),
            ),
          ])
          ..where(db.cashSessions.deletedAt.isNull())
          ..orderBy([OrderingTerm.desc(db.cashSessions.openedAt)])
          ..limit(limit);
    return requete.watch().map(
      (rows) => [
        for (final r in rows)
          CashSessionSummary(
            session: r.readTable(db.cashSessions),
            agentName:
                _nom(
                  r.readTableOrNull(db.users)?.firstName,
                  r.readTableOrNull(db.users)?.lastName,
                ) ??
                'Agent',
          ),
      ],
    );
  }

  static String? _nom(String? prenom, String? nom) {
    final t = [prenom, nom].whereType<String>().join(' ').trim();
    return t.isEmpty ? null : t;
  }

  /// La session ouverte de l'agent, sans son attendu. Sert au rattachement
  /// d'un encaissement, qui n'a pas besoin du calcul.
  Future<String?> openSessionId(String userId) async {
    // `limit(1)` : une seule est possible, mais une lecture qui leverait sur
    // deux lignes rendrait tout encaissement impossible pour cet agent.
    final s =
        await (db.select(db.cashSessions)
              ..where(
                (c) =>
                    c.userId.equals(userId) &
                    c.status.equalsValue(CashSessionStatus.OPEN) &
                    c.deletedAt.isNull(),
              )
              ..orderBy([(c) => OrderingTerm.desc(c.openedAt)])
              ..limit(1))
            .getSingleOrNull();
    return s?.id;
  }

  /// Prise de poste : l'agent compte son fond de caisse.
  ///
  /// Idempotent : si une caisse est deja ouverte, on la rend. Rappuyer ne doit
  /// pas couper la journee de l'agent en deux comptages qui ne tomberont
  /// jamais justes.
  ///
  /// [by] : l'agent qui execute l'ouverture, potentiellement different de
  /// [userId] (le titulaire de la caisse) -- par exemple un superviseur qui
  /// ouvre la caisse pour un agent. Ecrit dans `createdBy` (colonne fournie
  /// par `SyncedTableColumns`) et transmis au serveur en `created_by`.
  ///
  /// [outletId] : le point de vente dont c'est le tiroir. A laisser nul pour
  /// qui tient la caisse centrale -- il se verserait a lui-meme, et le
  /// serveur l'ignorerait de toute facon.
  Future<String> open({
    required String userId,
    required int openingFloat,
    String? by,
    String? outletId,
  }) async {
    if (openingFloat < 0) {
      throw StateError('Le fond de caisse ne peut pas etre negatif.');
    }

    final deja = await openSessionId(userId);
    if (deja != null) return deja;

    final id = newId();
    final now = DateTime.now().toUtc();

    await writeAndEnqueue(
      table: 'cash_sessions',
      id: id,
      operation: SyncOp.INSERT,
      payload: {
        'id': id,
        'opening_float': openingFloat,
        'outlet_id': outletId,
        'created_by': by,
      },
      action: () => db
          .into(db.cashSessions)
          .insert(
            CashSessionsCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              hotelId: hotelId,
              userId: userId,
              status: const Value(CashSessionStatus.OPEN),
              openedAt: Value(now),
              openingFloat: Value(openingFloat),
              outletId: Value(outletId),
              createdBy: Value(by),
              syncState: const Value(SyncState.pending),
            ),
          ),
    );

    return id;
  }

  /// Fin de service : l'agent recompte, l'ecart se constate.
  ///
  /// Pour la caisse d'un point de vente, c'est le versement du soir :
  /// [countedAmount] est ce que l'agent declare remettre a la reception.
  ///
  /// L'attendu est fige a cet instant, et l'ecart avec lui. Refermer plus tard
  /// ne recalcule rien -- le chiffre constate au comptage est celui que
  /// l'agent a vu, et c'est celui-la qui doit rester.
  ///
  /// [by] : l'agent qui execute la fermeture. Ecrit dans `updatedBy` et
  /// transmis au serveur en `updated_by` : la fermeture est la seule mise a
  /// jour d'une caisse, donc `updatedBy` designe bien qui l'a fermee.
  Future<int> close({
    required String sessionId,
    required int countedAmount,
    String? by,
  }) async {
    if (countedAmount < 0) {
      throw StateError('Un comptage ne peut pas etre negatif.');
    }

    final s = await (db.select(
      db.cashSessions,
    )..where((c) => c.id.equals(sessionId))).getSingleOrNull();
    if (s == null) throw StateError('Caisse introuvable.');
    if (s.status != CashSessionStatus.OPEN) {
      throw StateError('Cette caisse est deja fermee.');
    }

    final attendu =
        s.openingFloat +
        await _cashCollected(sessionId) +
        await _remittedInto(sessionId);
    final ecart = countedAmount - attendu;
    final now = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(
        db.cashSessions,
      )..where((c) => c.id.equals(sessionId))).write(
        CashSessionsCompanion(
          status: const Value(CashSessionStatus.CLOSED),
          closedAt: Value(now),
          countedAmount: Value(countedAmount),
          expectedAmount: Value(attendu),
          variance: Value(ecart),
          updatedBy: Value(by),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      await enqueue(
        table: 'cash_sessions',
        id: sessionId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': sessionId,
          'counted_amount': countedAmount,
          'updated_by': by,
        },
      );
    });

    return ecart;
  }

  /// La reception confirme ce qu'elle recoit d'un point de vente.
  ///
  /// Les memes refus que le serveur, avant lui : un refus qui arrive par la
  /// file d'envoi la bloque. S'y ajoute la caisse ouverte de celui qui recoit
  /// -- l'argent doit tomber dans un tiroir, et c'est son attendu qu'il
  /// gonfle.
  ///
  /// Rend l'ecart entre le recu et l'attendu. Leve une [StateError] dont le
  /// message est fait pour etre montre tel quel.
  Future<int> confirmRemittance({
    required String sessionId,
    required int receivedAmount,
    required String by,
  }) async {
    if (receivedAmount < 0) {
      throw StateError('Un montant reçu ne peut pas être négatif.');
    }
    final s = await (db.select(
      db.cashSessions,
    )..where((c) => c.id.equals(sessionId))).getSingleOrNull();
    if (s == null) throw StateError('Caisse introuvable.');
    if (s.outletId == null) {
      throw StateError("Cette caisse n'est pas celle d'un point de vente.");
    }
    if (s.status == CashSessionStatus.OPEN) {
      throw StateError(
        "Ce point de vente n'a pas encore déclaré son versement.",
      );
    }
    if (s.receivedAt != null) {
      throw StateError('Ce versement a déjà été confirmé.');
    }
    final centrale = await openSessionId(by);
    if (centrale == null) {
      throw StateError(
        'Ouvrez votre caisse avant de recevoir un versement : '
        "l'argent doit tomber dans un tiroir.",
      );
    }

    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(
        db.cashSessions,
      )..where((c) => c.id.equals(sessionId))).write(
        CashSessionsCompanion(
          receivedAmount: Value(receivedAmount),
          receivedBy: Value(by),
          receivedAt: Value(now),
          receivedSessionId: Value(centrale),
          updatedBy: Value(by),
          updatedAt: Value(now),
          syncState: const Value(SyncState.pending),
        ),
      );

      // `action` : l'envoyeur des caisses ne connaissait que l'ouverture et
      // la fermeture.
      await enqueue(
        table: 'cash_sessions',
        id: sessionId,
        operation: SyncOp.UPDATE,
        payload: {
          'id': sessionId,
          'action': 'RECEIVE',
          'received_amount': receivedAmount,
          'updated_by': by,
        },
      );
    });

    return receivedAmount - s.expectedAmount;
  }

  /// Le rapport du soir d'une journee hoteliere.
  ///
  /// Les caisses de point de vente qui comptent ce soir-la : celles encore
  /// ouvertes, celles dont le versement attend sa confirmation -- quelle que
  /// soit leur anciennete, c'est de l'argent en attente -- et celles fermees
  /// dans la journee.
  Stream<EveningReport> watchEveningReport(String businessDate) {
    return db
        .customSelect(
          '''
          SELECT cs.id, cs.outlet_id, cs.status, cs.opened_at, cs.closed_at,
                 cs.opening_float, cs.counted_amount, cs.expected_amount,
                 cs.received_amount, cs.received_at,
                 o.label AS outlet_label,
                 u.first_name, u.last_name,
                 (SELECT COALESCE(SUM(CASE WHEN p.is_refund = 1
                                           THEN -p.amount ELSE p.amount END), 0)
                    FROM payments p
                   WHERE p.cash_session_id = cs.id
                     AND p.method = 'CASH'
                     AND p.deleted_at IS NULL) AS cash_in
            FROM cash_sessions cs
            LEFT JOIN outlets o ON o.id = cs.outlet_id
            LEFT JOIN users u   ON u.id = cs.user_id
           WHERE cs.deleted_at IS NULL
             AND cs.outlet_id IS NOT NULL
           ORDER BY cs.opened_at DESC
          ''',
          readsFrom: {db.cashSessions, db.payments, db.outlets, db.users},
        )
        .watch()
        .asyncMap((rows) async {
          final parPoint = <String, List<Remittance>>{};
          final libelles = <String, String>{};
          for (final r in rows) {
            final ouverte = r.read<String>('status') == 'OPEN';
            final ferme = r.readNullable<DateTime>('closed_at');
            final recu = r.readNullable<int>('received_amount');
            final duSoir =
                ouverte ||
                recu == null ||
                (ferme != null &&
                    formatIsoDate(businessDayFor(ferme.toLocal())) ==
                        businessDate);
            if (!duSoir) continue;

            final point = r.read<String>('outlet_id');
            final libelle = r.readNullable<String>('outlet_label') ?? 'Point de vente';
            libelles[point] = libelle;
            parPoint
                .putIfAbsent(point, () => [])
                .add(
                  Remittance(
                    sessionId: r.read<String>('id'),
                    outletId: point,
                    outletLabel: libelle,
                    agentName:
                        _nom(
                          r.readNullable<String>('first_name'),
                          r.readNullable<String>('last_name'),
                        ) ??
                        'Agent',
                    // Ouverte : le tiroir bouge encore. Fermee : l'attendu
                    // est celui qui a ete fige au versement.
                    expected: ouverte
                        ? r.read<int>('opening_float') + r.read<int>('cash_in')
                        : r.read<int>('expected_amount'),
                    openedAt: r.readNullable<DateTime>('opened_at'),
                    closedAt: ferme,
                    declared: ouverte
                        ? null
                        : r.readNullable<int>('counted_amount'),
                    received: recu,
                    receivedAt: r.readNullable<DateTime>('received_at'),
                  ),
                );
          }

          final recettes = await _takingsByOutlet(businessDate);
          for (final e in recettes.entries) {
            if (e.key != null) libelles.putIfAbsent(e.key!, () => e.value.$3);
          }
          final points = [
            for (final e in libelles.entries)
              OutletEvening(
                outletId: e.key,
                outletLabel: e.value,
                takings: recettes[e.key]?.$1 ?? 0,
                cashTakings: recettes[e.key]?.$2 ?? 0,
                remittances: parPoint[e.key] ?? const [],
              ),
          ]..sort((a, b) => a.outletLabel.compareTo(b.outletLabel));
          return EveningReport(
            outlets: points,
            centralTakings: recettes[null]?.$1 ?? 0,
          );
        });
  }

  /// La recette d'une journee par point de vente : (tous moyens, dont
  /// especes, libelle). La cle nulle est la caisse centrale -- ce que la
  /// reception a encaisse elle-meme, et les encaissements sans caisse.
  Future<Map<String?, (int, int, String)>> _takingsByOutlet(
    String businessDate,
  ) async {
    final rows = await db
        .customSelect(
          '''
          SELECT cs.outlet_id AS outlet_id,
                 MAX(o.label) AS outlet_label,
                 COALESCE(SUM(CASE WHEN p.is_refund = 1
                                   THEN -p.amount ELSE p.amount END), 0) AS total,
                 COALESCE(SUM(CASE WHEN p.method <> 'CASH' THEN 0
                                   WHEN p.is_refund = 1 THEN -p.amount
                                   ELSE p.amount END), 0) AS especes
            FROM payments p
            LEFT JOIN cash_sessions cs ON cs.id = p.cash_session_id
            LEFT JOIN outlets o        ON o.id = cs.outlet_id
           WHERE p.deleted_at IS NULL
             AND p.business_date = ?1
           GROUP BY cs.outlet_id
          ''',
          variables: [Variable.withString(businessDate)],
          readsFrom: {db.payments, db.cashSessions, db.outlets},
        )
        .get();
    return {
      for (final r in rows)
        r.readNullable<String>('outlet_id'): (
          r.read<int>('total'),
          r.read<int>('especes'),
          r.readNullable<String>('outlet_label') ?? 'Point de vente',
        ),
    };
  }

  /// Adopte l'identifiant que le serveur a retenu pour une caisse.
  ///
  /// Un agent n'a qu'une caisse ouverte : si le serveur en connaissait deja
  /// une -- ouverte depuis un autre poste -- il la rend au lieu d'en ouvrir
  /// une seconde. La tablette prend alors la sienne, avec tout ce qui s'y
  /// rattachait : les encaissements, les versements recus, et la fermeture
  /// qui attend peut-etre dans la file. Sans cela, cette fermeture partirait
  /// vers une caisse que le serveur n'a jamais vue.
  Future<void> adoptServerSession({
    required String localId,
    required String serverId,
  }) async {
    if (localId == serverId) return;

    await db.transaction(() async {
      final locale = await (db.select(
        db.cashSessions,
      )..where((c) => c.id.equals(localId))).getSingleOrNull();
      if (locale == null) return;

      final vars = [Variable.withString(serverId), Variable.withString(localId)];
      // Une fermeture qui attend encore : la version locale reste en attente,
      // pour que la descente ne la rouvre pas avant qu'elle soit remontee.
      final suite = await db
          .customSelect(
            '''
            SELECT COUNT(*) AS n FROM outbox_entries
             WHERE status <> 'ACKED' AND op <> 'INSERT'
               AND entity_table = 'cash_sessions' AND entity_id = ?
            ''',
            variables: [Variable.withString(localId)],
          )
          .getSingle();
      await (db.delete(db.cashSessions)..where((c) => c.id.equals(localId))).go();
      await db
          .into(db.cashSessions)
          .insertOnConflictUpdate(
            locale.copyWith(
              id: serverId,
              syncState: suite.read<int>('n') > 0
                  ? SyncState.pending
                  : SyncState.synced,
            ),
          );
      await db.customUpdate(
        'UPDATE payments SET cash_session_id = ?1 WHERE cash_session_id = ?2',
        variables: vars,
        updates: {db.payments},
      );
      await db.customUpdate(
        'UPDATE cash_sessions SET received_session_id = ?1 '
        'WHERE received_session_id = ?2',
        variables: vars,
        updates: {db.cashSessions},
      );
      await db.customUpdate(
        '''
        UPDATE outbox_entries SET entity_id = ?1
         WHERE status <> 'ACKED'
           AND entity_table = 'cash_sessions'
           AND entity_id = ?2
        ''',
        variables: vars,
        updates: {db.outboxEntries},
      );
    });
  }
}
