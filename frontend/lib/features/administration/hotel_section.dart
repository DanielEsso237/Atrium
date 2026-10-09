/// L'etablissement : le nom, les coordonnees et le logo imprimes en tete
/// des factures et des tickets.
///
/// A droite, l'apercu de l'en-tete se redessine a chaque frappe : ce que
/// l'administrateur regle ici est ce que le client emporte, en couleur sur
/// la facture et en noir et blanc sur le ticket de caisse.
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/tokens.dart';
import '../../core/ui/atrium_ui.dart';
import '../../core/ui/icons.dart';
import '../../data/local/database.dart';
import '../../data/repositories/hotel_repository.dart';
import '../../data/repositories/repository_providers.dart';
import '../auth/session.dart';
import '../hotel/en_tete_hotel.dart';
import '../hotel/logo_images.dart';

class HotelSection extends ConsumerStatefulWidget {
  const HotelSection({super.key});

  @override
  ConsumerState<HotelSection> createState() => _HotelSectionState();
}

class _HotelSectionState extends ConsumerState<HotelSection> {
  final _nom = TextEditingController();
  final _raison = TextEditingController();
  final _adresse = TextEditingController();
  final _ville = TextEditingController();
  final _pays = TextEditingController();
  final _telephone = TextEditingController();
  final _email = TextEditingController();
  final _nif = TextEditingController();

  late final _champs = [
    _nom,
    _raison,
    _adresse,
    _ville,
    _pays,
    _telephone,
    _email,
    _nif,
  ];

  String? _chargeDe;
  bool _enregistrement = false;
  bool _import = false;
  String? _erreurLogo;
  bool _nomTouche = false;

  @override
  void dispose() {
    for (final c in _champs) {
      c.dispose();
    }
    super.dispose();
  }

  /// Remplit le formulaire une fois, puis a chaque version venue d'ailleurs
  /// (descente) tant que l'administrateur n'a rien modifie.
  void _remplir(HotelRow h) {
    final cle = '${h.updatedAt.toIso8601String()}${h.name}';
    if (_chargeDe == cle || (_chargeDe != null && _modifie(h))) return;
    _chargeDe = cle;
    _nom.text = h.name;
    _raison.text = h.legalName ?? '';
    _adresse.text = h.address ?? '';
    _ville.text = h.city ?? '';
    _pays.text = h.country ?? '';
    _telephone.text = h.phone ?? '';
    _email.text = h.email ?? '';
    _nif.text = h.taxId ?? '';
  }

  bool _modifie(HotelRow h) {
    String n(String? v) => v?.trim() ?? '';
    return _nom.text.trim() != h.name.trim() ||
        _raison.text.trim() != n(h.legalName) ||
        _adresse.text.trim() != n(h.address) ||
        _ville.text.trim() != n(h.city) ||
        _pays.text.trim() != n(h.country) ||
        _telephone.text.trim() != n(h.phone) ||
        _email.text.trim() != n(h.email) ||
        _nif.text.trim() != n(h.taxId);
  }

  /// L'hotel tel qu'il sortira, avec ce qui est en cours de saisie.
  HotelRow _apercu(HotelRow h) {
    Value<String?> v(TextEditingController c) =>
        Value(c.text.trim().isEmpty ? null : c.text.trim());
    return h.copyWith(
      name: _nom.text.trim().isEmpty ? h.name : _nom.text.trim(),
      legalName: v(_raison),
      address: v(_adresse),
      city: v(_ville),
      country: v(_pays),
      phone: v(_telephone),
      email: v(_email),
      taxId: v(_nif),
    );
  }

  String? get _erreurNom => !_nomTouche
      ? null
      : _nom.text.trim().isEmpty
      ? "Indiquez le nom de l'hôtel : il ouvre chaque facture."
      : null;

