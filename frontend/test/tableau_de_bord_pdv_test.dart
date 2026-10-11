/// Les chiffres du tableau de bord des points de vente.
///
/// Un seul calcul pour tous les points de vente : il prend la liste a
/// couvrir et ne connait aucun d'eux par son nom. Ce qui compte : le bar ne
/// voit que le bar, une vente est un client servi (pas une ligne), et la
/// semaine se compare a la semaine precedente arretee au meme jour.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/queries/outlet_dashboard_queries.dart';
import 'package:atrium/data/repositories/order_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

const _hotel = '01920000-0000-7000-8000-000000000001';
const _bar = '01920000-0000-7000-8000-00000000d001';
const _resto = '01920000-0000-7000-8000-00000000d002';
const _spa = '01920000-0000-7000-8000-00000000d003';
const _barman = '01920000-0000-7000-8000-00000000d004';
const _admin = '01920000-0000-7000-8000-00000000d005';

// Un jeudi.
final _jeudi = DateTime(2026, 10, 15);

void main() {
  late AtriumDatabase db;
  var compteur = 0;
  final t0 = DateTime.utc(2026, 10, 1);

  String ident() =>
      '01920000-0000-7000-8000-${(++compteur).toString().padLeft(12, '0')}';

  setUp(() async {
    db = AtriumDatabase.memory();
    compteur = 0;
    for (final (id, code, kind) in [
      (_bar, 'BAR', OutletKind.OUTLET),
      (_resto, 'REST', OutletKind.OUTLET),
      (_spa, 'SPA', OutletKind.SERVICE),
    ]) {
      await db
          .into(db.outlets)
          .insert(
            OutletsCompanion.insert(
              id: id,
              createdAt: t0,
              updatedAt: t0,
              hotelId: _hotel,
              code: code,
              label: code,
              kind: Value(kind),
            ),
          );
    }
  });
  tearDown(() => db.close());

  Future<String> ardoise(FolioType type) async {
    final id = ident();
    await db
        .into(db.folios)
        .insert(
          FoliosCompanion.insert(
            id: id,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            number: 'FOL-$compteur',
            type: Value(type),
          ),
        );
    return id;
  }

  Future<void> vendre(
    String folio,
    String pointDeVente,
    DateTime jour, {
    String label = 'Biere',
    int prix = 1500,
    int quantite = 1,
    int heure = 20,
    bool annulee = false,
  }) async {
    await db
        .into(db.folioItems)
        .insert(
          FolioItemsCompanion.insert(
            id: ident(),
            createdAt: t0,
            updatedAt: t0,
            folioId: folio,
            category: ChargeCategory.FNB,
            label: label,
            quantity: Value(quantite),
            unitPrice: Value(prix),
            amount: Value(prix * quantite),
            businessDate:
                '${jour.year}-${jour.month.toString().padLeft(2, '0')}-'
                '${jour.day.toString().padLeft(2, '0')}',
            isVoid: Value(annulee),
            sourceTable: const Value('outlets'),
            sourceId: Value(pointDeVente),
            postedAt: Value(DateTime(jour.year, jour.month, jour.day, heure)),
          ),
        );
  }

  FiltresPdv filtres(List<String> points, PeriodePdv periode) =>
      FiltresPdv(pointsDeVente: points, periode: periode, reference: _jeudi);

  group('les periodes', () {
    test('la semaine court du lundi au jour regarde', () {
      final f = filtres([_bar], PeriodePdv.semaine);
      expect(f.du, DateTime(2026, 10, 12));
      expect(f.au, _jeudi);
      expect(f.precedente.du, DateTime(2026, 10, 5));
      expect(f.precedente.au, DateTime(2026, 10, 8));
    });

    test('le mois se compare au mois precedent arrete au meme jour', () {
      final f = FiltresPdv(
        pointsDeVente: const [_bar],
        periode: PeriodePdv.mois,
        reference: DateTime(2026, 3, 31),
      );
      expect(f.du, DateTime(2026, 3, 1));
      expect(f.precedente.du, DateTime(2026, 2, 1));
      // Fevrier n'a pas de 31.
      expect(f.precedente.au, DateTime(2026, 2, 28));
    });

    test('janvier se compare a decembre', () {
      final f = FiltresPdv(
        pointsDeVente: const [_bar],
        periode: PeriodePdv.mois,
        reference: DateTime(2027, 1, 10),
      );
      expect(f.precedente.du, DateTime(2026, 12, 1));
      expect(f.precedente.au, DateTime(2026, 12, 10));
    });
  });

  group('les chiffres', () {
    test('le bar ne voit que le bar', () async {
      final passage = await ardoise(FolioType.WALK_IN);
      await vendre(passage, _bar, _jeudi, prix: 2000);
      final autre = await ardoise(FolioType.WALK_IN);
      await vendre(autre, _resto, _jeudi, prix: 9000);

      final c = await db.chiffresPdv(filtres([_bar], PeriodePdv.jour));

      expect(c.recette, 2000);
      expect(c.ventes, 1);
    });

    test('trois bieres en 101 dans la soiree font une vente', () async {
      final chambre = await ardoise(FolioType.GUEST);
      for (var i = 0; i < 3; i++) {
        await vendre(chambre, _bar, _jeudi, heure: 19 + i);
      }
      final passage = await ardoise(FolioType.WALK_IN);
      await vendre(passage, _bar, _jeudi, prix: 1000, quantite: 2);

      final c = await db.chiffresPdv(filtres([_bar], PeriodePdv.jour));

      expect(c.ventes, 2);
      expect(c.articles, 5);
      expect(c.recette, 4500 + 2000);
      expect(c.surPlace, 2000);
      expect(c.enChambre, 4500);
      expect(c.ticketMoyen, 3250);
    });

    test("une ligne annulee n'est pas une vente", () async {
      final passage = await ardoise(FolioType.WALK_IN);
      await vendre(passage, _bar, _jeudi, annulee: true);

      final c = await db.chiffresPdv(filtres([_bar], PeriodePdv.jour));

      expect(c.recette, 0);
      expect(c.ventes, 0);
      expect(c.ticketMoyen, 0);
    });

    test('sans point de vente, rien -- pas tout', () async {
      final passage = await ardoise(FolioType.WALK_IN);
      await vendre(passage, _bar, _jeudi);

      final c = await db.chiffresPdv(filtres(const [], PeriodePdv.jour));

      expect(c.recette, 0);
    });

    test('la semaine se compare a la precedente', () async {
      final f = await ardoise(FolioType.WALK_IN);
      await vendre(f, _bar, DateTime(2026, 10, 12), prix: 5000); // lundi
      await vendre(f, _bar, DateTime(2026, 10, 6), prix: 3000); // mardi d'avant
      await vendre(f, _bar, DateTime(2026, 10, 10), prix: 7000); // samedi d'avant

      final t = await db.chargerTableauDeBordPdv(
        filtres([_bar], PeriodePdv.semaine),
      );

      expect(t.chiffres.recette, 5000);
      // Le samedi d'avant est apres le jeudi : hors de la comparaison.
      expect(t.precedent.recette, 3000);
    });
  });

  group('meilleures ventes et heures de pointe', () {
    test("les articles qui rapportent le plus d'abord", () async {
      final f = await ardoise(FolioType.WALK_IN);
      await vendre(f, _bar, _jeudi, label: 'Biere', prix: 1500, quantite: 4);
      await vendre(f, _bar, _jeudi, label: 'Whisky', prix: 8000);
      await vendre(f, _bar, _jeudi, label: 'Soda', prix: 500, quantite: 2);

      final t = await db.chargerTableauDeBordPdv(
        filtres([_bar], PeriodePdv.jour),
      );

      expect(t.meilleuresVentes.map((l) => l.libelle), [
        'Whisky',
        'Biere',
        'Soda',
      ]);
      expect(t.meilleuresVentes[1].quantite, 4);
    });

    test("l'heure de pointe se lit sur l'heure de la saisie", () async {
      final f = await ardoise(FolioType.WALK_IN);
      await vendre(f, _bar, _jeudi, heure: 13, prix: 2000);
      await vendre(f, _bar, _jeudi, heure: 21, prix: 1500, quantite: 3);

      final t = await db.chargerTableauDeBordPdv(
        filtres([_bar], PeriodePdv.jour),
      );

      expect(t.parHeure, hasLength(24));
      expect(t.parHeure[13].montant, 2000);
      expect(t.parHeure[21].articles, 3);
      expect(t.heureDePointe?.heure, 21);
    });
  });

  group('le perimetre', () {
    Future<void> agent(String id) => db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: id,
            createdAt: t0,
            updatedAt: t0,
            hotelId: _hotel,
            employeeCode: id.substring(30),
            firstName: 'Agent',
            lastName: id.substring(30),
          ),
        );

    test('le barman rattache ne voit que le bar', () async {
      await agent(_barman);
      await db
          .into(db.userOutlets)
          .insert(UserOutletsCompanion.insert(userId: _barman, outletId: _bar));

      final p = await OrderRepository(db).watchPerimetre(_barman).first;

      expect(p.rattache, isTrue);
      expect(p.pointsDeVente.map((o) => o.id), [_bar]);
      expect(p.plusieurs, isFalse);
    });

    test("sans rattachement, tout l'hotel, rangé par genre", () async {
      await agent(_admin);

      final p = await OrderRepository(db).watchPerimetre(_admin).first;

      expect(p.rattache, isFalse);
      expect(p.pointsDeVente, hasLength(3));
      expect(p.duGenre(OutletKind.SERVICE).map((o) => o.id), [_spa]);
      expect(p.duGenre(OutletKind.OUTLET), hasLength(2));
    });
  });
}
