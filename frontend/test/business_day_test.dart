/// La journee hoteliere (5.1).
///
/// Un hotel ne change pas de journee a minuit. Cette regle vivait cote
/// serveur et la tablette l'ignorait : a minuit une minute, le tableau de
/// bord retombait a zero alors que le service de nuit travaillait encore, et
/// une consommation portee a deux heures partait avec une date que le serveur
/// corrigeait ensuite. Les deux ne racontaient plus la meme journee.
library;

import 'package:atrium/core/business_day.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('apres la bascule, la journee est celle du calendrier', () {
    expect(businessDateNow(at: DateTime(2026, 9, 24, 6, 0)), '2026-09-24');
    expect(businessDateNow(at: DateTime(2026, 9, 24, 14, 30)), '2026-09-24');
    expect(businessDateNow(at: DateTime(2026, 9, 24, 23, 59)), '2026-09-24');
  });

  test('avant la bascule, on est encore la veille', () {
    // Le cas qui a fait tomber le tableau de bord a zero pendant un test a
    // deux heures du matin.
    expect(businessDateNow(at: DateTime(2026, 9, 25, 0, 1)), '2026-09-24');
    expect(businessDateNow(at: DateTime(2026, 9, 25, 2, 0)), '2026-09-24');
    expect(businessDateNow(at: DateTime(2026, 9, 25, 5, 59)), '2026-09-24');
  });

  test('la bascule elle-meme ouvre la journee', () {
    // A 6h00 pile on bascule : la borne est inclusive, comme cote serveur
    // (`if local.hour < day_rollover_hour`).
    expect(businessDateNow(at: DateTime(2026, 9, 25, 6, 0)), '2026-09-25');
  });

  test('un changement de mois se passe bien', () {
    expect(businessDateNow(at: DateTime(2026, 10, 1, 3, 0)), '2026-09-30');
  });

  test('un changement d annee aussi', () {
    expect(businessDateNow(at: DateTime(2027, 1, 1, 4, 0)), '2026-12-31');
  });

  test('l heure de bascule est reglable par hotel', () {
    // `hotels.day_rollover_hour` : tous les hotels ne basculent pas a 6h.
    expect(
      businessDateNow(at: DateTime(2026, 9, 25, 3, 0), rolloverHour: 2),
      '2026-09-25',
    );
    expect(
      businessDateNow(at: DateTime(2026, 9, 25, 1, 0), rolloverHour: 2),
      '2026-09-24',
    );
  });
}
