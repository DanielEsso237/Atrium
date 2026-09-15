# Atrium — Workflows métier et opérations en base

> Les parcours de base, traduits en écritures concrètes sur le schéma.
> Réf. `docs/01-modele-de-donnees.md` et `docs/02-base-locale-drift.md`.

Toutes les opérations décrites ici s'exécutent **sur la base locale de la
tablette**, dans une transaction. La remontée vers le serveur est un mécanisme
d'arrière-plan qui n'intervient à aucun moment dans ces parcours : c'est ce qui
rend l'application utilisable pendant une coupure réseau.

Conventions : `:x` est un paramètre, `now()` l'horodatage courant en UTC,
`bd` la journée hôtelière en cours (`AAAA-MM-JJ`). Toute écriture met aussi à
jour `updated_at`, `updated_by` et `origin_device_id` — non répété à chaque
ligne.

---

## Vue d'ensemble

```
                    ┌──────────── CLIENT RÉSIDENT ────────────┐
                    │                                          │
  Réservation ──► Check-in ──► Consommations ──► Check-out ──► Nettoyage
      │              │              │                │             │
  reservations  reservation_rooms  orders        invoices   housekeeping_tasks
  reservation_  rooms.occupancy    folio_items   payments   rooms.housekeeping_
    _rooms      folios             print_jobs    folios       _status
                stay_nights                                  maintenance_tickets

                    ┌────────── CLIENT DE PASSAGE ────────────┐
                    │                                          │
              Ouverture table ──► Commande ──► Addition ──► Paiement
                    │                 │            │            │
              folios(TABLE)        orders    folio_items    payments
              restaurant_tables  order_items  print_jobs    folios=SETTLED
```

Le point commun des deux parcours : **tout passe par un folio**. C'est lui qui
accumule les charges, et rien ne s'encaisse sans lui — `payments` n'a pas de
lien direct vers une commande.

---

## 1. Réservation

### 1.1 Recherche de disponibilité

Aucune écriture. Une seule requête, par type de chambre :

```sql
SELECT rt.id,
       rt.label,
       (SELECT COUNT(*) FROM rooms r
         WHERE r.room_type_id = rt.id
           AND r.is_active = 1
           AND r.is_out_of_order = 0
           AND r.deleted_at IS NULL)                        AS total,
       (SELECT COUNT(*) FROM reservation_rooms rr
         WHERE rr.room_type_id = rt.id
           AND rr.deleted_at IS NULL
           AND rr.status IN ('PENDING','CONFIRMED','CHECKED_IN')
           AND rr.arrival_date  < :departure
           AND rr.departure_date > :arrival)                AS vendues
FROM room_types rt
WHERE rt.deleted_at IS NULL AND rt.is_active = 1;
```

Disponible = `total - vendues`.

**Le test de chevauchement est le point à ne pas rater.** Les dates forment un
intervalle **semi-ouvert** : un séjour du 12 au 15 occupe les nuits du 12, 13 et
14, et libère la chambre le 15. Deux séjours se chevauchent donc si et seulement
si `A1 < D2 ET D1 > A2`. Écrire `<=` ferait croire à un conflit entre un départ
et une arrivée le même jour — soit une chambre invendable par jour et par
rotation.

`is_out_of_order` sort les chambres en maintenance du décompte ; les chambres
sales n'en sortent pas, puisqu'elles seront nettoyées d'ici l'arrivée.

### 1.2 Client

```sql
-- Recherche préalable : SELECT … FROM guests WHERE phone = :tel OR
--                       id_document_number = :piece
INSERT INTO guests (id, hotel_id, code, first_name, last_name, phone, …)
VALUES (:uuid7, :hotel, :code, …);
```

L'`id` est un **UUID v7 généré par la tablette**. C'est ce qui permet de créer
le client hors ligne sans attendre d'identifiant du serveur.

### 1.3 Le dossier

```sql
INSERT INTO reservations (
  id, hotel_id, reference, guest_id, source, status,
  arrival_date, departure_date, adults, children, estimated_total
) VALUES (
  :uuid7, :hotel, :ref, :guest, 'DIRECT', 'PENDING',
  :arrivee, :depart, 2, 0, :total
);

INSERT INTO reservation_rooms (
  id, reservation_id, room_type_id, room_id, rate_plan_id,
  arrival_date, departure_date, adults, children, nightly_rate, status
) VALUES (
  :uuid7, :reservation, :type, NULL, :plan,
  :arrivee, :depart, 2, 0, :tarif, 'PENDING'
);
```

