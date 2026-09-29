# Contrat d'API

Ce que la tablette et le serveur se promettent. Tout ce qui est écrit ici est
**vérifié dans le schéma** `docs/api/openapi.json`, exporté depuis le serveur —
ce n'est pas une intention, c'est l'état du code.

Régénérer le schéma après toute modification de l'API :

```bash
cd backend
SECRET_KEY=export-contrat .venv/Scripts/python -c "
import json
from fastapi.testclient import TestClient
import app.main as m
spec = TestClient(m.app).get('/openapi.json').json()
json.dump(spec, open('../docs/api/openapi.json','w',encoding='utf-8'),
          ensure_ascii=False, indent=2, sort_keys=True)"
```

Aucune base de données n'est nécessaire : FastAPI construit le schéma à partir
des définitions de routes, sans une requête SQL. Le versionner permet à
quelqu'un de développer l'application Flutter sans serveur qui tourne.

État au 28 septembre 2026 : **77 endpoints, 116 schémas.**

---

## Les montants

**Des entiers, en francs CFA. Jamais de décimaux, jamais de centimes.**

Ce n'est pas un choix d'affichage, c'est le format de la base des deux côtés :
`amount`, `unit_price`, `default_rate`, `balance` sont des `integer` dans le
schéma OpenAPI et des `bigint` en PostgreSQL. Le franc CFA n'a pas de
sous-unité en usage.

**Corollaire pour la couche réseau : ne jamais convertir en `double` en
chemin.** Un `int` qui part, un `int` qui revient. Un double ne représente pas
exactement 0,1 et une addition de factures finit par dériver — on ne compte pas
de l'argent en virgule flottante.

Le jour où une devise à décimales apparaîtrait, ce serait une décision
explicite et documentée, pas une dérive silencieuse.

## Les taux

**Des entiers, en points de base** — un centième de pour cent.

Une TVA de 18 % se transmet `1800`, un taux de 18,5 % se transmet `1850`.
Diviser par cent donne le pourcentage. C'est la convention comptable usuelle,
et elle garde les agrégats SQL justes.

## Les dates

Deux types distincts, qui ne se manipulent pas pareil.

| Champ | Forme | Exemple |
|---|---|---|
| `business_date`, `arrival_date`, `departure_date` | **date seule**, `AAAA-MM-JJ` | `2026-09-24` |
| `created_at`, `posted_at`, `checked_in_at` | **instant**, ISO-8601 en UTC | `2026-09-24T14:32:00Z` |

Une date seule n'a ni heure ni fuseau : la nuitée du 12 est la nuitée du 12
partout. Lui appliquer une conversion de fuseau la décalerait d'un jour une
fois sur deux.

**La journée hôtelière ne commence pas à minuit.** `business_date` est calculée
par le serveur à partir de `hotels.timezone` et `hotels.day_rollover_hour`
(6 h par défaut) : un encaissement à 2 h du matin appartient au chiffre
d'affaires de la veille. La tablette ne recalcule jamais cette date, elle
l'affiche.

## Les identifiants

**UUID v7, générés par la tablette, jamais par le serveur.**

C'est ce qui permet de créer une réservation, de l'imprimer et de la facturer
pendant une coupure Wi-Fi sans attendre un aller-retour. Les 48 premiers bits
sont l'horodatage, donc les clés restent croissantes et les insertions se font
en fin d'index.

Une exception : **les numéros de facture** viennent du serveur, de la table
`number_sequences`. Une séquence sans trou ne peut pas être garantie par un
client hors ligne. Les références internes (`CLI-`, `RES-`, `FOL-`) sont
attribuées localement et n'ont pas cette contrainte.

### Envoyer son `id`, et renvoyer sans crainte

Les écritures métier acceptent un champ `id` facultatif : `POST /guests`,
`POST /reservations` (dossier **et** chaque ligne de `rooms`),
`POST /folios/{id}/items`, `POST /folios/{id}/payments`, et `folio_id` au
check-in. Sans `id`, le serveur en génère un, comme avant.

Une tablette qui a perdu la réponse **renvoie la même requête, même `id`** :

