/// La commande en chambre (F2.6, reunion du 18 octobre).
///
/// Le client appelle la reception depuis sa chambre ; elle commande pour lui
/// a un point de vente -- le bar, le restaurant --, qui voit la commande
/// arriver, la prend en charge et la monte. A la livraison, chaque ligne
/// passe sur l'ardoise du sejour **au nom du point de vente** : son chiffre,
/// son stock, comme une consommation portee a la chambre au comptoir.
///
///     SENT (commandee) --prendreEnCharge--> IN_PREP --livrer--> SERVED
///        \___________________________________annuler--> CANCELLED
///
/// Chaque geste s'ecrit dans Drift et part par la file dans la meme
/// transaction (`orders`, un champ `action`), vers `/room-orders`. Les refus
/// du serveur sont recopies ici, avant la premiere ecriture : un refus par
/// la file la bloquerait, avec tout ce qui attend derriere (voir la section
/// « La commande en chambre » de `docs/04-contrat-api.md`).
library;

import 'package:drift/drift.dart';

import '../../core/business_day.dart';
import '../../core/ids.dart';
import '../local/database.dart';
import '../local/enums.dart';
import 'cash_repository.dart';
import 'folio_repository.dart';
import 'guest_repository.dart' show codeFromId;
import 'outbox.dart';
import 'stock_repository.dart';

/// Une ligne a commander : l'article de la carte, sa quantite, une
/// precision pour le bar (« bien fraiche »).
typedef LigneACommander = ({String menuItemId, int quantite, String? notes});

/// Une ligne de commande, telle qu'affichee.
class LigneCommandeChambre {
  const LigneCommandeChambre({
    required this.id,
    required this.libelle,
    required this.quantite,
    required this.montant,
    this.notes,
  });

  final String id;
  final String libelle;
  final int quantite;
  final int montant;
  final String? notes;
}

/// Une commande en chambre, avec ce qu'il faut pour la suivre.
class CommandeChambre {
  const CommandeChambre({
    required this.id,
    required this.numero,
    required this.statut,
    required this.outletId,
    required this.pointDeVente,
    required this.folioId,
    required this.total,
    required this.lignes,
    this.roomId,
    this.chambre,
    this.client,
    this.commandeeA,
    this.notes,
    this.motifAnnulation,
  });

  final String id;
  final String numero;
  final OrderStatus statut;
  final String outletId;
  final String pointDeVente;
  final String folioId;
  final int total;
  final List<LigneCommandeChambre> lignes;
  final String? roomId;
  final String? chambre;
  final String? client;
  final DateTime? commandeeA;
  final String? notes;
  final String? motifAnnulation;

  /// Commandee ou en preparation : pas encore sur l'ardoise, mais deja due.
  bool get enRoute => RoomOrderRepository.enCours.contains(statut);
}

