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
porte la nuitée sur l'ardoise, le check-out ouvre une tâche de ménage : qui
peut l'un doit pouvoir l'autre, sinon il produit des écritures que le serveur
lui refuse et la file se bloque derrière. Le piège s'est produit deux fois.
`backend/tests/test_droits_coherents.py` le verrouille — y ajouter chaque
nouvelle implication.

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

## Pièges rencontrés

- `customStatement` prend des **valeurs brutes** ; `customSelect` prend des
  `Variable`. Les confondre lève une erreur de liaison silencieuse.
- `customStatement` **ne prévient aucun écran**. Drift ne sait pas ce qu'une
  requête brute modifie : la ligne change en base et l'affichage garde sa
  valeur périmée. Utiliser `customUpdate(..., updates: {table})`.
- Le montage des tests serveur ne **reconstruit plus le schéma** à chaque test.
  L'ancienne version créait puis détruisait les soixante tables à chaque fois ;
  PostgreSQL a pris 24 minutes de synchronisation sur un point de contrôle et
  le postmaster s'est arrêté. Ne pas y revenir.
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
backend). Neo est parti sur un autre projet.

## Où en est le produit

Fonctionne de bout en bout : connexion par PIN, plan des chambres, clients,
réservations, arrivées et départs, facturation avec encaissement, ménage, et
**interfaces par métier** (§3.4) — chaque rôle ne voit que ses modules, et le
routeur refuse les autres, pas seulement l'affichage.

La **file d'envoi remonte toute seule**, dans l'ordre, sans doublon même en cas
de renvoi, avec espacement des tentatives hors ligne. Un refus du serveur
bloque la file au lieu de la sauter, et se voit.

Ce qui manque, par ordre d'importance :

- **La descente.** Seul le référentiel des chambres redescend du serveur. Ni
  clients, ni réservations, ni ardoises : une tablette neuve est aveugle, et
  une seconde tablette ne verrait pas le travail de la première.
- Restaurant et maintenance : modules absents, boutons masqués par les droits.
- Attribuer une chambre sans enregistrer d'arrivée n'a pas d'endpoint
  (`ReservationRoomUpdate` n'a pas de `room_id`) ; l'attribution repart avec le
  check-in, ce qui suffit aujourd'hui.
- `SyncOp.DELETE` n'est ni produit ni traité, et `SyncState.conflict` n'est
  utilisé nulle part — il n'y a pas d'arbitrage de conflit, parce qu'avec une
  seule tablette il ne peut pas y en avoir.
- `passlib` cherche `bcrypt.__about__` qui n'existe plus : trace d'erreur
  cosmétique à chaque démarrage. `passlib` n'a plus de version depuis 2020 et
  ne sert qu'à deux fonctions.
