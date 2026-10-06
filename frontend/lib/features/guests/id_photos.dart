/// Le recto et le verso de la piece d'identite d'un client.
///
/// Le meme bloc sert a l'arrivee et sur la fiche client : on photographie au
/// comptoir, on relit plus tard, hors connexion comme en ligne, puisque tout
/// vient du disque de la tablette.
///
/// Les cases ont le format d'une carte d'identite (85,6 x 54 mm) : la photo
/// s'y loge sans bandes, et la case vide dit deja ce qu'on attend d'y voir.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/tokens.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/repositories/id_photo_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';

const _formatCarte = 85.6 / 54;
const _rayon = 10.0;

final _photosProvider =
    StreamProvider.family<Map<IdPhotoSide, AttachmentRow>, String>(
      (ref, guestId) => ref.watch(idPhotoRepositoryProvider).watch(guestId),
    );

// Liberes des que la case disparait : quelques centaines de kilo-octets par
// photo, multiplies par chaque fiche ouverte dans la journee.
final _octetsProvider = FutureProvider.autoDispose
    .family<Uint8List?, AttachmentRow>(
      (ref, photo) => ref.watch(idPhotoRepositoryProvider).read(photo),
    );

String _nomCote(IdPhotoSide cote) => switch (cote) {
  IdPhotoSide.front => 'Recto',
  IdPhotoSide.back => 'Verso',
};

/// Ouvre l'appareil photo et rend une image deja reduite.
///
/// 1600 pixels sur le grand cote suffisent a relire le numero d'une piece en
/// agrandissant ; une photo brute de tablette en fait 4000 et pese plusieurs
/// megaoctets. La qualite JPEG 70 divise encore le poids par trois sans gener
/// la lecture.
Future<Uint8List?> _photographier() async {
  final photo = await ImagePicker().pickImage(
    source: ImageSource.camera,
    preferredCameraDevice: CameraDevice.rear,
    maxWidth: 1600,
    maxHeight: 1600,
    imageQuality: 70,
  );
  return photo?.readAsBytes();
}

class IdPhotoPair extends ConsumerStatefulWidget {
  const IdPhotoPair({super.key, required this.guestId});

  final String guestId;

  @override
  ConsumerState<IdPhotoPair> createState() => _IdPhotoPairState();
}

class _IdPhotoPairState extends ConsumerState<IdPhotoPair> {
  IdPhotoSide? _enCours;
  String? _erreur;

  Future<void> _prendre(IdPhotoSide cote) async {
    setState(() {
      _enCours = cote;
      _erreur = null;
    });
    try {
      final jpeg = await _photographier();
      if (jpeg == null) return;
      await ref
          .read(idPhotoRepositoryProvider)
          .save(
            guestId: widget.guestId,
            side: cote,
            jpeg: jpeg,
            by: ref.read(sessionProvider).agent?.id,
          );
    } on PlatformException catch (e) {
      _erreur = e.code == 'camera_access_denied'
          ? "L'appareil photo est refusé à Atrium. Autorisez-le dans les "
                'réglages de la tablette, rubrique Applications.'
          : "L'appareil photo ne s'est pas ouvert : ${e.message ?? e.code}";
    } catch (e) {
      _erreur = "La photo n'a pas été enregistrée : $e";
    } finally {
      if (mounted) setState(() => _enCours = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final disponible = ref.watch(idPhotoRepositoryProvider).files.available;
    // La photo remonte sous le droit d'ecrire la fiche : sans lui, le serveur
    // la refuserait et elle resterait sur la tablette.
    final autorise = ref.watch(sessionProvider).acces.peut('guests.write');
    final photos =
        ref.watch(_photosProvider(widget.guestId)).value ??
        const <IdPhotoSide, AttachmentRow>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (final cote in IdPhotoSide.values) ...[
              if (cote != IdPhotoSide.values.first) const SizedBox(width: 12),
              Expanded(
                child: _Case(
                  cote: cote,
                  photo: photos[cote],
                  occupee: _enCours == cote,
                  onPrendre: disponible && autorise && _enCours == null
                      ? () => _prendre(cote)
                      : null,
                ),
              ),
            ],
          ],
        ),
        // Une case grisee sans explication se lit comme une panne.
        if (disponible && !autorise) ...[
          const SizedBox(height: 8),
          Text(
            "Votre profil ne permet pas de photographier la pièce : il faut "
            'le droit de modifier les fiches clients.',
            style: TextStyle(fontSize: 13.5, color: p.textSecondary),
          ),
        ],
        if (!disponible) ...[
          const SizedBox(height: 8),
          Text(
            'Les photos se prennent et se consultent sur la tablette.',
            style: TextStyle(fontSize: 13.5, color: p.textSecondary),
          ),
        ],
        if (_erreur != null) ...[
          const SizedBox(height: 8),
          Text(_erreur!, style: TextStyle(fontSize: 13.5, color: p.error)),
        ],
      ],
    );
  }
}

class _Case extends ConsumerWidget {
  const _Case({
    required this.cote,
    required this.photo,
    required this.occupee,
    required this.onPrendre,
  });

