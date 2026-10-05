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

## Ce qui manque

- **La connexion hors ligne des nouveaux agents.** Un agent créé depuis
  l'administration se connecte en ligne seulement : son PIN est haché par le
  serveur et effacé de la file. `auth_locale.dart` ne vérifie que les
  empreintes `DEMO:` ; il faudrait bcrypt côté tablette et la descente des
  empreintes.
- **Impression des factures**, brique rouverte.
- **Photos de CNI** : prises à l'arrivée, rangées sur la tablette, remontées
  par `PUT /attachments/{id}` via leur propre file (`file_uploads`,
  `FileUploader`) — jamais par la file d'envoi. Reste la **descente** : un
  second poste ne voit pas les photos prises sur le premier.
- **Créer la carte du restaurant** (menus et prix) depuis l'écran Commandes :
  elle descend déjà et se choisit à la commande, mais ne se crée pas encore
  depuis la tablette.
- Le détail des **encaissements ne redescend pas** (`FolioOut` ne les expose
  pas) : sur un second poste, le solde est juste mais on ne sait pas qui a
  payé quoi.
- Attribuer une chambre sans enregistrer d'arrivée n'a pas d'endpoint
  (`ReservationRoomUpdate` n'a pas de `room_id`) ; l'attribution repart avec le
  check-in, ce qui suffit aujourd'hui.
- `SyncOp.DELETE` n'est ni produit ni traité, et `SyncState.conflict` n'est
  utilisé nulle part — pas d'arbitrage de conflit.
- Aucun endpoint ne filtre sur une date de modification : chaque descente
  relit sa fenêtre. Tenable pour dix-huit chambres, à revoir ensuite.
- `passlib` cherche `bcrypt.__about__` qui n'existe plus : trace d'erreur
  cosmétique à chaque démarrage. Il n'a plus de version depuis 2020 et ne sert
  qu'à deux fonctions.
