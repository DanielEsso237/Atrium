# Atrium — Base locale (SQLite / Drift)

> Schéma de la base embarquée sur chaque tablette.
> Fichiers : `frontend/lib/data/local/`

---

## 1. Ce que contient la base locale

**65 tables**, dont **61 répliquées** (miroir du serveur) et **4 purement locales**
(machinerie de synchronisation).

| Domaine | Tables | Fichier |
|---|---|---|
| Socle, sécurité, terminaux | 7 | `tables/core.dart` |
| Hébergement — chambres, tarifs | 6 | `tables/rooms.dart` |
| Clients | 3 | `tables/guests.dart` |
| Réservations et séjours | 5 | `tables/reservations.dart` |
| Facturation et caisse | 6 | `tables/billing.dart` |
| Restauration | 9 | `tables/restaurant.dart` |
| Housekeeping et maintenance | 7 | `tables/operations.dart` |
| Stocks | 8 | `tables/stock.dart` |
| Impression localisée | 5 | `tables/printing.dart` |
| Paramétrage | 3 | `tables/admin.dart` |
| **Synchronisation (local seul)** | **4** | `tables/sync.dart` |

Une seule table serveur n'est pas répliquée : `audit_logs`. La répliquer
multiplierait le volume transféré sans aucun usage terrain, et affaiblirait la
piste d'audit en la rendant modifiable hors ligne. Idem pour `refresh_tokens`,
`sync_change_log`, `sync_device_cursors`, `sync_conflicts` et `number_sequences`,
qui sont des mécanismes serveur.

---

## 2. Correspondance des types

SQLite ne connaît que cinq types de stockage : NULL, INTEGER, REAL, TEXT, BLOB.
Ni UUID, ni DECIMAL, ni DATE, ni BOOLEAN. D'où les conventions suivantes,
appliquées à tout le schéma.

| Concept | PostgreSQL | SQLite / Drift | Conversion |
|---|---|---|---|
| Identifiant | `uuid` | `TEXT(36)` | aucune |
| Montant | `bigint` | `INTEGER` | **aucune** |
| Quantité | `integer` | `INTEGER` | **aucune** |
| Taux / pourcentage | `integer` (points de base) | `INTEGER` | **aucune** |
| Horodatage | `timestamptz` | `TEXT` ISO-8601 UTC | aucune |
| Date seule | `date` | `TEXT` `AAAA-MM-JJ` | aucune |
| Booléen | `boolean` | `INTEGER` 0/1 | aucune |
| Énumération | `VARCHAR` + CHECK | `TEXT` | aucune |
| JSON | `jsonb` | `TEXT` | sérialisation |
| Binaire | `bytea` | `BLOB` | aucune |

### Aucune échelle nulle part

Un café à **500 FCFA** est stocké **`500`** — des deux côtés de la chaîne.
Pas de centimes, pas de facteur, pas de conversion à la synchronisation.

Le franc CFA n'a pas de subdivision en usage : un montant *est* un nombre
entier de francs. `REAL` est exclu d'office — un double ne représente pas
exactement 0,1 et une addition de factures finit par dériver. `numeric` côté
serveur n'apporterait qu'une partie décimale toujours nulle, plus un risque
d'oubli de conversion.

Les **quantités** sont également des entiers. On vend deux bières, trois nuits,
un massage. Pour les stocks, la finesse vient de l'unité du produit
(`products.unit`) : on compte en grammes plutôt qu'en kilogrammes, en
millilitres plutôt qu'en litres.

Seuls les **taux** portent une convention, et c'est la convention comptable
usuelle : les **points de base**, soit un centième de pour cent. Une TVA de
18 % vaut `1800`, un taux de 18,5 % vaut `1850`. Elle se relit sans notice —
diviser par cent donne le pourcentage.

Conséquence recherchée : il n'existe **aucun endroit** dans la chaîne où un
facteur d'échelle puisse être oublié, et la synchronisation recopie les valeurs
telles quelles. Les agrégats SQL restent par ailleurs justes : le « CA JOUR »
du tableau de bord est un `SUM()` exécuté par SQLite, hors ligne.

### Pourquoi les dates seules en texte

`AAAA-MM-JJ` est le seul format où l'**ordre alphabétique coïncide avec l'ordre
chronologique**. Les `BETWEEN`, les `ORDER BY` et les index fonctionnent donc
directement en SQL, sans conversion. Un entier Unix imposerait un calcul à
chaque comparaison de journée hôtelière.

---

