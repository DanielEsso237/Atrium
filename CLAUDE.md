# Atrium — contexte pour Claude Code

Gestion hôtelière sur tablettes, **hors ligne d'abord**, avec impression
localisée et synchronisation vers un serveur central. Cahier des charges :
`F:\CAHIER DES CHARGES - Gestion Hotelière.docx`, résumé sans jargon dans
`docs/le-classeur-de-l-hotel.html`.

```
Tablettes Flutter + Drift  ◄── REST / JWT ──►  FastAPI + PostgreSQL 18
```

## Les règles qui ne se négocient pas

**Les écrans lisent Drift, jamais le réseau.** La couche réseau alimente la
base locale en arrière-plan ; elle n'est jamais dans le chemin d'un affichage.
Si un widget importe `data/remote/`, la conception a dérapé — et le mode hors
connexion avec elle.

**Toute écriture va dans Drift *et* dans `outbox_entries`, même transaction.**
Écrire sans enfiler perdrait l'opération au prochain échange : personne ne
saurait qu'elle doit remonter. Voir `data/repositories/outbox.dart`.

**Une ligne protégée par une écriture en attente n'est jamais écrasée** par une
descente du serveur. Tant qu'une modification n'est pas remontée, la version
locale fait foi — c'est le serveur qui est en retard.

**L'état d'une chambre tient sur trois axes indépendants** — occupation,
propreté, hors service. La pastille du plan se *calcule* à l'affichage
(`RoomBoardEntry.displayStatus`), elle ne se stocke pas. Sinon réception et
housekeeping s'écrasent mutuellement.

**Les montants sont des entiers en francs CFA.** Jamais de décimaux, jamais de
`double` en chemin. Les taux sont en points de base (18 % → `1800`).

**Deux types de dates.** `business_date`, `arrival_date` sont des dates *seules*
(`AAAA-MM-JJ`) : leur appliquer un fuseau les décale d'un jour une fois sur
deux. `created_at`, `checked_in_at` sont des instants ISO-8601 UTC.

**La journée hôtelière ne commence pas à minuit** mais à
`hotels.day_rollover_hour` (6 h), dans `hotels.timezone`. Jamais
`dt.date.today()` côté serveur (`app/services/business_day.py`), jamais
`DateTime.now()` comme date d'exploitation côté tablette
(`core/business_day.dart`). Cette règle a été violée des deux côtés : la
tablette datait tout du calendrier, et à minuit une le tableau de bord
retombait à zéro en plein service pendant que le serveur, lui, rangeait les
mêmes écritures sur la veille.

**Une action qui en déclenche une autre exige les deux droits.** Le check-in
porte la nuitée sur l'ardoise, le check-out ouvre une tâche de ménage,
encaisser suppose une caisse : qui peut l'un doit pouvoir l'autre, sinon il
produit des écritures que le serveur lui refuse et la file se bloque derrière.
**Le piège s'est produit trois fois** — `folio.write`, `housekeeping.manage`,
`cash.session`. `backend/tests/test_droits_coherents.py` le verrouille : y
ajouter chaque nouvelle implication avant de livrer.

**Ce que le serveur refuse, la tablette doit le refuser avant.** Un refus qui
arrive par la file d'envoi la **bloque**, avec tout ce qui attend derrière.
Une règle métier ajoutée côté serveur sans son équivalent local transforme un
cas normal en tablette paralysée. Voir `_verifierSeuil` dans
`folio_repository.dart` : les règles y sont recopiées à la lettre, et deux
jeux de tests vérifient qu'elles disent la même chose.

**Toute colonne ajoutée à une table locale exige une migration.** Incrémenter
`schemaVersion` **et** écrire le pas dans `onUpgrade` (`database.dart`).
Oublier l'un des deux ne se voit pas en développement — une base neuve
fonctionne — et casse les tablettes déjà déployées.

**Le folio est le centre de la facturation.** Toute consommation y atterrit ; la
facture n'est qu'un gel du folio. Les totaux se recalculent **en SQL** dans la
même transaction.

## Conventions

- **Identifiants en anglais, documentation et commentaires en français.**
  Reste à finir dans `data/local/queries/room_detail_queries.dart` :
  `adultes`, `enfants`, `montant`, `libelle`, `categorie`.
