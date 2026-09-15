# Atrium — Modèle de données (MCD / MLD)

> Réf. cahier des charges « Système de gestion hôtelière sur tablettes », livrable §9.
> Cible : **PostgreSQL** (serveur central) + **SQLite/Drift** (tablette, offline-first).

---

## 0. Principes transverses

### 0.1 Le schéma local est un sous-ensemble du schéma serveur

Mêmes noms de tables, mêmes noms de colonnes, mêmes types logiques des deux côtés.
La synchronisation devient un mapping 1:1 — aucune traduction de modèle.

Les tables **non répliquées** sur la tablette sont marquées `SERVEUR` ci-dessous
(journal d'audit, change log, états de sync des autres appareils…).
Les tables **locales uniquement** sont marquées `LOCAL` (outbox, curseurs).

### 0.2 Colonnes de synchronisation (toute table métier)

| Colonne | Type | Rôle |
|---|---|---|
| `id` | `uuid` PK | **UUID v7**, généré **par le client**. Ordonnable dans le temps (bon pour les index B-tree) et sans collision entre tablettes hors ligne. |
| `created_at` | `timestamptz` | Horodatage de création (horloge du terminal créateur). |
| `updated_at` | `timestamptz` | Dernière modification. |
| `deleted_at` | `timestamptz NULL` | **Soft delete**. Obligatoire : une suppression physique ne peut pas se propager vers une tablette hors ligne. Toutes les lectures filtrent `deleted_at IS NULL`. |
| `change_seq` | `bigint` | *Serveur uniquement.* Numéro de séquence global monotone (voir §0.3). |
| `created_by` / `updated_by` | `uuid → users.id` | Traçabilité (exigence 6.2). |
| `origin_device_id` | `uuid → devices.id` | Tablette d'origine de l'écriture. Sert à l'arbitrage et au débogage terrain. |

Côté **Drift** uniquement, deux colonnes de plus :

| Colonne | Type | Rôle |
|---|---|---|
| `sync_state` | `text` | `synced` \| `pending` \| `conflict` |
| `server_seq` | `int NULL` | Dernier `change_seq` connu pour cette ligne (détection de conflit). |

### 0.3 Pourquoi `change_seq` et pas `updated_at` pour le pull delta

Un pull « donne-moi tout ce qui a changé depuis `updated_at > X` » est **cassé** en pratique :
horloges désynchronisées entre tablettes, et surtout transactions concurrentes qui committent
dans le désordre (une ligne écrite à T mais commitée après le pull à T+1 est perdue pour toujours).

On utilise donc une **séquence PostgreSQL globale** (`sync_seq`) incrémentée par trigger
sur chaque `INSERT`/`UPDATE`/`DELETE` logique. Le client ne retient qu'un entier par table
(`sync_cursors.last_seq`) et demande `WHERE change_seq > :last_seq ORDER BY change_seq`.
Monotone, sans trou observable, insensible aux horloges.

### 0.4 Montants, quantités et taux

**Montants : `bigint`, en francs CFA entiers.** Le franc CFA n'a pas de
subdivision en usage — un montant est un nombre entier de francs. Jamais de
`float` : un double ne représente pas exactement 0,1 et une addition de
factures finit par dériver. Pas de `numeric` non plus, dont la partie décimale
serait toujours nulle tout en ajoutant un risque d'oubli de conversion.

**Quantités : `integer`.** On vend deux bières, trois nuits. Pour les stocks, la
finesse vient de l'unité du produit (`products.unit`) : grammes plutôt que
kilogrammes, millilitres plutôt que litres.

**Taux : `integer` en points de base** (un centième de pour cent). Une TVA de
18 % vaut `1800`. C'est la convention comptable usuelle.

La tablette stocke exactement la même chose, donc la synchronisation recopie
les valeurs sans aucune conversion : il n'existe aucun endroit de la chaîne où
un facteur d'échelle puisse être oublié.

---

## 1. Socle, sécurité, terminaux

| Table | Colonnes principales |
|---|---|
| `hotels` | `code`, `name`, `address`, `city`, `country`, `phone`, `email`, `tax_id`, `logo_path`, `timezone`, `currency` |
| `users` | `employee_code`, `first_name`, `last_name`, `email`, `phone`, `password_hash`, `pin_hash`, `badge_code`, `is_active`, `last_login_at`, `must_change_password` |
| `roles` | `code` (`ADMIN`, `RECEPTION`, `CAISSE`, `RESTAURANT`, `HOUSEKEEPING`, `MAINTENANCE`, `MANAGER`), `label`, `is_system` |
| `permissions` | `code` (`reservation.create`, `folio.discount`, `print.reprint`…), `label`, `module` |
| `role_permissions` | `role_id`, `permission_id` |
| `user_roles` | `user_id`, `role_id` |
| `devices` | `device_uid` (identifiant matériel), `name`, `location`, `default_role_id`, `default_outlet_id`, `is_kiosk`, `app_version`, `last_seen_at`, `last_sync_at`, `is_active` |
| `refresh_tokens` `SERVEUR` | `user_id`, `device_id`, `token_hash`, `expires_at`, `revoked_at` |
| `audit_logs` `SERVEUR` | `user_id`, `device_id`, `entity_table`, `entity_id`, `action`, `before` `jsonb`, `after` `jsonb`, `ip`, `occurred_at` |

**Auth (§6.2)** : trois voies d'entrée — mot de passe, **code PIN** (usage kiosque : rebascule
rapide d'un agent à l'autre sur la même tablette) et **badge**. D'où trois colonnes de secret
distinctes sur `users`, toutes hachées.

