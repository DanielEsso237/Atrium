/// Porter une consommation depuis un point de vente (F3.1).
///
/// Le parcours que le patron a decrit : Jean est en chambre, il consomme au
/// restaurant, puis a la boite de nuit ; tout finit sur sa facture de sejour.
/// Celui qui encaisse au point de vente n'a pas besoin de voir l'ardoise, ni
/// le plan des chambres, ni le fichier client — il a besoin de savoir a
/// quelle chambre porter, et combien.
///
/// **Ce n'est pas encore le cycle complet des commandes.** Le modele prevoit
/// des articles de menu, des postes de preparation et des tickets de cuisine
/// (F3.2) : c'est un autre ticket. Ici, une consommation devient directement
/// une ligne d'ardoise, marquee du point de vente d'ou elle vient.
library;

import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';
import 'folio_repository.dart';

/// Une chambre a qui l'on peut porter une consommation.
class ChargeableRoom {
  const ChargeableRoom({
    required this.roomId,
    required this.roomNumber,
    required this.guestName,
    required this.folioId,
    required this.balance,
  });

  final String roomId;
  final String roomNumber;
  final String guestName;
  final String folioId;

  /// Ce que le client doit deja.
  ///
  /// Affiche avant de valider : c'est ce qui rendra le seuil de consommation
  /// comprehensible le jour ou il existera, plutot qu'un refus sec.
  final int balance;
}

/// Un article de la carte, tel que l'ecran le propose.
class MenuEntry {
  const MenuEntry({
    required this.id,
    required this.label,
    required this.price,
    required this.isAvailable,
    required this.categoryLabel,
  });

  final String id;
  final String label;

  /// Prix en francs CFA entiers.
  final int price;

  /// `false` = rupture : visible dans la carte, mais on ne peut pas le choisir.
  final bool isAvailable;

  final String categoryLabel;
}

class OrderRepository {
  OrderRepository(this.db);

  final AtriumDatabase db;

  /// Les chambres occupees dont l'ardoise est ouverte.
  ///
  /// Par numero de chambre : c'est ce que le client annonce au comptoir du
  /// bar, pas son nom ni son numero de dossier.
  Stream<List<ChargeableRoom>> watchChargeableRooms() {
    return db
        .customSelect(
          '''
      SELECT r.id            AS room_id,
             r.number        AS room_number,
             g.first_name    AS first_name,
             g.last_name     AS last_name,
             f.id            AS folio_id,
             f.balance       AS balance
        FROM reservation_rooms rr
        JOIN rooms r          ON r.id = rr.room_id
        JOIN reservations res ON res.id = rr.reservation_id
        JOIN guests g         ON g.id = res.guest_id
        JOIN folios f         ON f.reservation_room_id = rr.id
                             AND f.status = 'OPEN'
                             AND f.deleted_at IS NULL
       WHERE rr.status = 'CHECKED_IN'
         AND rr.deleted_at IS NULL
    ORDER BY r.number
      ''',
          readsFrom: {
            db.reservationRooms,
            db.rooms,
            db.reservations,
            db.guests,
            db.folios,
          },
        )
        .watch()
        .map(
          (lignes) => lignes
              .map(
                (l) => ChargeableRoom(
                  roomId: l.read<String>('room_id'),
                  roomNumber: l.read<String>('room_number'),
                  guestName:
                      '${l.read<String>('first_name')} '
                      '${l.read<String>('last_name')}',
                  folioId: l.read<String>('folio_id'),
                  balance: l.read<int>('balance'),
                ),
              )
              .toList(),
        );
  }

  /// Les points de vente ouverts, dans l'ordre de leurs onglets.
  Stream<List<OutletRow>> watchOutlets() {
    return (db.select(db.outlets)
          ..where((o) => o.isActive.equals(true) & o.deletedAt.isNull())
          ..orderBy([
            (o) => OrderingTerm(expression: o.sortOrder),
            (o) => OrderingTerm(expression: o.label),
          ]))
        .watch();
  }

