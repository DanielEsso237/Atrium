/// Formats d'affichage : montants en francs CFA entiers, dates ISO.
library;

import 'package:atrium/core/formats.dart';
import 'package:flutter_test/flutter_test.dart';

/// Espace insecable, le seul separateur de milliers admis : un montant ne doit
/// jamais se couper en fin de ligne.
const nbsp = ' ';

void main() {
  group('montants', () {
    test('les milliers sont separes par un espace insecable', () {
      expect(formatAmount(1250000), '1${nbsp}250${nbsp}000${nbsp}FCFA');
      expect(formatAmount(60000), '60${nbsp}000${nbsp}FCFA');
      expect(formatAmount(500), '500${nbsp}FCFA');
    });

    test('zero s affiche, il ne disparait pas', () {
      expect(formatAmount(0), '0${nbsp}FCFA');
    });

    test('un montant negatif garde son signe devant', () {
      // Un avoir sur une ardoise : « -25 000 FCFA », pas « 25 000- ».
      expect(formatAmount(-25000), '-25${nbsp}000${nbsp}FCFA');
    });

    test('aucun separateur decimal nulle part', () {
      // Le franc CFA n'a pas de sous-unite en usage, et toute la chaine est en
      // entiers : une virgule ici signalerait une conversion en flottant.
      for (final montant in [1, 999, 1000, 1250000, 987654321]) {
        expect(formatAmount(montant), isNot(contains(',')));
        expect(formatAmount(montant), isNot(contains('.')));
      }
    });

    test('la forme courte n abrege qu a partir du million', () {
      expect(formatAmountShort(999999), formatAmount(999999));
      expect(formatAmountShort(1250000), '1,25${nbsp}M${nbsp}FCFA');
      expect(formatAmountShort(12500000), '13${nbsp}M${nbsp}FCFA');
    });
  });

  group('dates', () {
    test('le format ISO est celui des colonnes de la base', () {
      expect(formatIsoDate(DateTime(2026, 9, 23)), '2026-09-23');
      expect(formatIsoDate(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('l ordre alphabetique des dates ISO est l ordre chronologique', () {
      // C'est ce qui permet les comparaisons et les BETWEEN directement en SQL.
      final dates = [
        formatIsoDate(DateTime(2026, 12, 1)),
        formatIsoDate(DateTime(2026, 1, 15)),
        formatIsoDate(DateTime(2026, 9, 23)),
      ]..sort();

      expect(dates, ['2026-01-15', '2026-09-23', '2026-12-01']);
    });

    test('la date courte est lisible par un receptionniste', () {
      expect(formatShortDate(DateTime(2026, 9, 23)), '23/09/2026');
    });

    test('la date longue sert d en-tete d ecran', () {
      expect(formatLongDate(DateTime(2026, 9, 23)), '23 septembre 2026');
    });

    test('une date de la base se relit, une valeur douteuse donne null', () {
      expect(parseIsoDate('2026-09-23'), DateTime(2026, 9, 23));
      expect(parseIsoDate(null), isNull);
      expect(parseIsoDate(''), isNull);
      expect(parseIsoDate('23/09'), isNull);
    });
  });
}
