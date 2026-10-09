/// Le PDF d'un rapport : lisible a l'ecran comme imprime, en francais.
///
/// La police de l'application (Plus Jakarta Sans) est embarquee : les
/// polices standard du PDF ne connaissent pas toutes les lettres accentuees,
/// et un montant ecrit dans une autre police que l'ecran ne se relit pas
/// pareil.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/formats.dart';
import 'export_model.dart';

const _bleu = PdfColor.fromInt(0xFF143894);
const _encre = PdfColor.fromInt(0xFF1C2333);
const _gris = PdfColor.fromInt(0xFF5E6880);
const _filet = PdfColor.fromInt(0xFFE1E6F0);
const _fond = PdfColor.fromInt(0xFFF4F6FB);
const _fondTotal = PdfColor.fromInt(0xFFE3EAFA);

Future<Uint8List> construirePdf(DocumentRapport doc) async {
  final normale = pw.Font.ttf(
    await rootBundle.load('assets/fonts/jakarta/PlusJakartaSans-400.ttf'),
  );
  final grasse = pw.Font.ttf(
    await rootBundle.load('assets/fonts/jakarta/PlusJakartaSans-700.ttf'),
  );
  final pdf = pw.Document(
    title: '${doc.titre} : ${doc.periode}',
    author: doc.hotel,
    creator: 'Atrium',
    theme: pw.ThemeData.withFont(base: normale, bold: grasse),
  );

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 30),
      footer: (context) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 12),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              '${doc.hotel}, ${doc.titre.toLowerCase()}',
              style: const pw.TextStyle(fontSize: 8, color: _gris),
            ),
            pw.Text(
              'Page ${context.pageNumber} sur ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: _gris),
            ),
          ],
        ),
      ),
      build: (context) => [
        _enTete(doc),
        for (final s in doc.sections) ..._section(s),
      ],
    ),
  );
  return pdf.save();
}

pw.Widget _enTete(DocumentRapport doc) {
  final h = doc.etabliLe;
  final heure =
      '${h.hour.toString().padLeft(2, '0')} h ${h.minute.toString().padLeft(2, '0')}';
  return pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 14),
    margin: const pw.EdgeInsets.only(bottom: 18),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _bleu, width: 2)),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                doc.hotel,
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: _bleu,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                doc.titre,
                style: pw.TextStyle(
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                  color: _encre,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                doc.periode,
                style: const pw.TextStyle(fontSize: 12, color: _encre),
              ),
              if (doc.filtres.isNotEmpty) ...[
                pw.SizedBox(height: 3),
                pw.Text(
                  'Filtres : ${doc.filtres.join(', ')}',
                  style: const pw.TextStyle(fontSize: 9, color: _gris),
                ),
              ],
            ],
          ),
        ),
        pw.Text(
          'Établi le ${formatLongDate(h)}\nà $heure',
          textAlign: pw.TextAlign.right,
          style: const pw.TextStyle(fontSize: 8.5, color: _gris),
        ),
      ],
    ),
  );
}

List<pw.Widget> _section(Section s) => [
  pw.Header(
    level: 1,
    margin: const pw.EdgeInsets.only(top: 6, bottom: 4),
    padding: pw.EdgeInsets.zero,
    decoration: const pw.BoxDecoration(),
    child: pw.Text(
      s.titre,
      style: pw.TextStyle(
        fontSize: 15,
        fontWeight: pw.FontWeight.bold,
        color: _bleu,
      ),
    ),
  ),
  pw.Text(s.description, style: const pw.TextStyle(fontSize: 9, color: _gris)),
  pw.SizedBox(height: 10),
  if (s.chiffres.isNotEmpty) _chiffres(s.chiffres),
  if (s.graphique case final g?) ...[
    pw.SizedBox(height: 12),
    _graphique(g),
  ],
  for (final t in s.tableaux) ...[pw.SizedBox(height: 14), ..._tableau(t)],
  pw.SizedBox(height: 22),
];