| Cas | Réponse |
|---|---|
| Premier envoi | `201`, ligne créée avec l'`id` de la tablette |
| Renvoi d'un client | `200`, fiche mise à jour, même code `CLI-` |
| Renvoi d'une réservation, charge ou paiement | `200`, état actuel, **rien n'est réécrit** ni compté deux fois |
| Check-in, check-out, changement de chambre, annulation déjà faits | `200`, état actuel |
| `id` appartenant à un autre hôtel | `404` |

Un renvoi ne reçoit **jamais de 409**, même si l'hôtel est devenu complet ou
le folio clos entre-temps : un 409 bloquerait la file d'envoi de la tablette
et toutes les écritures suivantes derrière lui.

## L'authentification

`POST /api/v1/auth/login` prend du **JSON**, pas un formulaire — le
`tokenUrl` déclaré dans le schéma ne sert qu'au bouton « Authorize » de la
documentation Swagger.

Le jeton se présente ensuite en en-tête : `Authorization: Bearer <jeton>`.

**Durée de vie : 60 minutes**, puis `POST /auth/refresh` échange le jeton de
rafraîchissement contre une nouvelle paire. Le serveur émet **un nouveau jeton
de rafraîchissement à chaque échange** : garder l'ancien conduit à se faire
refuser au suivant.

La tablette rafraîchit toute seule sur un 401 et rejoue la requête, une seule
fois. Plusieurs requêtes qui prennent un 401 ensemble partagent le même
échange plutôt que d'en lancer cinq.

`POST /auth/logout` révoque le jeton de rafraîchissement. Il est idempotent —
un jeton inconnu répond aussi 204, pour ne rien apprendre à qui essaie des
valeurs. Le jeton d'accès en cours expire de lui-même.

Les permissions sont vérifiées route par route (`require_permission`). Un droit
manquant donne **403**, pas 401.

## Les erreurs

Format FastAPI standard, un seul champ :

```json
{ "detail": "Permission manquante : folio.discount" }
```

Sur une erreur de validation (422), `detail` est un **tableau** d'objets
`{loc, msg, type}` et non une chaîne. La couche réseau doit gérer les deux
formes.

| Code | Sens | Ce que fait la tablette |
|---|---|---|
| 401 | jeton absent, invalide ou expiré | retour à l'écran de connexion |
| 403 | droit manquant, ou compte désactivé | message, pas de redirection |
| 423 | compte verrouillé après cinq échecs | message, relâché après 15 min |
| 404 | introuvable, ou appartient à un autre hôtel | message |
| 409 | conflit d'état (arrivée déjà enregistrée…) | message, recharger la ligne |
| 422 | corps invalide | c'est un défaut de l'application, à journaliser |

## Modifier un client

`PATCH /guests/{id}` ne touche **qu'aux champs présents** dans le corps. Un
champ envoyé à `null` s'efface ; un champ absent reste tel quel. Avant, le
schéma entier était écrit, et chaque modification remettait à vide
l'adresse, la date de naissance et les notes. `credit_limit` à `null`
n'efface pas le seuil.

La tablette envoie les six champs de son écran, vides compris : nom,
prénom, téléphone, courriel, nationalité, type et numéro de pièce. Ce sont
ceux que la descente rapatrie.

Les champs obligatoires à la création (téléphone, pièce) sont une règle de
la **tablette** seulement : le serveur les laisse facultatifs, pour ne pas
refuser les créations anciennes qui attendent encore dans une file.

## Changer de chambre en cours de séjour

`POST /reservations/{id}/rooms/{ligne}/change-room`, corps `{"room_id": …}`,
droit `reservation.manage`. Réservé à une ligne **déjà arrivée** (`409`
sinon) ; avant l'arrivée, la chambre choisie part avec le check-in.

- La nouvelle chambre passe **occupée**. L'ancienne redevient **vacante sans
  devenir sale** : le client n'y a pas dormi. C'est l'inverse du départ.
- Le folio est rattaché à la ligne, pas à la chambre : l'ardoise suit le
  client, rien n'y est écrit.
- Refus : autre catégorie `422`, hors service ou déjà occupée `409`,
  chambre d'un autre hôtel `404`. Une chambre **sale n'est pas refusée** —
  la tablette ne la propose pas, mais son état de ménage peut être en retard,
  et un refus bloquerait sa file pour une question de propreté.