---

## 2. Hébergement — chambres

| Table | Colonnes principales |
|---|---|
| `floors` | `hotel_id`, `code`, `label`, `sort_order`, `map_image_path` |
| `room_types` | `code`, `label`, `description`, `base_capacity`, `max_capacity`, `default_rate`, `amenities` `jsonb`, `photo_path` |
| `rooms` | `number`, `room_type_id`, `floor_id`, `occupancy_status`, `housekeeping_status`, `is_out_of_order`, `map_x`, `map_y`, `phone_ext`, `notes`, `is_active` |
| `rate_plans` | `code`, `label`, `room_type_id`, `is_default`, `valid_from`, `valid_to`, `min_nights`, `includes_breakfast` |
| `rate_plan_prices` | `rate_plan_id`, `date_from`, `date_to`, `weekday_mask`, `price` |
| `taxes` | `code`, `label`, `mode` (`PERCENT` \| `PER_NIGHT` \| `PER_PERSON_NIGHT`), `rate`, `applies_to`, `is_included` |

### Comment le parc est organisé

Trois niveaux, et un seul porte le prix.

```
room_types  ──<  rooms  >──  floors
 catégorie       chambre       étage
 + LE PRIX       + le n°       + le plan
```

**`room_types`** est la catégorie commerciale : Standard, Classic, VIP, Suite.
Elle porte `default_rate`, la capacité, les équipements, la photo.

**`rooms`** est la chambre physique : un numéro, un type, un étage, et ses trois
axes d'état. Elle **ne porte aucun prix**.

C'est le point de conception. Deux chambres de même catégorie se vendent au même
tarif. Mettre le prix sur la chambre obligerait à soixante écritures pour une
revalorisation de gamme, et garantirait qu'au bout de six mois la 203 et la 309
ne coûtent plus pareil sans que personne ne sache pourquoi.

Le numéro et la catégorie sont **indépendants** : rien n'impose que les VIP
soient contiguës ni sur le même étage. Surclasser une chambre revient à changer
son `room_type_id` — le client de la 203 garde son numéro de porte.

| Table | Rôle | Porte le prix ? |
|---|---|---|
| `room_types` | Catégorie commerciale | **oui** — `default_rate` |
| `rate_plans` + `rate_plan_prices` | Tarifs par période et jour de semaine | **oui** — prix effectif |
| `rooms` | Chambre physique, numéro, état | non |
| `floors` | Étage, fond de plan | non |