pw.Widget _chiffres(List<Chiffre> chiffres) => pw.LayoutBuilder(
  builder: (context, contraintes) {
    const ecart = 8.0;
    final largeur = (contraintes!.maxWidth - 2 * ecart) / 3;
    return pw.Wrap(
      spacing: ecart,
      runSpacing: ecart,
      children: [
        for (final c in chiffres)
          pw.Container(
            width: largeur,
            padding: const pw.EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: _filet),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  c.libelle,
                  style: const pw.TextStyle(fontSize: 8.5, color: _gris),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  c.texte,
                  style: pw.TextStyle(
                    fontSize: 13,
                    fontWeight: pw.FontWeight.bold,
                    color: c.valeur < 0
                        ? const PdfColor.fromInt(0xFFD2423B)
                        : _encre,
                  ),
                ),
                if (c.detail != null) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    c.detail!,
                    style: const pw.TextStyle(fontSize: 7.5, color: _gris),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  },
);

pw.Widget _graphique(Graphique g) {
  final valeurs = [for (final s in g.series) ...s.valeurs];
  if (valeurs.isEmpty || valeurs.every((v) => v == 0)) {
    return pw.Text(
      'Aucune donnée à représenter sur la période.',
      style: const pw.TextStyle(fontSize: 9, color: _gris),
    );
  }
  return switch (g.type) {
    // Une courbe d'un seul point ne montre aucune pente : les barres disent
    // la meme chose sans tromper.
    TypeGraphique.courbe when g.etiquettes.length >= 2 => _courbe(g),
    _ => _barres(g),
  };
}

/// Des graduations rondes qui couvrent les valeurs, zero compris.
List<int> _graduations(int mini, int maxi) {
  final int bas = math.min(0, mini);
  final int haut = math.max(maxi, 1);
  final brut = (haut - bas) / 4;
  final int puissance = math.max(
    1,
    math.pow(10, (math.log(brut) / math.ln10).floor()).toInt(),
  );
  var pas = 10 * puissance;
  for (final m in const [1, 2, 5]) {
    if (m * puissance >= brut) {
      pas = m * puissance;
      break;
    }
  }
  final int debut = (bas / pas).floor() * pas;
  return [for (var v = debut; v < haut + pas; v += pas) v];
}

String _court(num v, Unite unite) {
  if (unite == Unite.pourcentage) return '${v.toInt()} %';
  final n = v.toInt();
  if (n.abs() >= 1000000) {
    final m = n / 1000000;
    return '${m.toStringAsFixed(m.abs() >= 10 ? 0 : 1).replaceAll('.', ',')} M';
  }
  if (n.abs() >= 1000) return '${(n / 1000).round()} k';
  return '$n';
}

pw.Widget _courbe(Graphique g) {
  final n = g.etiquettes.length;
  final pas = (n / 10).ceil();
  final etiquettes = [
    for (var i = 0; i < n; i++)
      i % pas == 0 || i == n - 1 ? g.etiquettes[i] : '',
  ];
  final valeurs = [for (final s in g.series) ...s.valeurs];
  final graduations = _graduations(
    valeurs.reduce(math.min),
    valeurs.reduce(math.max),
  );
  const style = pw.TextStyle(fontSize: 7, color: _gris);

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.SizedBox(
        height: 170,
        child: pw.Chart(
          grid: pw.CartesianGrid(
            xAxis: pw.FixedAxis.fromStrings(
              etiquettes,
              marginStart: 8,
              marginEnd: 8,
              ticks: true,
              textStyle: style,
              color: _filet,
            ),
            yAxis: pw.FixedAxis(
              graduations,
              format: (v) => _court(v, g.unite),
              divisions: true,
              divisionsColor: _filet,
              divisionsWidth: 0.5,
              textStyle: style,
              color: _filet,
            ),
          ),
          datasets: [
            for (final s in g.series)
              pw.LineDataSet(
                legend: s.libelle,
                color: PdfColor.fromInt(s.couleur),
                lineWidth: 1.6,
                drawPoints: n <= 31,
                pointSize: 1.8,
                isCurved: true,
                smoothness: 0.2,
                drawSurface: g.series.length == 1,
                surfaceOpacity: 0.12,
                data: [
                  for (var i = 0; i < n; i++)
                    pw.PointChartValue(i.toDouble(), s.valeurs[i].toDouble()),
                ],
              ),
          ],
        ),
      ),
      if (g.series.length > 1) ...[
        pw.SizedBox(height: 6),
        pw.Row(
          children: [
            for (final s in g.series) ...[
              pw.Container(
                width: 10,
                height: 3,
                color: PdfColor.fromInt(s.couleur),
              ),
              pw.SizedBox(width: 4),
              pw.Text(s.libelle, style: const pw.TextStyle(fontSize: 8)),
              pw.SizedBox(width: 14),
            ],
          ],
        ),
      ],
    ],
  );
}