**`room_id` reste nul.** On réserve un *type* de chambre, pas un numéro :
l'attribution physique se fait au dernier moment, souvent le jour même. Fixer
un numéro trois semaines à l'avance ne fait qu'empêcher la réception
d'optimiser son plan d'occupation, et provoque des réattributions en cascade
au moindre prolongement de séjour.

Une réservation de groupe insère **plusieurs lignes** `reservation_rooms` sous
un seul dossier.

### 1.4 Arrhes (optionnel)

Un acompte est un encaissement : il lui faut donc un folio, dès maintenant.

```sql
INSERT INTO folios (id, hotel_id, number, type, status,
                    reservation_room_id, guest_id, opened_at)
VALUES (:uuid7, :hotel, :num, 'GUEST', 'OPEN', :rr, :guest, now());

INSERT INTO payments (id, hotel_id, folio_id, method, amount,
                      received_by, received_at, business_date, cash_session_id)
VALUES (:uuid7, :hotel, :folio, 'TRANSFER', :montant, :user, now(), :bd, :caisse);

UPDATE folios SET payments_total = payments_total + :montant,
                  balance = charges_total - payments_total   -- devient négatif
WHERE id = :folio;

UPDATE reservations SET deposit_amount = :montant, deposit_paid_at = now(),
                        status = 'CONFIRMED'
WHERE id = :reservation;
```

**Un acompte est un `payments`, et rien d'autre.** Surtout pas *aussi* un
`folio_items` : ce serait compter la somme deux fois — une fois en charge, une
fois en règlement — et le solde retomberait à zéro. Le client apparaîtrait
comme ne devant rien alors qu'il a payé d'avance, et on lui réclamerait au
départ le montant total au lieu du reste à payer.

Après le versement, `balance` est **négatif** : c'est un crédit au bénéfice du
client, qui se résorbe au fur et à mesure que les nuitées se portent au compte.

`ChargeCategory.DEPOSIT` ne sert donc qu'à un seul cas : une arrhe **conservée**
après une annulation tardive ou un *no-show*. Là, elle devient bien une charge,
puisque l'hôtel garde l'argent sans avoir rendu le service.

### 1.5 Annulation

```sql
UPDATE reservations
   SET status = 'CANCELLED', cancelled_at = now(), cancel_reason = :motif
 WHERE id = :reservation;

UPDATE reservation_rooms SET status = 'CANCELLED' WHERE reservation_id = :reservation;

-- Si une chambre avait déjà été attribuée :
UPDATE rooms SET occupancy_status = 'VACANT' WHERE id = :room;
```

Jamais de `DELETE` : le dossier annulé reste, pour les statistiques de taux
d'annulation et pour la traçabilité des arrhes non remboursées.

---

## 2. Check-in — occupation de la chambre

C'est l'opération la plus dense du système. **Tout en une transaction.**

### 2.1 Vérifications préalables

```sql
-- La chambre est-elle réellement prenable ?
SELECT occupancy_status, housekeeping_status, is_out_of_order
  FROM rooms WHERE id = :room;
```

Trois refus possibles, et ils ne se valent pas :

| Condition | Conduite |
|---|---|
| `is_out_of_order = 1` | **Blocage.** La chambre n'est pas vendable. |
| `occupancy_status = 'OCCUPIED'` | **Blocage.** Double attribution. |
| `housekeeping_status <> 'CLEAN'` | **Avertissement**, pas blocage. La réception peut décider d'installer le client et de faire passer l'étage en priorité. |

### 2.2 Attribution et occupation

```sql
UPDATE reservation_rooms
   SET room_id = :room,
       status = 'CHECKED_IN',
       checked_in_at = now(),
       checked_in_by = :user
 WHERE id = :rr;

UPDATE rooms SET occupancy_status = 'OCCUPIED' WHERE id = :room;

UPDATE reservations SET status = 'CHECKED_IN' WHERE id = :reservation;
```

`rooms.housekeeping_status` **n'est pas touché**. C'est tout l'intérêt des trois
axes séparés : la réception écrit l'occupation, le housekeeping écrit la
propreté, et les deux services ne s'écrasent jamais l'un l'autre à la
synchronisation.

### 2.3 Folio

S'il n'existe pas déjà (cas sans arrhes) :