`default_rate` est le tarif de référence, celui qu'on affiche sans date. Le prix
réellement facturé vient de `rate_plan_prices`, résolu nuit par nuit et figé
dans `stay_nights` — c'est ce qui permet qu'un séjour à cheval sur un week-end
produise une facture détaillée ligne à ligne.

#### Jeu de démonstration

`backend/app/db/seed.py` et `frontend/lib/data/local/seed.dart` créent le même
établissement de 18 chambres, avec des identifiants **fixes et identiques des
deux côtés** — sinon la première synchronisation dupliquerait le paramétrage.

| Catégorie | Code | Tarif | Chambres |
|---|---|---|---|
| Standard | `STD` | 25 000 | 101, 102, **123**, 204, 302, 401, **567** |
| Classic | `CLS` | 35 000 | 103, 201, 202, 301, 402 |
| VIP | `VIP` | 60 000 | **203**, **309**, 403, 510 |
| Suite | `SUI` | 90 000 | 501, 502 |

Les numéros sont arbitraires et provisoires. Le jeu est **idempotent** : le
rejouer met à jour les lignes au lieu d'en créer.

---

### Décision : l'état d'une chambre est sur **trois axes**, pas un

Le cahier des charges (§5.2) affiche un état unique : 🟢 Disponible / 🔴 Occupée / 🟡 Réservée /
🔵 Nettoyage / ⚫ Maintenance. C'est le bon affichage, mais un **mauvais stockage** : ces valeurs
ne sont pas mutuellement exclusives. Une chambre peut être occupée *et* en cours de nettoyage ;
une chambre en maintenance peut aussi être sale.

On stocke donc :

- `occupancy_status` : `VACANT` \| `RESERVED` \| `OCCUPIED`
- `housekeeping_status` : `CLEAN` \| `DIRTY` \| `IN_PROGRESS` \| `INSPECTED`
- `is_out_of_order` : booléen (+ `out_of_order_reason`, `out_of_order_until`)

et la pastille de l'écran §5.2 est **calculée** par priorité :
`maintenance > nettoyage en cours > occupée > réservée > disponible`.

Ces colonnes sont **matérialisées** (et non dérivées à la volée des réservations) : la tablette
doit pouvoir peindre le plan de l'hôtel instantanément et hors ligne, sans recalculer des
intersections de dates sur toute la table `reservations`.

---

## 3. Clients

| Table | Colonnes principales |
|---|---|
| `guests` | `code`, `title`, `first_name`, `last_name`, `birth_date`, `nationality`, `id_document_type`, `id_document_number`, `id_document_expiry`, `email`, `phone`, `address`, `city`, `country`, `company_id`, `preferences` `jsonb`, `notes`, `is_blacklisted`, `blacklist_reason`, `marketing_consent`, `consent_at` |
| `guest_documents` | `guest_id`, `doc_type`, `file_path_local`, `file_url`, `upload_state`, `captured_at` |
| `companies` | `name`, `tax_id`, `address`, `contact_name`, `phone`, `email`, `credit_limit`, `payment_terms` |

**RGPD (§8)** : `marketing_consent` + `consent_at` explicites, et `guests` est la seule table
portant des données personnelles en clair — ce qui rend le chiffrement au repos (§6.2) et
le droit à l'effacement ciblables sur un périmètre réduit.

`companies` couvre le client corporate / agence — absent du cahier des charges mais
indissociable d'une facturation hôtelière réelle (facture au nom d'une société, débiteur
différent de l'occupant).

---

## 4. Réservations et séjours

