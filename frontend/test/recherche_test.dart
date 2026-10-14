/// La recherche des listes : chaque mot, dans n'importe quel champ, sans
/// accents ni majuscules, et les numeros ecrits autrement.
library;

import 'package:atrium/core/recherche.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('une recherche vide garde tout', () {
    expect(Recherche('  ').garde(['Castel']), isTrue);
  });

  test('chaque mot doit se trouver, dans n importe quel champ', () {
    final champs = ['Jean-Marc Mballa', '102', 'Bar Lounge'];
    expect(Recherche('mballa 102').garde(champs), isTrue);
    expect(Recherche('102 mballa').garde(champs), isTrue);
    expect(Recherche('mballa 205').garde(champs), isFalse);
  });

  test('ni accents ni majuscules ne comptent', () {
    expect(Recherche('economat').garde(['Économat']), isTrue);
    expect(Recherche('NDOLÉ').garde(['Ndolé crevettes']), isTrue);
    expect(Recherche('jus d orange').garde(['Jus d’orange']), isTrue);
    expect(Recherche('jus orange').garde(['Jus d’orange']), isTrue);
    expect(Recherche('jus ananas').garde(['Jus d’orange']), isFalse);
  });

  test('un numero se trouve sans ses espaces', () {
    final champs = ['+237 6 77 41 20 18'];
    expect(Recherche('677412018').garde(champs), isTrue);
    expect(Recherche('677 41').garde(champs), isTrue);
    expect(Recherche('185000').garde(['185 000']), isTrue);
  });

  test('« 33 » trouve « 33 Export »', () {
    expect(Recherche('33').garde(['33 Export']), isTrue);
    expect(Recherche('33').garde(['Castel']), isFalse);
  });
}
