/// Un signal d'alerte qui ne fait rien.
///
/// La cloche des notifications est sur chaque ecran (19 octobre) : sans ce
/// remplacant, un test d'ecran ouvrait le vrai lecteur de son, absent des
/// tests (`MissingPluginException` sur `audioplayers`).
library;

import 'package:atrium/data/local/queries/alert_queries.dart';
import 'package:atrium/features/alerts/alert_signal.dart';

class SignalSilencieux implements SignalAlerte {
  @override
  Future<void> emettre(
    NiveauAlerte niveau, {
    required Sonnerie sonnerie,
    bool son = true,
    bool vibration = true,
  }) async {}

  @override
  Future<void> arreter() async {}
}