| Table | Colonnes principales |
|---|---|
| `reservations` | `reference`, `guest_id`, `company_id`, `source` (`DIRECT`,`PHONE`,`WALK_IN`,`OTA`,`CORPORATE`), `status`, `arrival_date`, `departure_date`, `adults`, `children`, `estimated_total`, `deposit_amount`, `deposit_paid_at`, `special_requests`, `cancelled_at`, `cancel_reason` |
| `reservation_rooms` | `reservation_id`, `room_type_id`, `room_id` `NULL`, `rate_plan_id`, `arrival_date`, `departure_date`, `adults`, `children`, `nightly_rate`, `status`, `checked_in_at`, `checked_in_by`, `checked_out_at`, `checked_out_by`, `key_card_code` |
| `stay_nights` | `reservation_room_id`, `business_date`, `room_id`, `rate`, `is_posted`, `posted_at` |
| `reservation_guests` | `reservation_room_id`, `guest_id`, `is_primary` |
| `signatures` | `entity_table`, `entity_id`, `kind` (`CHECK_IN`,`CHECK_OUT`,`INVOICE`), `image_path_local`, `image_url`, `signed_at`, `signed_by_name` |

**`status` de `reservations`** : `PENDING` → `CONFIRMED` → `CHECKED_IN` → `CHECKED_OUT`,
plus `CANCELLED` et `NO_SHOW`.

### Décision : `reservation_rooms` porte le séjour

Une réservation peut couvrir plusieurs chambres (famille, groupe, séminaire) avec des dates
et des tarifs différents. Le check-in / check-out se fait **par chambre**, pas par réservation.
Toute la logique opérationnelle s'accroche donc à `reservation_rooms` : c'est cette ligne qui
est attribuée à une chambre, qui porte le folio, et qui a un statut propre.

### Décision : `stay_nights`, une ligne par nuit

Le prix d'une nuitée n'est pas constant sur un séjour (haute/basse saison, surclassement,
remise négociée le 3ᵉ jour). Matérialiser chaque nuit sert trois choses à la fois :
la **facture détaillée**, le **CA journalier** du dashboard (§5.1 « CA JOUR ») sans recalcul,
et le *night audit* qui poste automatiquement la charge de la nuit sur le folio.

### F1.2 — Signature électronique

