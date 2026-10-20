/// L'apercu d'un rapport a l'ecran (F3.3, 19 octobre) : la feuille telle
/// qu'elle sortira en PDF -- l'en-tete de l'hotel avec son logo et ses
/// coordonnees, le titre, la periode, les filtres, chaque bloc avec ses
/// chiffres et ses tableaux, puis les cases de signature.
///
/// Les couleurs sont celles du papier, en clair comme en sombre : c'est un
/// document, pas un ecran. Elles reprennent celles du PDF
/// (`pdf_export.dart`) pour que l'apercu ne promette rien d'autre.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../core/tokens.dart';
import 'export/export_model.dart';

const _bleu = Color(0xFF143894);
const _encre = Color(0xFF1C2333);
const _gris = Color(0xFF5E6880);
const _filet = Color(0xFFE1E6F0);
const _fond = Color(0xFFF4F6FB);
const _fondTotal = Color(0xFFE3EAFA);
const _rouge = Color(0xFFD2423B);

/// Au-dela, l'apercu s'arrete et dit combien de lignes suivent : l'export,
/// lui, les contient toutes.
const _lignesApercu = 80;

TextStyle _style(double taille, {Color couleur = _encre, bool gras = false}) =>
    TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: taille,
      fontWeight: gras ? FontWeight.w700 : FontWeight.w400,
      color: couleur,
      height: 1.35,
      fontFeatures: tabularFigures,
    );

class ApercuDocument extends StatelessWidget {
  const ApercuDocument({super.key, required this.doc});

  final DocumentRapport doc;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, zone) {
        final etroit = zone.maxWidth < 600;
        return Container(
          padding: EdgeInsets.all(etroit ? 20 : 40),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _filet),
            boxShadow: AtriumShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _EnTete(doc: doc, etroit: etroit),
              for (final s in doc.sections) _SectionApercu(section: s),
              if (doc.visas.isNotEmpty) _Signatures(doc: doc, etroit: etroit),
            ],
          ),
        );
      },
    );
  }
}

class _EnTete extends StatelessWidget {
  const _EnTete({required this.doc, required this.etroit});

  final DocumentRapport doc;
  final bool etroit;

  @override
  Widget build(BuildContext context) {
    final h = doc.etabliLe;
    final heure =
        '${h.hour.toString().padLeft(2, '0')} h ${h.minute.toString().padLeft(2, '0')}';
    final hotel = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (doc.logo != null) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170, maxHeight: 52),
            child: Image.memory(doc.logo!, fit: BoxFit.contain),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          doc.hotel,
          style: _style(doc.logo == null ? 18 : 14, gras: true),
        ),
        for (final l in doc.coordonnees)
          Text(l, style: _style(11, couleur: _gris)),
      ],
    );
    final titre = Column(
      crossAxisAlignment: etroit
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      children: [
        Text(
          doc.titre,
          textAlign: etroit ? TextAlign.left : TextAlign.right,
          style: _style(22, couleur: _bleu, gras: true),
        ),
        const SizedBox(height: 4),
        Text(doc.periode, style: _style(13)),
        const SizedBox(height: 4),
        Text(
          'Établi le ${formatLongDate(h)} à $heure'
          '${doc.etabliPar == null ? '' : ' par ${doc.etabliPar}'}',
          textAlign: etroit ? TextAlign.left : TextAlign.right,
          style: _style(11, couleur: _gris),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.only(bottom: 16),
      margin: const EdgeInsets.only(bottom: 22),
      // Le filet sous l'en-tete, comme sur la facture.
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _bleu, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (etroit) ...[hotel, const SizedBox(height: 16), titre]
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: hotel),
                const SizedBox(width: 16),
                Flexible(child: titre),
              ],
            ),
          if (doc.filtres.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Filtres : ${doc.filtres.join(', ')}',
              style: _style(11, couleur: _gris),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionApercu extends StatelessWidget {
  const _SectionApercu({required this.section});

  final Section section;

  @override
  Widget build(BuildContext context) {
    final s = section;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.titre, style: _style(17, couleur: _bleu, gras: true)),
          const SizedBox(height: 2),
          Text(s.description, style: _style(11.5, couleur: _gris)),
          const SizedBox(height: 12),
          if (s.chiffres.isNotEmpty) _Chiffres(chiffres: s.chiffres),
          for (final t in s.tableaux) ...[
            const SizedBox(height: 16),
            _TableauApercu(tableau: t),
          ],
        ],
      ),
    );
  }
}

class _Chiffres extends StatelessWidget {
  const _Chiffres({required this.chiffres});