  final IdPhotoSide cote;
  final AttachmentRow? photo;
  final bool occupee;

  /// `null` quand la prise de vue est impossible : navigateur, ou une autre
  /// photo en cours.
  final VoidCallback? onPrendre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final nom = _nomCote(cote);
    final octets = photo == null ? null : ref.watch(_octetsProvider(photo!));
    final image = octets?.value;

    final Widget contenu;
    if (occupee) {
      contenu = const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    } else if (image != null) {
      contenu = _Apercu(
        nom: nom,
        image: image,
        heroTag: 'piece-${photo!.id}-${photo!.filePathLocal}',
        onReprendre: onPrendre,
      );
    } else {
      contenu = _CaseVide(
        nom: nom,
        // Une ligne sans fichier : la photo a ete prise sur une autre
        // tablette, ou le fichier a disparu. On le dit plutot que d'afficher
        // une case vide qui laisserait croire qu'il n'y a jamais rien eu.
        detail: photo != null && octets!.hasValue
            ? 'Fichier absent de cette tablette'
            : onPrendre != null
            ? 'Photographier'
            : 'Pas de photo',
        onPrendre: onPrendre,
      );
    }

    return AspectRatio(
      aspectRatio: _formatCarte,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.surfaceMuted,
          borderRadius: BorderRadius.circular(_rayon),
          border: Border.all(color: p.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_rayon - 1),
          child: contenu,
        ),
      ),
    );
  }
}

class _CaseVide extends StatelessWidget {
  const _CaseVide({required this.nom, required this.detail, this.onPrendre});

  final String nom;
  final String detail;
  final VoidCallback? onPrendre;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPrendre,
        child: Semantics(
          button: onPrendre != null,
          label: onPrendre != null
              ? 'Photographier le ${nom.toLowerCase()}'
              : null,
          excludeSemantics: onPrendre != null,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  onPrendre != null
                      ? PhosphorIconsLight.camera
                      : PhosphorIconsLight.identificationCard,
                  size: 26,
                  color: p.textSecondary,
                ),
                const SizedBox(height: 6),
                Text(
                  nom,
                  style: TextStyle(
                    fontFamily: atriumFontFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Apercu extends StatelessWidget {
  const _Apercu({
    required this.nom,
    required this.image,
    required this.heroTag,
    required this.onReprendre,
  });

  final String nom;
  final Uint8List image;
  final String heroTag;
  final VoidCallback? onReprendre;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final ratio = MediaQuery.devicePixelRatioOf(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => _ouvrir(context),
            child: Semantics(
              image: true,
              button: true,
              label: '${nom.toLowerCase()} de la pièce, agrandir',
              child: Hero(
                tag: heroTag,
                child: LayoutBuilder(
                  // Decodee a la taille de la case : une image de 1600 pixels
                  // pour une vignette de 220 occuperait la memoire pour rien.
                  builder: (context, c) => Image.memory(
                    image,
                    fit: BoxFit.cover,
                    cacheWidth: (c.maxWidth * ratio).round(),
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: p.night.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                nom,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: p.onNight,
                ),
              ),
            ),
          ),
        ),
        if (onReprendre != null)
          Positioned(
            right: 4,
            top: 4,
            child: IconButton(
              tooltip: 'Reprendre le ${nom.toLowerCase()}',
              onPressed: onReprendre,
              style: IconButton.styleFrom(
                backgroundColor: p.night.withValues(alpha: 0.6),
                foregroundColor: p.onNight,
              ),
              icon: const Icon(PhosphorIconsLight.camera, size: 19),
            ),
          ),
      ],
    );
  }

  void _ouvrir(BuildContext context) {
    final sansAnimation = MediaQuery.disableAnimationsOf(context);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.transparent,
        transitionDuration: sansAnimation
            ? Duration.zero
            : const Duration(milliseconds: 260),
        reverseTransitionDuration: sansAnimation
            ? Duration.zero
            : const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) =>
            _Visionneuse(nom: nom, image: image, heroTag: heroTag),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }
}

/// La piece en grand, pour relire un numero ou une date d'expiration.
class _Visionneuse extends StatelessWidget {
  const _Visionneuse({
    required this.nom,
    required this.image,
    required this.heroTag,
  });

  final String nom;
  final Uint8List image;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    return Material(
      color: p.night.withValues(alpha: 0.96),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
              child: Row(
                children: [
                  Text(
                    nom,
                    style: TextStyle(
                      fontFamily: atriumFontFamily,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: p.onNight,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Fermer',
                    onPressed: () => Navigator.of(context).pop(),
                    style: IconButton.styleFrom(
                      backgroundColor: p.onNight.withValues(alpha: 0.1),
                      foregroundColor: p.onNight,
                    ),
                    icon: const Icon(PhosphorIconsLight.x),
                  ),
                ],
              ),
            ),
            Expanded(
              child: InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Hero(
                      tag: heroTag,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(_rayon),
                        child: Image.memory(image, gaplessPlayback: true),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Écartez deux doigts pour agrandir.',
                style: TextStyle(fontSize: 13.5, color: p.onNightSoft),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