Table `signatures` polymorphe, avec `image_path_local` **et** `image_url` : la signature est
capturée hors ligne sur la tablette, stockée en fichier local, et l'upload est une opération
de sync distincte de celle de la ligne métier (un binaire ne passe pas dans l'outbox JSON).
Même mécanique pour les photos de maintenance (§7) et les pièces d'identité.

---

## 5. Facturation et caisse

| Table | Colonnes principales |
|---|---|
| `folios` | `reservation_room_id` `NULL`, `guest_id`, `company_id` `NULL`, `type` (`GUEST`,`MASTER`,`WALK_IN`,`TABLE`), `status` (`OPEN`,`CLOSED`,`SETTLED`), `balance`, `opened_at`, `closed_at` |
| `folio_items` | `folio_id`, `category` (`ROOM`,`FNB`,`MINIBAR`,`SPA`,`LAUNDRY`,`TAX`,`DISCOUNT`,`MISC`), `label`, `quantity`, `unit_price`, `amount`, `tax_amount`, `business_date`, `source_table`, `source_id`, `posted_by`, `is_void`, `void_reason` |
| `invoices` | `number`, `folio_id`, `guest_id`, `company_id`, `issued_at`, `subtotal`, `tax_total`, `discount_total`, `total`, `status` (`DRAFT`,`ISSUED`,`PAID`,`CANCELLED`), `pdf_path`, `is_provisional` |
| `invoice_lines` | `invoice_id`, `label`, `quantity`, `unit_price`, `tax_rate`, `amount` |
| `payments` | `folio_id`, `invoice_id` `NULL`, `method` (`CASH`,`CARD`,`TRANSFER`,`MOBILE_MONEY`,`CITY_LEDGER`,`VOUCHER`), `amount`, `currency`, `reference`, `received_by`, `cash_session_id`, `received_at`, `is_refund` |
| `cash_sessions` | `user_id`, `device_id`, `opened_at`, `opening_float`, `closed_at`, `counted_amount`, `expected_amount`, `variance`, `status`, `notes` |

### Décision : le **folio** est le centre de la facturation

Toute charge — nuitée, addition du restaurant, minibar, spa — atterrit dans `folio_items`,
avec un couple `(source_table, source_id)` qui remonte à son origine (`orders`, `stay_nights`…).
La facture (`invoices`) n'est alors qu'un **gel** du folio à un instant donné : on peut émettre
une facture partielle, une facture provisoire pendant le séjour, ou éclater un folio entre
le client et sa société, sans jamais toucher aux charges d'origine.

C'est aussi ce qui rend F3.6 (« report chambre ou paiement direct ») trivial : un report chambre,
c'est un `folio_item` sur le folio de la chambre ; un paiement direct, c'est un folio de type
`TABLE` ouvert et soldé dans la foulée.

### `cash_sessions` → « Rapport de shift » (§4.2)

Le document « Rapport de shift » listé dans la matrice d'impression n'a pas de source de données
dans le cahier des charges. `cash_sessions` la fournit : ouverture de caisse avec fond,
encaissements rattachés (`payments.cash_session_id`), fermeture avec comptage et écart.

---

## 6. Restauration

| Table | Colonnes principales |
|---|---|
| `outlets` | `code` (`RESTAURANT`,`BAR`,`POOL`,`ROOM_SERVICE`), `label`, `is_active`, `opens_at`, `closes_at` |
| `prep_stations` | `code` (`CUISINE`,`BAR`,`PATISSERIE`), `label`, `printer_id` |
| `restaurant_tables` | `outlet_id`, `number`, `capacity`, `zone`, `status` (`FREE`,`OCCUPIED`,`RESERVED`), `map_x`, `map_y` |
| `menu_categories` | `outlet_id`, `label`, `sort_order` |
| `menu_items` | `menu_category_id`, `code`, `label`, `description`, `price`, **`prep_station_id`** `NULL`, `is_available`, `allergens` `jsonb`, `photo_path`, `sort_order` |
| `menu_item_options` | `menu_item_id`, `label`, `price_delta`, `group_label`, `is_required` |
| `orders` | `number`, `outlet_id`, `type` (`ON_SITE`,`ROOM_SERVICE`,`TAKEAWAY`,`DELIVERY`), `restaurant_table_id` `NULL`, `room_id` `NULL`, `folio_id` `NULL`, `waiter_id`, `status`, `opened_at`, `sent_at`, `ready_at`, `served_at`, `total`, `covers` |
| `order_items` | `order_id`, `menu_item_id`, `label_snapshot`, `quantity`, `unit_price`, `amount`, `notes`, `prep_station_id`, `status`, `sent_at`, `ready_at`, `is_void`, `void_reason` |
| `order_item_options` | `order_item_id`, `menu_item_option_id`, `label_snapshot`, `price_delta` |

### Décision : `prep_station_id` porté par `menu_items`, et recopié sur `order_items`

C'est **la** clé de la règle R1 du cahier des charges (« un ticket cuisine ne doit *jamais*
être envoyé au bar »). En attachant la station de préparation à l'article du menu, le routage
d'impression devient une conséquence du modèle de données et non une règle applicative qu'un
développeur peut oublier : une commande mixte est automatiquement scindée en un ticket cuisine
et un ticket bar, parce que ses lignes ont des `prep_station_id` différents.

`label_snapshot` et `unit_price` sont **dupliqués** sur `order_items` : une commande imprimée
et facturée ne doit pas changer rétroactivement parce que le gérant a modifié le prix ou le
nom du plat une heure plus tard.

`orders.status` : `DRAFT` → `SENT` → `IN_PREP` → `READY` → `SERVED`, plus `CANCELLED` (F3.4).

---

## 7. Housekeeping et maintenance