class RoomOrderRepository with OutboxWriter {
  RoomOrderRepository(this.db, {this.hotelId = FolioRepository.defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  /// Commandee (SENT), prise en charge (IN_PREP) : la commande est en route.
  static const enCours = {OrderStatus.SENT, OrderStatus.IN_PREP};

  // --- Ce qui est en route vers une ardoise ----------------------------------

  /// Le nombre et le total des commandes en route vers cette ardoise.
  static Future<(int, int)> _enRoute(AtriumDatabase db, String folioId) async {
    final r = await db
        .customSelect(
          '''
      SELECT COUNT(*) AS n, COALESCE(SUM(total), 0) AS total
        FROM orders
       WHERE folio_id = ?1 AND type = 'ROOM_SERVICE'
         AND status IN ('SENT','IN_PREP') AND deleted_at IS NULL
      ''',
          variables: [Variable.withString(folioId)],
          readsFrom: {db.orders},
        )
        .getSingle();
    return (r.read<int>('n'), r.read<int>('total'));
  }

  /// Le client ne part pas avec un plateau en route. Le serveur refuse le
  /// depart, la cloture de l'ardoise et l'annulation de l'arrivee tant
  /// qu'une commande en chambre n'est pas livree ou annulee : sans ce refus,
  /// la livraison trouvait l'ardoise close et bloquait la file du point de
  /// vente. La tablette le refuse avant, pour ne pas bloquer la sienne.
  ///
  /// `geste` complete la phrase : « … avant le départ ».
  static Future<void> verifierAucuneEnRoute(
    AtriumDatabase db,
    String folioId,
    String geste,
  ) async {
    final (n, _) = await _enRoute(db, folioId);
    if (n == 0) return;
    throw StateError(
      n == 1
          ? 'Une commande en chambre n’est pas encore livrée : livrez-la ou '
                'annulez-la avant $geste.'
          : '$n commandes en chambre ne sont pas encore livrées : livrez-les '
                'ou annulez-les avant $geste.',
    );
  }

  // --- Commander ---------------------------------------------------------------

  /// La reception commande pour une chambre ; rend l'id de la commande.
  ///
  /// Refuse, comme `POST /room-orders` : un point de vente inconnu, inactif,
  /// qui ne porte pas sur la chambre ou **ferme** (aucun tiroir ouvert sur
  /// lui, quel que soit l'agent qui le tient) ; une ardoise qui n'est pas
  /// celle d'un sejour en cours ; un article absent de la carte du point de
  /// vente, retire ou plus disponible ; et le plafond du client, compte avec
  /// les commandes **deja en route** vers la meme ardoise -- elles ne sont pas
  /// encore sur l'ardoise, mais le client les doit deja.
  ///
  /// Leve une [StateError] dont le message est fait pour etre montre tel quel.
  Future<String> commander({
    required String outletId,
    required String folioId,
    required List<LigneACommander> lignes,
    required String by,
    String? notes,
    String? overrideBy,
  }) async {
    if (lignes.isEmpty) throw StateError('Ajoutez au moins un article.');
    if (lignes.any((l) => l.quantite < 1)) {
      throw StateError('Chaque article se commande au moins une fois.');
    }

    final pointDeVente = await (db.select(
      db.outlets,
    )..where((o) => o.id.equals(outletId))).getSingleOrNull();
    if (pointDeVente == null ||
        pointDeVente.deletedAt != null ||
        !pointDeVente.isActive) {
      throw StateError('Point de vente introuvable.');
    }
    if (!pointDeVente.allowsRoomCharge) {
      throw StateError('${pointDeVente.label} ne porte pas sur la chambre.');
    }
    // Ouvert tant qu'un de ses tiroirs l'est, celui de n'importe quel agent :
    // la reception ne tient pas la caisse du bar, elle verifie seulement que
    // quelqu'un est la pour servir.
    final ouvert =
        await (db.select(db.cashSessions)
              ..where(
                (s) =>
                    s.outletId.equals(outletId) &
                    s.status.equalsValue(CashSessionStatus.OPEN) &
                    s.deletedAt.isNull(),
              )
              ..limit(1))
            .getSingleOrNull();
    if (ouvert == null) {
      throw StateError(
        '${pointDeVente.label} est fermé (aucune caisse ouverte) : il ne '
        'peut pas livrer.',
      );
    }

    final ardoise = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(folioId))).getSingleOrNull();
    if (ardoise == null ||
        ardoise.deletedAt != null ||
        ardoise.status != FolioStatus.OPEN ||
        ardoise.reservationRoomId == null) {
      throw StateError(
        'Ce séjour n’a pas d’ardoise ouverte : le client est parti.',
      );
    }
    final sejour = await (db.select(
      db.reservationRooms,
    )..where((l) => l.id.equals(ardoise.reservationRoomId!))).getSingleOrNull();

    // La carte du point de vente : ses categories, et celles de tout l'hotel.
    final ids = {for (final l in lignes) l.menuItemId};
    final carte = await db
        .customSelect(
          '''
      SELECT m.id, m.label, m.price, m.tax_rate, m.prep_station_id,
             m.is_available
        FROM menu_items m
        JOIN menu_categories c ON c.id = m.menu_category_id
       WHERE m.id IN (${List.filled(ids.length, '?').join(', ')})
         AND m.deleted_at IS NULL AND m.is_active = 1
         AND (c.outlet_id IS NULL OR c.outlet_id = ?)
      ''',
          variables: [
            for (final id in ids) Variable.withString(id),
            Variable.withString(outletId),
          ],
          readsFrom: {db.menuItems, db.menuCategories},
        )
        .get();
    final articles = {for (final a in carte) a.read<String>('id'): a};
    if (ids.length != articles.length) {
      throw StateError('Article absent de la carte de ${pointDeVente.label}.');
    }
    final indisponibles = [
      for (final a in articles.values)
        if (!a.read<bool>('is_available')) a.read<String>('label'),
    ]..sort();
    if (indisponibles.isNotEmpty) {
      throw StateError('Plus disponible : ${indisponibles.join(', ')}.');
    }

    // Les prix de la carte sont TTC, comme sur l'ardoise : la taxe est la
    // part du montant qui lui revient, pas un supplement.
    var total = 0;
    var taxe = 0;
    for (final l in lignes) {
      final a = articles[l.menuItemId]!;
      final montant = a.read<int>('price') * l.quantite;
      total += montant;
      taxe += montant * a.read<int>('tax_rate') ~/ 100;
    }
    final (_, dejaEnRoute) = await _enRoute(db, folioId);
    await FolioRepository(
      db,
    ).verifierSeuil(folioId, total + dejaEnRoute, overrideBy);

    final id = newId();
    final now = DateTime.now().toUtc();
    final lignesIds = [for (final _ in lignes) newId()];

    await writeAndEnqueue(
      table: 'orders',
      id: id,
      operation: SyncOp.INSERT,
      payload: {
        'action': 'CREATE',
        'id': id,
        'outlet_id': outletId,
        'folio_id': folioId,
        'notes': notes,
        'override_by': overrideBy,
        'items': [
          for (var i = 0; i < lignes.length; i++)
            {
              'id': lignesIds[i],
              'menu_item_id': lignes[i].menuItemId,
              'quantity': lignes[i].quantite,
              'notes': lignes[i].notes,
            },
        ],
      },
      action: () async {
        await db
            .into(db.orders)
            .insert(
              OrdersCompanion.insert(
                id: id,
                createdAt: now,
                updatedAt: now,
                hotelId: hotelId,
                // Provisoire : la suite `ORD-…` n'a qu'une autorite, le
                // serveur, et sa reponse la recopie.
                number: codeFromId(id, 'ORD'),
                outletId: outletId,
                type: const Value(OrderType.ROOM_SERVICE),
                status: const Value(OrderStatus.SENT),
                roomId: Value(sejour?.roomId),
                folioId: Value(folioId),
                guestId: Value(ardoise.guestId),
                businessDate: Value(businessDateNow()),
                openedAt: Value(now),
                sentAt: Value(now),
                orderedBy: Value(by),
                overrideBy: Value(overrideBy),
                notes: Value(notes),
                subtotal: Value(total),
                taxTotal: Value(taxe),
                total: Value(total),
                createdBy: Value(by),
                syncState: const Value(SyncState.pending),
              ),
            );
        for (var i = 0; i < lignes.length; i++) {
          final a = articles[lignes[i].menuItemId]!;
          await db
              .into(db.orderItems)
              .insert(
                OrderItemsCompanion.insert(
                  id: lignesIds[i],
                  createdAt: now,
                  updatedAt: now,
                  orderId: id,
                  menuItemId: Value(lignes[i].menuItemId),
                  prepStationId: Value(a.read<String?>('prep_station_id')),
                  labelSnapshot: a.read<String>('label'),
                  quantity: Value(lignes[i].quantite),
                  unitPrice: Value(a.read<int>('price')),
                  taxRate: Value(a.read<int>('tax_rate')),
                  amount: Value(a.read<int>('price') * lignes[i].quantite),
                  status: const Value(OrderStatus.SENT),
                  notes: Value(lignes[i].notes),
                  sentAt: Value(now),
                  sortOrder: Value(i),
                  syncState: const Value(SyncState.pending),
                ),
              );
        }
      },
    );
    return id;
  }

