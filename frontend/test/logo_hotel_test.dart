/// Le logo et l'identite de l'hotel : ranges sur la tablette, remontes,
/// redescendus, et portes par les factures en PDF.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/donnees_de_test.dart';
import 'package:atrium/data/repositories/hotel_repository.dart';
import 'package:atrium/data/repositories/invoice_repository.dart';
import 'package:atrium/features/billing/invoice_pdf.dart';
import 'package:atrium/features/hotel/logo_images.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'helpers/fake_catalog_api.dart';

class _FauxApi extends ApiClient {
  _FauxApi() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final appels = <(String, String, Map<String, Object?>)>[];

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    appels.add(('PATCH', path, (body as Map).cast<String, Object?>()));
    return {};
  }
}

/// Un vrai PNG, de la taille demandee. `bruit` : des points au hasard, le
/// pire cas pour la compression.
Uint8List _png(int largeur, int hauteur, {bool bruit = false}) {
  final hasard = Random(7);
  final image = img.Image(width: largeur, height: hauteur);
  for (var y = 0; y < hauteur; y++) {
    for (var x = 0; x < largeur; x++) {
      image.setPixelRgb(
        x,
        y,
        bruit ? hasard.nextInt(256) : (x * 7 + y) % 256,
        bruit ? hasard.nextInt(256) : (y * 13) % 256,
        bruit ? hasard.nextInt(256) : (x ^ y) % 256,
      );
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AtriumDatabase db;
  late HotelRepository hotel;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    hotel = HotelRepository(db);
  });

  tearDown(() => db.close());

  test('renommer l hotel ecrit en base et part vers PATCH /hotel', () async {
    await hotel.modifierIdentite(
      nom: '  Edge Hotel Plateau ',
      telephone: '+225 27 20 30 40 50',
      numeroFiscal: 'CI-ABJ-2026-B-1234',
    );
    final h = (await hotel.lire())!;
    expect(h.name, 'Edge Hotel Plateau');
    expect(h.syncState, SyncState.pending);

    final api = _FauxApi();
    await OutboxSender(db: db, api: api).drain();
    final (methode, chemin, corps) = api.appels.single;
    expect((methode, chemin), ('PATCH', '/hotel'));
    expect(corps['name'], 'Edge Hotel Plateau');
    expect(corps['tax_id'], 'CI-ABJ-2026-B-1234');
    expect(corps.containsKey('timezone'), isFalse);
    expect((await hotel.lire())!.syncState, SyncState.synced);
  });

  test('un nom vide ou un faux logo est refuse avant le serveur', () async {
    expect(() => hotel.modifierIdentite(nom: '  '), throwsStateError);
    expect(
      () => hotel.importerLogo(Uint8List.fromList('GIF89a....'.codeUnits)),
      throwsStateError,
    );
    final lourd = Uint8List(logoMaxOctets + 10)
      ..setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    expect(() => hotel.importerLogo(lourd), throwsStateError);
  });

  test('une grande image est reduite sous la limite a l import', () {
    final grande = _png(1600, 1000, bruit: true);
    expect(grande.length, greaterThan(logoMaxOctets));
    final pret = preparerLogo(grande);
    expect(pret.length, lessThanOrEqualTo(logoMaxOctets));
    final relu = img.decodeImage(pret)!;
    expect(relu.width, 800);
  });

  test('le logo du ticket est en noir et blanc, 384 points de large', () {
    final nb = logoNoirEtBlanc(_png(300, 120))!;
    final relu = img.decodeImage(nb)!;
    expect(relu.width, largeurLogoTicket);
    final teintes = <num>{
      for (final p in relu) p.r,
    };
    expect(teintes.difference({0, 255}), isEmpty);
  });

  test('le logo importe remonte, puis la descente ne le rapporte pas',
      () async {
    final logo = _png(120, 60);
    await hotel.importerLogo(logo);
    expect(HotelRepository.logoEnAttente(await hotel.lire()), isTrue);

    final serveur = FakeCatalogApi(
      hotel: {'name': 'Edge Hotel', 'logo_version': 'srv-${logo.length}'},
    );
    await hotel.synchroniser(serveur);
    final h = (await hotel.lire())!;
    expect(h.logoVersion, 'srv-${logo.length}');
    expect(h.logoData, logo);
  });

  test('un logo change ailleurs redescend, une identite en attente reste',
      () async {
    await hotel.modifierIdentite(nom: 'Nom saisi ici');
    final logo = _png(80, 40);
    await hotel.synchroniser(
      FakeCatalogApi(
        hotel: {'name': 'Nom du serveur', 'logo_version': 'v2'},
        logo: logo,
      ),
    );
    final h = (await hotel.lire())!;
    expect(h.logoData, logo);
    expect(h.logoVersion, 'v2');
    expect(h.name, 'Nom saisi ici', reason: 'pas encore remonte : il fait foi');

    // Retire sur le serveur : il disparait ici aussi.
    await hotel.synchroniser(
      FakeCatalogApi(hotel: {'name': 'Nom du serveur', 'logo_version': null}),
    );
    expect((await hotel.lire())!.logoData, isNull);
  });

  test('la facture A4 et le ticket se fabriquent avec le logo', () async {
    await hotel.importerLogo(_png(200, 80));
    final h = await hotel.lire();
    final maintenant = DateTime.utc(2026, 10, 9);
    final vue = InvoiceView(
      invoice: InvoiceRow(
        id: '01920000-0000-7000-8000-00000000c001',
        createdAt: maintenant,
        updatedAt: maintenant,
        syncState: SyncState.synced,
        hotelId: HotelRepository.defaultHotelId,
        folioId: '01920000-0000-7000-8000-00000000c002',
        isProvisional: true,
        provisionalNumber: 'PROV-0001',
        status: InvoiceStatus.ISSUED,
        issuedAt: maintenant,
        subtotal: 50000,
        discountTotal: 0,
        taxTotal: 4500,
        total: 50000,
        currency: 'XOF',
      ),
      lines: [
        InvoiceLineRow(
          id: '01920000-0000-7000-8000-00000000c003',
          createdAt: maintenant,
          updatedAt: maintenant,
          syncState: SyncState.synced,
          invoiceId: '01920000-0000-7000-8000-00000000c001',
          label: 'Nuitée',
          quantity: 2,
          unitPrice: 25000,
          taxRate: 0,
          taxAmount: 0,
          amount: 50000,
          sortOrder: 0,
        ),
      ],
    );
    final a4 = await factureA4(vue: vue, hotel: h, client: 'Awa Koné');
    expect(String.fromCharCodes(a4.take(5)), '%PDF-');
    final ticket = await factureTicket(
      vue: vue,
      hotel: h,
      client: 'Awa Koné',
      logoNoirBlanc: logoNoirEtBlanc(h!.logoData!),
    );
    expect(String.fromCharCodes(ticket.take(5)), '%PDF-');
  });

  test('les donnees de test donnent un logo et des coordonnees a l hotel',
      () async {
    await seedAccounts(db);
    final admin = await (db.select(
      db.users,
    )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
    final logo = preparerLogo(
      File('assets/images/edge-hotel-logo.png').readAsBytesSync(),
    );

    // Sans le droit : l'hotel n'est pas touche.
    await chargerDonneesDeTest(db, agentId: admin.id, logo: logo);
    expect((await hotel.lire())!.logoData, isNull);

    final bilan = await chargerDonneesDeTest(
      db,
      agentId: admin.id,
      peutModifierHotel: true,
      logo: logo,
    );
    expect(bilan, contains('Hôtel : coordonnées et logo ajoutés.'));
    final h = (await hotel.lire())!;
    expect(h.logoData, logo);
    expect(h.phone, '+225 27 20 30 40 50');
    expect(HotelRepository.logoEnAttente(h), isTrue);
    final file = await db.select(db.outboxEntries).get();
    expect(file.where((e) => e.entityTable == 'hotels'), hasLength(1));

    // Une seconde fois : rien n'est remplace.
    expect(
      await chargerDonneesDeTest(
        db,
        agentId: admin.id,
        peutModifierHotel: true,
        logo: logo,
      ),
      contains('déjà son logo'),
    );
  });
}
