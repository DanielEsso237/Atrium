/// Le ticket d'une vente encaissee au comptoir se fabrique, logo ou pas.
library;

import 'dart:convert';

import 'package:atrium/features/billing/invoice_pdf.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('le ticket du bar est un PDF, sans logo comme sans hotel', () async {
    final octets = await ticketDeComptoir(
      hotel: null,
      pointDeVente: 'Bar / Lounge',
      numero: 'FOL-01A12B',
      date: DateTime(2026, 10, 11, 21, 40),
      lignes: const [('Mutzig', 1000, 2), ('Eau', 500, 1)],
      moyen: 'Espèces',
      client: 'Awa Diallo, chambre 102',
      agent: 'Ines Mbarga',
    );

    expect(octets.length, greaterThan(1000));
    expect(ascii.decode(octets.sublist(0, 5)), '%PDF-');
  });
}
