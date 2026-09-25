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
`hotels.day_rollover_hour` (6 h), dans `hotels.timezone`. Ne jamais utiliser
`dt.date.today()` côté serveur : `app/services/business_day.py` existe pour ça.

**Le folio est le centre de la facturation.** Toute consommation y atterrit ; la
facture n'est qu'un gel du folio. Les totaux se recalculent **en SQL** dans la
même transaction.

## Conventions

- **Identifiants en anglais, documentation et commentaires en français.**
  Exception connue et à corriger : `data/local/queries/room_detail_queries.dart`.
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
cd frontend && flutter run -d chrome        # ou -d <appareil Android>
flutter test && flutter analyze lib/ test/
```

`flutter analyze` met une dizaine de minutes sur cette machine. `flutter run`
attrape les mêmes **erreurs** en deux minutes ; l'analyseur voit en plus les
avertissements. Lancer l'application pour itérer, l'analyseur avant une PR.

Compte de démonstration : `ADMIN01` / `ChangeMe123!` (serveur) ou `1234` (PIN
local, hors ligne).

## Pièges rencontrés

- `customStatement` prend des **valeurs brutes** ; `customSelect` prend des
  `Variable`. Les confondre lève une erreur de liaison silencieuse.
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