```sql
INSERT INTO folios (id, hotel_id, number, type, status,
                    reservation_room_id, guest_id, opened_at)
VALUES (:uuid7, :hotel, :num, 'GUEST', 'OPEN', :rr, :guest, now());
```

### 2.4 Génération des nuitées

Une ligne par nuit, de la date d'arrivée à la veille du départ :

```sql
INSERT INTO stay_nights (id, reservation_room_id, business_date, room_id,
                         rate, is_posted)
VALUES (:uuid7, :rr, :date_nuit, :room, :tarif_du_jour, 0);
-- répété pour chaque nuit du séjour
```

Le tarif est résolu nuit par nuit depuis `rate_plan_prices`, en tenant compte
du `weekday_mask`. Un séjour à cheval sur un week-end n'a pas un prix unique, et
la facture doit pouvoir le justifier ligne à ligne.

### 2.5 Signature électronique (F1.2)

```sql
INSERT INTO signatures (id, entity_table, entity_id, kind,
                        image_path_local, upload_state, signed_by_name, signed_at)
VALUES (:uuid7, 'reservation_rooms', :rr, 'CHECK_IN',
        :chemin_local, 'PENDING', :nom, now());
```

Le fichier reste local. Son envoi est une opération distincte de la
synchronisation des lignes métier : une image ne transite pas par la file JSON.

---

## 3. Clôture journalière — la nuitée devient une charge

Opération automatique, lancée à l'heure de bascule (`hotels.day_rollover_hour`).
C'est le seul endroit où `stay_nights` alimente `folio_items`.

```sql
-- Pour chaque nuitée du jour pas encore portée au compte :
SELECT sn.id, sn.rate, f.id AS folio_id, r.number
  FROM stay_nights sn
  JOIN reservation_rooms rr ON rr.id = sn.reservation_room_id
  JOIN folios f             ON f.reservation_room_id = rr.id AND f.status = 'OPEN'
  JOIN rooms r              ON r.id = sn.room_id
 WHERE sn.business_date = :bd AND sn.is_posted = 0 AND sn.deleted_at IS NULL;

INSERT INTO folio_items (id, folio_id, category, label, quantity, unit_price,
                         amount, tax_rate, tax_amount, business_date,
                         source_table, source_id, posted_at)
VALUES (:uuid7, :folio, 'ROOM', 'Chambre ' || :numero || ' — nuit du ' || :bd,
        1, :rate, :rate, :taux, :taxe, :bd, 'stay_nights', :stay_night, now());

UPDATE stay_nights SET is_posted = 1, posted_at = now() WHERE id = :sn;

UPDATE folios SET charges_total = charges_total + :rate + :taxe,
                  balance = charges_total - payments_total
WHERE id = :folio;
```

**`is_posted` est ce qui rend la clôture rejouable.** Une tablette qui perd le
réseau au milieu du traitement, ou un opérateur qui relance la clôture, ne
doivent pas facturer la nuit deux fois.

Puis :

```sql
UPDATE business_days
   SET status = 'CLOSED', closed_at = now(), closed_by = :user,
       totals = :json   -- CA hébergement, CA restauration, taxes,
                        -- encaissements par mode, taux d'occupation
 WHERE business_date = :bd;
```

Les totaux sont **figés** dans `totals` et non recalculés : un chiffre d'affaires
arrêté ne doit plus bouger, même si une facture de la veille est annulée demain.

---

## 4. Consommation au restaurant — client résident

### 4.1 Ouverture de la commande

```sql
INSERT INTO orders (id, hotel_id, number, outlet_id, type, status,
                    room_id, folio_id, waiter_id, covers, business_date, opened_at)
VALUES (:uuid7, :hotel, :num, :outlet, 'ROOM_SERVICE', 'DRAFT',
        :room, :folio, :serveur, 2, :bd, now());
```

**Contrôle indispensable avant de rattacher un folio à une chambre :**

```sql
SELECT f.id FROM folios f
  JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
 WHERE rr.room_id = :room
   AND rr.status = 'CHECKED_IN'
   AND f.status = 'OPEN';
```

Sans ce filtre sur `CHECKED_IN`, n'importe qui peut faire porter une addition
sur une chambre vide — et personne ne s'en aperçoit avant la clôture.

### 4.2 Les lignes

