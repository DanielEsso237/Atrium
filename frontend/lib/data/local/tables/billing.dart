/// Facturation et caisse : folios, charges, factures, encaissements, shifts.
library;

import 'package:drift/drift.dart';

import '../columns.dart';
import '../enums.dart';

/// Compte client : le centre de gravite de toute la facturation.
///
/// Chaque charge du systeme -- nuitee, addition du restaurant, minibar, spa --
/// atterrit dans [FolioItems]. La facture n'est ensuite qu'un gel du folio a
/// un instant donne.
///
/// Ce decouplage est ce qui rend possibles la facture provisoire en cours de
/// sejour, la facture partielle, et l'eclatement d'un compte entre le client
/// et sa societe, sans jamais retoucher les charges d'origine. C'est aussi ce
/// qui rend F3.6 immediat : un report en chambre est une charge sur le folio
/// de la chambre, un paiement direct est un folio de type TABLE ouvert et
/// solde dans la foulee.
@DataClassName('FolioRow')
class Folios extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get number => text().withLength(max: 32)();
  TextColumn get type =>
      textEnum<FolioType>().withDefault(const Constant('GUEST'))();
  TextColumn get status =>
      textEnum<FolioStatus>().withDefault(const Constant('OPEN'))();

  TextColumn get reservationRoomId => text().nullable()();
  TextColumn get guestId => text().nullable()();
  TextColumn get companyId => text().nullable()();
  TextColumn get restaurantTableId => text().nullable()();

  /// Totaux tenus a jour a chaque ecriture, en francs CFA, entiers.
  ///
  /// Redondants avec la somme des lignes, mais un ecran de tablette doit
  /// afficher un solde immediatement : recalculer l'agregat du folio a chaque
  /// rafraichissement rendrait la liste des chambres visiblement lente.
  IntColumn get chargesTotal => integer().withDefault(const Constant(0))();
  IntColumn get paymentsTotal => integer().withDefault(const Constant(0))();
  IntColumn get balance => integer().withDefault(const Constant(0))();

  DateTimeColumn get openedAt => dateTime().nullable()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
}

/// Une charge portee au compte du client.
///
/// Le couple (`sourceTable`, `sourceId`) remonte a l'origine de la charge --
/// une commande au restaurant, une nuitee, une intervention. C'est ce qui
/// permet de justifier chaque ligne de facture devant un client qui conteste.
///
/// Une charge ne se supprime jamais : on l'annule avec un motif. Une
/// suppression casserait la piste d'audit exigee au paragraphe 6.2 et ne se
/// propagerait pas correctement vers les tablettes hors ligne.
@DataClassName('FolioItemRow')
class FolioItems extends Table with SyncedTableColumns {
  TextColumn get folioId =>
      text().references(Folios, #id, onDelete: KeyAction.cascade)();
  TextColumn get category => textEnum<ChargeCategory>()();
  TextColumn get label => text().withLength(max: 160)();

  /// Quantite entiere. L'unite est portee par le produit (`products.unit`).
  IntColumn get quantity => integer().withDefault(const Constant(1))();

  /// Montants en francs CFA, entiers.
  IntColumn get unitPrice => integer().withDefault(const Constant(0))();
  IntColumn get amount => integer().withDefault(const Constant(0))();
  IntColumn get taxAmount => integer().withDefault(const Constant(0))();

  /// Taux de taxe en points de base : 18 % vaut 1800, 18,5 % vaut 1850.
  IntColumn get taxRate => integer().withDefault(const Constant(0))();

  TextColumn get businessDate => text().withLength(max: 10)();

  TextColumn get sourceTable => text().withLength(max: 64).nullable()();
  TextColumn get sourceId => text().nullable()();

  TextColumn get postedBy => text().nullable()();
  DateTimeColumn get postedAt => dateTime().nullable()();
  BoolColumn get isVoid => boolean().withDefault(const Constant(false))();
  TextColumn get voidReason => text().withLength(max: 255).nullable()();
  TextColumn get voidedBy => text().nullable()();
}

/// Facture : gel du folio a un instant donne (F1.4).
///
/// Point dicte par le mode hors ligne. Une numerotation legale doit etre
/// continue et sans trou, ce qu'aucune tablette isolee ne peut garantir seule.
/// Une facture emise sans reseau est donc marquee provisoire, porte un numero
/// interne clairement identifie comme tel, et recoit son numero definitif du
/// serveur a la synchronisation.
@DataClassName('InvoiceRow')
class Invoices extends Table with SyncedTableColumns, HotelScoped {
  /// Nul tant que le serveur n'a pas attribue le numero definitif.
  TextColumn get number => text().withLength(max: 32).nullable()();
  TextColumn get provisionalNumber => text().withLength(max: 40).nullable()();
  BoolColumn get isProvisional =>
      boolean().withDefault(const Constant(false))();