/// Barres horizontales : le libelle se lit en entier, quelle que soit sa
/// longueur, ce qu'un axe incline ne permet pas.
pw.Widget _barres(Graphique g) {
  final s = g.series.first;
  final maxi = s.valeurs.map((v) => v.abs()).fold(0, math.max);
  return pw.LayoutBuilder(
    builder: (context, c) {
      final largeurBarre = c!.maxWidth * 0.5;
      return pw.Column(
        children: [
          for (var i = 0; i < g.etiquettes.length; i++)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
              child: pw.Row(
                children: [
                  pw.SizedBox(
                    width: c.maxWidth * 0.27,
                    child: pw.Text(
                      g.etiquettes[i],
                      maxLines: 1,
                      style: const pw.TextStyle(fontSize: 8.5, color: _encre),
                    ),
                  ),
                  pw.Container(
                    width: maxi == 0
                        ? 0
                        : math.max(1.5, largeurBarre * s.valeurs[i].abs() / maxi),
                    height: 9,
                    decoration: pw.BoxDecoration(
                      color: s.valeurs[i] < 0
                          ? const PdfColor.fromInt(0xFFD2423B)
                          : PdfColor.fromInt(s.couleur),
                      borderRadius: pw.BorderRadius.circular(2),
                    ),
                  ),
                  pw.SizedBox(width: 6),
                  pw.Text(
                    formaterValeur(s.valeurs[i], g.unite),
                    style: pw.TextStyle(
                      fontSize: 8.5,
                      fontWeight: pw.FontWeight.bold,
                      color: _encre,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}

List<pw.Widget> _tableau(Tableau t) {
  pw.Widget cellule(
    String texte, {
    required bool aDroite,
    bool entete = false,
    bool gras = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4.5),
    child: pw.Text(
      texte,
      textAlign: aDroite ? pw.TextAlign.right : pw.TextAlign.left,
      style: pw.TextStyle(
        fontSize: entete ? 8 : 8.5,
        fontWeight: entete || gras ? pw.FontWeight.bold : pw.FontWeight.normal,
        color: entete ? PdfColors.white : _encre,
      ),
    ),
  );

  String texte(Object? v, int i) =>
      formaterValeur(v, i == 0 ? Unite.texte : t.colonnes[i].unite);

  return [
    pw.Text(
      t.titre,
      style: pw.TextStyle(
        fontSize: 10.5,
        fontWeight: pw.FontWeight.bold,
        color: _encre,
      ),
    ),
    pw.SizedBox(height: 5),
    if (t.lignes.isEmpty)
      pw.Text(
        'Rien à afficher sur la période.',
        style: const pw.TextStyle(fontSize: 9, color: _gris),
      )
    else
      pw.Table(
        columnWidths: {
          0: const pw.FlexColumnWidth(2.2),
          for (var i = 1; i < t.colonnes.length; i++)
            i: const pw.FlexColumnWidth(1),
        },
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: _filet, width: 0.5),
        ),
        children: [
          pw.TableRow(
            repeat: true,
            decoration: const pw.BoxDecoration(color: _bleu),
            children: [
              for (var i = 0; i < t.colonnes.length; i++)
                cellule(
                  t.colonnes[i].titre,
                  aDroite: t.colonnes[i].aDroite,
                  entete: true,
                ),
            ],
          ),
          for (var k = 0; k < t.lignes.length; k++)
            pw.TableRow(
              decoration: pw.BoxDecoration(
                color: k.isOdd ? _fond : PdfColors.white,
              ),
              children: [
                for (var i = 0; i < t.colonnes.length; i++)
                  cellule(
                    texte(t.lignes[k][i], i),
                    aDroite: t.colonnes[i].aDroite,
                  ),
              ],
            ),
          if (t.total case final total?)
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: _fondTotal),
              children: [
                for (var i = 0; i < t.colonnes.length; i++)
                  cellule(
                    texte(total[i], i),
                    aDroite: t.colonnes[i].aDroite,
                    gras: true,
                  ),
              ],
            ),
        ],
      ),
  ];
}
