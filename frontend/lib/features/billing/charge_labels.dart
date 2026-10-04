/// Les categories de charge, dites en francais.
///
/// L'enumeration porte les codes du serveur — `FNB`, `MISC`, `LAUNDRY` — et
/// c'est tres bien pour la base. Mais un receptionniste n'a pas a deviner ce
/// que veut dire « FNB » dans une liste deroulante.
///
/// Un seul endroit pour ces libelles : la boite de consommation, le detail de
/// l'ardoise et la future facture doivent dire la meme chose.
library;

import 'package:flutter/widgets.dart';

import '../../core/ui/icons.dart';
import '../../data/local/enums.dart';

String chargeCategoryLabel(ChargeCategory c) => switch (c) {
  ChargeCategory.ROOM => 'Hébergement',
  ChargeCategory.FNB => 'Restaurant / bar',
  ChargeCategory.MINIBAR => 'Minibar',
  ChargeCategory.SPA => 'Spa et bien-être',
  ChargeCategory.LAUNDRY => 'Blanchisserie',
  ChargeCategory.TELEPHONE => 'Téléphone',
  ChargeCategory.TAX => 'Taxes',
  ChargeCategory.DISCOUNT => 'Remise',
  ChargeCategory.DEPOSIT => 'Acompte',
  ChargeCategory.MISC => 'Divers',
};

/// Les moyens de paiement, de meme (paragraphe 4.1).
String paymentMethodLabel(PaymentMethod m) => switch (m) {
  PaymentMethod.CASH => 'Espèces',
  PaymentMethod.CARD => 'Carte bancaire',
  PaymentMethod.TRANSFER => 'Virement',
  PaymentMethod.MOBILE_MONEY => 'Mobile Money',
  PaymentMethod.CITY_LEDGER => 'Facture société',
  PaymentMethod.VOUCHER => 'Bon / voucher',
};

/// L'icone de chaque categorie : la meme dans la fiche, l'ardoise et la
/// saisie.
IconData chargeCategoryIcon(ChargeCategory c) => switch (c) {
  ChargeCategory.ROOM => PhosphorIconsLight.bed,
  ChargeCategory.FNB => PhosphorIconsLight.forkKnife,
  ChargeCategory.MINIBAR => PhosphorIconsLight.wine,
  ChargeCategory.SPA => PhosphorIconsLight.flowerLotus,
  ChargeCategory.LAUNDRY => PhosphorIconsLight.tShirt,
  ChargeCategory.TELEPHONE => PhosphorIconsLight.phone,
  ChargeCategory.TAX => PhosphorIconsLight.receipt,
  ChargeCategory.DISCOUNT => PhosphorIconsLight.percent,
  ChargeCategory.DEPOSIT => PhosphorIconsLight.coins,
  ChargeCategory.MISC => PhosphorIconsLight.dotsThree,
};
