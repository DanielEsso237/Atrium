/// Colonnes communes a toutes les tables de la base locale.
///
/// Ces mixins sont le pendant exact des classes de base SQLAlchemy du serveur
/// (`backend/app/db/base.py`). Les tenir identiques des deux cotes est ce qui
/// permettra a la synchronisation d'etre une simple recopie champ a champ.
///
/// ## Conventions de types
///
/// SQLite ne connait que cinq types de stockage : NULL, INTEGER, REAL, TEXT et
/// BLOB. Il n'a ni UUID, ni DECIMAL, ni DATE, ni BOOLEAN. Les choix ci-dessous
/// s'appliquent donc a tout le schema.
///
/// **Identifiants** -> TEXT. UUID v7 en representation canonique a 36
/// caracteres. Les UUID v7 commencent par un horodatage, donc l'ordre
/// alphabetique des chaines correspond a l'ordre de creation : les index
/// restent efficaces et `ORDER BY id` a un sens.
///
/// **Montants** -> INTEGER, en **francs CFA entiers**. Le franc CFA n'a pas de
/// subdivision en usage : un montant est un nombre entier de francs, point.
/// Pas de facteur d'echelle, pas de centimes, pas de conversion a l'affichage.
///
/// Jamais REAL : un double ne represente pas exactement 0,1 et une addition de
/// factures finit par deriver. On ne compte pas de l'argent en virgule
/// flottante.
///
/// Le serveur stocke la meme chose : un `bigint`. Aucune conversion nulle part
/// dans la chaine, donc aucun endroit ou une erreur de facteur puisse se
/// glisser. Le jour ou une devise a decimales apparaitrait, ce serait une
/// decision explicite et non une derive silencieuse.
///
/// **Quantites** -> INTEGER, sans echelle. On vend deux bieres, trois nuits,
/// un massage. Pour les stocks, la finesse vient de l'unite du produit
/// (`products.unit`) : on compte en grammes plutot qu'en kilogrammes, en
/// millilitres plutot qu'en litres. Aucune multiplication a retenir.
///
/// **Taux** -> INTEGER, en **points de base** (un centieme de pour cent).
/// Une TVA de 18 % se stocke 1800, un taux de 18,5 % se stocke 1850. C'est la
/// convention comptable usuelle, et elle se relit sans notice : diviser par
/// cent donne le pourcentage.
///
/// L'interet de tout garder en entiers plutot qu'en texte decimal : les
/// agregats SQL restent justes. Le chiffre d'affaires du jour affiche au
/// tableau de bord est un `SUM()` execute par SQLite, hors ligne, sans passer
/// par Dart.
///
/// **Horodatages** -> TEXT ISO-8601 en UTC. Impose par
/// `storeDateTimeValuesAsText` dans la configuration de la base. Un entier
/// Unix serait plus compact mais illisible quand on inspecte la base d'une
/// tablette sur site, et perdrait le fuseau.
///
/// **Dates seules** (date d'arrivee, journee hoteliere) -> TEXT `AAAA-MM-JJ`.
/// L'ordre alphabetique coincide avec l'ordre chronologique, donc les
/// comparaisons et les `BETWEEN` fonctionnent directement en SQL.
///
/// **Booleens** -> INTEGER 0/1, gere par Drift.
library;

import 'package:drift/drift.dart';

import 'enums.dart';

/// Diviseur des taux exprimes en points de base : 1800 -> 18 %.
const int kBasisPoints = 10000;

/// Cle primaire et horodatages, communs a absolument toutes les tables.
mixin BaseColumns on Table {
  /// UUID v7 genere par la tablette, jamais par le serveur.
  ///
  /// C'est ce qui permet de creer une reservation, de l'imprimer et de la
  /// facturer hors ligne sans attendre d'identifiant distant.
  TextColumn get id => text().withLength(min: 36, max: 36)();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Suppression logique.
///
/// Une suppression physique n'apparaitrait dans aucun delta et la ligne
/// reviendrait au prochain echange. Toutes les lectures de l'application
/// doivent filtrer `deletedAt IS NULL`.
mixin SoftDeleteColumns on Table {
  DateTimeColumn get deletedAt => dateTime().nullable()();
}

/// Traceurs d'ecriture et etat de replication.
mixin SyncColumns on Table {
  TextColumn get createdBy => text().nullable()();
  TextColumn get updatedBy => text().nullable()();

  /// Tablette d'origine de l'ecriture. Utile au diagnostic terrain et a
  /// l'arbitrage d'un conflit.
  TextColumn get originDeviceId => text().nullable()();

  /// Position de la ligne dans l'ordre total des modifications du serveur.
  /// Nul tant que la ligne n'a jamais ete synchronisee.
  IntColumn get changeSeq => integer().nullable()();

  /// Etat local de la ligne vis-a-vis du serveur.
  TextColumn get syncState =>
      textEnum<SyncState>().withDefault(const Constant('pending'))();
}

/// Rattachement a l'etablissement.
///
/// Mono-etablissement au demarrage, mais la colonne est posee des maintenant :
/// l'ajouter plus tard sur une soixantaine de tables deja peuplees, y compris
/// sur des tablettes deployees, couterait une migration lourde.
mixin HotelScoped on Table {
  TextColumn get hotelId => text().withLength(min: 36, max: 36)();
}

/// Raccourci : table metier complete, repliquee vers le serveur.
mixin SyncedTableColumns on Table {
  TextColumn get id => text().withLength(min: 36, max: 36)();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  TextColumn get createdBy => text().nullable()();
  TextColumn get updatedBy => text().nullable()();
  TextColumn get originDeviceId => text().nullable()();

  IntColumn get changeSeq => integer().nullable()();
  TextColumn get syncState =>
      textEnum<SyncState>().withDefault(const Constant('pending'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Table de referentiel : parametree a l'administration, lue partout.
mixin RefTableColumns on Table {
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}
