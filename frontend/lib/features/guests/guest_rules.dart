/// Ce qu'une fiche client doit porter pour etre **creee**.
///
/// Les regles ne valent qu'a la creation. Les clients deja en base n'ont
/// souvent ni telephone ni piece : les bloquer a la modification les rendrait
/// intouchables, et la lecture ne verifie rien du tout.
///
/// Deux niveaux, parce qu'on cree un client a deux endroits :
///
/// - **le module Clients** : la fiche complete, piece d'identite comprise.
///   Nom, prenom, telephone, type et numero de piece.
/// - **la creation rapide a la reservation** : le client est au telephone, on
///   a un nom et un numero, pas sa piece. Le cahier des charges exige la piece
///   au check-in (F1.2), pas a la reservation. Nom, prenom, telephone.
///
/// Rien de plus sans la fiche de reservation de l'hotel : un champ obligatoire
/// de trop empeche d'enregistrer un client qui n'a pas ses papiers sur lui.
///
/// Le serveur ne reprend pas ces regles : des creations anciennes attendent
/// peut-etre encore dans la file d'une tablette, et un refus la bloquerait.
library;

import '../../data/local/enums.dart';

const champRequis = 'Requis';

/// Message d'erreur d'un champ texte obligatoire, ou `null` s'il est rempli.
String? requiredText(String? value) =>
    (value == null || value.trim().isEmpty) ? champRequis : null;

/// Les champs manquants pour creer un client, dans l'ordre du formulaire.
///
/// `withDocument` : vrai dans le module Clients, faux a la reservation.
List<String> missingForCreation({
  required String firstName,
  required String lastName,
  required String? phone,
  IdDocumentType? documentType,
  String? documentNumber,
  bool withDocument = true,
}) {
  return [
    if (requiredText(firstName) != null) 'prenom',
    if (requiredText(lastName) != null) 'nom',
    if (requiredText(phone) != null) 'telephone',
    if (withDocument && documentType == null) 'type de piece',
    if (withDocument && requiredText(documentNumber) != null)
      'numero de piece',
  ];
}
