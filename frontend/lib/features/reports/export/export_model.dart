/// Ce qu'un export contient, independamment de son format.
///
/// Un bloc du rapport se decrit une fois -- ses chiffres, son graphique,
/// ses tableaux -- et le PDF comme le classeur Excel le mettent en forme.
/// Deux descriptions separees finiraient par ne plus dire la meme chose.
library;

import '../../../core/formats.dart';

/// Comment lire et mettre en forme une valeur.
enum Unite {
  texte,

  /// Francs CFA, entiers.
  montant,
  nombre,

  /// Pourcentage entier (68 -> 68 %).
  pourcentage,

  /// Points de base (1850 -> 18,5 %).
  pointsDeBase,

  /// Dixiemes (23 -> 2,3) : une duree moyenne sans flottant en chemin.
  dixiemes,
}

/// Une valeur lisible par un humain, en francais.
String formaterValeur(Object? v, Unite unite) {
  if (v == null) return '';
  // Un texte dans une colonne chiffree : « sans repère », par exemple.
  if (v is String) return v;
  return switch (unite) {
    Unite.texte => '$v',
    Unite.montant => formatAmount(v as int),
    Unite.nombre => formatNombre(v as int),
    Unite.pourcentage => '$v %',
    Unite.pointsDeBase => formatPointsDeBase(v as int),
    Unite.dixiemes => formatDixiemes(v as int),
  };
}

/// 23 -> `2,3`.
String formatDixiemes(int d) {
  final reste = d.abs() % 10;
  final signe = d < 0 ? '-' : '';
  return reste == 0 ? '$signe${d.abs() ~/ 10}' : '$signe${d.abs() ~/ 10},$reste';
}

/// 12500 -> `12 500`, l'espace insecable des montants.
String formatNombre(int n) {
  final montant = formatAmount(n);
  return montant.substring(0, montant.length - ' FCFA'.length);
}

/// 1850 -> `18,5 %`.
String formatPointsDeBase(int bp) {
  final entier = bp ~/ 100;
  final reste = (bp.abs() % 100) ~/ 10;
  final signe = bp < 0 && entier == 0 ? '-' : '';
  return reste == 0
      ? '$signe$entier %'
      : '$signe$entier,$reste %';
}

class Colonne {
  const Colonne(this.titre, [this.unite = Unite.texte, this.droite = false]);

  final String titre;
  final Unite unite;

  /// Des chiffres deja mis en forme (texte) s'alignent quand meme a droite.
  final bool droite;

  bool get aDroite => droite || unite != Unite.texte;
}

class Tableau {
  const Tableau({
    required this.titre,
    required this.colonnes,
    required this.lignes,
    this.total,
  });

  final String titre;
  final List<Colonne> colonnes;
  final List<List<Object?>> lignes;

  /// La ligne de total, mise en evidence ; `null` quand un total n'a pas de
  /// sens (un stock ne s'additionne pas d'un produit a l'autre).
  final List<Object?>? total;
}

/// Un chiffre mis en avant : libelle, valeur, et ce qu'il signifie.
class Chiffre {
  const Chiffre(this.libelle, this.valeur, this.unite, {this.detail});

  final String libelle;
  final int valeur;
  final Unite unite;
  final String? detail;

  String get texte => formaterValeur(valeur, unite);
}

enum TypeGraphique { courbe, barres }

class Serie {
  const Serie(this.libelle, this.valeurs, this.couleur);

  final String libelle;
  final List<int> valeurs;

  /// ARGB, pour que le PDF et l'ecran gardent la meme couleur.
  final int couleur;
}

class Graphique {
  const Graphique({
    required this.type,
    required this.etiquettes,
    required this.series,
    required this.unite,
  });

  final TypeGraphique type;
  final List<String> etiquettes;
  final List<Serie> series;
  final Unite unite;
}

/// Un bloc du rapport : ce qu'exporte le bouton d'une carte.
class Section {
  const Section({
    required this.titre,
    required this.description,
    this.chiffres = const [],
    this.graphique,
    this.tableaux = const [],
  });

  final String titre;

  /// Ce que le bloc mesure et quels filtres il suit, en une phrase.
  final String description;
  final List<Chiffre> chiffres;
  final Graphique? graphique;
  final List<Tableau> tableaux;
}

/// Un export complet : en-tete commun et un ou plusieurs blocs.
class DocumentRapport {
  const DocumentRapport({
    required this.titre,
    required this.hotel,
    required this.periode,
    required this.filtres,
    required this.etabliLe,
    required this.sections,
  });

  final String titre;
  final String hotel;
  final String periode;

  /// Les filtres retenus, en clair ; vide quand rien n'est filtre.
  final List<String> filtres;
  final DateTime etabliLe;
  final List<Section> sections;

  /// `rapport-financier_2026-10-01_2026-10-09`, sans accent ni espace :
  /// certains logiciels de messagerie abiment les noms de fichiers.
  String nomFichier(String debut, String fin) {
    final base = titre
        .toLowerCase()
        .replaceAll(RegExp('[àâä]'), 'a')
        .replaceAll(RegExp('[éèêë]'), 'e')
        .replaceAll(RegExp('[îï]'), 'i')
        .replaceAll(RegExp('[ôö]'), 'o')
        .replaceAll(RegExp('[ùûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp('^-|-\$'), '');
    return debut == fin ? '${base}_$debut' : '${base}_${debut}_$fin';
  }
}
