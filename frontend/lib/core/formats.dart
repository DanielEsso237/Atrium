/// Formats d'affichage partages par tous les ecrans.
///
/// Un seul endroit pour les montants et les dates : c'est ce qui evite que la
/// reception affiche `60 000 FCFA` et la facturation `60000.00`.
library;

/// Les montants sont des **entiers en francs CFA**, jamais des decimaux.
///
/// Ce n'est pas un choix d'affichage, c'est le format de la base : toutes les
/// colonnes monetaires du serveur et de la tablette sont des entiers
/// (`default_rate`, `unit_price`, `amount`, `balance`...). Le franc CFA n'a pas
/// de sous-unite en usage, il n'y a donc pas de centimes a perdre, et les
/// entiers evitent les erreurs d'arrondi des flottants sur les totaux.
///
/// Corollaire pour la couche reseau : ne jamais convertir en `double` en
/// chemin. Un `int` qui part, un `int` qui revient.
String formatAmount(int montant) {
  final signe = montant < 0 ? '-' : '';
  final chiffres = montant.abs().toString();
  final tampon = StringBuffer();

  for (var i = 0; i < chiffres.length; i++) {
    if (i > 0 && (chiffres.length - i) % 3 == 0) {
      // Espace insecable : un montant ne doit jamais se couper en fin de ligne.
      tampon.write(' ');
    }
    tampon.write(chiffres[i]);
  }
  return '$signe$tampon FCFA';
}

/// Version courte pour les tuiles du tableau de bord, ou la place manque.
///
/// 1 250 000 devient `1,25 M`. En dessous du million, le montant complet passe
/// sans probleme et reste plus lisible qu'une approximation.
String formatAmountShort(int montant) {
  if (montant.abs() < 1000000) return formatAmount(montant);
  final millions = montant / 1000000;
  final texte = millions.toStringAsFixed(millions.abs() >= 10 ? 0 : 2);
  return '${texte.replaceAll('.', ',')} M FCFA';
}

/// Date metier au format de la base : `AAAA-MM-JJ`.
///
/// Les colonnes `arrival_date`, `departure_date` et `business_date` sont du
/// texte ISO, pas des horodatages : ce sont des **dates**, sans heure ni
/// fuseau. Une nuitee du 12 est la nuitee du 12 partout.
String formatIsoDate(DateTime jour) {
  final m = jour.month.toString().padLeft(2, '0');
  final j = jour.day.toString().padLeft(2, '0');
  return '${jour.year}-$m-$j';
}

const _mois = [
  'janvier',
  'fevrier',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'aout',
  'septembre',
  'octobre',
  'novembre',
  'decembre',
];

/// Date lisible pour l'en-tete des ecrans : `23 septembre 2026`.
String formatLongDate(DateTime jour) =>
    '${jour.day} ${_mois[jour.month - 1]} ${jour.year}';

/// Date compacte pour les listes et les fiches : `23/09/2026`.
String formatShortDate(DateTime jour) {
  final m = jour.month.toString().padLeft(2, '0');
  final j = jour.day.toString().padLeft(2, '0');
  return '$j/$m/${jour.year}';
}

/// Relit une date ISO de la base. Renvoie `null` si le texte est inexploitable.
DateTime? parseIsoDate(String? iso) {
  if (iso == null || iso.length < 10) return null;
  return DateTime.tryParse(iso.substring(0, 10));
}