  TextColumn get folioId => text().withLength(min: 36, max: 36)();
  TextColumn get guestId => text().nullable()();
  TextColumn get companyId => text().nullable()();

  TextColumn get status =>
      textEnum<InvoiceStatus>().withDefault(const Constant('DRAFT'))();
  DateTimeColumn get issuedAt => dateTime().nullable()();
  TextColumn get dueDate => text().withLength(max: 10).nullable()();

  /// Montants en francs CFA, entiers.
  IntColumn get subtotal => integer().withDefault(const Constant(0))();
  IntColumn get discountTotal => integer().withDefault(const Constant(0))();
  IntColumn get taxTotal => integer().withDefault(const Constant(0))();
  IntColumn get total => integer().withDefault(const Constant(0))();
  TextColumn get currency =>
      text().withLength(max: 8).withDefault(const Constant('XOF'))();

  /// Identite du destinataire, figee a l'emission.
  ///
  /// Si le client demenage l'annee suivante, une facture deja emise ne doit
  /// pas changer d'adresse : un document comptable est immuable.
  TextColumn get billToName => text().withLength(max: 160).nullable()();
  TextColumn get billToAddress => text().withLength(max: 255).nullable()();
  TextColumn get billToTaxId => text().withLength(max: 40).nullable()();

  TextColumn get pdfPath => text().withLength(max: 255).nullable()();
  DateTimeColumn get cancelledAt => dateTime().nullable()();
  TextColumn get cancelReason => text().withLength(max: 255).nullable()();
}

@DataClassName('InvoiceLineRow')
class InvoiceLines extends Table with SyncedTableColumns {
  TextColumn get invoiceId =>
      text().references(Invoices, #id, onDelete: KeyAction.cascade)();
  TextColumn get folioItemId => text().nullable()();
  TextColumn get label => text().withLength(max: 160)();
  IntColumn get quantity => integer().withDefault(const Constant(1))();
  IntColumn get unitPrice => integer().withDefault(const Constant(0))();
  IntColumn get taxRate => integer().withDefault(const Constant(0))();
  IntColumn get taxAmount => integer().withDefault(const Constant(0))();
  IntColumn get amount => integer().withDefault(const Constant(0))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Shift de caisse : ouverture, encaissements, fermeture, ecart.
///
/// Le cahier des charges liste un document "Rapport de shift" dans la matrice
/// d'impression (paragraphe 4.2) sans prevoir la donnee qui l'alimente. Cette
/// table la fournit : les encaissements s'y rattachent, et l'ecart de caisse
/// se calcule a la fermeture.
@DataClassName('CashSessionRow')
class CashSessions extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get userId => text().withLength(min: 36, max: 36)();
  TextColumn get deviceId => text().nullable()();
  TextColumn get status =>
      textEnum<CashSessionStatus>().withDefault(const Constant('OPEN'))();

  DateTimeColumn get openedAt => dateTime().nullable()();

  /// Fond de caisse et comptages, en francs CFA, entiers.
  IntColumn get openingFloat => integer().withDefault(const Constant(0))();
  DateTimeColumn get closedAt => dateTime().nullable()();

  /// Montant reellement compte par le caissier a la fermeture.
  IntColumn get countedAmount => integer().nullable()();

  /// Montant attendu d'apres les encaissements enregistres.
  IntColumn get expectedAmount => integer().withDefault(const Constant(0))();
  IntColumn get variance => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
}

/// Encaissement ou remboursement (F1.4).
@DataClassName('PaymentRow')
class Payments extends Table with SyncedTableColumns, HotelScoped {
  TextColumn get folioId => text().nullable()();
  TextColumn get invoiceId => text().nullable()();
  TextColumn get cashSessionId => text().nullable()();

  TextColumn get method => textEnum<PaymentMethod>()();

  /// Montant en francs CFA, entiers.
  IntColumn get amount => integer()();
  TextColumn get currency =>
      text().withLength(max: 8).withDefault(const Constant('XOF'))();

  /// Reference externe : numero de transaction carte, identifiant Mobile
  /// Money, reference de virement. Indispensable au rapprochement bancaire.
  TextColumn get reference => text().withLength(max: 80).nullable()();
  TextColumn get receivedBy => text().nullable()();
  DateTimeColumn get receivedAt => dateTime().nullable()();
  TextColumn get businessDate => text().withLength(max: 10).nullable()();
  BoolColumn get isRefund => boolean().withDefault(const Constant(false))();
  TextColumn get notes => text().withLength(max: 255).nullable()();
}