```sql
INSERT INTO order_items (id, order_id, menu_item_id, prep_station_id,
                         label_snapshot, quantity, unit_price, tax_rate,
                         amount, status, notes)
SELECT :uuid7, :order, mi.id, mi.prep_station_id,
       mi.label, :qte, mi.price, mi.tax_rate, mi.price * :qte, 'DRAFT', :note
  FROM menu_items mi WHERE mi.id = :article;
```

`prep_station_id`, `label_snapshot` et `unit_price` sont **recopiés** depuis
l'article. Le poste de préparation figé sur la ligne est ce qui garantit la
règle R1 ; le libellé et le prix figés font qu'une commande déjà imprimée ne
change pas rétroactivement si le gérant modifie la carte une heure plus tard.

### 4.3 Envoi en cuisine — le routage d'impression (F3.2, R1)

```sql
UPDATE orders      SET status = 'SENT', sent_at = now() WHERE id = :order;
UPDATE order_items SET status = 'SENT', sent_at = now()
 WHERE order_id = :order AND status = 'DRAFT';
```

Puis **un ticket par poste de préparation distinct** :

```sql
-- 1. Quels postes sont concernés ?
SELECT DISTINCT prep_station_id FROM order_items
 WHERE order_id = :order AND status = 'SENT' AND is_void = 0;

-- 2. Pour chaque poste, quelle imprimante ? (règle R5)
SELECT pr.printer_id
  FROM print_routes pr
 WHERE pr.document_type_id = :type_doc
   AND pr.is_active = 1
   AND (pr.match_prep_station_id IS NULL OR pr.match_prep_station_id = :station)
   AND (pr.match_outlet_id       IS NULL OR pr.match_outlet_id = :outlet)
   AND (pr.match_device_id       IS NULL OR pr.match_device_id = :device)
 ORDER BY pr.priority DESC
 LIMIT 1;

-- 3. Un travail d'impression par poste
INSERT INTO print_jobs (id, hotel_id, document_type_id, printer_id, payload,
                        status, source_table, source_id,
                        requested_by, requested_from_device_id)
VALUES (:uuid7, :hotel, :type_doc, :printer, :json_lignes_du_poste,
        'QUEUED', 'orders', :order, :user, :device);
```

Une commande « steak + mojito » produit **deux travaux** : un vers la cuisine,
un vers le bar. Ce n'est pas une règle applicative — c'est la conséquence
mécanique du `DISTINCT prep_station_id`. Un ticket cuisine ne *peut pas* partir
au bar, parce qu'aucune requête ne le construirait.

`payload` porte les lignes du poste concerné, pas une référence à la commande :
une réimpression doit reproduire l'original même si la commande a changé depuis.

### 4.4 Suivi (F3.4)

```sql
UPDATE order_items SET status = 'READY', ready_at = now() WHERE id = :ligne;
UPDATE orders      SET status = 'READY', ready_at = now()
 WHERE id = :order
   AND NOT EXISTS (SELECT 1 FROM order_items
                    WHERE order_id = :order AND is_void = 0
                      AND status NOT IN ('READY','SERVED'));
```

### 4.5 Report en chambre (F3.6)

```sql
INSERT INTO folio_items (id, folio_id, category, label, quantity, unit_price,
                         amount, tax_rate, tax_amount, business_date,
                         source_table, source_id, posted_by, posted_at)
SELECT :uuid7, :folio, 'FNB', oi.label_snapshot, oi.quantity, oi.unit_price,
       oi.amount, oi.tax_rate, …, :bd, 'order_items', oi.id, :user, now()
  FROM order_items oi
 WHERE oi.order_id = :order AND oi.is_void = 0;

UPDATE orders SET status = 'SERVED', served_at = now() WHERE id = :order;
UPDATE folios SET charges_total = …, balance = … WHERE id = :folio;
```

Une ligne de folio par ligne de commande, et non un total agrégé : au
check-out, un client qui conteste doit pouvoir se voir répondre « le mardi à
21 h, deux mojitos ».

---

## 5. Check-out et facturation

### 5.1 Solde des charges en attente

Les nuitées de la nuit en cours ne sont pas encore portées si la clôture n'a pas
tourné. On les poste (§3), puis :

```sql
SELECT charges_total, payments_total, balance FROM folios WHERE id = :folio;
```

### 5.2 Émission de la facture — le gel

