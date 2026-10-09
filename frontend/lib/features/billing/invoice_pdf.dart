/// La facture en PDF : une page A4 en couleur, ou un ticket de 80 mm en noir
/// et blanc pour les imprimantes thermiques.
///
/// Les deux portent le logo et les coordonnees de l'hotel, comme la facture a
/// l'ecran. Le ticket prend la version tramee du logo : une imprimante de
/// tickets ne sait faire que du noir.
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../core/formats.dart';
import '../../data/local/database.dart';
import '../../data/repositories/invoice_repository.dart';
import '../hotel/en_tete_hotel.dart';

const _encre = PdfColor.fromInt(0xFF1C2333);
const _gris = PdfColor.fromInt(0xFF5E6880);
const _bleu = PdfColor.fromInt(0xFF143894);
const _filet = PdfColor.fromInt(0xFFE1E6F0);

Future<pw.ThemeData> _theme() async => pw.ThemeData.withFont(
  base: pw.Font.ttf(
    await rootBundle.load('assets/fonts/jakarta/PlusJakartaSans-400.ttf'),
  ),
  bold: pw.Font.ttf(
    await rootBundle.load('assets/fonts/jakarta/PlusJakartaSans-700.ttf'),
  ),
);

String _date(DateTime? d) => d == null ? '' : formatShortDate(d.toLocal());

String _quantite(InvoiceLineRow l) =>
    l.quantity > 1 ? '${l.label} × ${l.quantity}' : l.label;

/// La facture sur une page A4, en couleur.
Future<Uint8List> factureA4({
  required InvoiceView vue,
  required HotelRow? hotel,
  required String client,
}) async {
  final f = vue.invoice;
  final logo = hotel?.logoData;
  final pdf = pw.Document(
    title: 'Facture ${vue.displayNumber}',
    author: hotel?.name,
    theme: await _theme(),
  );
  const petit = pw.TextStyle(fontSize: 9, color: _gris);

  pw.Widget ligneTotal(String libelle, int montant, {bool fort = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.end,
          children: [
            pw.Text(
              libelle,
              style: pw.TextStyle(
                fontSize: fort ? 12 : 10,
                color: fort ? _encre : _gris,
                fontWeight: fort ? pw.FontWeight.bold : pw.FontWeight.normal,
              ),
            ),
            pw.SizedBox(
              width: 120,
              child: pw.Text(
                formatAmount(montant),
                textAlign: pw.TextAlign.right,
                style: pw.TextStyle(
                  fontSize: fort ? 14 : 10,
                  fontWeight: fort ? pw.FontWeight.bold : pw.FontWeight.normal,
                  color: _encre,
                ),
              ),
            ),
          ],
        ),
      );

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 40, 40, 36),
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(hotel?.name ?? '', style: petit),
          pw.Text(
            'Page ${context.pageNumber} sur ${context.pagesCount}',
            style: petit,
          ),
        ],
      ),
      build: (context) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (logo != null) ...[
                    pw.Container(
                      height: 56,
                      constraints: const pw.BoxConstraints(maxWidth: 180),
                      alignment: pw.Alignment.centerLeft,
                      child: pw.Image(pw.MemoryImage(logo), fit: pw.BoxFit.contain),
                    ),
                    pw.SizedBox(height: 8),
                  ],
                  pw.Text(
                    hotel?.name ?? 'Hôtel',
                    style: pw.TextStyle(
                      fontSize: logo == null ? 18 : 13,
                      fontWeight: pw.FontWeight.bold,
                      color: _encre,
                    ),
                  ),
                  for (final l in lignesCoordonnees(hotel))
                    pw.Text(l, style: petit),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  'Facture',
                  style: pw.TextStyle(
                    fontSize: 20,
                    fontWeight: pw.FontWeight.bold,
                    color: _bleu,
                  ),
                ),
                pw.Text(
                  vue.displayNumber,
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: _encre,
                  ),
                ),
                if (f.issuedAt != null)
                  pw.Text('Émise le ${_date(f.issuedAt)}', style: petit),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 24),
        pw.Text('Facturé à', style: petit),
        pw.Text(
          f.billToName ?? client,
          style: pw.TextStyle(
            fontSize: 13,
            fontWeight: pw.FontWeight.bold,
            color: _encre,
          ),
        ),
        if (f.billToTaxId != null)
          pw.Text('N° contribuable ${f.billToTaxId}', style: petit),
        if (vue.provisional) ...[
          pw.SizedBox(height: 12),
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: const PdfColor.fromInt(0xFFFFF1D6),
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Text(
              'Numéro provisoire. Le numéro définitif sera attribué par le '
              'serveur dès que cette facture y sera remontée.',
              style: const pw.TextStyle(
                fontSize: 9,
                color: PdfColor.fromInt(0xFF6B4200),
              ),
            ),
          ),
        ],
        pw.SizedBox(height: 20),
        pw.Table(
          columnWidths: const {
            0: pw.FlexColumnWidth(4),
            1: pw.FlexColumnWidth(1),
            2: pw.FlexColumnWidth(1.6),
            3: pw.FlexColumnWidth(1.6),
          },
          border: const pw.TableBorder(
            horizontalInside: pw.BorderSide(color: _filet, width: 0.5),
            bottom: pw.BorderSide(color: _filet, width: 0.5),
          ),
          children: [
            pw.TableRow(
              repeat: true,
              decoration: const pw.BoxDecoration(color: _bleu),
              children: [
                for (final (t, droite) in const [
                  ('Désignation', false),
                  ('Qté', true),
                  ('Prix unitaire', true),
                  ('Montant', true),
                ])
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: pw.Text(
                      t,
                      textAlign: droite ? pw.TextAlign.right : pw.TextAlign.left,
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.white,
                      ),
                    ),
                  ),
              ],
            ),
            for (final l in vue.lines)
              pw.TableRow(
                children: [
                  for (final (t, droite) in [
                    (l.label, false),
                    ('${l.quantity}', true),
                    (formatAmount(l.unitPrice), true),
                    (formatAmount(l.amount), true),
                  ])
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(6),
                      child: pw.Text(
                        t,
                        textAlign: droite ? pw.TextAlign.right : pw.TextAlign.left,
                        style: const pw.TextStyle(fontSize: 10, color: _encre),
                      ),
                    ),
                ],
              ),
          ],
        ),
        pw.SizedBox(height: 12),
        if (f.discountTotal != 0) ligneTotal('Remises', -f.discountTotal.abs()),
        if (f.taxTotal != 0) ligneTotal('Dont taxes', f.taxTotal),
        ligneTotal('Total TTC', f.total, fort: true),
        pw.SizedBox(height: 28),
        pw.Text('Merci de votre visite.', style: petit),
      ],
    ),
  );
  return pdf.save();
}