- Renvoi : si la ligne est déjà dans cette chambre, `200`.

Côté tablette, l'entrée de file porte `action: CHANGE_ROOM` et garde le
statut `CHECKED_IN` : l'envoyeur lit l'action avant le statut.

## Le seuil de consommation et les arrhes

**Seuil.** `guests.credit_limit` (FCFA, `0` = pas de limite) borne le solde
de l'ardoise. `POST /folios/{id}/items` accepte une charge tant que
`solde + montant <= seuil` : atteindre exactement le seuil est permis. Au-delà,
**409** avec un `detail` lisible tel quel :

```
Seuil depasse : solde 45 000 F + 10 000 F = 55 000 F, seuil 50 000 F,
depassement 5 000 F. Un responsable doit autoriser.
```

Pour passer outre, renvoyer la même charge avec `override_by` : l'`id` du
responsable qui autorise, après avoir vérifié son PIN sur la tablette. Le
serveur exige qu'il soit actif, de cet hôtel, et qu'il ait
`folio.override_limit` (manager, pas la réception ni la caisse) — sinon 403.
Son `id` reste sur la ligne (`folio_items.override_by`). Seules les charges
qui augmentent le solde sont contrôlées. `GuestIn.credit_limit` est
facultatif : absent, le seuil en place ne change pas.

**Arrhes.** Envoyer `deposit_amount` dans `POST /reservations`, c'est
déclarer des arrhes **encaissées maintenant** : `deposit_method` devient
obligatoire (422 sinon), `deposit_reference` facultatif. Le serveur crée un
paiement rattaché à la réservation et à la session de caisse ouverte de celui
qui encaisse. Seules les espèces (`CASH`) font monter l'attendu du tiroir ; un
Mobile Money ou un virement n'y entre pas.

Sans `deposit_amount`, le serveur calcule ce qui est **dû** avec la règle de
l'hôtel, ligne `settings` `reservation.deposit_rule`, sans rien encaisser
(`deposit_paid_at` reste `null`) :

```json
{ "mode": "FIXED", "amount": 20000 }      // somme fixe
{ "mode": "PERCENT", "rate_bp": 3000 }    // 30 % du séjour
```

Pas de règle : pas d'arrhes. Des arrhes supérieures au prix du séjour : 422.
À l'annulation, l'argent reste encaissé (rien n'est remboursé). À
l'arrivée, le paiement passe de la réservation à l'ardoise : le client ne
doit que le reste, et la facture montre le séjour entier. Une seule fois par
dossier, même en groupe ou sur un check-in renvoyé.

Un paiement a **un seul** rattachement : ardoise (`folio_id`), facture
(`invoice_id`) ou réservation (`reservation_id`) — garanti en base.

## La pagination

**Il n'y en a pas.** Aucun endpoint n'expose `limit`, `offset` ou `page` — les
listes renvoient tout.

Acceptable pour un hôtel d'une vingtaine de chambres, à revoir avant tout
déploiement plus large. À noter maintenant pour que personne ne suppose le
contraire en écrivant le client.

## Ce qui manque encore côté serveur

Vérifié sur `main` au 24 septembre 2026 :

Livré depuis : `POST /auth/refresh` et `/auth/logout`, `GET` et
`PATCH /rooms/{id}`, `PATCH /reservations/{id}`, le calendrier, les sessions
de caisse, et la numérotation par séquence (`services/numbering.py`) qui
remplace les `COUNT` concurrents.

Reste côté tablette : les références `CLI-`, `RES-` et `FOL-` créées hors
ligne sont encore attribuées par un `COUNT` local. Acceptable pour une
référence interne sur une seule tablette, à remplacer quand la file
d'attente remontera au serveur.

## Le principe qui gouverne tout le reste

**Les écrans lisent Drift, jamais le réseau.**

La couche réseau alimente la base locale en arrière-plan et vide la file
`outbox_entries` ; elle ne se trouve jamais dans le chemin d'un affichage. Si
un widget appelle directement le client HTTP, la conception a dérapé — et le
mode hors connexion avec elle.