```sql
INSERT INTO invoices (id, hotel_id, number, provisional_number, is_provisional,
                      folio_id, guest_id, status, issued_at,
                      subtotal, tax_total, discount_total, total, currency,
                      bill_to_name, bill_to_address, bill_to_tax_id)
VALUES (:uuid7, :hotel,
        NULL,                       -- numéro légal : attribué par le serveur
        :num_provisoire,            -- ex. 'REC01-2026-0042'
        1,                          -- hors ligne → provisoire
        :folio, :guest, 'ISSUED', now(),
        :ht, :taxes, :remises, :ttc, 'XOF',
        :nom, :adresse, :num_fiscal);

INSERT INTO invoice_lines (id, invoice_id, folio_item_id, label, quantity,
                           unit_price, tax_rate, tax_amount, amount, sort_order)
SELECT :uuid7, :invoice, fi.id, fi.label, fi.quantity,
       fi.unit_price, fi.tax_rate, fi.tax_amount, fi.amount, …
  FROM folio_items fi
 WHERE fi.folio_id = :folio AND fi.is_void = 0;
```

**`number` reste nul hors ligne.** Une numérotation légale doit être continue et
sans trou ; aucune tablette isolée ne peut le garantir. Le client repart avec un
document clairement marqué provisoire, et le serveur attribue le numéro
définitif depuis `number_sequences` à la synchronisation.

`bill_to_*` fige l'identité du destinataire : si le client déménage l'an
prochain, la facture déjà émise ne doit pas changer d'adresse.

### 5.3 Encaissement

```sql
INSERT INTO payments (id, hotel_id, folio_id, invoice_id, cash_session_id,
                      method, amount, currency, reference,
                      received_by, received_at, business_date)
VALUES (:uuid7, :hotel, :folio, :invoice, :caisse,
        'CARD', :montant, 'XOF', :ref_transaction, :user, now(), :bd);

UPDATE folios  SET payments_total = payments_total + :montant,
                   balance = charges_total - payments_total,
                   status = CASE WHEN charges_total - payments_total <= 0
                                 THEN 'SETTLED' ELSE 'OPEN' END,
                   closed_at = now()
 WHERE id = :folio;

UPDATE invoices SET status = 'PAID' WHERE id = :invoice;
```

Un règlement partagé (moitié carte, moitié espèces) insère simplement **deux
lignes** `payments` sur le même folio.

### 5.4 Libération de la chambre

```sql
UPDATE reservation_rooms
   SET status = 'CHECKED_OUT', checked_out_at = now(), checked_out_by = :user
 WHERE id = :rr;

UPDATE reservations SET status = 'CHECKED_OUT'
 WHERE id = :reservation
   AND NOT EXISTS (SELECT 1 FROM reservation_rooms
                    WHERE reservation_id = :reservation
                      AND status <> 'CHECKED_OUT' AND deleted_at IS NULL);

UPDATE rooms SET occupancy_status   = 'VACANT',
                 housekeeping_status = 'DIRTY'
 WHERE id = :room;
```

Un dossier de groupe ne passe en `CHECKED_OUT` que lorsque **toutes** ses
chambres sont parties.

### 5.5 Déclenchement du nettoyage

```sql
INSERT INTO housekeeping_tasks (id, hotel_id, room_id, type, status, priority,
                                business_date)
VALUES (:uuid7, :hotel, :room, 'DEPARTURE', 'PENDING',
        CASE WHEN :arrivee_le_jour_meme THEN 'HIGH' ELSE 'NORMAL' END, :bd);
```

La priorité vient de l'exploitation : une chambre qui doit être réoccupée le
soir même passe devant.

### 5.6 Impression de la facture (F1.5)

```sql
INSERT INTO print_jobs (id, hotel_id, document_type_id, printer_id, payload,
                        status, source_table, source_id,
                        requested_by, requested_from_device_id)
VALUES (:uuid7, :hotel, :type_facture, :imprimante_reception, :json,
        'QUEUED', 'invoices', :invoice, :user, :device);
```

Réimpression (règle R3) — jamais une réexécution du premier travail :

```sql
INSERT INTO print_jobs (…, is_duplicate, original_job_id)
VALUES (…, 1, :job_original);
```

---

## 6. Nettoyage de la chambre

### 6.1 Affectation

```sql
UPDATE housekeeping_tasks
   SET status = 'ASSIGNED', assigned_to = :agent, assigned_at = now()
 WHERE id = :task;
```

