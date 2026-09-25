/// La journee hoteliere (cahier des charges, 5.1).
///
/// Un hotel ne change pas de journee a minuit. Le service de nuit encaisse a
/// une heure du matin, et cet argent appartient a la journee de la veille :
/// c'est ce que le comptable attend, et c'est ce que la caisse rapproche. La
/// bascule se fait a `hotels.day_rollover_hour`, six heures par defaut.
///
/// **Cette regle existait deja cote serveur** (`app/services/business_day.py`)
/// et la tablette l'ignorait. Le tableau de bord datait tout avec la date du
/// calendrier : a minuit une minute, arrivees du jour, departs du jour et
/// chiffre d'affaires retombaient a zero alors que le service continuait.
///
/// Plus grave que l'affichage : une consommation portee a deux heures du matin
/// etait estampillee du lendemain par la tablette et de la veille par le
/// serveur. Les deux ne racontaient plus la meme journee, et c'est le genre
/// d'ecart qui ne se decouvre qu'a la cloture.
///
/// Pas de fuseau ici, contrairement au serveur : la tablette est **dans**
/// l'hotel, son heure locale est l'heure de l'hotel. Le serveur, lui, peut
/// etre ailleurs et doit convertir.
library;

import 'formats.dart';

/// Heure de bascule par defaut, alignee sur `hotels.day_rollover_hour`.
const heureBasculeParDefaut = 6;

/// La date d'exploitation correspondant a `instant`.
///
/// Avant l'heure de bascule, on est encore dans la journee de la veille.
DateTime businessDayFor(DateTime instant, {int rolloverHour = heureBasculeParDefaut}) {
  final local = instant.isUtc ? instant.toLocal() : instant;
  final jour = DateTime(local.year, local.month, local.day);
  return local.hour < rolloverHour
      ? jour.subtract(const Duration(days: 1))
      : jour;
}

/// La date d'exploitation courante, au format `AAAA-MM-JJ`.
///
/// C'est la seule forme qui doit finir dans une colonne `business_date` ou
/// dans une requete qui la compare.
String businessDateNow({
  DateTime? at,
  int rolloverHour = heureBasculeParDefaut,
}) {
  return formatIsoDate(
    businessDayFor(at ?? DateTime.now(), rolloverHour: rolloverHour),
  );
}