/// La facture en ticket de 80 mm, noir sur blanc.
Future<Uint8List> factureTicket({
  required InvoiceView vue,
  required HotelRow? hotel,
  required String client,
  Uint8List? logoNoirBlanc,
}) async {
  final f = vue.invoice;
  final pdf = pw.Document(
    title: 'Ticket ${vue.displayNumber}',
    author: hotel?.name,
    theme: await _theme(),
  );
  const noir = PdfColors.black;
  const texte = pw.TextStyle(fontSize: 8.5, color: noir);
  pw.Widget tirets() => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 5),
    child: pw.Divider(
      height: 1,
      thickness: 0.6,
      color: noir,
      borderStyle: pw.BorderStyle.dashed,
    ),
  );
  pw.Widget ligne(String gauche, String droite, {bool fort = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Text(
                gauche,
                style: fort
                    ? pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)
                    : texte,
              ),
            ),
            pw.Text(
              droite,
              style: fort
                  ? pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)
                  : texte,
            ),
          ],
        ),
      );

  pdf.addPage(
    pw.Page(
      // Un rouleau de 80 mm, de la longueur qu'il faut.
      pageFormat: PdfPageFormat.roll80.copyWith(
        marginLeft: 3 * PdfPageFormat.mm,
        marginRight: 3 * PdfPageFormat.mm,
        marginTop: 4 * PdfPageFormat.mm,
        marginBottom: 6 * PdfPageFormat.mm,
      ),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          if (logoNoirBlanc != null) ...[
            pw.Center(
              child: pw.Container(
                width: 46 * PdfPageFormat.mm,
                height: 20 * PdfPageFormat.mm,
                child: pw.Image(
                  pw.MemoryImage(logoNoirBlanc),
                  fit: pw.BoxFit.contain,
                ),
              ),
            ),
            pw.SizedBox(height: 4),
          ],
          pw.Text(
            hotel?.name ?? 'Hôtel',
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
          ),
          for (final l in lignesCoordonnees(hotel))
            pw.Text(l, textAlign: pw.TextAlign.center, style: texte),
          tirets(),
          ligne('Facture', vue.displayNumber),
          if (f.issuedAt != null) ligne('Date', _date(f.issuedAt)),
          ligne('Client', f.billToName ?? client),
          tirets(),
          for (final l in vue.lines) ligne(_quantite(l), formatAmount(l.amount)),
          tirets(),
          if (f.taxTotal != 0) ligne('Dont taxes', formatAmount(f.taxTotal)),
          ligne('Total', formatAmount(f.total), fort: true),
          if (vue.provisional) ...[
            pw.SizedBox(height: 4),
            pw.Text(
              'Numéro provisoire, en attente du numéro définitif.',
              textAlign: pw.TextAlign.center,
              style: texte,
            ),
          ],
          pw.SizedBox(height: 6),
          pw.Text(
            'Merci de votre visite.',
            textAlign: pw.TextAlign.center,
            style: texte,
          ),
        ],
      ),
    ),
  );
  return pdf.save();
}

/// Remet le PDF : feuille de partage sur la tablette (imprimer, envoyer,
/// enregistrer), telechargement dans un navigateur.
Future<void> partagerPdf(
  Uint8List octets, {
  required String nom,
  required String sujet,
  Rect? origine,
}) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(octets, mimeType: 'application/pdf', name: '$nom.pdf')],
      fileNameOverrides: ['$nom.pdf'],
      subject: sujet,
      title: sujet,
      sharePositionOrigin: origine,
    ),
  );
}