Impression de la fiche de tâches (F2.5) : `print_jobs` avec
`document_type = 'HK_TASK_SHEET'`, routé vers l'imprimante housekeeping.

### 6.2 Démarrage

```sql
UPDATE housekeeping_tasks
   SET status = 'IN_PROGRESS', started_at = now()
 WHERE id = :task;

UPDATE rooms SET housekeeping_status = 'IN_PROGRESS' WHERE id = :room;
```

Deux écritures, deux rôles : la **tâche** suit le travail de l'agent, la
**chambre** porte l'état visible par la réception sur le plan de l'hôtel.

### 6.3 Consommables (F2.4)

```sql
INSERT INTO amenity_consumptions (id, task_id, product_id, quantity)
VALUES (:uuid7, :task, :produit, :qte);

INSERT INTO stock_movements (id, hotel_id, product_id, stock_location_id, type,
                             quantity, reason, source_table, source_id,
                             moved_at, moved_by)
VALUES (:uuid7, :hotel, :produit, :magasin_etage, 'OUT', :qte,
        'Consommation housekeeping', 'housekeeping_tasks', :task, now(), :agent);

UPDATE stock_levels SET quantity = quantity - :qte, last_movement_at = now()
 WHERE product_id = :produit AND stock_location_id = :magasin_etage;
```

`stock_movements` est la source de vérité, `stock_levels` le compteur que la
tablette lit hors ligne sans agréger tout l'historique.

### 6.4 Achèvement

```sql
UPDATE housekeeping_tasks
   SET status = 'DONE', finished_at = now(),
       duration_minutes = :duree   -- calculée côté Dart depuis started_at
 WHERE id = :task;

UPDATE rooms SET housekeeping_status = 'CLEAN' WHERE id = :room;
```

`duration_minutes` n'est pas décoratif : c'est la seule donnée qui permette de
dimensionner une équipe d'étage et d'alimenter les indicateurs de F5.1.

### 6.5 Inspection (gouvernante)

```sql
UPDATE housekeeping_tasks
   SET status = 'INSPECTED', inspected_by = :gouvernante, inspected_at = now()
 WHERE id = :task;

UPDATE rooms SET housekeeping_status = 'INSPECTED' WHERE id = :room;
```

Un contrôle qui échoue **ne repart pas en arrière sur la même ligne** : on crée
une nouvelle tâche `REFRESH`, et on remet `rooms.housekeeping_status = 'DIRTY'`.
La tâche initiale conserve sa trace — sans quoi on perd l'information qu'un
repassage a été nécessaire.

### 6.6 Signalement d'anomalie (F2.3)

```sql
INSERT INTO maintenance_tickets (id, hotel_id, number, room_id, title,
                                 description, priority, status,
                                 reported_by, reported_at, blocks_room)
VALUES (:uuid7, :hotel, :num, :room, 'Climatiseur en panne', :desc,
        'HIGH', 'OPEN', :agent, now(), 1);

INSERT INTO attachments (id, entity_table, entity_id, kind,
                         file_path_local, upload_state, captured_at, captured_by)
VALUES (:uuid7, 'maintenance_tickets', :ticket, 'PHOTO',
        :chemin_local, 'PENDING', now(), :agent);

-- Ticket bloquant → la chambre sort de la vente
UPDATE rooms SET is_out_of_order = 1,
                 out_of_order_reason = 'Ticket ' || :num
 WHERE id = :room;

INSERT INTO notifications (id, hotel_id, kind, title, severity,
                           target_role_id, entity_table, entity_id)
VALUES (:uuid7, :hotel, 'MAINTENANCE_URGENTE', :titre, 'WARNING',
        :role_maintenance, 'maintenance_tickets', :ticket);
```

La photo part par la file de téléversement, pas par la synchronisation des
lignes : trois mégaoctets ne doivent pas retarder la remontée d'un ticket urgent
qui en pèse cinq cents.

### 6.7 Clôture de l'intervention

```sql
INSERT INTO maintenance_interventions (id, ticket_id, technician_id,
                                       started_at, ended_at, description, cost)
VALUES (:uuid7, :ticket, :technicien, :debut, now(), :compte_rendu, :cout);

UPDATE maintenance_tickets
   SET status = 'CLOSED', resolved_at = now(), closed_at = now(),
       resolution = :compte_rendu
 WHERE id = :ticket;

-- Clôturer un ticket bloquant remet la chambre en vente
UPDATE rooms SET is_out_of_order = 0, out_of_order_reason = NULL,
                 out_of_order_until = NULL
 WHERE id = :room
   AND NOT EXISTS (SELECT 1 FROM maintenance_tickets
                    WHERE room_id = :room AND blocks_room = 1
                      AND status NOT IN ('CLOSED','CANCELLED')
                      AND deleted_at IS NULL);
```