| Table | Colonnes principales |
|---|---|
| `housekeeping_tasks` | `room_id`, `type` (`DEPARTURE`,`STAYOVER`,`REFRESH`,`DEEP_CLEAN`,`INSPECTION`), `business_date`, `priority`, `status`, `assigned_to`, `started_at`, `finished_at`, `duration_minutes`, `inspected_by`, `inspected_at`, `notes` |
| `housekeeping_task_items` | `task_id`, `label`, `is_done`, `remark` |
| `amenity_consumptions` | `task_id`, `product_id`, `quantity` |
| `equipments` | `code`, `label`, `category`, `room_id` `NULL`, `location`, `brand`, `model`, `serial_number`, `installed_at`, `warranty_until` |
| `maintenance_tickets` | `number`, `room_id` `NULL`, `equipment_id` `NULL`, `location`, `category`, `priority` (`LOW`,`NORMAL`,`HIGH`,`URGENT`), `title`, `description`, `status`, `reported_by`, `reported_at`, `assigned_to`, `assigned_at`, `resolved_at`, `closed_at`, `resolution`, `cost`, `blocks_room` |
| `maintenance_interventions` | `ticket_id`, `technician_id`, `started_at`, `ended_at`, `description`, `parts_used` `jsonb`, `cost` |
| `attachments` | `entity_table`, `entity_id`, `kind`, `file_path_local`, `file_url`, `mime_type`, `size_bytes`, `upload_state`, `captured_at`, `captured_by` |

**F2.3 (signalement avec photo)** et **F5.4** passent par la table générique `attachments`,
identique dans son principe à `signatures` : chemin local d'abord, URL serveur après upload,
`upload_state` piloté par un worker de sync distinct.

`maintenance_tickets.blocks_room` fait le lien avec `rooms.is_out_of_order` : clôturer un
ticket bloquant libère automatiquement la chambre.

---

## 8. Stocks

| Table | Colonnes principales |
|---|---|
| `product_categories` | `label`, `parent_id`, `sort_order` |
| `products` | `reference`, `label`, `category_id`, `unit`, `purchase_price`, `sale_price`, `min_stock`, `is_sellable`, `is_active`, `barcode` |
| `stock_locations` | `code` (`ECONOMAT`,`CUISINE`,`BAR`,`HOUSEKEEPING`), `label`, `manager_id` |
| `stock_levels` | `product_id`, `stock_location_id`, `quantity`, `last_movement_at` |
| `stock_movements` | `product_id`, `stock_location_id`, `type` (`IN`,`OUT`,`TRANSFER`,`ADJUSTMENT`,`LOSS`,`RETURN`), `quantity`, `unit_cost`, `reason`, `source_table`, `source_id`, `counterpart_location_id`, `moved_at`, `moved_by` |
| `inventories` | `stock_location_id`, `label`, `status`, `started_at`, `closed_at`, `closed_by` |
| `inventory_lines` | `inventory_id`, `product_id`, `theoretical_qty`, `counted_qty`, `variance`, `comment` |
| `suppliers` | `name`, `contact_name`, `phone`, `email`, `address`, `payment_terms`, `is_active` |

`stock_levels` est une table **maintenue** (et non une vue) : la tablette doit afficher un
stock hors ligne sans agréger l'historique complet des mouvements. `stock_movements` reste
la source de vérité, `stock_levels` est reconstruit côté serveur en cas de divergence.

---

## 9. Impression localisée — le cœur du projet (§4.2)

