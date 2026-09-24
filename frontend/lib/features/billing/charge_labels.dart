/// Les categories de charge, dites en francais.
///
/// L'enumeration porte les codes du serveur — `FNB`, `MISC`, `LAUNDRY` — et
/// c'est tres bien pour la base. Mais un receptionniste n'a pas a deviner ce
/// que veut dire « FNB » dans une liste deroulante.
///
/// Un seul endroit pour ces libelles : la boite de consommation, le detail de
/// l'ardoise et la future facture doivent dire la meme chose.
library;

import '../../data/local/enums.dart';

String chargeCategoryLabel(ChargeCategory c) => switch (c) {
  ChargeCategory.ROOM => 'Hebergement',
  ChargeCategory.FNB => 'Restaurant / bar',
  ChargeCategory.MINIBAR => 'Minibar',
  ChargeCategory.SPA => 'Spa et bien-etre',
  ChargeCategory.LAUNDRY => 'Blanchisserie',
  ChargeCategory.TELEPHONE => 'Telephone',
  ChargeCategory.TAX => 'Taxes',
  ChargeCategory.DISCOUNT => 'Remise',
  ChargeCategory.DEPOSIT => 'Acompte',
  ChargeCategory.MISC => 'Divers',
};

/// Les moyens de paiement, de meme (paragraphe 4.1).
String paymentMethodLabel(PaymentMethod m) => switch (m) {
  PaymentMethod.CASH => 'Especes',
  PaymentMethod.CARD => 'Carte bancaire',
  PaymentMethod.TRANSFER => 'Virement',
  PaymentMethod.MOBILE_MONEY => 'Mobile Money',
  PaymentMethod.CITY_LEDGER => 'Facture societe',
  PaymentMethod.VOUCHER => 'Bon / voucher',
};