La sous-requête est nécessaire : deux tickets bloquants peuvent coexister sur
une même chambre, et clôturer le premier ne doit pas la remettre en vente.

---

## 7. Client de passage — restaurant, piscine, boîte de nuit

Un client non résident n'a **ni réservation, ni chambre, ni séjour**. Le schéma
l'absorbe sans table supplémentaire : il suffit d'un folio sans
`reservation_room_id`.

| | Client résident | Client de passage |
|---|---|---|
| `folios.type` | `GUEST` | `TABLE` ou `WALK_IN` |
| `folios.reservation_room_id` | renseigné | **NULL** |
| `folios.guest_id` | obligatoire | facultatif |
| Durée de vie du folio | tout le séjour | un service |
| Règlement | au check-out | immédiat |

### 7.1 Ouverture de table

```sql
UPDATE restaurant_tables SET status = 'OCCUPIED' WHERE id = :table;

INSERT INTO folios (id, hotel_id, number, type, status,
                    reservation_room_id, guest_id, restaurant_table_id, opened_at)
VALUES (:uuid7, :hotel, :num, 'TABLE', 'OPEN',
        NULL, NULL, :table, now());
```

`guest_id` nul : on ne demande pas sa pièce d'identité à quelqu'un qui vient
boire un café. Il devient obligatoire seulement si le client réclame une facture
à son nom (§7.5).

### 7.2 Commande

Identique au §4, à trois champs près :

```sql
INSERT INTO orders (id, hotel_id, number, outlet_id, type, status,
                    restaurant_table_id, room_id, folio_id,
                    waiter_id, covers, business_date, opened_at)
VALUES (:uuid7, :hotel, :num, :outlet_restaurant, 'ON_SITE', 'DRAFT',
        :table,          -- la table, pas la chambre
        NULL,            -- aucune chambre
        :folio_table,    -- le folio de la table
        :serveur, 4, :bd, now());
```

L'envoi en cuisine, le routage vers les postes de préparation et le suivi des
statuts sont **exactement** ceux du §4.3. Le poste de préparation vient de
l'article, pas du client : la cuisine ne sait pas — et n'a pas à savoir — si le
steak part vers une chambre ou vers la table 12.

### 7.3 Piscine et boîte de nuit

Ce sont des **points de vente**, donc des lignes dans `outlets` :

```sql
INSERT INTO outlets (id, hotel_id, code, label, allows_room_charge)
VALUES (:uuid7, :hotel, 'POOL',       'Piscine',       1),
       (:uuid7, :hotel, 'NIGHTCLUB',  'Boîte de nuit', 0);
```

`allows_room_charge = 0` sur la boîte de nuit est une décision d'exploitation :
on peut interdire le report en chambre là où le risque d'impayé est le plus
élevé. Le contrôle est une donnée, pas une règle codée en dur.

Un droit d'entrée est un article de carte comme un autre :

```sql
INSERT INTO menu_items (id, hotel_id, code, label, menu_category_id,
                        prep_station_id, price, tax_rate)
VALUES (:uuid7, :hotel, 'ENT-NC', 'Entrée boîte de nuit',
        :categorie_entrees, NULL, 5000, 1800);
```

> `prep_station_id` est nullable — voir §8.1. Un droit d'entrée ne se prépare nulle part et ne doit produire aucun
> ticket de production.

La suite est identique : `orders` sur l'outlet `NIGHTCLUB`, `order_items`,
folio de type `TABLE`, encaissement immédiat.

### 7.4 Addition et encaissement immédiat

