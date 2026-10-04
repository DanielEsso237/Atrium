/// Ce que la tablette comprend de ce que le serveur lui envoie.
///
/// Ces tests portent sur la traduction, pas sur le reseau : un champ absent,
/// un type inattendu, une ligne incomplete. C'est la que les descentes se
/// cassent en vrai — le serveur evolue, la tablette encaisse.
///
/// La regle du fichier : **une ligne illisible est ignoree, jamais fatale**.
/// Une reservation mal formee ne doit pas priver la reception des autres.
library;

import 'package:atrium/data/remote/catalog_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('un client', () {
    test('se lit avec ses champs facultatifs absents', () {
      final g = RemoteGuest.fromJson({
        'id': 'g1',
        'code': 'CLI-00001',
        'first_name': 'Awa',
        'last_name': 'Diallo',
      });

      expect(g, isNotNull);
      expect(g!.phone, isNull);
      expect(g.email, isNull);
      expect(g.isVip, isFalse);
    });

    test('un champ nul ne devient pas la chaine « null »', () {
      // Interpoler directement produirait « null », qui passerait ensuite
      // pour un vrai numero de telephone jusque dans la base.
      final g = RemoteGuest.fromJson({
        'id': 'g1',
        'code': 'CLI-00001',
        'first_name': 'Awa',
        'last_name': 'Diallo',
        'phone': null,
      });

      expect(g!.phone, isNull);
      expect(g.phone, isNot('null'));
    });

    test('sans identifiant ni code, la ligne est ecartee', () {
      expect(RemoteGuest.fromJson({'first_name': 'Awa'}), isNull);
      expect(RemoteGuest.fromJson({'id': 'g1'}), isNull);
      expect(RemoteGuest.fromJson('pas un objet'), isNull);
    });
  });

  group('une reservation', () {
    Map<String, Object?> dossier({List<Object?>? rooms}) => {
      'id': 'r1',
      'reference': 'RES-000001',
      'guest_id': 'g1',
      'status': 'CONFIRMED',
      'arrival_date': '2026-09-24',
      'departure_date': '2026-09-26',
      'adults': 2,
      'children': 1,
      'rooms': rooms ?? const [],
    };

    test('porte ses lignes de sejour', () {
      final r = RemoteReservation.fromJson(
        dossier(
          rooms: [
            {
              'id': 'l1',
              'room_type_id': 't1',
              'status': 'CHECKED_IN',
              'arrival_date': '2026-09-24',
              'departure_date': '2026-09-26',
              'nightly_rate': 25000,
              'room_id': 'c1',
            },
          ],
        ),
      );

      expect(r!.rooms, hasLength(1));
      expect(r.rooms.single.roomId, 'c1');
      expect(r.rooms.single.nightlyRate, 25000);
      expect(r.adults, 2);
    });

    test('une ligne illisible est ecartee, le dossier reste', () {
      // Le cas qui compte : le serveur ajoute un champ, une ligne devient
      // incomprehensible, et le reste doit continuer d'arriver.
      final r = RemoteReservation.fromJson(
        dossier(
          rooms: [
            {'id': 'l1', 'room_type_id': 't1', 'status': 'CONFIRMED',
             'arrival_date': '2026-09-24', 'departure_date': '2026-09-26'},
            {'status': 'CONFIRMED'}, // sans id ni categorie
          ],
        ),
      );

      expect(r, isNotNull);
      expect(r!.rooms, hasLength(1));
    });

    test('un dossier sans client est ecarte', () {
      final sansClient = Map<String, Object?>.from(dossier())
        ..remove('guest_id');
      expect(RemoteReservation.fromJson(sansClient), isNull);
    });

    test('les montants restent des entiers', () {
      // Le contrat impose des entiers en francs CFA. Un `double` en chemin
      // reintroduirait des arrondis dans de l'argent.
      final r = RemoteReservation.fromJson(
        dossier(
          rooms: [
            {'id': 'l1', 'room_type_id': 't1', 'status': 'CONFIRMED',
             'arrival_date': '2026-09-24', 'departure_date': '2026-09-26',
             'nightly_rate': 25000.0},
          ],
        ),
      );

      expect(r!.rooms.single.nightlyRate, isA<int>());
      expect(r.rooms.single.nightlyRate, 25000);
    });
  });

  group('une ardoise', () {
    test('porte ses lignes et ses totaux', () {
      final f = RemoteFolio.fromJson({
        'id': 'f1',
        'number': 'FOL-000001',
        'status': 'OPEN',
        'type': 'GUEST',
        'charges_total': 30000,
        'payments_total': 10000,
        'balance': 20000,
        'reservation_room_id': 'l1',
        'items': [
          {
            'id': 'i1',
            'category': 'ROOM',
            'label': 'Nuitee',
            'quantity': 1,
            'unit_price': 25000,
            'amount': 25000,
            'business_date': '2026-09-24',
          },
        ],
      });

      expect(f!.balance, 20000);
      expect(f.items, hasLength(1));
      expect(f.items.single.label, 'Nuitee');
      expect(f.stayLineId, 'l1');
    });

    test('une ardoise sans lignes se lit quand meme', () {
      // Une ardoise ouverte au check-in n'a rien dessus pendant un instant.
      final f = RemoteFolio.fromJson({
        'id': 'f1',
        'number': 'FOL-000001',
        'status': 'OPEN',
        'type': 'GUEST',
      });

      expect(f, isNotNull);
      expect(f!.items, isEmpty);
      expect(f.balance, 0);
    });
  });

  group('une categorie de la carte', () {
    test('sans point de vente, elle est commune a tous', () {
      final c = RemoteMenuCategory.fromJson({
        'id': 'c1',
        'outlet_id': null,
        'label': 'Plats',
        'sort_order': 0,
      });

      expect(c, isNotNull);
      expect(c!.outletId, isNull);
      expect(c.outletId, isNot('null'));
      expect(c.label, 'Plats');
    });

    test('avec un point de vente, elle lui est rattachee', () {
      final c = RemoteMenuCategory.fromJson({
        'id': 'c2',
        'outlet_id': 'o1',
        'label': 'Cocktails',
        'sort_order': 2,
      });

      expect(c!.outletId, 'o1');
      expect(c.sortOrder, 2);
    });

    test('sans identifiant ou sans libelle, la ligne est ecartee', () {
      expect(RemoteMenuCategory.fromJson({'label': 'Plats'}), isNull);
      expect(RemoteMenuCategory.fromJson({'id': 'c1'}), isNull);
      expect(RemoteMenuCategory.fromJson('pas un objet'), isNull);
    });
  });

  group('un article de la carte', () {
    Map<String, Object?> article({Map<String, Object?>? changes}) => {
      'id': 'a1',
      'code': 'PLAT1',
      'label': 'Poulet DG',
      'menu_category_id': 'c1',
      'price': 5000,
      'tax_rate': 0,
      'is_available': true,
      'prep_station_id': 'p1',
      ...?changes,
    };

    test('se lit avec tous ses champs', () {
      final a = RemoteMenuItem.fromJson(article());

      expect(a!.label, 'Poulet DG');
      expect(a.menuCategoryId, 'c1');
      expect(a.price, 5000);
      expect(a.prepStationId, 'p1');
      expect(a.isAvailable, isTrue);
    });

    test('sans poste de preparation, le champ reste nul', () {
      final a = RemoteMenuItem.fromJson(
        article(changes: {'prep_station_id': null}),
      );

      expect(a!.prepStationId, isNull);
      expect(a.prepStationId, isNot('null'));
    });

    test('un article en rupture reste lisible', () {
      final a = RemoteMenuItem.fromJson(
        article(changes: {'is_available': false}),
      );

      expect(a!.isAvailable, isFalse);
    });

    test('le prix reste un entier', () {
      final a = RemoteMenuItem.fromJson(article(changes: {'price': 5000.0}));

      expect(a!.price, isA<int>());
      expect(a.price, 5000);
    });

    test('le taux de taxe est un pourcentage, garde tel quel', () {
      final a = RemoteMenuItem.fromJson(article(changes: {'tax_rate': 19}));

      expect(a!.taxRate, 19);
    });

    test('sans identifiant ou sans categorie, la ligne est ecartee', () {
      expect(RemoteMenuItem.fromJson({'label': 'Poulet DG'}), isNull);
      expect(
        RemoteMenuItem.fromJson({'id': 'a1', 'label': 'Poulet DG'}),
        isNull,
      );
    });
  });
}