  final List<Chiffre> chiffres;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, zone) {
      const ecart = 8.0;
      final colonnes = zone.maxWidth >= 520 ? 3 : 2;
      final largeur = (zone.maxWidth - ecart * (colonnes - 1)) / colonnes;
      return Wrap(
        spacing: ecart,
        runSpacing: ecart,
        children: [
          for (final c in chiffres)
            Container(
              width: largeur,
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
              decoration: BoxDecoration(
                border: Border.all(color: _filet),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.libelle, style: _style(11, couleur: _gris)),
                  const SizedBox(height: 2),
                  Text(
                    c.texte,
                    style: _style(
                      16,
                      gras: true,
                      couleur: c.valeur < 0 ? _rouge : _encre,
                    ),
                  ),
                  if (c.detail != null)
                    Text(c.detail!, style: _style(10, couleur: _gris)),
                ],
              ),
            ),
        ],
      );
    },
  );
}

class _TableauApercu extends StatelessWidget {
  const _TableauApercu({required this.tableau});

  final Tableau tableau;

  @override
  Widget build(BuildContext context) {
    final t = tableau;
    String texte(Object? v, int i) =>
        formaterValeur(v, i == 0 ? Unite.texte : t.colonnes[i].unite);
    Widget cellule(
      String s, {
      required bool aDroite,
      bool entete = false,
      bool gras = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Text(
        s,
        textAlign: aDroite ? TextAlign.right : TextAlign.left,
        style: _style(
          entete ? 11 : 11.5,
          gras: entete || gras,
          couleur: entete ? Colors.white : _encre,
        ),
      ),
    );
    final lignes = t.lignes.take(_lignesApercu).toList();
    final reste = t.lignes.length - lignes.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t.titre, style: _style(13, gras: true)),
        const SizedBox(height: 6),
        if (t.lignes.isEmpty)
          Text('Rien à afficher sur la période.', style: _style(11.5, couleur: _gris))
        else
          LayoutBuilder(
            builder: (context, zone) {
              // Trop etroit pour toutes les colonnes : le tableau garde sa
              // largeur et defile, au lieu d'ecraser les chiffres.
              final largeur = math.max(zone.maxWidth, t.colonnes.length * 96.0);
              final tableauLarge = SizedBox(
                width: largeur,
                child: Table(
                  columnWidths: {
                    for (var i = 0; i < t.colonnes.length; i++)
                      i: FlexColumnWidth(t.largeurs?[i] ?? (i == 0 ? 2.2 : 1)),
                  },
                  border: const TableBorder(
                    horizontalInside: BorderSide(color: _filet, width: 0.6),
                  ),
                  children: [
                    TableRow(
                      decoration: const BoxDecoration(color: _bleu),
                      children: [
                        for (var i = 0; i < t.colonnes.length; i++)
                          cellule(
                            t.colonnes[i].titre,
                            aDroite: t.colonnes[i].aDroite,
                            entete: true,
                          ),
                      ],
                    ),
                    for (var k = 0; k < lignes.length; k++)
                      TableRow(
                        decoration: BoxDecoration(
                          color: k.isOdd ? _fond : Colors.white,
                        ),
                        children: [
                          for (var i = 0; i < t.colonnes.length; i++)
                            cellule(
                              texte(lignes[k][i], i),
                              aDroite: t.colonnes[i].aDroite,
                            ),
                        ],
                      ),
                    if (t.total case final total?)
                      TableRow(
                        decoration: const BoxDecoration(color: _fondTotal),
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
              );
              return largeur > zone.maxWidth
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: tableauLarge,
                    )
                  : tableauLarge;
            },
          ),
        if (reste > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Et $reste ligne${reste > 1 ? 's' : ''} de plus, toutes dans '
              'l’export PDF ou Excel.',
              style: _style(11, couleur: _gris),
            ),
          ),
      ],
    );
  }
}

class _Signatures extends StatelessWidget {
  const _Signatures({required this.doc, required this.etroit});

  final DocumentRapport doc;
  final bool etroit;

  @override
  Widget build(BuildContext context) {
    Widget caseVisa(int i, String visa) => Container(
      height: 104,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: _filet),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(visa, style: _style(12, gras: true)),
          if (i == 0 && doc.etabliPar != null)
            Text(doc.etabliPar!, style: _style(12)),
          const Spacer(),
          Text('Date et signature', style: _style(10, couleur: _gris)),
        ],
      ),
    );
    final cases = [
      for (final (i, v) in doc.visas.indexed) caseVisa(i, v),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: etroit
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, c) in cases.indexed) ...[
                  if (i > 0) const SizedBox(height: 12),
                  c,
                ],
              ],
            )
          : Row(
              children: [
                for (final (i, c) in cases.indexed) ...[
                  if (i > 0) const SizedBox(width: 16),
                  Expanded(child: c),
                ],
              ],
            ),
    );
  }
}