- Les commentaires expliquent *pourquoi*, pas *quoi*.
- Une interface = une branche = une PR. Fusion vers `main` tous les 2-3 jours.
- Messages de commit longs : les écrire dans `.git/COMMIT_MSG.txt` et utiliser
  `git commit -F`. **Jamais `-m` multi-ligne** — `cmd.exe` coupe à la première
  ligne.

## Lancer

```bash
# Serveur — le .env est obligatoire (SECRET_KEY sans défaut)
cd backend && .venv/Scripts/activate
python -m alembic upgrade head
python -m uvicorn app.main:app --reload     # http://localhost:8000/docs

# Tablette
cd frontend && lance-web.cmd                # ou flutter run -d <Android>
flutter test && flutter analyze lib/ test/

# Tests serveur : 39 sans base, 74 avec
cd backend
psql -U postgres -c "CREATE DATABASE atrium_test OWNER atrium"   # une fois
set TEST_DATABASE_URL=postgresql+asyncpg://atrium:...@localhost:5432/atrium_test
.venv/Scripts/python -m pytest
```

**Essais sur tablette : `backend/lance-serveur.cmd`.** Il met la base à jour,
lance le serveur sur `127.0.0.1:8001` et le publie par ngrok sous le domaine
fixe de `NGROK_DOMAIN` (dans `backend/.env`, avec `NGROK_EXE` si ngrok n'est
pas dans le PATH). La tablette se compile une fois pour toutes avec
`--dart-define=ATRIUM_API=https://<domaine>/api/v1` et joint le serveur de
n'importe quel réseau. Avant, on passait l'IP du PC : elle changeait à chaque
Wi-Fi, il fallait recompiler, et le pare-feu Windows bloquait Python dès que
le réseau était classé public.

**Toujours `lance-web.cmd`, jamais `flutter run -d chrome` à la main.** La
base locale du navigateur est cloisonnée par origine et `flutter run` choisit
un port au hasard : chaque lancement ouvrait une base neuve, et la saisie
précédente restait dans l'ancienne, intacte mais introuvable. Le script fixe
le port à 8080.

**`TEST_DATABASE_URL` ne doit jamais pointer sur `atrium`** : le montage vide
toutes les tables. Sans elle, 29 tests sont ignorés — et 29 tests ignorés se
lisent comme un succès.

`flutter analyze` met une dizaine de minutes sur cette machine. `flutter run`
attrape les mêmes **erreurs** en deux minutes ; l'analyseur voit en plus les
avertissements. Lancer l'application pour itérer, l'analyseur avant une PR.

Comptes de démonstration, mot de passe `ChangeMe123!` ou PIN `1234` — les deux
marchent en ligne comme hors ligne :

| | Rôle | Ouvre sur |
|---|---|---|
| `ADMIN01` | tout | tableau de bord |
| `RECEP01` | réception | tableau de bord |
| `MENAGE01` | housekeeping | sa liste, sans retour possible |
| `RESTAU01` | restauration | ses commandes, sans retour possible |

Un métier à écran unique **n'a pas de flèche retour** : le routeur le renvoie
à son écran, et le bouton de déconnexion apparaît à la place. Lui montrer une
flèche, c'est promettre un ailleurs qui n'existe pas.

## Pièges rencontrés

- `customStatement` prend des **valeurs brutes** ; `customSelect` prend des
  `Variable`. Les confondre lève une erreur de liaison silencieuse.
- `customStatement` **ne prévient aucun écran**. Drift ne sait pas ce qu'une
  requête brute modifie : la ligne change en base et l'affichage garde sa
  valeur périmée. Utiliser `customUpdate(..., updates: {table})`.
- Le montage des tests serveur ne **reconstruit plus le schéma** à chaque test.
  L'ancienne version créait puis détruisait les soixante tables à chaque fois ;
  PostgreSQL a pris 24 minutes de synchronisation sur un point de contrôle et
  le postmaster s'est arrêté. Ne pas y revenir. À la place, le schéma est
  comparé aux modèles **une fois par lancement** et reconstruit s'il a dérivé
  (`tests/schema_de_test.py`) : `create_all` seul n'ajoutait jamais une
  colonne à une table existante. Le montage refuse toute base dont le nom ne
  finit pas par `_test`.
- Le magasin sécurisé peut échouer sans rien dire. `TokenStore` garde une copie
  en mémoire : sans elle, la connexion réussissait puis toutes les requêtes
  partaient sans jeton, et rien dans les logs ne l'expliquait.