## 3. Colonnes communes

Définies une fois dans `columns.dart`, via des mixins Drift — le pendant exact
des classes de base SQLAlchemy du serveur.

```dart
mixin SyncedTableColumns on Table {
  TextColumn  get id             => text().withLength(min: 36, max: 36)();
  DateTimeColumn get createdAt   => dateTime()();
  DateTimeColumn get updatedAt   => dateTime()();
  DateTimeColumn get deletedAt   => dateTime().nullable()();
  TextColumn  get createdBy      => text().nullable()();
  TextColumn  get updatedBy      => text().nullable()();
  TextColumn  get originDeviceId => text().nullable()();
  IntColumn   get changeSeq      => integer().nullable()();
  TextColumn  get syncState      => textEnum<SyncState>()...;
}
```

- **`id`** — UUID v7 généré par la tablette. C'est ce qui permet de créer une
  réservation, de l'imprimer et de la facturer hors ligne sans attendre un
  identifiant distant. L'horodatage en tête d'un UUID v7 rend les clés
  croissantes : les insertions se font en fin d'index B-tree.
- **`deletedAt`** — suppression logique. Une suppression physique n'apparaîtrait
  dans aucun delta et la ligne reviendrait au prochain échange.
- **`changeSeq`** — position dans l'ordre total des modifications du serveur.
  Nul tant que la ligne n'a jamais été synchronisée.
- **`syncState`** — `synced` / `pending` / `conflict`.

---

## 4. Configuration SQLite

Trois réglages posés dans `database.dart`, chacun pour une raison précise en
contexte kiosque :

| Pragma | Raison |
|---|---|
| `journal_mode = WAL` | Une tablette débranchée ou éteinte brutalement ne doit pas corrompre la base. Permet aussi de lire pendant qu'une écriture est en cours — la synchronisation en arrière-plan n'oblige pas l'écran à se figer. |
| `foreign_keys = ON` | SQLite désactive l'intégrité référentielle **par défaut**, et le réglage est par connexion, pas par base. Sans cette ligne, rien n'empêche une ligne de facture orpheline. |
| `busy_timeout = 5000` | Le worker de synchronisation et l'interface écrivent en concurrence ; sans délai d'attente, l'un échoue immédiatement sur un `SQLITE_BUSY`. |

**Bibliothèque native** : `package:sqlite3` 3.x embarque SQLite lui-même via les
*hooks* de build Dart. Toutes les tablettes du parc utilisent donc la même
version du moteur, quel que soit leur constructeur ou leur version d'Android —
point important quand Android en livre des versions variables.

Le paquet `sqlite3_flutter_libs` n'est **plus nécessaire** : depuis sa version
0.6.0 c'est une coquille vide, publiée uniquement pour empêcher les anciens
scripts de build de subsister. Il a été retiré des dépendances.

---

## 5. Index

Drift crée les index des clés primaires. Ceux de `_createIndexes()` visent les
écrans qui doivent rester instantanés au doigt :

- **plan de l'hôtel** (§5.2) — `rooms(occupancy_status)`, `rooms(housekeeping_status)`
- **arrivées et départs du jour** — `reservations(arrival_date, departure_date)`,
  `reservation_rooms(room_id, arrival_date, departure_date)`
- **recherche client** — `guests(last_name)`, `guests(phone)`, `guests(id_document_number)`
- **écrans cuisine et bar** (F3.4) — `order_items(prep_station_id, status)`
- **file d'impression** (R2) — `print_jobs(status, created_at)`
- **housekeeping du jour** — `housekeeping_tasks(business_date, status)`

---

## 6. Tables locales de synchronisation

Présentes dès la version 1 du schéma mais **inertes** : le moteur d'échange
n'est pas encore écrit. Les poser maintenant évite une migration sur des
tablettes déjà déployées le jour où la synchronisation sera branchée.

| Table | Rôle |
|---|---|
| `outbox_entries` | File des écritures locales à pousser. L'ordre d'insertion est l'ordre d'envoi : créer une réservation puis lui attribuer une chambre doit arriver dans cet ordre. |
| `sync_cursors` | Un entier par table : la position atteinte dans l'ordre total du serveur. |
| `sync_statuses` | Ligne unique. Alimente l'indicateur « en ligne / hors ligne » que l'agent doit voir en permanence. |
| `file_uploads` | File séparée pour les photos, signatures et scans. Une photo de 3 Mo ne doit pas retarder le ticket de maintenance urgent qu'elle accompagne. |

---

