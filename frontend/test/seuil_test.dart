/// Le seuil de consommation, verifie sur la tablette avant d'ecrire.
///
/// Le serveur le controle aussi et repond 409. Mais un refus qui arrive par
/// la file d'envoi la **bloque**, avec tout ce qui attend derriere :
/// check-ins, encaissements, menage. Le comptoir se retrouverait avec une
/// tablette paralysee sans comprendre pourquoi.
///
/// Refuser tot garde le serveur comme simple filet. Ces tests verifient que
/// les deux appliquent bien la **meme** regle — sinon la tablette laisserait
/// passer ce que le serveur refuse, et on retomberait dans le blocage.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late FolioRepository folios;

  const hotel = '01920000-0000-7000-8000-000000000001';
  const clientId = '01920000-0000-7000-8000-00000000a001';
  const folioId = '01920000-0000-7000-8000-00000000a002';
  const responsable = '01920000-0000-7000-8000-000000050001';

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    folios = FolioRepository(db);
  });

  tearDown(() => db.close());

  /// Un client avec son seuil, et son ardoise ouverte.
  Future<void> installer({required int seuil}) async {
    final now = DateTime.now().toUtc();
    await db.into(db.guests).insert(
          GuestsCompanion.insert(
            id: clientId,
            createdAt: now,
            updatedAt: now,
            hotelId: hotel,
            code: 'CLI-00001',
            firstName: 'Jean',
            lastName: 'Bamba',
            creditLimit: Value(seuil),
          ),
        );
    await db.into(db.folios).insert(
          FoliosCompanion.insert(
            id: folioId,
            createdAt: now,
            updatedAt: now,
            hotelId: hotel,
            number: 'FOL-00001',
            guestId: const Value(clientId),
          ),
        );
  }

  Future<void> porter(int montant, {String? autorisePar}) {
    return folios.addCharge(
      folioId: folioId,
      category: ChargeCategory.FNB,
      label: 'Biere',
      unitPrice: montant,
      overrideBy: autorisePar,
    );
  }

  Future<int> solde() async {
    final f = await (db.select(
      db.folios,
    )..where((f) => f.id.equals(folioId))).getSingle();
    return f.balance;
  }

  test('un seuil a zero veut dire pas de limite', () async {
    // Valeur par defaut de tout le monde : le controle ne doit jamais se
    // declencher tant que personne n'a fixe de seuil.
    await installer(seuil: 0);

    await porter(500000);
    expect(await solde(), 500000);
  });

  test('atteindre exactement le seuil est permis', () async {
    await installer(seuil: 50000);

    await porter(50000);
    expect(await solde(), 50000);
  });

  test('le depasser d un franc ne l est pas', () async {
    await installer(seuil: 50000);

    await expectLater(porter(50001), throwsA(isA<StateError>()));
    expect(await solde(), 0, reason: 'un refus ne doit rien avoir ecrit');
  });

  test('le message donne de quoi appeler son responsable', () async {
    await installer(seuil: 50000);
    await porter(40000);

    try {
      await porter(20000);
      fail('la charge aurait du etre refusee');
    } on StateError catch (e) {
      // L'agent va lire ce message au telephone : les quatre chiffres
      // doivent y etre.
      expect(e.message, contains('40'));
      expect(e.message, contains('20'));
      expect(e.message, contains('60'));
      expect(e.message, contains('50'));
      expect(e.message, contains('responsable'));
    }
  });

  test('un responsable peut autoriser le depassement', () async {
    // Le seuil n'est pas un blocage, c'est une autorisation.
    await installer(seuil: 50000);

    await porter(80000, autorisePar: responsable);

    expect(await solde(), 80000);
    final ligne = await db
        .customSelect('SELECT override_by AS o FROM folio_items')
        .getSingle();
    expect(ligne.read<String?>('o'), responsable);
  });

  test('l autorisation part au serveur avec la ligne', () async {
    // Sans elle, le serveur refuserait une charge que la tablette a
    // acceptee : elle a vu l'autorisation, lui non.
    await installer(seuil: 50000);
    await porter(80000, autorisePar: responsable);

    final entree = await db
        .customSelect(
          "SELECT payload FROM outbox_entries WHERE entity_table = 'folio_items'",
        )
        .getSingle();
    expect(entree.read<String>('payload'), contains(responsable));
  });

  test('le cumul compte, pas la charge seule', () async {
    // Trois bieres a 20 000 passent chacune sous le seuil et le crevent
    // ensemble : c'est le solde apres qui decide.
    await installer(seuil: 50000);

    await porter(20000);
    await porter(20000);
    await expectLater(porter(20000), throwsA(isA<StateError>()));
    expect(await solde(), 40000);
  });

  test('une remise n est jamais bloquee', () async {
    // Elle fait baisser le solde : la controler n'aurait aucun sens, et
    // empecherait de corriger une ardoise deja au-dessus du seuil.
    await installer(seuil: 50000);
    await porter(50000);

    await folios.addCharge(
      folioId: folioId,
      category: ChargeCategory.DISCOUNT,
      label: 'Geste commercial',
      unitPrice: -10000,
    );

    expect(await solde(), 40000);
  });

  test('une ardoise sans client n est pas bloquee', () async {
    // Une ardoise de table au restaurant n'a pas de client rattache : il n'y
    // a aucun seuil a lui opposer.
    final now = DateTime.now().toUtc();
    await db.into(db.folios).insert(
          FoliosCompanion.insert(
            id: folioId,
            createdAt: now,
            updatedAt: now,
            hotelId: hotel,
            number: 'FOL-00002',
          ),
        );

    await porter(500000);
    expect(await solde(), 500000);
  });
}