| Table | Colonnes principales |
|---|---|
| `printers` | **`logical_name`** (`IMP_CUISINE_01`), `label`, `kind` (`LASER`,`THERMAL`), `protocol` (`IPP`,`LPD`,`ESCPOS_NET`,`ESCPOS_USB`,`RAW9100`), `host`, `port`, `paper_width_mm`, `location`, `prep_station_id` `NULL`, `is_active`, `is_online`, `last_heartbeat_at`, `fallback_printer_id` |
| `document_types` | `code` (`KITCHEN_TICKET`,`BAR_TICKET`,`GUEST_INVOICE`,`HK_TASK_SHEET`,`SHIFT_REPORT`,`MAINTENANCE_ORDER`,`ROOM_SERVICE_TICKET`), `label`, `default_kind` |
| `print_routes` | `document_type_id`, `match_outlet_id` `NULL`, `match_prep_station_id` `NULL`, `match_device_id` `NULL`, `match_role_id` `NULL`, `printer_id`, `priority`, `is_active` |
| `document_templates` | `document_type_id`, `version`, `format` (`ESCPOS`,`HTML`,`PDF`), `content`, `is_active` |
| `print_jobs` | `document_type_id`, `printer_id`, `payload` `jsonb`, `rendered` `bytea`/`blob`, `status`, `attempts`, `last_error`, `is_duplicate`, `original_job_id` `NULL`, `requested_by`, `requested_from_device_id`, `created_at`, `sent_at`, `printed_at` |

Correspondance directe avec les règles du cahier des charges :

| Règle | Mécanisme |
|---|---|
| **R1** — cuisine ≠ bar | `order_items.prep_station_id` → `print_routes.match_prep_station_id` → `printers`. Le mauvais routage devient structurellement impossible. |
| **R2** — imprimante hors ligne → file + alerte | `print_jobs.status` = `QUEUED` → `SENT` → `PRINTED` \| `FAILED`, avec `attempts`/`last_error` ; `printers.is_online` + `last_heartbeat_at` déclenchent l'alerte, `fallback_printer_id` permet le repli. |
| **R3** — réimpression « DUPLICATA » | Nouveau `print_jobs` avec `is_duplicate = true` et `original_job_id` renseigné ; le template imprime le bandeau. |
| **R4** — nom logique | `printers.logical_name`, unique. L'application ne connaît jamais une IP. |
| **R5** — routage configurable | `print_routes` éditable depuis l'admin, résolu par `priority` décroissante sur le premier critère qui matche. |

`print_jobs` vit **aussi sur la tablette** : un ticket créé pendant une coupure Wi-Fi est mis
en file localement et part à la reconnexion. C'est la file d'attente exigée au §6.3.

---

## 10. Synchronisation

### Côté serveur

| Table | Colonnes principales |
|---|---|
| `sync_change_log` `SERVEUR` | `seq` `bigserial` (séquence globale), `entity_table`, `entity_id`, `op` (`INSERT`,`UPDATE`,`DELETE`), `changed_at`, `changed_by_device_id`, `payload` `jsonb` |
| `sync_device_cursors` `SERVEUR` | `device_id`, `entity_table`, `last_seq_pulled`, `last_pull_at`, `last_push_at` |
| `sync_conflicts` `SERVEUR` | `entity_table`, `entity_id`, `device_id`, `client_payload` `jsonb`, `server_payload` `jsonb`, `resolution` (`SERVER_WINS`,`CLIENT_WINS`,`MERGED`,`MANUAL`), `resolved_by`, `resolved_at` |
| `number_sequences` `SERVEUR` | `scope` (`INVOICE`,`RESERVATION`,`ORDER`,`TICKET`), `prefix`, `period`, `current_value` |

### Côté tablette (Drift)

| Table | Colonnes principales |
|---|---|
| `outbox` `LOCAL` | `entity_table`, `entity_id`, `op`, `payload` `json`, `created_at`, `attempts`, `last_error`, `status` (`PENDING`,`SENDING`,`ACKED`,`FAILED`) |
| `sync_cursors` `LOCAL` | `entity_table`, `last_seq`, `last_pull_at` |
| `sync_state` `LOCAL` | `device_id`, `user_id`, `last_full_sync_at`, `is_online`, `pending_count` |
| `file_uploads` `LOCAL` | `entity_table`, `entity_id`, `local_path`, `status`, `attempts`, `last_error` |

### Le cycle

1. **PUSH** — l'outbox est vidée dans l'ordre d'insertion, par lots, en une transaction serveur.
   Idempotent : la PK étant un UUID client, un rejeu ne crée pas de doublon (`ON CONFLICT DO UPDATE`).
