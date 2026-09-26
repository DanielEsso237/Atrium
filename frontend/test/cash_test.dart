/// La caisse : fond de caisse, encaissements, ecart.
///
/// L'ecart est le seul chiffre qui compte en fin de service : il dit si la
/// journee est saine. Tout le reste n'existe que pour qu'il soit juste.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/cash_repository.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late CashRepository caisse;
  late FolioRepository folios;

  const agent = '01920000-0000-7000-8000-000000050002';
  const folioId = '01920000-0000-7000-8000-000000009001';
  const hotel = '01920000-0000-7000-8000-000000000001';

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    caisse = CashRepository(db);
    folios = FolioRepository(db);

    final now = DateTime.now().toUtc();
    await db.into(db.guests).insert(
          GuestsCompanion.insert(
            id: '01920000-0000-7000-8000-000000009301',
            createdAt: now,
            updatedAt: now,
            hotelId: hotel,
            code: 'CLI-00001',
            firstName: 'Amadou',
            lastName: 'Kone',
          ),
        );
    await db.into(db.folios).insert(
          FoliosCompanion.insert(
            id: folioId,
            createdAt: now,
            updatedAt: now,
            hotelId: hotel,
            number: 'FOL-00001',
            guestId: const Value('01920000-0000-7000-8000-000000009301'),
          ),
        );
    await folios.addCharge(
      folioId: folioId,
      category: ChargeCategory.ROOM,
      label: 'Nuitee',
      unitPrice: 50000,
    );
  });

  tearDown(() => db.close());

  test('ouvrir pose le fond de caisse comme attendu', () async {
    await caisse.open(userId: agent, openingFloat: 20000);

    final vue = await caisse.watchCurrent(agent).first;
    expect(vue!.open, isTrue);
    expect(vue.expected, 20000);
    expect(vue.cashCollected, 0);
  });

  test('rouvrir ne coupe pas la journee en deux', () async {
    final a = await caisse.open(userId: agent, openingFloat: 20000);
    final b = await caisse.open(userId: agent, openingFloat: 99000);

    // Deux caisses pour un agent, ce sont deux comptages qui ne tomberont
    // jamais justes.
    expect(a, b);
    expect((await caisse.watchCurrent(agent).first)!.expected, 20000);
  });

  test('les especes encaissees gonflent l attendu', () async {
    await caisse.open(userId: agent, openingFloat: 20000);
    await folios.addPayment(
      folioId: folioId,
      method: PaymentMethod.CASH,
      amount: 30000,
      receivedBy: agent,
    );

    final vue = await caisse.watchCurrent(agent).first;
    expect(vue!.cashCollected, 30000);
    expect(vue.expected, 50000);
  });

  test('la carte ne passe pas par le tiroir', () async {
    // Les compter ferait constater un ecart enorme a chaque fermeture.
    await caisse.open(userId: agent, openingFloat: 20000);
    await folios.addPayment(
      folioId: folioId,
      method: PaymentMethod.CARD,
      amount: 30000,
      receivedBy: agent,
    );

    final vue = await caisse.watchCurrent(agent).first;
    expect(vue!.cashCollected, 0);
    expect(vue.expected, 20000);
  });

  test('fermer constate l ecart', () async {
    await caisse.open(userId: agent, openingFloat: 20000);
    await folios.addPayment(
      folioId: folioId,
      method: PaymentMethod.CASH,
      amount: 30000,
      receivedBy: agent,
    );
    final id = (await caisse.openSessionId(agent))!;

    // Il manque 2 000 dans le tiroir.
    final ecart = await caisse.close(sessionId: id, countedAmount: 48000);

    expect(ecart, -2000);
    expect(await caisse.watchCurrent(agent).first, isNull);
  });

  test('une caisse fermee ne se referme pas', () async {
    await caisse.open(userId: agent, openingFloat: 20000);
    final id = (await caisse.openSessionId(agent))!;
    await caisse.close(sessionId: id, countedAmount: 20000);

    await expectLater(
      caisse.close(sessionId: id, countedAmount: 99000),
      throwsA(isA<StateError>()),
    );
  });

  test('apres fermeture, la releve suivante ouvre une caisse neuve', () async {
    await caisse.open(userId: agent, openingFloat: 20000);
    final premiere = (await caisse.openSessionId(agent))!;
    await caisse.close(sessionId: premiere, countedAmount: 20000);

    final seconde = await caisse.open(userId: agent, openingFloat: 30000);
    expect(seconde, isNot(premiere));
    expect((await caisse.watchCurrent(agent).first)!.expected, 30000);
  });

  test('ouverture et fermeture partent dans la file', () async {
    await caisse.open(userId: agent, openingFloat: 20000);
    final id = (await caisse.openSessionId(agent))!;
    await caisse.close(sessionId: id, countedAmount: 20000);

    final r = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM outbox_entries "
          "WHERE entity_table = 'cash_sessions'",
        )
        .getSingle();
    expect(r.read<int>('n'), 2);
  });

  test('un montant negatif est refuse des deux cotes', () async {
    await expectLater(
      caisse.open(userId: agent, openingFloat: -1),
      throwsA(isA<StateError>()),
    );
    await caisse.open(userId: agent, openingFloat: 0);
    final id = (await caisse.openSessionId(agent))!;
    await expectLater(
      caisse.close(sessionId: id, countedAmount: -1),
      throwsA(isA<StateError>()),
    );
  });
}