  // --- Le point de vente --------------------------------------------------------

  /// Le point de vente prend la commande en charge : elle est en preparation.
  /// Deja prise en charge ou livree : rien a faire.
  Future<void> prendreEnCharge({
    required String orderId,
    required String by,
  }) async {
    final commande = await _commande(orderId);
    await _verifierRattachement(by, commande.outletId);
    if (commande.status == OrderStatus.IN_PREP ||
        commande.status == OrderStatus.SERVED) {
      return;
    }
    if (commande.status != OrderStatus.SENT) {
      throw StateError('Cette commande a été annulée.');
    }
    final now = DateTime.now().toUtc();
    await writeAndEnqueue(
      table: 'orders',
      id: orderId,
      operation: SyncOp.UPDATE,
      payload: {'action': 'ACCEPT', 'id': orderId},
      action: () async {
        await (db.update(db.orders)..where((o) => o.id.equals(orderId))).write(
          OrdersCompanion(
            status: const Value(OrderStatus.IN_PREP),
            takenBy: Value(by),
            takenAt: Value(now),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
        await (db.update(db.orderItems)..where(
              (i) =>
                  i.orderId.equals(orderId) &
                  i.status.equalsValue(OrderStatus.SENT),
            ))
            .write(
              OrderItemsCompanion(
                status: const Value(OrderStatus.IN_PREP),
                updatedAt: Value(now),
              ),
            );
      },
    );
  }

  /// Le plateau est monte : chaque ligne passe sur l'ardoise du sejour.
  ///
  /// La ligne d'ardoise prend l'id de la ligne de commande, comme sur le
  /// serveur : la tablette ecrit hors ligne la meme ligne que lui, et la
  /// descente la recouvre sans la doubler. Elle porte le point de vente
  /// (`source_table = 'outlets'`) et la journee de la **commande** : un
  /// plateau commande a 23 h et monte a 0 h 30 reste sur sa journee. Le
  /// stock du point de vente baisse tout de suite.
  ///
  /// Refuse, comme `POST /room-orders/{id}/deliver` : une commande annulee,
  /// l'agent qui livre sans **son** tiroir ouvert sur ce point de vente, une
  /// ardoise close. Le plafond ne se revérifie pas : c'est a la commande que
  /// quelqu'un pouvait encore dire non.
  ///
  /// `payeMaintenant` : le client paie devant le plateau plutot que de
  /// laisser sur l'ardoise (decision du client, 18 octobre). Le total de la
  /// commande tombe dans le tiroir de celui qui livre, sur l'ardoise du
  /// sejour : les lignes y sont, et le paiement les solde.
  Future<void> livrer({
    required String orderId,
    required String by,
    PaymentMethod? payeMaintenant,
  }) async {
    final commande = await _commande(orderId);
    await _verifierRattachement(by, commande.outletId);
    if (commande.status == OrderStatus.SERVED) return;
    if (!enCours.contains(commande.status)) {
      throw StateError('Cette commande a été annulée.');
    }
    final caisse = await CashRepository(
      db,
    ).openSessionId(by, outletId: commande.outletId);
    if (caisse == null) {
      throw StateError(
        'Ouvrez la caisse du point de vente avant de livrer : il est fermé.',
      );
    }
    final ardoise = commande.folioId == null
        ? null
        : await (db.select(
            db.folios,
          )..where((f) => f.id.equals(commande.folioId!))).getSingleOrNull();
    if (ardoise == null ||
        ardoise.deletedAt != null ||
        ardoise.status != FolioStatus.OPEN) {
      throw StateError('L’ardoise du séjour est close : le client est parti.');
    }
    final lignes = await (db.select(
      db.orderItems,
    )..where((i) => i.orderId.equals(orderId) & i.isVoid.equals(false))).get();
    final now = DateTime.now().toUtc();
    final journee = commande.businessDate ?? businessDateNow();
    // Le paiement couvre la commande, ni plus ni moins, comme le serveur
    // l'exige : la monnaie rendue n'est pas une ligne d'ardoise.
    final aPayer = lignes.fold(0, (s, l) => s + l.amount);
    final paiementId = payeMaintenant == null ? null : newId();

    await writeAndEnqueue(
      table: 'orders',
      id: orderId,
      operation: SyncOp.UPDATE,
      payload: {
        'action': 'DELIVER',
        'id': orderId,
        if (payeMaintenant != null)
          'payment': {
            'id': paiementId,
            'method': payeMaintenant.name,
            'amount': aPayer,
          },
      },
      action: () async {
        for (final l in lignes) {
          await db
              .into(db.folioItems)
              .insert(
                FolioItemsCompanion.insert(
                  id: l.id,
                  createdAt: now,
                  updatedAt: now,
                  folioId: ardoise.id,
                  category: ChargeCategory.FNB,
                  label: l.labelSnapshot,
                  quantity: Value(l.quantity),
                  unitPrice: Value(l.unitPrice),
                  amount: Value(l.amount),
                  taxRate: Value(l.taxRate),
                  taxAmount: Value(l.amount * l.taxRate ~/ 100),
                  businessDate: journee,
                  sourceTable: const Value('outlets'),
                  sourceId: Value(commande.outletId),
                  postedBy: Value(by),
                  postedAt: Value(now),
                  overrideBy: Value(commande.overrideBy),
                  // Le serveur ecrit la meme ligne a la livraison : elle ne
                  // remonte pas seule. C'est la commande, en attente, qui
                  // protege l'ardoise de la descente (`Descente`).
                  syncState: const Value(SyncState.synced),
                ),
              );
          if (l.menuItemId != null) {
            await StockRepository(db, hotelId: hotelId).deductLocalForSale(
              outletId: commande.outletId,
              menuItemId: l.menuItemId!,
              quantity: l.quantity,
              folioItemId: l.id,
              by: by,
            );
          }
        }
        if (payeMaintenant != null) {
          await db
              .into(db.payments)
              .insert(
                PaymentsCompanion.insert(
                  id: paiementId!,
                  createdAt: now,
                  updatedAt: now,
                  hotelId: hotelId,
                  method: payeMaintenant,
                  amount: aPayer,
                  folioId: Value(ardoise.id),
                  receivedBy: Value(by),
                  cashSessionId: Value(caisse),
                  receivedAt: Value(now),
                  businessDate: Value(businessDateNow()),
                  // Remonte avec la livraison, pas a part.
                  syncState: const Value(SyncState.synced),
                ),
              );
        }
        await FolioRepository(db).recalculer(ardoise.id);
        await (db.update(db.orders)..where((o) => o.id.equals(orderId))).write(
          OrdersCompanion(
            status: const Value(OrderStatus.SERVED),
            servedAt: Value(now),
            deliveredBy: Value(by),
            // Livree sans prise en charge prealable : celui qui livre l'a
            // prise, comme le serveur l'ecrit.
            takenBy: commande.takenBy == null
                ? Value(by)
                : const Value.absent(),
            takenAt: commande.takenAt == null
                ? Value(now)
                : const Value.absent(),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
        await (db.update(
              db.orderItems,
            )..where((i) => i.orderId.equals(orderId) & i.isVoid.equals(false)))
            .write(
              OrderItemsCompanion(
                status: const Value(OrderStatus.SERVED),
                updatedAt: Value(now),
              ),
            );
      },
    );
  }

  /// Le client se ravise, ou le point de vente ne peut pas servir : avec un
  /// motif. Une commande livree ne s'annule plus : elle est sur l'ardoise,
  /// et c'est la que la ligne se corrige.
  Future<void> annuler({
    required String orderId,
    required String motif,
    required String by,
  }) async {
    final raison = motif.trim();
    if (raison.isEmpty) throw StateError('Indiquez le motif de l’annulation.');
    final commande = await _commande(orderId);
    if (commande.status == OrderStatus.CANCELLED) return;
    if (commande.status == OrderStatus.SERVED) {
      throw StateError(
        'Cette commande est déjà livrée : elle est sur l’ardoise.',
      );
    }
    final now = DateTime.now().toUtc();
    await writeAndEnqueue(
      table: 'orders',
      id: orderId,
      operation: SyncOp.UPDATE,
      payload: {'action': 'CANCEL', 'id': orderId, 'reason': raison},
      action: () async {
        await (db.update(db.orders)..where((o) => o.id.equals(orderId))).write(
          OrdersCompanion(
            status: const Value(OrderStatus.CANCELLED),
            cancelledAt: Value(now),
            cancelledBy: Value(by),
            cancelReason: Value(raison),
            updatedAt: Value(now),
            syncState: const Value(SyncState.pending),
          ),
        );
        await (db.update(
          db.orderItems,
        )..where((i) => i.orderId.equals(orderId))).write(
          OrderItemsCompanion(
            status: const Value(OrderStatus.CANCELLED),
            updatedAt: Value(now),
          ),
        );
      },
    );
  }

  Future<OrderRow> _commande(String orderId) async {
    final commande = await (db.select(
      db.orders,
    )..where((o) => o.id.equals(orderId))).getSingleOrNull();
    if (commande == null ||
        commande.deletedAt != null ||
        commande.type != OrderType.ROOM_SERVICE) {
      throw StateError('Commande en chambre introuvable.');
    }
    return commande;
  }

  /// Un agent rattache a des points de vente ne touche qu'aux commandes des
  /// siens (le serveur repond 403) ; sans rattachement, il les voit toutes.
  Future<void> _verifierRattachement(String by, String outletId) async {
    final siens = await (db.select(
      db.userOutlets,
    )..where((u) => u.userId.equals(by))).get();
    if (siens.isEmpty || siens.any((u) => u.outletId == outletId)) return;
    throw StateError('Cette commande est adressée à un autre point de vente.');
  }

  // --- Lire ---------------------------------------------------------------------

  /// Les points de vente a qui commander pour une chambre : actifs, qui
  /// portent sur la chambre, avec leur etat. Un point de vente ferme (aucun
  /// tiroir ouvert) reste dans la liste, grise : la reception doit savoir que
  /// le bar existe mais ne sert pas en ce moment, plutot que de le chercher.
  Stream<List<(OutletRow, bool ouvert)>> watchPointsDeVentePourChambre() {
    final pointsDeVente = db.select(db.outlets)
      ..where(
        (o) =>
            o.deletedAt.isNull() &
            o.isActive.equals(true) &
            o.allowsRoomCharge.equals(true),
      )
      ..orderBy([
        (o) => OrderingTerm.asc(o.sortOrder),
        (o) => OrderingTerm.asc(o.label),
      ]);
    return pointsDeVente.watch().asyncMap((liste) async {
      final ouverts = {
        for (final s
            in await (db.select(db.cashSessions)..where(
                  (s) =>
                      s.status.equalsValue(CashSessionStatus.OPEN) &
                      s.deletedAt.isNull() &
                      s.outletId.isNotNull(),
                ))
                .get())
          s.outletId,
      };
      return [for (final o in liste) (o, ouverts.contains(o.id))];
    });
  }

  /// Les commandes en chambre d'une ardoise, les plus recentes d'abord : ce
  /// que la fiche de la chambre montre sous « Commandes ».
  Stream<List<CommandeChambre>> watchPourArdoise(String folioId) =>
      _watch('o.folio_id = ?', [Variable.withString(folioId)]);

  /// Celles qu'un point de vente doit preparer et monter : en route, les
  /// plus anciennes d'abord.
  Stream<List<CommandeChambre>> watchEnRoutePour(String outletId) => _watch(
    "o.outlet_id = ? AND o.status IN ('SENT','IN_PREP')",
    [Variable.withString(outletId)],
    plusAnciennesDabord: true,
  );

  Stream<List<CommandeChambre>> _watch(
    String filtre,
    List<Variable> variables, {
    bool plusAnciennesDabord = false,
  }) {
    return db
        .customSelect(
          '''
      SELECT o.id, o.number, o.status, o.outlet_id, o.folio_id, o.total,
             o.room_id, o.opened_at, o.notes, o.cancel_reason,
             p.label AS point_de_vente, r.number AS chambre,
             TRIM(COALESCE(g.first_name, '') || ' ' ||
                  COALESCE(g.last_name, '')) AS client
        FROM orders o
        LEFT JOIN outlets p ON p.id = o.outlet_id
        LEFT JOIN rooms r ON r.id = o.room_id
        LEFT JOIN guests g ON g.id = o.guest_id
       WHERE o.type = 'ROOM_SERVICE' AND o.deleted_at IS NULL AND $filtre
       ORDER BY o.opened_at ${plusAnciennesDabord ? 'ASC' : 'DESC'}, o.id
      ''',
          variables: variables,
          readsFrom: {
            db.orders,
            db.orderItems,
            db.outlets,
            db.rooms,
            db.guests,
          },
        )
        .watch()
        .asyncMap((rows) async {
          if (rows.isEmpty) return const <CommandeChambre>[];
          final ids = [for (final r in rows) r.read<String>('id')];
          final lignes =
              await (db.select(db.orderItems)
                    ..where((i) => i.orderId.isIn(ids) & i.isVoid.equals(false))
                    ..orderBy([(i) => OrderingTerm.asc(i.sortOrder)]))
                  .get();
          return [
            for (final r in rows)
              CommandeChambre(
                id: r.read<String>('id'),
                numero: r.read<String>('number'),
                statut: OrderStatus.values.byName(r.read<String>('status')),
                outletId: r.read<String>('outlet_id'),
                pointDeVente: r.read<String?>('point_de_vente') ?? '—',
                folioId: r.read<String>('folio_id'),
                total: r.read<int>('total'),
                roomId: r.read<String?>('room_id'),
                chambre: r.read<String?>('chambre'),
                client: switch (r.read<String?>('client')) {
                  final c? when c.isNotEmpty => c,
                  _ => null,
                },
                commandeeA: r.read<DateTime?>('opened_at'),
                notes: r.read<String?>('notes'),
                motifAnnulation: r.read<String?>('cancel_reason'),
                lignes: [
                  for (final l in lignes)
                    if (l.orderId == r.read<String>('id'))
                      LigneCommandeChambre(
                        id: l.id,
                        libelle: l.labelSnapshot,
                        quantite: l.quantity,
                        montant: l.amount,
                        notes: l.notes,
                      ),
                ],
              ),
          ];
        });
  }
}