2. **PULL** — pour chaque table, `GET /sync/{table}?since={last_seq}` ; application en transaction ;
   `last_seq` avancé seulement après commit local.
3. **FICHIERS** — worker séparé pour photos, signatures, PDF (`file_uploads`).

### Conflits (§6.3)

Trois politiques selon la nature de la donnée, et non une politique unique :

| Donnée | Politique |
|---|---|
| Fiches de référence (client, produit, menu) | **Last-write-wins** sur `updated_at`, conflit tracé. |
| Statuts opérationnels (chambre propre/sale, statut commande) | **Machine à états** : seule une transition valide est acceptée, l'état le plus avancé gagne. |
| Ressource rare — **attribution de chambre**, numéro de facture | **Serveur autoritaire**. Le client propose, le serveur tranche et peut **rejeter**. Le rejet remonte dans `sync_conflicts` et génère une alerte à la réception. |

La troisième ligne est le vrai point dur du projet : deux réceptionnistes hors ligne peuvent
attribuer la chambre 205 au même moment. Aucune résolution automatique n'est acceptable —
il faut un arbitrage serveur explicite et une notification humaine.

---

## 11. Paramétrage et reporting

| Table | Colonnes principales |
|---|---|
| `settings` | `key`, `value` `jsonb`, `scope` (`GLOBAL`,`DEVICE`,`USER`), `scope_id`, `updated_at` |
| `business_days` | `business_date`, `status` (`OPEN`,`CLOSED`), `closed_at`, `closed_by`, `totals` `jsonb` |
| `notifications` | `target_role_id` / `target_user_id`, `kind`, `title`, `body`, `entity_table`, `entity_id`, `is_read`, `created_at` |

Les statistiques du §4 (« CA, occupation, recettes, performances ») ne créent **aucune table** :
ce sont des **vues** PostgreSQL (`v_daily_revenue`, `v_occupancy`, `v_room_status`) calculées
sur `stay_nights`, `folio_items` et `payments`. Seuls les totaux figés de la clôture journalière
sont matérialisés dans `business_days.totals`, parce qu'ils ne doivent plus bouger.

---

## 12. Récapitulatif

**~65 tables**, réparties en 11 domaines :

| # | Domaine | Tables | Répliqué sur tablette |
|---|---|---|---|
| 1 | Socle & sécurité | 9 | partiel (pas d'audit ni de refresh tokens) |
| 2 | Chambres | 6 | oui |
| 3 | Clients | 3 | oui |
| 4 | Réservations | 5 | oui |
| 5 | Facturation | 6 | oui |
| 6 | Restauration | 9 | oui |
| 7 | Housekeeping & maintenance | 7 | oui |
| 8 | Stocks | 8 | oui |
| 9 | Impression | 5 | oui |
| 10 | Synchronisation | 8 | miroir (outbox local / change log serveur) |
| 11 | Paramétrage | 3 | oui |

---

## 13. Points ouverts — à trancher avant génération du schéma

1. **Mono-établissement ou multi-hôtel ?** Le cahier des charges parle d'« un établissement »
   mais l'évolution « groupe hôtelier » change tout : `hotel_id` sur chaque table + filtrage
   systématique. Beaucoup moins cher à faire maintenant qu'après.
2. **Numérotation des factures hors ligne.** Une facture doit avoir un numéro séquentiel légal
   sans trou. Impossible à garantir hors ligne. Deux options : facture provisoire non numérotée
   hors ligne + numéro attribué à la sync, ou préfixe par tablette (`REC01-2026-0042`).
3. **Déstockage automatique par recettes** (un cocktail décrémente le stock de rhum) : ça implique
   une table `menu_item_ingredients`. À inclure maintenant ou en phase 2 ?
4. **Portée de la réplication.** Faut-il répliquer *tout* l'historique sur chaque tablette, ou
   une fenêtre glissante (ex. 90 jours) ? Impacte la taille de la base locale et le temps du
   premier sync.
