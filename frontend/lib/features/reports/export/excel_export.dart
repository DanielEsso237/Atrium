/// Le classeur Excel d'un rapport : une feuille par bloc.
///
/// Les montants restent des nombres (format `# ##0 FCFA`), pas du texte :
/// le comptable doit pouvoir les additionner, les trier, les reprendre dans
/// ses propres tableaux.
library;

import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../../core/formats.dart';
import 'export_model.dart';

Uint8List construireExcel(DocumentRapport doc) {
  final classeur = Excel.createExcel();
  final parDefaut = classeur.getDefaultSheet() ?? 'Sheet1';
  final noms = <String>{};

  for (final section in doc.sections) {
    final nom = _nomFeuille(section.titre, noms);
    noms.add(nom);
    _feuille(classeur[nom], doc, section);
  }
  if (!noms.contains(parDefaut)) classeur.delete(parDefaut);
  classeur.setDefaultSheet(noms.first);

  return Uint8List.fromList(classeur.encode()!);
}

final _titre = CellStyle(
  bold: true,
  fontSize: 14,
  fontColorHex: ExcelColor.fromHexString('#143894'),
);
final _discret = CellStyle(
  italic: true,
  fontColorHex: ExcelColor.fromHexString('#5E6880'),
);
final _sousTitre = CellStyle(
  bold: true,
  fontSize: 12,
  fontColorHex: ExcelColor.fromHexString('#1C2333'),
);

CellStyle _entete(bool aDroite) => CellStyle(
  bold: true,
  fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
  backgroundColorHex: ExcelColor.fromHexString('#143894'),
  horizontalAlign: aDroite ? HorizontalAlign.Right : HorizontalAlign.Left,
);

CellStyle _cellule(Unite unite, {bool total = false}) => CellStyle(
  bold: total,
  backgroundColorHex: total
      ? ExcelColor.fromHexString('#E3EAFA')
      : ExcelColor.none,
  horizontalAlign: unite == Unite.texte
      ? HorizontalAlign.Left
      : HorizontalAlign.Right,
  numberFormat: switch (unite) {
    Unite.montant => NumFormat.custom(formatCode: '#,##0 "FCFA"'),
    Unite.nombre => NumFormat.standard_3,
    Unite.pourcentage || Unite.pointsDeBase => NumFormat.custom(
      formatCode: '0.0%',
    ),
    Unite.dixiemes => NumFormat.custom(formatCode: '0.0'),
    Unite.texte => NumFormat.standard_0,
  },
);

CellValue? _valeur(Object? v, Unite unite) {
  if (v == null) return null;
  if (v is! int) return TextCellValue('$v');
  return switch (unite) {
    Unite.pourcentage => DoubleCellValue(v / 100),
    Unite.pointsDeBase => DoubleCellValue(v / 10000),
    Unite.dixiemes => DoubleCellValue(v / 10),
    Unite.texte => TextCellValue('$v'),
    _ => IntCellValue(v),
  };
}

void _feuille(Sheet f, DocumentRapport doc, Section s) {
  var ligne = 0;
  void ecrire(int col, CellValue? v, CellStyle style) => f.updateCell(
    CellIndex.indexByColumnRow(columnIndex: col, rowIndex: ligne),
    v,
    cellStyle: style,
  );

  ecrire(0, TextCellValue('${doc.hotel} : ${s.titre}'), _titre);
  ligne++;
  ecrire(0, TextCellValue(doc.periode), _sousTitre);
  ligne++;
  if (doc.filtres.isNotEmpty) {
    ecrire(0, TextCellValue('Filtres : ${doc.filtres.join(', ')}'), _discret);
    ligne++;
  }
  ecrire(
    0,
    TextCellValue(
      'Établi le ${formatLongDate(doc.etabliLe)} à '
      '${doc.etabliLe.hour.toString().padLeft(2, '0')} h '
      '${doc.etabliLe.minute.toString().padLeft(2, '0')}',
    ),
    _discret,
  );
  ligne++;
  ecrire(0, TextCellValue(s.description), _discret);
  ligne += 2;

  var largeurs = <int, int>{0: 28};
  void mesurer(int col, String texte) {
    final l = texte.length + 2;
    if (l > (largeurs[col] ?? 12)) largeurs[col] = l;
  }

  if (s.chiffres.isNotEmpty) {
    ecrire(0, TextCellValue('Chiffres clés'), _sousTitre);
    ligne++;
    for (final c in s.chiffres) {
      ecrire(0, TextCellValue(c.libelle), CellStyle());
      ecrire(1, _valeur(c.valeur, c.unite), _cellule(c.unite));
      if (c.detail != null) ecrire(2, TextCellValue(c.detail!), _discret);
      mesurer(0, c.libelle);
      mesurer(1, c.texte);
      ligne++;
    }
    ligne++;
  }

  for (final t in s.tableaux) {
    ecrire(0, TextCellValue(t.titre), _sousTitre);
    ligne++;
    for (var i = 0; i < t.colonnes.length; i++) {
      final c = t.colonnes[i];
      ecrire(i, TextCellValue(c.titre), _entete(c.aDroite));
      mesurer(i, c.titre);
    }
    ligne++;
    for (final l in [...t.lignes, ?t.total]) {
      final total = identical(l, t.total);
      for (var i = 0; i < t.colonnes.length; i++) {
        final u = t.colonnes[i].unite;
        // La premiere cellule d'un total est un libelle, quelle que soit
        // l'unite de la colonne.
        ecrire(i, _valeur(l[i], i == 0 ? Unite.texte : u),
            _cellule(i == 0 ? Unite.texte : u, total: total));
        mesurer(i, formaterValeur(l[i], i == 0 ? Unite.texte : u));
      }
      ligne++;
    }
    ligne++;
  }

  if (s.tableaux.isEmpty && s.graphique != null) {
    // Un bloc sans tableau exporte au moins les points de son graphique.
    final g = s.graphique!;
    ecrire(0, TextCellValue('Données du graphique'), _sousTitre);
    ligne++;
    ecrire(0, TextCellValue(''), _entete(false));
    for (var i = 0; i < g.series.length; i++) {
      ecrire(i + 1, TextCellValue(g.series[i].libelle), _entete(true));
    }
    ligne++;
    for (var k = 0; k < g.etiquettes.length; k++) {
      ecrire(0, TextCellValue(g.etiquettes[k]), CellStyle());
      for (var i = 0; i < g.series.length; i++) {
        ecrire(i + 1, _valeur(g.series[i].valeurs[k], g.unite),
            _cellule(g.unite));
      }
      ligne++;
    }
  }

  largeurs = {for (final e in largeurs.entries) e.key: e.value.clamp(10, 48)};
  for (final e in largeurs.entries) {
    f.setColumnWidth(e.key, e.value.toDouble());
  }
}

/// Un nom de feuille valide et unique : 31 caracteres au plus, sans les
/// signes qu'Excel refuse.
String _nomFeuille(String titre, Set<String> pris) {
  var base = titre.replaceAll(RegExp(r'[\[\]\*\?/\\:]'), ' ').trim();
  if (base.length > 28) base = base.substring(0, 28).trim();
  var nom = base;
  for (var i = 2; pris.contains(nom); i++) {
    nom = '$base $i';
  }
  return nom;
}