- Sur le web, Drift tombe en stockage dégradé faute de `sharedArrayBuffers`
  (`flutter run` n'envoie pas les en-têtes d'isolation d'origine). Le journal
  dit le mode retenu au démarrage ; seul `inMemory` perd les données.
  **Développer sur un appareil Android évite toute cette famille de pièges.**
- **Un `TextEditingController` ne se détruit pas juste après `showDialog`.**
  La fenêtre est encore à l'écran pendant son animation de sortie : son
  champ lit un contrôleur détruit, et l'application lève
  `_dependents.isEmpty` (retour d'Android sur « Annuler la réservation »,
  16 octobre). Le contrôleur appartient à la fenêtre (un `State`) ; pour un
  motif, `demanderMotif` (`core/ui/fenetre_motif.dart`).
- **Pas de `LayoutBuilder` dans un `AlertDialog`.** Il mesure la largeur
  naturelle de son contenu (`IntrinsicWidth`), ce qu'un `LayoutBuilder` ne
  sait pas donner : la fenêtre plante avant de s'afficher. Les cases du PIN
  (`PinCells`) en contiennent un — la fenêtre du code responsable est un
  `Dialog` (16 octobre).
- Hot reload refusé après un changement de champs d'une classe `const` :
  utiliser `R` (restart), pas `r`.
- `StateProvider` n'existe plus en Riverpod 3 — utiliser un `Notifier`.
- PostgreSQL met >100 s à démarrer après un arrêt sale ; Windows abandonne à
  30 s et le laisse orphelin. `ServicesPipeTimeout` est porté à 3 min.

## Où regarder

| | |
|---|---|
| `docs/04-contrat-api.md` | ce que la tablette et le serveur se promettent |
| `docs/api/openapi.json` | le schéma exporté, versionné |
| `docs/01-modele-de-donnees.md` | MCD/MLD et décisions de modélisation |
| `docs/le-classeur-de-l-hotel.html` | les 65 tables expliquées sans jargon |
| `backend/README-setup.md` | mise en route pas à pas |

L'équipe : Daniel (frontend et liaison), Oriol (backend), Yann (junior,
backend), Neo (frontend, refonte visuelle des écrans).

## Où en est le produit

Fonctionne de bout en bout, testé à la main sur deux postes : connexion par
PIN, plan des chambres, clients, réservations, arrivées et départs,
facturation avec encaissement au départ, édition de facture, caisse avec
écart de fin de service, ménage, commandes par point de vente, et
**interfaces par métier** (§3.4) — chaque rôle ne voit que ses modules, et le
routeur refuse les autres, pas seulement l'affichage.