## 7. Inspecter la base

1. **Développement sur Windows** — la base est un fichier `.sqlite` dans le
   dossier Documents de l'application, ouvrable dans **DB Browser for SQLite**
   pendant que l'appli tourne. Boucle de debug la plus rapide.
2. **`drift_db_viewer`** — écran d'inspection intégré à l'application, à placer
   derrière un geste caché en mode kiosque. Seul moyen de déboguer une tablette
   déjà déployée à la réception.
3. **Extension Drift de Flutter DevTools** — onglet dédié en mode debug.
4. **Extraction Android** (build debug uniquement) :
   `adb exec-out run-as com.atrium.atrium cat databases/atrium.sqlite > atrium.sqlite`

À prévoir dans l'écran d'administration : un bouton **« exporter la base »** qui
copie le fichier vers le stockage partagé ou l'envoie au serveur. Le jour où une
tablette a un problème de synchronisation sur site, récupérer sa base sans la
rooter fera gagner des heures.

---

## 8. Divergences assumées avec le schéma serveur

| Point | Serveur | Tablette | Raison |
|---|---|---|---|
| Clés étrangères déclarées | Oui, sur toutes les relations | Sur les **16 relations de composition** seulement (voir §9) | Les référentiels peuvent sortir de la fenêtre glissante ; contraindre `guest_id` ou `room_id` rejetterait des lignes parfaitement valides. |
| `audit_logs` | Présente | Absente | Volume inutile côté terrain, et piste d'audit non modifiable hors ligne. |
| Vues statistiques | Vues PostgreSQL | Requêtes Drift | Les agrégats locaux portent sur la fenêtre répliquée, pas sur tout l'historique. |
| Portée des données | Tout l'historique | Fenêtre glissante (90 j passés, 365 j à venir) | Base locale légère, premier sync rapide. Référentiels répliqués intégralement. |

---

## 9. Clés étrangères

Activées sur les **relations de composition** : celles où l'enfant n'a aucun
sens sans son parent.

| Enfant | Parent |
|---|---|
| `reservation_rooms` | `reservations` |
| `stay_nights`, `reservation_guests` | `reservation_rooms` |
| `folio_items` | `folios` |
| `invoice_lines` | `invoices` |
| `order_items` | `orders` |
| `order_item_options` | `order_items` |
| `menu_item_options` | `menu_items` |
| `housekeeping_task_items`, `amenity_consumptions` | `housekeeping_tasks` |
| `maintenance_interventions` | `maintenance_tickets` |
| `inventory_lines` | `inventories` |
| `guest_documents` | `guests` |
| `rate_plan_prices` | `rate_plans` |
| `role_permissions` | `roles`, `permissions` |
| `user_roles` | `users`, `roles` |

Toutes en `ON DELETE CASCADE` : c'est ce qui permettra de purger une période
entière quand la fenêtre glissante avancera, sans laisser d'orphelins. La
suppression *métier* reste logique (`deletedAt`) — la suppression physique n'a
lieu qu'à la purge.

### Ce qui n'est **pas** contraint, et pourquoi

Les références vers un référentiel (`guest_id`, `room_id`, `company_id`,
`assigned_to`, `menu_item_id` sur une ligne de commande…) restent des colonnes
`TEXT` libres. Deux raisons :

- la tablette ne détient qu'une **fenêtre glissante** ; un client ou une
  chambre peut légitimement ne pas y être ;
- `order_items.label_snapshot` existe précisément pour que la ligne survive à
  la disparition de l'article du menu. Une contrainte la contredirait.

### Ordre d'arrivée : `defer_foreign_keys`

Une contrainte FK impose normalement que le parent soit inséré avant l'enfant.
Un lot venu du serveur devrait donc arriver dans un ordre strictement
topologique — condition fragile à garantir.

`AtriumDatabase.syncTransaction()` lève la contrainte d'ordre en posant
`PRAGMA defer_foreign_keys = ON` au début de la transaction : le contrôle est
reporté au **commit**. À l'intérieur d'un lot, l'ordre n'a plus d'importance ;
seule compte la cohérence du lot une fois complet.

Le contrôle a bien lieu : un lot qui référence un parent absent est rejeté
**en bloc**, ce qui est exactement le comportement voulu. Le pragma se
réinitialise de lui-même à la fin de chaque transaction.

Quatre tests couvrent ce comportement dans `test/foreign_keys_test.dart` :
contrainte active, cascade effective, ordre libre dans un lot, rejet d'un lot
incohérent.
