/// La nuitee de 12 h a 12 h et la prolongation.
///
/// Une nuitee va de l'heure d'arrivee a l'heure de depart de l'hotel (12 h par
/// defaut) : c'est distinct de la **journee d'exploitation**, qui bascule a 6 h
/// (`business_day.dart`). Un client qui part a 14 h ne change pas de journee
/// d'exploitation, il depasse simplement l'heure de depart : l'hotel lui
/// facture deux heures de prolongation.
///
/// Tout ce fichier est du calcul pur, sans base ni ecran, pour que les cas
/// limites (11 h 59, 12 h 30, prolongation de trois heures) se testent a la
/// seconde pres.
library;

/// Heure de depart par defaut : midi.
const heureDepartParDefaut = 12;

/// Debut du libelle de toute ligne de prolongation sur l'ardoise.
///
/// C'est aussi ce qui les retrouve : le serveur ne garde pas la provenance
/// d'une ligne saisie a la main, le libelle est donc la seule trace qui
/// survive a la synchronisation. Ne pas le renommer sans migrer les lignes.
const libelleProlongation = 'Prolongation';

/// Le libelle d'une ligne : « Prolongation 3 h ».
String libelleDeProlongation(int heures) => '$libelleProlongation $heures h';

/// L'instant limite de depart d'un sejour.
///
/// `jourDepart` est la date de depart (date seule, sans heure) ;
/// `heuresProlongees` repousse la limite d'autant. Une limite qui passe minuit
/// retombe correctement sur le lendemain : le constructeur de `DateTime`
/// reporte le surplus d'heures.
DateTime limiteDeDepart(
  DateTime jourDepart, {
  int heureDepart = heureDepartParDefaut,
  int heuresProlongees = 0,
}) {
  return DateTime(
    jourDepart.year,
    jourDepart.month,
    jourDepart.day,
    heureDepart + heuresProlongees,
  );
}

/// Les heures a facturer pour un depart a `maintenant`.
///
/// Zero jusqu'a la limite **incluse** : partir a 12 h 00 est partir a l'heure.
/// Toute heure entamee est due -- 12 h 30 fait une heure, 14 h 00 en fait
/// deux. Les secondes ne comptent pas : 12 h 00 min 40 s est encore 12 h 00.
int heuresDeDepassement(DateTime maintenant, DateTime limite) {
  final minutes = maintenant.difference(limite).inMinutes;
  if (minutes <= 0) return 0;
  return (minutes + 59) ~/ 60;
}

/// « 12 h », « 15 h » : l'heure d'une limite, sans les minutes.
String formatHeure(DateTime instant) => '${instant.hour} h';
