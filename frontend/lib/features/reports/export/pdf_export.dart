/// Le PDF d'un rapport : lisible a l'ecran comme imprime, en francais.
///
/// Des chiffres et des tableaux, sans graphique : le document part chez le
/// comptable ou la direction, qui recopient et recalculent. Les graphiques
/// restent a l'ecran, ou ils se touchent. L'en-tete reprend celui de la
/// facture : le logo et les coordonnees de l'hotel.
///
/// La police de l'application (Plus Jakarta Sans) est embarquee : les
/// polices standard du PDF ne connaissent pas toutes les lettres accentuees,
/// et un montant ecrit dans une autre police que l'ecran ne se relit pas
/// pareil.
library;

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
  const petit = pw.TextStyle(fontSize: 8.5, color: _gris);
  final logo = doc.logo;
  return pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 14),
    margin: const pw.EdgeInsets.only(bottom: 18),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _bleu, width: 2)),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (logo != null) ...[
                    pw.Container(
                      height: 52,
                      constraints: const pw.BoxConstraints(maxWidth: 170),
                      alignment: pw.Alignment.centerLeft,
                      child: pw.Image(
                        pw.MemoryImage(logo),
                        fit: pw.BoxFit.contain,
                      ),
                    ),
                    pw.SizedBox(height: 8),
                  ],
                  pw.Text(
                    doc.hotel,
                    style: pw.TextStyle(
                      fontSize: logo == null ? 16 : 12,
                      fontWeight: pw.FontWeight.bold,
                      color: _encre,
                    ),
                  ),
                  for (final l in doc.coordonnees) pw.Text(l, style: petit),
                ],
              ),
            ),
            pw.SizedBox(width: 16),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  doc.titre,
                  style: pw.TextStyle(
                    fontSize: 20,
                    fontWeight: pw.FontWeight.bold,
                    color: _bleu,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  doc.periode,
                  style: const pw.TextStyle(fontSize: 11, color: _encre),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  'Établi le ${formatLongDate(h)} à $heure',
                  style: petit,
                ),
              ],
            ),
          ],
        ),
        if (doc.filtres.isNotEmpty) ...[
          pw.SizedBox(height: 10),
          pw.Text('Filtres : ${doc.filtres.join(', ')}', style: petit),
        ],
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
  // Un bloc sans tableau livre au moins les points de son graphique.
  if (s.tableaux.isEmpty && s.graphique != null) ...[
    pw.SizedBox(height: 14),
    ..._tableau(_tableauDuGraphique(s.graphique!)),
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

Tableau _tableauDuGraphique(Graphique g) => Tableau(
  titre: 'Détail',
  colonnes: [
    const Colonne(''),
    for (final serie in g.series) Colonne(serie.libelle, g.unite),
  ],
  lignes: [
    for (var k = 0; k < g.etiquettes.length; k++)
      [g.etiquettes[k], for (final serie in g.series) serie.valeurs[k]],
  ],
);

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
