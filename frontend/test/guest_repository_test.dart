/// Numerotation des fiches clients : derivee de l'UUID, jamais d'un COUNT.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
  });
  tearDown(() async => db.close());

  test('deux clients crees de suite recoivent des codes differents', () async {
    final repo = GuestRepository(db);

    final guest1 = await repo.create(firstName: 'A', lastName: 'B');
    final guest2 = await repo.create(firstName: 'C', lastName: 'D');

    expect(guest1.code, isNot(equals(guest2.code)));
  });

  test('le code est derive de l\'id, pas d\'un compteur', () async {
    final repo = GuestRepository(db);

    final guest = await repo.create(firstName: 'A', lastName: 'B');

    // Le code se retrouve dans les 8 derniers caracteres hexadecimaux de
    // l'id, en majuscules -- la preuve qu'aucune requete de comptage n'a
    // ete necessaire pour l'obtenir.
    final expectedSuffix = guest.id
        .replaceAll('-', '')
        .substring(guest.id.replaceAll('-', '').length - 8)
        .toUpperCase();
    expect(guest.code, 'CLI-$expectedSuffix');
  });
}