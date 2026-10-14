/// La recherche des listes : une seule regle pour tous les ecrans.
///
/// On tape comme on parle : « mballa 102 », « castel bar », « eneo ». Chaque
/// mot doit se retrouver dans un des champs de la ligne, dans n'importe quel
/// ordre ; les accents et les majuscules ne comptent pas, et un numero se
/// trouve meme ecrit autrement (« 677 41 » trouve « +237 677 41 20 18 »).
library;

const _accents = {
  'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ã': 'a',
  'ç': 'c',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'î': 'i', 'ï': 'i', 'í': 'i',
  'ô': 'o', 'ö': 'o', 'ó': 'o', 'õ': 'o',
  'ù': 'u', 'û': 'u', 'ü': 'u', 'ú': 'u',
  'ÿ': 'y', 'ñ': 'n', 'œ': 'oe', 'æ': 'ae',
  '’': "'",
};

/// En minuscules et sans accents.
String sansAccents(String texte) {
  final bas = texte.toLowerCase();
  final tampon = StringBuffer();
  for (final c in bas.split('')) {
    tampon.write(_accents[c] ?? c);
  }
  return tampon.toString();
}

/// Une recherche preparee une fois, appliquee a chaque ligne.
class Recherche {
  Recherche(String texte)
    : mots = [
        for (final m in sansAccents(texte).split(RegExp(r'\s+')))
          if (m.isNotEmpty) m,
      ];

  final List<String> mots;

  bool get vide => mots.isEmpty;

  /// Vrai si chaque mot se retrouve dans un des [champs]. Une recherche vide
  /// garde tout.
  bool garde(Iterable<String?> champs) {
    if (mots.isEmpty) return true;
    final textes = [
      for (final c in champs)
        if (c != null && c.isNotEmpty) sansAccents(c),
    ];
    final chiffres = [for (final t in textes) t.replaceAll(RegExp(r'\D'), '')];
    for (final mot in mots) {
      final numero = mot.replaceAll(RegExp(r'\D'), '');
      // Un mot fait de chiffres se cherche aussi sans les espaces ni les
      // signes qui les separent.
      final trouve =
          textes.any((t) => t.contains(mot)) ||
          (numero.length >= 2 &&
              numero.length == mot.replaceAll(RegExp(r'[\s.+-]'), '').length &&
              chiffres.any((t) => t.contains(numero)));
      if (!trouve) return false;
    }
    return true;
  }
}
