/// Editer la facture : le gel de l'ardoise, et son numero.
///
/// Le numero est le point sensible. C'est une donnee legale : unique,
/// continue, attribuee par une seule autorite. Une tablette hors ligne ne peut
/// pas la connaitre -- deux tablettes qui numeroteraient chacune de leur cote
/// produiraient des doublons sur des documents comptables. D'ou le numero
/// provisoire, remplace par le legal a la remontee.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/repositories/folio_repository.dart';
import 'package:atrium/data/repositories/invoice_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AtriumDatabase db;
  late FolioRepository folios;
  late InvoiceRepository factures;

  const folioId = '01920000-0000-7000-8000-000000009001';
  const hotel = '01920000-0000-7000-8000-000000000001';

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    folios = FolioRepository(db);
    factures = InvoiceRepository(db);

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
  });

  tearDown(() => db.close());

  Future<void> charger(int montant, {String libelle = 'Nuitee'}) {
    return folios.addCharge(
      folioId: folioId,
      category: ChargeCategory.ROOM,
      label: libelle,
      unitPrice: montant,
    );
  }

  test('la facture gele les lignes de l ardoise', () async {
    await charger(25000);
    await charger(5000, libelle: 'Petit dejeuner');

    final id = await factures.issue(folioId);
    final vue = await factures.watchForFolio(folioId).first;

    expect(vue, isNotNull);
    expect(vue!.invoice.id, id);
    expect(vue.lines, hasLength(2));
    expect(vue.invoice.total, 30000);
  });

  test('modifier l ardoise apres coup ne change pas la facture', () async {
    // « La facture n'est qu'un gel du folio » : un document remis au client
    // ne doit pas bouger parce qu'on a ajoute une consommation ensuite.
    await charger(25000);
    await factures.issue(folioId);

    await charger(9000, libelle: 'Ajoute apres');

    final vue = await factures.watchForFolio(folioId).first;
    expect(vue!.lines, hasLength(1));
    expect(vue.invoice.total, 25000);
  });

  test('une ardoise n a qu une facture', () async {
    await charger(25000);
    final a = await factures.issue(folioId);
    final b = await factures.issue(folioId);

    // Deux numeros pour les memes prestations serait une faute comptable,
    // pas une simple duplication.
    expect(a, b);
    final combien = await db
        .customSelect('SELECT COUNT(*) AS n FROM invoices')
        .getSingle();
    expect(combien.read<int>('n'), 1);
  });

  test('une ardoise vide ne se facture pas', () async {
    await expectLater(factures.issue(folioId), throwsA(isA<StateError>()));
  });

  test('hors ligne, le numero est provisoire et le dit', () async {
    await charger(25000);
    await factures.issue(folioId);

    final vue = await factures.watchForFolio(folioId).first;
    expect(vue!.provisional, isTrue);
    expect(vue.displayNumber, startsWith('PROV-'));
    expect(vue.invoice.number, isNull);
  });

  test('le serveur impose son numero legal a la remontee', () async {
    await charger(25000);
    final id = await factures.issue(folioId);

    await factures.applyServerNumber(id, {'number': 'FAC-2026-000042'});

    final vue = await factures.watchForFolio(folioId).first;
    expect(vue!.provisional, isFalse);
    expect(vue.displayNumber, 'FAC-2026-000042');
  });

  test('l edition part dans la file d envoi', () async {
    await charger(25000);
    await factures.issue(folioId);

    final r = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM outbox_entries WHERE entity_table = 'invoices'",
        )
        .getSingle();
    expect(r.read<int>('n'), 1);
  });
}
