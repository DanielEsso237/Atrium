/// Reservations, sejours, nuitees, signatures.
library;

import 'package:drift/drift.dart';

import '../columns.dart';
import '../enums.dart';

/// Dossier de reservation (F1.1).
///
/// Le dossier est le contenant commercial : un titulaire, une source, un
/// statut d'ensemble. Le detail operationnel vit dans [ReservationRooms],
/// parce qu'un meme dossier peut couvrir plusieurs chambres avec des dates et
/// des tarifs differents -- famille, groupe, seminaire.
@DataClassName('ReservationRow')
class Reservations extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get reference => text().withLength(max: 32)();
  TextColumn get guestId => text().withLength(min: 36, max: 36)();
  TextColumn get companyId => text().nullable()();

  TextColumn get source =>
      textEnum<ReservationSource>().withDefault(const Constant('DIRECT'))();
  TextColumn get status =>
      textEnum<ReservationStatus>().withDefault(const Constant('PENDING'))();

  TextColumn get arrivalDate => text().withLength(max: 10)();
  TextColumn get departureDate => text().withLength(max: 10)();
  IntColumn get adults => integer().withDefault(const Constant(1))();
  IntColumn get children => integer().withDefault(const Constant(0))();

  /// Montants en francs CFA, entiers.
  IntColumn get estimatedTotal => integer().withDefault(const Constant(0))();
  IntColumn get depositAmount => integer().withDefault(const Constant(0))();
  DateTimeColumn get depositPaidAt => dateTime().nullable()();

  TextColumn get specialRequests => text().nullable()();
  TextColumn get internalNotes => text().nullable()();
  DateTimeColumn get cancelledAt => dateTime().nullable()();
  TextColumn get cancelReason => text().withLength(max: 255).nullable()();
}

/// Une chambre reservee : c'est ici que vit reellement le sejour.
///
/// Toute la logique operationnelle s'accroche a cette ligne et non au dossier.
/// C'est elle qu'on attribue a une chambre physique, elle qu'on prend en
/// charge au check-in, elle qui porte un folio. Dans un dossier de groupe,
/// chaque chambre arrive et repart independamment des autres.
///
/// `roomId` est volontairement nullable : on reserve d'abord un *type* de
/// chambre, l'attribution d'un numero physique intervient plus tard, souvent
/// le jour meme de l'arrivee.
@DataClassName('ReservationRoomRow')
class ReservationRooms extends Table with SyncedTableColumns {
  TextColumn get reservationId =>
      text().references(Reservations, #id, onDelete: KeyAction.cascade)();
  TextColumn get roomTypeId => text().withLength(min: 36, max: 36)();
  TextColumn get roomId => text().nullable()();
  TextColumn get ratePlanId => text().nullable()();

  TextColumn get arrivalDate => text().withLength(max: 10)();
  TextColumn get departureDate => text().withLength(max: 10)();
  IntColumn get adults => integer().withDefault(const Constant(1))();
  IntColumn get children => integer().withDefault(const Constant(0))();

  /// Tarif de la nuitee, en francs CFA, entiers.
  IntColumn get nightlyRate => integer().withDefault(const Constant(0))();

  TextColumn get status =>
      textEnum<ReservationStatus>().withDefault(const Constant('PENDING'))();
  DateTimeColumn get checkedInAt => dateTime().nullable()();
  TextColumn get checkedInBy => text().nullable()();
  DateTimeColumn get checkedOutAt => dateTime().nullable()();
  TextColumn get checkedOutBy => text().nullable()();
  TextColumn get keyCardCode => text().withLength(max: 64).nullable()();
  TextColumn get notes => text().nullable()();

  /// Trace d'un rejet d'attribution par le serveur.
  ///
  /// Deux receptions travaillant hors ligne peuvent attribuer la chambre 205
  /// au meme moment. Aucune regle automatique n'est acceptable dans ce cas :
  /// le serveur tranche, et le terminal perdant doit pouvoir expliquer a
  /// l'agent pourquoi son attribution a saute.
  DateTimeColumn get assignmentRejectedAt => dateTime().nullable()();
  TextColumn get assignmentRejectReason =>
      text().withLength(max: 255).nullable()();
}

/// Une nuit facturable d'un sejour.
///
/// Materialiser chaque nuit sert trois choses a la fois : la facture detaillee
/// ligne a ligne, le chiffre d'affaires du jour du tableau de bord
/// (paragraphe 5.1) sans recalcul de prorata, et la cloture journaliere qui
/// porte automatiquement la charge de la nuit sur le folio.
///
/// Un tarif unique multiplie par un nombre de nuits ne suffirait pas : le prix
/// varie en cours de sejour -- saison, surclassement, remise accordee le
/// troisieme jour.
@DataClassName('StayNightRow')
class StayNights extends Table with SyncedTableColumns {
  TextColumn get reservationRoomId =>
      text().references(ReservationRooms, #id, onDelete: KeyAction.cascade)();
  TextColumn get businessDate => text().withLength(max: 10)();
  TextColumn get roomId => text().nullable()();

  /// Prix applique cette nuit-la, en francs CFA, entiers.
  IntColumn get rate => integer().withDefault(const Constant(0))();

  /// Passe a vrai une fois la charge portee au folio, pour que la cloture
  /// journaliere puisse etre rejouee sans facturer deux fois la meme nuit.
  BoolColumn get isPosted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get postedAt => dateTime().nullable()();
  TextColumn get remark => text().withLength(max: 255).nullable()();
}

/// Occupants d'une chambre, au-dela du titulaire du dossier.
@DataClassName('ReservationGuestRow')
class ReservationGuests extends Table with SyncedTableColumns {
  TextColumn get reservationRoomId =>
      text().references(ReservationRooms, #id, onDelete: KeyAction.cascade)();
  TextColumn get guestId => text().withLength(min: 36, max: 36)();
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();
}

/// Signature electronique de check-in, de check-out ou de facture (F1.2).
///
/// Table polymorphe plutot qu'une colonne par usage : les signatures se
/// ressemblent toutes et suivent le meme cycle de televersement, alors que la
/// liste des documents signes va s'allonger.
///
/// Le trace est capture hors ligne et ecrit dans un fichier local ; son envoi
/// au serveur est independant de celui de la ligne metier, parce qu'une image
/// ne passe pas par la file d'attente JSON.
@DataClassName('SignatureRow')
class Signatures extends Table with SyncedTableColumns {
  TextColumn get entityTable => text().withLength(max: 64)();
  TextColumn get entityId => text().withLength(min: 36, max: 36)();
  TextColumn get kind => textEnum<SignatureKind>()();
  TextColumn get imagePathLocal => text().withLength(max: 255).nullable()();
  TextColumn get imageUrl => text().withLength(max: 512).nullable()();
  TextColumn get uploadState =>
      textEnum<UploadState>().withDefault(const Constant('PENDING'))();
  TextColumn get signedByName => text().withLength(max: 160).nullable()();
  DateTimeColumn get signedAt => dateTime().nullable()();
}