```sql
INSERT INTO folio_items (id, folio_id, category, label, quantity, unit_price,
                         amount, tax_rate, tax_amount, business_date,
                         source_table, source_id, posted_by, posted_at)
SELECT :uuid7, :folio, 'FNB', oi.label_snapshot, oi.quantity, oi.unit_price,
       oi.amount, oi.tax_rate, …, :bd, 'order_items', oi.id, :user, now()
  FROM order_items oi WHERE oi.order_id = :order AND oi.is_void = 0;

INSERT INTO payments (id, hotel_id, folio_id, cash_session_id, method, amount,
                      received_by, received_at, business_date)
VALUES (:uuid7, :hotel, :folio, :caisse, 'MOBILE_MONEY', :montant,
        :user, now(), :bd);

UPDATE folios SET charges_total = :total, payments_total = :montant,
                  balance = 0, status = 'SETTLED', closed_at = now()
 WHERE id = :folio;

UPDATE orders             SET status = 'SERVED', served_at = now() WHERE id = :order;
UPDATE restaurant_tables  SET status = 'FREE' WHERE id = :table;
```

Le folio vit le temps d'un service, puis se solde. C'est le même objet que
celui d'un séjour de cinq nuits — seule sa durée de vie change.

### 7.5 Le client de passage veut une facture à son nom

```sql
INSERT INTO guests (id, hotel_id, code, first_name, last_name, phone)
VALUES (:uuid7, :hotel, :code, :prenom, :nom, :tel);

UPDATE folios SET guest_id = :guest, type = 'WALK_IN' WHERE id = :folio;
```

Puis facture et impression comme au §5.2 et §5.6. Le passage `TABLE` →
`WALK_IN` n'est pas cosmétique : il distingue, dans les statistiques, le service
anonyme au comptoir du client identifié — lequel alimente l'historique et le
fichier commercial.

### 7.6 Un résident invite un non-résident

Cas fréquent et sans difficulté : la commande est passée au nom de la chambre.

```sql
-- Contrôle : le point de vente autorise-t-il le report ?
SELECT allows_room_charge FROM outlets WHERE id = :outlet;
-- Contrôle : la chambre est-elle réellement occupée ?
SELECT f.id FROM folios f
  JOIN reservation_rooms rr ON rr.id = f.reservation_room_id
 WHERE rr.room_id = :room AND rr.status = 'CHECKED_IN' AND f.status = 'OPEN';
```

Les deux contrôles réunis sont ce qui empêche de faire porter une consommation
sur une chambre vide ou depuis un point de vente où c'est interdit.

---

## 8. Ce que ces parcours révèlent du schéma

Dérouler les workflows a fait apparaître deux corrections, **appliquées depuis**,
et un choix à confirmer.

### 8.1 `menu_items.prep_station_id` — corrigé

**Problème.** La colonne est `NOT NULL`. Impossible d'enregistrer un droit
d'entrée en boîte de nuit, un accès piscine, un dépôt de vestiaire ou une
bouteille vendue telle quelle : ces articles ne se préparent nulle part.

**Correction appliquée.** `prep_station_id` est nullable sur `menu_items` **et**
sur `order_items`. Une ligne sans poste de préparation ne produit simplement aucun
ticket de production — le `DISTINCT prep_station_id` du §4.3 l'ignore.

La règle R1 n'est pas affaiblie : elle dit qu'un ticket ne doit pas partir au
mauvais poste, pas qu'il doit exister un ticket pour tout.

### 8.2 `OrderType` mélangeait deux notions — corrigé

**Problème.** Les valeurs étaient `DINE_IN`, `ROOM_SERVICE`, `POOL`,
`TAKEAWAY`. `POOL` est un **lieu**, alors que les trois autres sont des **modes
de service** — et le lieu est déjà porté par `outlet_id`. La piscine est donc
représentable de deux façons, ce qui garantit qu'on trouvera les deux dans les
données.

**Correction appliquée.** `OrderType = { ON_SITE, ROOM_SERVICE, TAKEAWAY, DELIVERY }`,
le lieu restant `outlets`. Une commande au bord de la piscine devient
`type = 'ON_SITE'`, `outlet = 'POOL'`. Une commande livrée en chambre depuis la
boîte de nuit devient `ROOM_SERVICE` / `NIGHTCLUB`, ce qui est aujourd'hui
inexprimable.

### 8.3 À confirmer — numérotation des folios de passage

`folios.number` est unique par établissement. Les numéros de factures sont
attribués par le serveur (`number_sequences`), mais un folio de table est un
objet **interne** : il n'a aucune valeur légale.

Proposition : le numéroter localement avec le préfixe du terminal
(`REST02-2026-0417`), sans passer par le serveur. Les collisions entre tablettes
deviennent impossibles, et aucune attente réseau n'est introduite au moment où
un serveur ouvre une table.
