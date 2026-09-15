/// Clients : particuliers, societes, pieces d'identite.
library;

import 'package:drift/drift.dart';

import '../columns.dart';
import '../enums.dart';

/// Societe, agence de voyage ou tour-operateur.
///
/// Absente du cahier des charges, mais indissociable d'une facturation
/// hoteliere reelle : le debiteur d'une facture n'est pas toujours l'occupant
/// de la chambre. Sans cette table, impossible d'emettre une facture au nom
/// d'une entreprise ni de suivre un encours.
@DataClassName('CompanyRow')
class Companies extends Table
    with SyncedTableColumns, HotelScoped, RefTableColumns {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get name => text().withLength(max: 160)();
  TextColumn get taxId => text().withLength(max: 40).nullable()();
  TextColumn get address => text().withLength(max: 255).nullable()();
  TextColumn get city => text().withLength(max: 80).nullable()();
  TextColumn get country => text().withLength(max: 80).nullable()();
  TextColumn get contactName => text().withLength(max: 120).nullable()();
  TextColumn get phone => text().withLength(max: 40).nullable()();
  TextColumn get email => text().withLength(max: 160).nullable()();

  /// Encours autorise, en francs CFA, entiers.
  IntColumn get creditLimit => integer().withDefault(const Constant(0))();
  IntColumn get paymentTermsDays => integer().withDefault(const Constant(0))();

  /// Remise negociee, en points de base : 5 % vaut 500.
  IntColumn get discountRate => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
}

/// Fiche client (F1.6).
///
/// C'est la seule table de la base qui porte des donnees personnelles en
/// clair. Ce cloisonnement est voulu : il concentre sur un perimetre etroit le
/// chiffrement au repos (exigence 6.2) et le droit a l'effacement (RGPD,
/// paragraphe 8). Disperser nom et telephone dans dix tables rendrait les deux
/// impossibles a garantir.
@DataClassName('GuestRow')
class Guests extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get code => text().withLength(max: 32)();
  TextColumn get title => text().withLength(max: 16).nullable()();
  TextColumn get firstName => text().withLength(max: 80)();
  TextColumn get lastName => text().withLength(max: 80)();
  TextColumn get birthDate => text().withLength(max: 10).nullable()();
  TextColumn get birthPlace => text().withLength(max: 120).nullable()();
  TextColumn get nationality => text().withLength(max: 80).nullable()();
  TextColumn get gender => text().withLength(max: 16).nullable()();

  TextColumn get idDocumentType => textEnum<IdDocumentType>().nullable()();
  TextColumn get idDocumentNumber => text().withLength(max: 64).nullable()();
  TextColumn get idDocumentExpiry => text().withLength(max: 10).nullable()();

  TextColumn get email => text().withLength(max: 160).nullable()();
  TextColumn get phone => text().withLength(max: 40).nullable()();
  TextColumn get phoneAlt => text().withLength(max: 40).nullable()();
  TextColumn get address => text().withLength(max: 255).nullable()();
  TextColumn get city => text().withLength(max: 80).nullable()();
  TextColumn get postalCode => text().withLength(max: 20).nullable()();
  TextColumn get country => text().withLength(max: 80).nullable()();

  TextColumn get companyId => text().nullable()();

  /// Preferences libres, en JSON : etage eleve, chambre non-fumeur, oreiller
  /// ferme, allergies. Chaque hotel suit ses propres criteres et les fait
  /// evoluer souvent -- un schema fige vieillirait mal.
  TextColumn get preferences => text().nullable()();
  TextColumn get notes => text().nullable()();

  BoolColumn get isVip => boolean().withDefault(const Constant(false))();
  BoolColumn get isBlacklisted =>
      boolean().withDefault(const Constant(false))();
  TextColumn get blacklistReason => text().withLength(max: 255).nullable()();

  /// Consentement commercial, horodate et distinct de la simple presence
  /// d'une adresse courriel (RGPD).
  BoolColumn get marketingConsent =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get consentAt => dateTime().nullable()();
  DateTimeColumn get anonymizedAt => dateTime().nullable()();
}

/// Scan ou photo d'une piece d'identite.
///
/// Le fichier existe d'abord sur la tablette, puis recoit une URL serveur
/// apres televersement. Un binaire ne transite pas par la file d'attente JSON
/// de synchronisation : c'est un traitement distinct, dont `uploadState` suit
/// l'avancement.
@DataClassName('GuestDocumentRow')
class GuestDocuments extends Table with SyncedTableColumns {
  TextColumn get guestId =>
      text().references(Guests, #id, onDelete: KeyAction.cascade)();
  TextColumn get docType => textEnum<IdDocumentType>()();
  TextColumn get filePathLocal => text().withLength(max: 255).nullable()();
  TextColumn get fileUrl => text().withLength(max: 512).nullable()();
  TextColumn get mimeType => text().withLength(max: 80).nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  TextColumn get uploadState =>
      textEnum<UploadState>().withDefault(const Constant('PENDING'))();
  DateTimeColumn get capturedAt => dateTime().nullable()();
}