**L'écran d'administration** (`/administration`, droit `users.write`) : points
de vente (le Restaurant `RESTO` par défaut ne se désactive pas), règle des
arrhes, agents avec PIN, rôle et points de vente, permissions des rôles
(la dernière permission d'administration ne se retire pas), plafonds clients.
Les droits d'un agent viennent du serveur à sa connexion en ligne
(`/auth/me` porte les permissions de chaque rôle) : un agent créé sur un
poste a ses droits sur tous les autres.

La **synchronisation marche dans les deux sens**. La file remonte toute
seule, dans l'ordre, sans doublon même en cas de renvoi, avec espacement des
tentatives hors ligne ; un refus du serveur bloque la file au lieu de la
sauter, et se voit. La descente rapatrie référentiel, clients, réservations
et ardoises ouvertes, sans jamais écraser une écriture en attente. Une
ressource que l'agent n'a pas le droit de lire (403) est sautée, pas fatale :
la réception ne lit pas le restaurant, le ménage ne lit pas les clients.

## Ce que la direction a décidé le 29 septembre

Plusieurs points **rouvrent le périmètre v1** arrêté en septembre :

- **Photos de pièce d'identité : en v1.** La table `attachments` revient, avec
  la capture et la remontée de binaire — la file ne transporte que du JSON.
- **Impression des factures : en v1.** Petites imprimantes de tickets, au
  départ du client. `printers` et `print_jobs` reviennent.
- **Chaque agent est restreint à ses points de vente.** Fait : `user_outlets`
  des deux côtés, et les onglets de l'écran Commandes suivent l'agent
  connecté. Seul le rôle Commandes (code `RESTAURANT`) s'y rattache.
- **Caisse arrhes** : les arrhes sont détenues contre la réservation, puis
  basculent dans la caisse à l'arrivée — ou à l'annulation, où elles restent
  acquises. C'est un compte d'attente, pas un tiroir.
- **Pas de contournement du seuil** : si le responsable n'est pas joignable,
  on refuse. Le plafond d'un client est fixé par l'administrateur.
- **Maintenance : hors v1.** Restaurant : carte et prix, pas de ticket cuisine.
- **Stocks v1** : les produits de l'hôtel — bières, savons, serviettes.
- Plusieurs tablettes sont prévues, sans nombre arrêté.

## Ce qui a été décidé du 7 au 11 octobre

Retours du client le 7 octobre, puis essais sur tablette avec Daniel :

- **Économat et stocks** : l'économat ravitaille les points de vente ; un
  transfert attend la validation du contrôleur ou du comptable, et celui qui
  le demande ne le valide pas (second regard, des deux côtés). Rôles
  Économe, Contrôleur, Comptable. Sur l'onglet d'un point de vente, le bouton
  Transfert ouvre « Ravitailler … depuis » (l'économat d'abord). Le stock peut
  passer sous zéro : on vend et on alerte, la file ne se bloque jamais.
- **La réception est la caisse centrale.** Chaque soir, chaque point de vente
  lui verse sa recette ; elle confirme ce qu'elle reçoit. Trois chiffres
  restent : attendu, déclaré, reçu.
- **Un tiroir par point de vente** (migration 0020) : ouvert et fermé
  indépendamment, même tenu par le même agent ; une vente tombe dans le tiroir
  de son point de vente. La caisse centrale est le tiroir sans point de vente.
- **Pas d'argent hors d'un tiroir** : encaisser exige un agent et sa caisse
  ouverte, à la réception comme au comptoir. Les arrhes restent hors tiroir.
- **Caisse fermée, point de vente fermé** : rien ne se sert sans le tiroir
  ouvert du point de vente, même « Porter à la chambre ». Le client logé peut
  aussi « Payer maintenant » au comptoir. Après chaque vente encaissée, un
  ticket PDF de 80 mm se partage (imprimer, envoyer).
- **Comptage à l'aveugle** pour les points de vente : l'attendu ne s'affiche
  avant le comptage que pour qui tient la caisse centrale (`cash.central`).
- **Alertes** : à la connexion, toute alerte non lue sonne une fois (une seule
  sonnerie pour l'ensemble, au niveau réglé de chaque type) ; « Stock bas »
  est discret par défaut, réglable dans l'administration.
- **Onglets Points de vente / Services** selon le genre des points de vente
  auxquels l'agent est rattaché (`AccessProfile.genres`).
- **Serveur d'essai** : le PC de Daniel publié par ngrok (voir « Lancer »).
  L'heure des tablettes doit être automatique : elle date la journée
  hôtelière, les départs et les caisses.

## Le tableau de bord des points de vente (11-12 octobre)

Demandé le 11 octobre, livré en six tickets les 11 et 12 :
`feature/descente-ventes-point-de-vente`, `feature/perimetre-et-chiffres-pdv`,
`feature/ecran-tableau-de-bord-pdv`, `feature/tableau-de-bord-tiroirs-et-stock`,
`feature/comparatif-points-de-vente`, `feature/onglet-caisse-pdv`. Reste
l'**occupation des services**, reportée par Daniel (« on verra plus tard »).

**Où regarder** : l'écran Ventes (`/ventes`,
`features/outlets/outlet_dashboard_screen.dart`) et ses requêtes
(`data/local/queries/outlet_dashboard_queries.dart`) ; Ma caisse
(`/ma-caisse`, `outlet_cash_screen.dart`) ; le périmètre d'un agent
(`OrderRepository.watchPerimetre`).

**Le besoin.** Un tableau de bord complet des points de vente et services.
Dans l'administration et à la réception, il couvre tout l'hôtel. Le même
écran s'affiche, automatiquement, pour chaque point de vente existant ou créé
plus tard, filtré sur le sien : l'agent d'un « salon de thé » créé demain ne
voit que le salon de thé. Ensuite, un **onglet Caisse** pour les points de
vente : chacun consulte sa caisse.

**L'architecture retenue.** Un seul écran, paramétré par un périmètre, la
même règle que les stocks et les onglets : sans rattachement à un point de
vente (admin, réception, direction), tous, avec un filtre ; rattaché, les
siens seulement (avec un filtre s'il en a plusieurs). Aucun code par point
de vente : il suffit de le créer et d'y rattacher des agents.

**Ce que Daniel a tranché le 11 octobre :**

1. **Les données d'un agent descendent du serveur, filtrées sur ses points
   de vente** : `GET /outlet-activity` (`order.read`) rend leurs lignes
   vendues — pas les ardoises entières, l'ardoise d'une chambre ne regarde
   pas le barman —, les encaissements de leurs tiroirs et leurs tiroirs,
   **ceux des collègues compris**. Sans elle, l'agent ne voyait que les ventes
   de sa tablette (403 sur `/folios` et `/payments`). Une ligne arrive avec
   l'en-tête seul de son ardoise, écrit sans totaux si l'ardoise manque,
   jamais par-dessus une ardoise complète.
2. **Comptage à l'aveugle** : tant que son tiroir est ouvert, l'agent voit
   le nombre de ventes, les articles et ce qui est porté aux chambres, **pas
   l'argent encaissé** — fond plus encaissé, c'est l'attendu. Il le voit
   après son versement. L'attendu reste à `cash.central`. L'attendu des
   tiroirs descend quand même sur la tablette : la règle est à l'affichage.
3. **Les services** : ventes, argent **et occupation** — « ça peut aider à
   prendre des décisions ». Aujourd'hui un service se vend comme une
   consommation, sans capacité ni créneau : la définition de l'occupation
   reste à arrêter avec Daniel avant son ticket.
4. **Un agent de point de vente ouvre toujours sur Commandes** ; tableau de
   bord et Caisse sont à un clic. Il n'est donc plus un métier à écran
   unique : il lui faut un menu.

**Contenu retenu :** recette, nombre de ventes, ticket moyen, payé sur place
(ardoise `WALK_IN`) ou porté aux chambres ; jour, semaine, mois et
comparaison à la période précédente ; meilleures ventes et heures de pointe
(`posted_at`) ; tiroirs et versements du soir ; stock bas du magasin et
transferts en attente ; pour l'administration et la réception, le comparatif
de tous les points de vente.

**L'onglet Caisse des points de vente** : « Ma caisse » (`/ma-caisse`,
`cash.session`), et non la « Caisse du jour » (`/caisse`, `folio.read`), qui
est celle de la caisse centrale : tous les encaissements de l'hôtel et
l'écart de chacun. Le comptoir y voit ses tiroirs, les ouvre et les ferme,
ses encaissements par moyen — **les espèces sans montant tant que le tiroir
est ouvert**, la carte et le mobile money ne sont pas dans le tiroir — et
ses versements jusqu'à leur réception. L'entrée est masquée à qui lit déjà
la caisse du jour (`Destination.sauf`).

**Autres tickets en attente** : le module Cuisine (stock de la cuisine,
quantités utilisées déduites, ravitaillement par l'économat, pertes) ;
séparer Points de vente et Services dans l'administration ; l'impression
réelle des tickets ; ne plus demander à un agent les ressources qu'il n'a
pas le droit de lire (les 403 du journal sont normaux, mais inutiles).

## Les ardoises du comptoir (12 octobre)

Au bar, un client consomme au fil de la soirée et paie à la fin. Son
**ardoise du comptoir** est un folio `WALK_IN` qui porte `outlet_id` et
`tab_number` (« Passage n°3 ») ; un client logé a la sienne, à son nom
(`guest_id`), une seule ouverte par comptoir. Elle se **paie** au comptoir
(le total, dans le tiroir du point de vente), se **porte à la chambre** en un
geste (les lignes passent sur l'ardoise du séjour en gardant leur point de
vente) ou s'**annule** avec un motif (`tab.cancel`, un responsable).
Serveur : `POST /outlet-tabs…` ; tablette : `OutletTabRepository`, hors ligne.

- **Le comptoir nomme une ardoise** pour reconnaître son client (« Table 4 »,
  14 octobre) : `PATCH /outlet-tabs/{id}`, `folios.tab_label` (migration
  0023). Le numéro reste ; « Passage n°N » devient « Client divers n°N ».
  Serveur fait ; la tablette suit (ticket D5).
- **Le plafond du client compte toutes ses ardoises ouvertes**, chambre et
  comptoirs, des deux côtés. Sinon il passait sous son plafond au bar.
- L'écran Commandes filtre : en cours, non payées (défaut) · payées
  aujourd'hui · toutes. « Payer maintenant » reste possible.
- Verser avec des ardoises ouvertes : on prévient (« 2 ardoises non payées,
  7 500 FCFA »), on ne bloque pas.
- Écran Ventes : « Payé sur place » ne compte que les ardoises closes ;
  « Ardoises à payer » ce qui est servi et pas encore payé (visible à
  l'aveugle : ce n'est pas dans le tiroir).

**Une tablette qui ne sert qu'au bar** ne proposait aucune chambre à
« Porter à la chambre » : le comptoir porte (`folio.charge`) sans lire les
réservations, et les chambres n'arrivaient que si la réception s'était
connectée avant sur la même tablette. Corrigé par `GET /chargeable-stays`
(branche `fix/chambres-pour-le-comptoir`). Les consommations portées en
chambre avant le correctif du ticket 1 restent sans point de vente sur le
serveur : données d'essai, non reprises (décision du 11 octobre).

## Prix, marges et valeur du stock (14 octobre)

« La compta en gros ». Sur la tablette, l'écran **Comptabilité**
(`/comptabilite`, `accounting.read`, ticket D8, schéma local 13) : marge de
chaque point de vente sur une période, article par article, marge d'une
unité de chaque produit, valeur du stock de chaque magasin
(`data/local/queries/compta_queries.dart`). Il lit `products.average_cost`,
qui descend avec les produits ; les Rapports calculent encore leur marge au
prix d'achat (`report_queries.dart`). **Écart connu** : le serveur fige le
coût d'une vente sur sa sortie de stock, la tablette prend le coût du jour
(ses mouvements de stock ne descendent pas).

- **Coût moyen pondéré** : `products.average_cost` (migration 0022),
  recalculé à chaque entrée `IN` qui dit son prix, pour tout l'hôtel
  (`app/services/costing.py`). À zéro, le coût est le `purchase_price`.
- **Le coût d'une vente est figé sur sa sortie de stock** (`unit_cost`,
  `deduct_for_sale`) : une livraison ne change pas la marge déjà faite.
- `GET /accounting/margins`, `/accounting/product-margins`,
  `/accounting/stock-value`, sous `accounting.read` (administrateur,
  direction, contrôleur, comptable — **pas le comptoir** : une marge lui
  donnerait la recette d'un tiroir qu'il compte à l'aveugle).
  La valeur du stock s'ouvre aussi à `stock.manage` : l'économe la lit, pas
  les marges.
- Ce qui ne sort d'aucun stock n'a pas de coût connu : sa recette reste hors
  de la marge (`uncosted_revenue`).

## Le surclassement (14 octobre)

À l'arrivée ou en cours de séjour, le client reçoit une chambre d'une autre
catégorie : le check-in et `change-room` l'acceptent quand le corps porte
`upgrade: {keep_rate, reason}`, et la refusent toujours sans lui. Offert par
défaut (le tarif réservé reste) ; `keep_rate: false` applique le tarif de la
nouvelle catégorie aux nuits pas encore facturées. La ligne passe dans la
catégorie de la chambre — la disponibilité se compte là où le client dort —
et garde `booked_room_type_id`, `upgrade_reason`, `upgraded_by` (migration
0024). Tablette (D6, schéma local 11) : « Donner une chambre supérieure »
dans la fenêtre d'arrivée, les catégories supérieures au changement de
chambre, motif obligatoire, payant réservé à `reservation.manage`, et les
mêmes refus avant la file. **On ne surclasse que vers une catégorie
supérieure** (décision du 15 octobre) : un `default_rate` plus élevé que
celui de la catégorie actuelle de la ligne. La tablette le refuse, le
serveur aussi (409, `_ensure_upgrade_available`). **La nouvelle catégorie doit rester libre sur toute la durée du
séjour** (409 sinon, tranché par Daniel le 14 octobre) : une chambre libre
ce soir mais promise demain ne se surclasse pas pour deux nuits.

## L'arrivée directe (14 octobre)

Un voyageur sans réservation prend une chambre, en **nuits ou en heures**, à
un prix saisi librement : `POST /stays/walk-in` (`app/api/v1/stays.py`,
droits `reservation.create` + `folio.write`) crée d'un geste la fiche si elle
manque, le dossier, l'arrivée, l'ardoise et **une seule charge** du prix du
séjour entier. Migration 0025 : `is_walk_in`, `stay_unit`, `departure_at`,
`rate_set_by` sur `reservation_rooms`. Tablette : écran « Arrivée directe »
(`/reservations/arrivee-directe`, bouton sur Réservations et Aujourd'hui),
`ReservationRepository.arriveeDirecte`, schéma local 9 — D5 et D6 prendront
10 et 11.

- **Un séjour en heures part à `departure_at`** (instant UTC). Sa
  `departure_date` vaut le lendemain parce que le schéma l'exige : ne jamais
  la lire. Il n'a pas de nuit et ne compte pas dans la disponibilité.
- **Les nuits d'une arrivée directe naissent déjà portées** : la charge du
  séjour les couvre, et les porter une à une rend cette charge.
- Tous les refus passent **avant la première écriture** — le plafond du
  client compris : une levée après un `flush` laissait le dossier à moitié
  créé dans la session.
- Le tableau de bord lit des vues (`v_occupancy`) que la base de test n'a
  pas : sa logique testable vit dans des fonctions (`count_departures`).

## L'inventaire (15 octobre)

Un tableau à quatre colonnes par magasin : l'article, la quantité théorique
(**figée à l'ouverture** de l'inventaire), la quantité comptée sur le terrain
(seule colonne saisie) et l'écart. **Rééquilibrer** aligne le stock : un
manque devient une perte (`LOSS`, visible dans le bénéfice), un surplus un
ajustement (`ADJUSTMENT`) ; les lignes non comptées ne bougent pas. Un seul
inventaire ouvert par magasin. Deux droits : `stock.inventory` (ouvrir,
compter, abandonner) et `stock.rebalance` (rééquilibrer) ; l'un ou l'autre
ouvre l'écran (`AccessProfile.peutUnDe`, exigence `a|b`).

Tablette : `/inventaire`, `InventoryRepository`, tables `inventories` et
`inventory_lines` (déjà au schéma). Serveur (`feature/inventaire-serveur`,
migration 0027) : `POST /inventories`,
`PUT /inventories/{id}/lines/{product_id}`, `POST /inventories/{id}/rebalance`
(avec les `movement_ids` de la tablette), `POST /inventories/{id}/cancel`,
`GET /inventories`. **Fusionner le serveur d'abord** : sans ses routes,
ouvrir un inventaire bloque la file d'envoi (404).

**La descente** (`Descente._ecrireInventaires`) rapporte les inventaires
ouverts et ceux modifiés sur la fenêtre des rapports, abandonnés et clos
compris : un second poste reprend celui d'un collègue, avec la théorique du
serveur et ce qui est déjà compté. Un inventaire qui a un envoi en attente
ici est épargné en entier, lignes comprises : un comptage part dans la file
sous l'id de l'inventaire.

## Mouvements, Entretien et retours en arrière (16 octobre)

**Le menu.** « Réservations » devient **Mouvements** (`/mouvements`) : un clic
ouvre son tableau de bord (arrivées et départs du jour, en séjour, à venir,
derniers mouvements), la flèche déplie ses vues — **Nouvelle arrivée**
(l'ancienne « Arrivée directe », en tête), Réservations (filtre « Toutes »),
Faire une réservation, Arrivées, Départs, **Historique**
(`/mouvements/historique`). Même principe pour **Entretien** (`/entretien`,
`housekeeping.read|maintenance.read`) : deux tuiles, Ménage et Maintenance,
chacune avec ses chiffres et son bouton. Une sous-entrée porte `parent` dans
`app_shell.dart` ; elle remonte au premier niveau si l'agent ne voit pas son
parent, et un métier à écran unique (`MENAGE01`) n'a pas de tableau parent.

**L'historique** : la chronologie de tout ce qui entre et sort (arrivées,
départs, réservations prises ou annulées, encaissements et leurs annulations),
rangée par journée hôtelière ; et chaque client déjà venu, ses séjours, nuits,
consommations ligne par ligne et paiements (`mouvements_queries.dart`).
`?client=` ouvre d'emblée un parcours. Une réservation prise se reconnaît à
l'absence de ligne `is_walk_in`, **pas** à `source` : la tablette pose
`WALK_IN` sur tous les dossiers qu'elle crée.

**Après une création**, réservation ou nouvelle arrivée, la liste s'ouvre sur
« Toutes » : sur le filtre du matin, la réservation de la semaine prochaine
était invisible.

**Revenir en arrière** : annuler une arrivée, un départ ou un encaissement
exige le **code d'un responsable** (`operations.undo`, migration 0028 :
administrateur et direction), **même s'il est déjà connecté** — l'agent va le
chercher. `POST /auth/authorize` vérifie le code sans ouvrir de session
(403, jamais 401, pour un code faux) ; hors ligne, la tablette vérifie les
empreintes `DEMO:` et ses droits locaux (`AutorisationRepository`). Le geste
porte `approved_by` et part par la file ; le serveur revérifie le droit et
trace dans `audit_logs`. Rien ne s'efface :

- arrivée annulée : ligne `CONFIRMED` (annulée pour une arrivée directe),
  chambre libre, ardoise **retirée** (`deleted_at`), lignes annulées, arrhes
  rendues au dossier. Refusée tant qu'un encaissement n'est pas annulé ou
  qu'une consommation est portée ;
- départ annulé : le client reprend sa chambre (refusé si elle est
  réoccupée), l'ardoise se rouvre ;
- encaissement annulé : un **remboursement** du même montant
  (`payments.reverses_payment_id`, schéma local 14), dans le tiroir ouvert de
  celui qui annule. Les totaux d'ardoise retranchent désormais les
  remboursements, des deux côtés.

Les boutons : « Revenir » sur la liste des réservations, « Annuler
l'arrivée » sur la fiche chambre, la flèche ↺ dans l'historique et les
derniers mouvements (`features/annulations/accord_responsable.dart`), sur
chaque encaissement de l'ardoise et de la caisse du jour, et le panneau
**« Revenir en arrière »** de la fiche de chaque client : tout ce qui peut
encore s'y défaire (`watchMouvements(guestId:)`).

## Ce qui manque

- **La connexion hors ligne des nouveaux agents.** Un agent créé depuis
  l'administration se connecte en ligne seulement : son PIN est haché par le
  serveur et effacé de la file. `auth_locale.dart` ne vérifie que les
  empreintes `DEMO:` ; il faudrait bcrypt côté tablette et la descente des
  empreintes.
- **Impression des factures**, brique rouverte : les factures et le ticket du
  comptoir existent en PDF (partage), pas encore l'envoi à une imprimante.
- **Photos de CNI** : prises à l'arrivée, rangées sur la tablette, remontées
  par `PUT /attachments/{id}` via leur propre file (`file_uploads`,
  `FileUploader`) — jamais par la file d'envoi. Reste la **descente** : un
  second poste ne voit pas les photos prises sur le premier.
- **Créer la carte du restaurant** (menus et prix) depuis l'écran Commandes :
  elle descend déjà et se choisit à la commande, mais ne se crée pas encore
  depuis la tablette.
- Les **encaissements et les ardoises closes ne redescendent que sur 62
  jours** (`GET /payments?since=`, `GET /folios?closed_since=`, constante
  `Descente.fenetreRapports`) : les rapports d'un second poste sont complets
  sur cette fenêtre, pas au-delà.
- Attribuer une chambre sans enregistrer d'arrivée n'a pas d'endpoint
  (`ReservationRoomUpdate` n'a pas de `room_id`) ; l'attribution repart avec le
  check-in, ce qui suffit aujourd'hui.
- **Une arrivée annulée sur un poste** retire l'ardoise sur le serveur, mais
  un second poste qui l'avait déjà descendue la garde ouverte : `GET /folios`
  ne rend pas les ardoises retirées, la descente ne voit donc pas le retrait.
  Même cause que `SyncOp.DELETE` ci-dessous. La tâche de ménage ouverte par
  un départ annulé reste aussi dans la liste du ménage.
- `SyncOp.DELETE` n'est ni produit ni traité, et `SyncState.conflict` n'est
  utilisé nulle part — pas d'arbitrage de conflit.
- Aucun endpoint ne filtre sur une date de modification : chaque descente
  relit sa fenêtre. Tenable pour dix-huit chambres, à revoir ensuite.
- `passlib` cherche `bcrypt.__about__` qui n'existe plus : trace d'erreur
  cosmétique à chaque démarrage. Il n'a plus de version depuis 2020 et ne sert
  qu'à deux fonctions.