  Future<void> _enregistrer() async {
    setState(() {
      _nomTouche = true;
      _enregistrement = true;
    });
    if (_nom.text.trim().isEmpty) {
      setState(() => _enregistrement = false);
      return;
    }
    final messager = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(hotelRepositoryProvider)
          .modifierIdentite(
            nom: _nom.text,
            raisonSociale: _raison.text,
            adresse: _adresse.text,
            ville: _ville.text,
            pays: _pays.text,
            telephone: _telephone.text,
            email: _email.text,
            numeroFiscal: _nif.text,
            by: ref.read(sessionProvider).agent?.id,
          );
      _chargeDe = null;
      messager.showSnackBar(
        const SnackBar(content: Text('Coordonnées de l’hôtel enregistrées.')),
      );
    } on StateError catch (e) {
      messager.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _enregistrement = false);
    }
  }

  Future<void> _importer() async {
    setState(() {
      _erreurLogo = null;
      _import = true;
    });
    try {
      final fichier = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (fichier == null) return;
      final brut = await fichier.readAsBytes();
      // Reduite et recompressee hors du fil de l'ecran : une grande photo
      // figerait l'interface le temps du calcul.
      final pret = await compute(preparerLogo, brut);
      await ref
          .read(hotelRepositoryProvider)
          .importerLogo(pret, by: ref.read(sessionProvider).agent?.id);
    } on StateError catch (e) {
      setState(() => _erreurLogo = e.message);
    } catch (e) {
      setState(() => _erreurLogo = "L'image n'a pas pu être importée : $e");
    } finally {
      if (mounted) setState(() => _import = false);
    }
  }

  Future<void> _retirer() async {
    setState(() => _erreurLogo = null);
    await ref
        .read(hotelRepositoryProvider)
        .retirerLogo(by: ref.read(sessionProvider).agent?.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final hotel = ref.watch(hotelProvider).value;
    final peut = ref.watch(sessionProvider).acces.peut('hotel.write');
    if (hotel == null) {
      return const Center(child: CircularProgressIndicator());
    }
    _remplir(hotel);
    final apercu = _apercu(hotel);
    final modifie = _modifie(hotel);

    Widget champ(
      TextEditingController c,
      String libelle, {
      TextInputType? clavier,
      String? erreur,
      String? aide,
    }) => TextField(
      controller: c,
      enabled: peut,
      keyboardType: clavier,
      onChanged: (_) => setState(() {}),
      onEditingComplete: c == _nom
          ? () => setState(() => _nomTouche = true)
          : null,
      decoration: InputDecoration(
        labelText: libelle,
        errorText: erreur,
        helperText: aide,
      ),
    );

    Widget paire(Widget a, Widget b, bool large) => large
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: 16),
              Expanded(child: b),
            ],
          )
        : Column(children: [a, const SizedBox(height: 14), b]);

    final formulaire = LayoutBuilder(
      builder: (context, c) {
        final large = c.maxWidth >= 520;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BlocLogo(
              hotel: hotel,
              peut: peut,
              enCours: _import,
              erreur: _erreurLogo,
              onImporter: _importer,
              onRetirer: _retirer,
            ),
            const SizedBox(height: 24),
            champ(
              _nom,
              "Nom de l'hôtel",
              erreur: _erreurNom,
              aide: 'En tête de chaque facture et de chaque ticket.',
            ),
            const SizedBox(height: 14),
            champ(
              _raison,
              'Raison sociale',
              aide: 'Si elle diffère du nom ; elle s’imprime dessous.',
            ),
            const SizedBox(height: 14),
            champ(_adresse, 'Adresse'),
            const SizedBox(height: 14),
            paire(champ(_ville, 'Ville'), champ(_pays, 'Pays'), large),
            const SizedBox(height: 14),
            paire(
              champ(_telephone, 'Téléphone', clavier: TextInputType.phone),
              champ(_email, 'E-mail', clavier: TextInputType.emailAddress),
              large,
            ),
            const SizedBox(height: 14),
            champ(_nif, 'N° contribuable'),
            const SizedBox(height: 22),
            if (peut)
              Align(
                alignment: Alignment.centerLeft,
                child: PillButton(
                  label: _enregistrement ? 'Enregistrement…' : 'Enregistrer',
                  icon: PhosphorIconsLight.check,
                  compact: true,
                  onPressed: modifie && !_enregistrement ? _enregistrer : null,
                ),
              )
            else
              Text(
                'Seul un agent autorisé à modifier l’établissement peut '
                'changer ces informations.',
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 13,
                  color: p.textSecondary,
                ),
              ),
          ],
        );
      },
    );

    final apercus = _Apercus(hotel: apercu);

    return LayoutBuilder(
      builder: (context, c) {
        final large = c.maxWidth >= 980;
        final marge = c.maxWidth < 600 ? 16.0 : 24.0;
        return ListView(
          padding: EdgeInsets.all(marge),
          children: [
            Text(
              "L'hôtel sur les factures",
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: p.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Le nom, les coordonnées et le logo imprimés en tête de chaque '
              'facture et de chaque ticket, sur tous les postes.',
              style: TextStyle(
                fontFamily: atriumFontFamily,
                fontSize: 13.5,
                color: p.textSecondary,
              ),
            ),
            const SizedBox(height: 22),
            if (large)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: formulaire),
                  const SizedBox(width: 32),
                  Expanded(flex: 4, child: apercus),
                ],
              )
            else ...[
              formulaire,
              const SizedBox(height: 28),
              apercus,
            ],
          ],
        );
      },
    );
  }
}