  /// La carte d'un point de vente, groupee par categorie.
  ///
  /// Le serveur ne filtre pas la carte : c'est ici qu'on garde les categories
  /// du point de vente courant et les categories communes (`outlet_id` nul).
  /// Les articles en rupture restent dans la liste : l'ecran les grise.
  Stream<List<MenuEntry>> watchMenu(String outletId) {
    return db
        .customSelect(
          '''
      SELECT i.id            AS id,
             i.label         AS label,
             i.price         AS price,
             i.is_available  AS is_available,
             c.label         AS category_label
        FROM menu_items i
        JOIN menu_categories c ON c.id = i.menu_category_id
       WHERE i.deleted_at IS NULL AND i.is_active = 1
         AND c.deleted_at IS NULL AND c.is_active = 1
         AND (c.outlet_id IS NULL OR c.outlet_id = ?)
    ORDER BY c.sort_order, c.label, i.sort_order, i.label
      ''',
          variables: [Variable.withString(outletId)],
          readsFrom: {db.menuItems, db.menuCategories},
        )
        .watch()
        .map(
          (lignes) => lignes
              .map(
                (l) => MenuEntry(
                  id: l.read<String>('id'),
                  label: l.read<String>('label'),
                  price: l.read<int>('price'),
                  isAvailable: l.read<bool>('is_available'),
                  categoryLabel: l.read<String>('category_label'),
                ),
              )
              .toList(),
        );
  }

  /// Porte une consommation sur l'ardoise d'une chambre.
  ///
  /// Passe par `FolioRepository.addCharge` plutot que d'ecrire la ligne
  /// ici : les totaux se recalculent, la file d'envoi se remplit, et les
  /// garde-fous de l'ardoise s'appliquent. Dupliquer cette logique la ferait
  /// diverger au premier changement.
  ///
  /// Leve une [StateError] dont le message est fait pour etre montre tel quel.
  Future<void> charge({
    required OutletRow outlet,
    required String folioId,
    required String label,
    required int unitPrice,
    int quantity = 1,
    String? by,
  }) async {
    if (!outlet.allowsRoomCharge) {
      throw StateError(
        '${outlet.label} n\'est pas autorise a porter sur la chambre. '
        'Encaissez sur place.',
      );
    }
    if (label.trim().isEmpty) {
      throw StateError('Indiquez ce qui a ete consomme.');
    }
    if (unitPrice <= 0 || quantity <= 0) {
      throw StateError('Le montant doit etre superieur a zero.');
    }

    await FolioRepository(db).addCharge(
      folioId: folioId,
      category: _categoriePour(outlet.code),
      label: label.trim(),
      unitPrice: unitPrice,
      quantity: quantity,
      postedBy: by,
      // D'ou vient la ligne. Le modele prevoit ces deux colonnes pour ca, et
      // c'est ce qui permettra plus tard de ventiler le chiffre d'affaires
      // par point de vente sans ajouter de colonne.
      sourceTable: 'outlets',
      sourceId: outlet.id,
    );
  }

  /// La categorie comptable d'une consommation, deduite du point de vente.
  ///
  /// Un rapprochement volontairement grossier : le plan comptable de l'hotel
  /// n'a pas une categorie par point de vente, et `MISC` est un aveu honnete
  /// pour ce qui ne rentre pas dans les autres.
  static ChargeCategory _categoriePour(String code) {
    final c = code.toUpperCase();
    if (c.contains('BAR') || c.contains('RESTAURANT') || c.contains('NUIT')) {
      return ChargeCategory.FNB;
    }
    if (c.contains('SPA')) return ChargeCategory.SPA;
    if (c.contains('MINIBAR')) return ChargeCategory.MINIBAR;
    if (c.contains('LAUNDRY') || c.contains('BLANCH')) {
      return ChargeCategory.LAUNDRY;
    }
    return ChargeCategory.MISC;
  }
}