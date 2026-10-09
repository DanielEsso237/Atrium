/// Les traitements d'image du logo : le preparer a l'import, et en tirer la
/// version noir et blanc des tickets.
///
/// Une imprimante de tickets thermique ne connait que le noir : un logo en
/// couleur y sort en pave sombre ou disparait. On le ramene donc a du noir
/// sur blanc par un seuil choisi d'apres l'image elle-meme (methode d'Otsu).
/// Un tramage a ete essaye : sur un logo en aplats, il semait des points
/// dans les couleurs moyennes et le logo sortait pique au lieu de net.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../data/repositories/hotel_repository.dart';
import '../../data/repositories/repository_providers.dart';

/// Largeur d'un logo de ticket : 384 points, la tete d'une imprimante de
/// 58 mm a 203 dpi, et une bonne moitie de celle d'une 80 mm.
const largeurLogoTicket = 384;

/// Le plus grand cote garde a l'import : bien assez pour une tete de page A4.
const _coteMaxImport = 800;

/// Rend un logo pret a envoyer : reduit, recompresse au besoin, sous la
/// limite du serveur. Leve `StateError` si l'image est illisible.
///
/// Un PNG garde sa transparence tant qu'il tient dans la limite ; au-dela,
/// il devient un JPEG pose sur fond blanc -- le fond d'une facture.
Uint8List preparerLogo(Uint8List source) {
  final image = img.decodeImage(source);
  if (image == null) {
    throw StateError("Cette image ne se lit pas. Choisissez un PNG ou un JPEG.");
  }
  // Les marges vides autour du dessin, retirees : sans elles, le logo
  // occupe vraiment la place qui lui est donnee en tete de facture.
  final rognee = _rogner(image);
  final reduite = rognee.width > _coteMaxImport || rognee.height > _coteMaxImport
      ? img.copyResize(
          rognee,
          width: rognee.width >= rognee.height ? _coteMaxImport : null,
          height: rognee.height > rognee.width ? _coteMaxImport : null,
          interpolation: img.Interpolation.average,
        )
      : rognee;

  final png = Uint8List.fromList(img.encodePng(reduite, level: 9));
  if (png.length <= logoMaxOctets) return png;

  final opaque = _surBlanc(reduite);
  for (final qualite in const [88, 75, 60]) {
    final jpeg = Uint8List.fromList(img.encodeJpg(opaque, quality: qualite));
    if (jpeg.length <= logoMaxOctets) return jpeg;
  }
  throw StateError(
    'Ce logo reste trop lourd même réduit. Choisissez une image plus simple.',
  );
}

/// La version noir et blanc d'un logo, en PNG, `largeur` points de large.
Uint8List? logoNoirEtBlanc(Uint8List source, {int largeur = largeurLogoTicket}) {
  final image = img.decodeImage(source);
  if (image == null) return null;
  final mise = img.copyResize(
    _surBlanc(image),
    width: largeur,
    interpolation: img.Interpolation.average,
  );
  final gris = img.grayscale(mise);
  final w = gris.width;
  final h = gris.height;
  final seuil = _seuilOtsu(gris);
  final sortie = img.Image(width: w, height: h, numChannels: 1);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      sortie.setPixelR(x, y, gris.getPixel(x, y).r <= seuil ? 0 : 255);
    }
  }
  return Uint8List.fromList(img.encodePng(sortie));
}

/// Le seuil qui separe le mieux le dessin du fond (Otsu) : celui qui rend
/// les deux groupes de gris les plus distincts. Un logo pale garde ainsi son
/// dessin au lieu de disparaitre sous un seuil fixe a mi-gris.
int _seuilOtsu(img.Image gris) {
  final histo = List<int>.filled(256, 0);
  for (final p in gris) {
    histo[p.r.toInt().clamp(0, 255)]++;
  }
  final total = gris.width * gris.height;
  var somme = 0.0;
  for (var i = 0; i < 256; i++) {
    somme += i * histo[i];
  }
  var sommeFond = 0.0;
  var poidsFond = 0;
  var meilleur = 0.0;
  var seuil = 127;
  for (var t = 0; t < 256; t++) {
    poidsFond += histo[t];
    if (poidsFond == 0) continue;
    final poidsDessin = total - poidsFond;
    if (poidsDessin == 0) break;
    sommeFond += t * histo[t];
    final moyFond = sommeFond / poidsFond;
    final moyDessin = (somme - sommeFond) / poidsDessin;
    final ecart = poidsFond * poidsDessin * (moyFond - moyDessin) * (moyFond - moyDessin);
    if (ecart > meilleur) {
      meilleur = ecart;
      seuil = t;
    }
  }
  // Une image presque unie n'a pas de second groupe : on ne noircit que
  // ce qui est franchement sombre.
  return meilleur == 0 ? 127 : seuil;
}

/// Retire le fond uni ou transparent autour du dessin, en gardant une
/// petite respiration.
img.Image _rogner(img.Image source) {
  final rognee = img.trim(
    source,
    mode: source.hasAlpha ? img.TrimMode.transparent : img.TrimMode.topLeftColor,
    fuzzy: 0.06,
  );
  if (rognee.width < 8 || rognee.height < 8) return source;
  final marge = (0.04 * (rognee.width > rognee.height ? rognee.width : rognee.height)).round();
  final cadre = img.Image(
    width: rognee.width + 2 * marge,
    height: rognee.height + 2 * marge,
    numChannels: rognee.numChannels,
  );
  if (!rognee.hasAlpha) cadre.clear(img.ColorRgb8(255, 255, 255));
  return img.compositeImage(cadre, rognee, dstX: marge, dstY: marge);
}

/// Pose l'image sur du blanc : la transparence d'un PNG deviendrait du noir
/// sur une imprimante, ou dans un JPEG.
img.Image _surBlanc(img.Image source) {
  if (!source.hasAlpha) return source;
  final fond = img.Image(width: source.width, height: source.height)
    ..clear(img.ColorRgb8(255, 255, 255));
  return img.compositeImage(fond, source);
}

/// Le logo du ticket, recalcule seulement quand le logo change.
final logoTicketProvider = FutureProvider<Uint8List?>((ref) async {
  final hotel = await ref.watch(hotelProvider.future);
  final logo = hotel?.logoData;
  if (logo == null) return null;
  return logoNoirEtBlanc(logo);
});