/// Le logo en place, et de quoi le changer.
class _BlocLogo extends StatelessWidget {
  const _BlocLogo({
    required this.hotel,
    required this.peut,
    required this.enCours,
    required this.erreur,
    required this.onImporter,
    required this.onRetirer,
  });

  final HotelRow hotel;
  final bool peut;
  final bool enCours;
  final String? erreur;
  final VoidCallback onImporter;
  final VoidCallback onRetirer;

  @override
  Widget build(BuildContext context) {
    final p = AtriumPalette.current;
    final logo = hotel.logoData;
    final attente = HotelRepository.logoEnAttente(hotel);
    final style = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 12.5,
      color: p.textSecondary,
      height: 1.4,
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Le logo sur du papier blanc, comme sur la facture : un logo
              // sombre se jugerait mal sur le fond de l'application.
              Container(
                width: 132,
                height: 84,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: p.border),
                ),
                child: logo == null
                    ? Icon(PhosphorIconsLight.image, size: 30, color: p.placeholder)
                    : Image.memory(
                        logo,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        semanticLabel: 'Logo actuel',
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      logo == null ? 'Aucun logo' : 'Logo de l’hôtel',
                      style: TextStyle(
                        fontFamily: atriumFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      logo == null
                          ? 'Le nom de l’hôtel s’affiche seul en tête des '
                                'factures.'
                          : 'PNG ou JPEG, 512 Ko au plus. Une image plus '
                                'grande est réduite à l’import.',
                      style: style,
                    ),
                    if (attente) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            PhosphorIconsLight.cloudArrowUp,
                            size: 16,
                            color: p.warning,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              hotel.logoVersion == 'local-retire'
                                  ? 'Retrait pas encore transmis au serveur.'
                                  : 'Pas encore envoyé : il partira à la '
                                        'prochaine synchronisation.',
                              style: style.copyWith(color: p.warning),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (peut) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                PillButton(
                  label: enCours
                      ? 'Import…'
                      : logo == null
                      ? 'Importer un logo'
                      : 'Remplacer le logo',
                  icon: PhosphorIconsLight.uploadSimple,
                  tone: PillTone.quiet,
                  compact: true,
                  onPressed: enCours ? null : onImporter,
                ),
                if (logo != null)
                  TextButton.icon(
                    onPressed: enCours ? null : onRetirer,
                    icon: const Icon(PhosphorIconsLight.trash, size: 18),
                    label: const Text('Retirer'),
                    style: TextButton.styleFrom(
                      foregroundColor: p.error,
                      minimumSize: const Size(48, 44),
                    ),
                  ),
              ],
            ),
          ],
          if (erreur != null) ...[
            const SizedBox(height: 10),
            Text(erreur!, style: style.copyWith(color: p.error)),
          ],
        ],
      ),
    );
  }
}

/// L'en-tete tel qu'il sortira : facture en couleur, ticket en noir et
/// blanc.
class _Apercus extends ConsumerWidget {
  const _Apercus({required this.hotel});

  final HotelRow hotel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AtriumPalette.current;
    final logoTicket = ref.watch(logoTicketProvider).value;
    final legende = TextStyle(
      fontFamily: atriumFontFamily,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: p.text,
    );
    final papier = BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      boxShadow: const [
        BoxShadow(
          color: Color(0x2414244F),
          blurRadius: 28,
          spreadRadius: -12,
          offset: Offset(0, 14),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sur la facture', style: legende),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: papier,
          child: EnTeteFacture(
            hotel: hotel,
            titre: 'Facture',
            numero: 'FAC-2026-0001',
          ),
        ),
        const SizedBox(height: 26),
        Text('Sur le ticket de caisse', style: legende),
        const SizedBox(height: 10),
        // La largeur d'un rouleau de 80 mm, a l'echelle de l'ecran.
        Container(
          width: 280,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          decoration: papier.copyWith(borderRadius: BorderRadius.circular(6)),
          child: Column(
            children: [
              EnTeteTicket(hotel: hotel, logoNoirBlanc: logoTicket),
              const SizedBox(height: 10),
              Text(
                '- - - - - - - - - - - - - - - - - - - -',
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontFamily: atriumFontFamily,
                  fontSize: 11,
                  color: Colors.black.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Le logo y passe en noir et blanc : une imprimante de tickets '
          'n’imprime que du noir.',
          style: TextStyle(
            fontFamily: atriumFontFamily,
            fontSize: 12.5,
            color: p.textSecondary,
          ),
        ),
      ],
    );
  }
}
