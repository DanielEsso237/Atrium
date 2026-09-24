# Atrium

Système de gestion hôtelière sur tablettes, **hors ligne d'abord**, avec
impression localisée et synchronisation vers un serveur central.

Réf. cahier des charges « Système de gestion hôtelière sur tablettes avec
serveur central, impression localisée et mode hors connexion ».

---

## Architecture

```
Tablettes (mode kiosque)          Serveur central
┌──────────────────────┐          ┌──────────────────────┐
│  Flutter             │          │  FastAPI (Python)    │
│  SQLite / Drift      │ ◄─REST─► │  PostgreSQL          │
│  file d'impression   │   JWT    │  moteur d'impression │
└──────────────────────┘          └──────────────────────┘
         │                                  │
         └──────── ESC/POS · IPP ───────────┘
              imprimantes réseau
```

L'application fonctionne intégralement sans réseau : toutes les lectures et
écritures passent par la base locale, l'échange avec le serveur n'étant qu'un
mécanisme d'arrière-plan.

## Arborescence

```
atrium/
├── docs/
│   ├── 01-modele-de-donnees.md      MCD/MLD, décisions de modélisation
│   ├── 02-base-locale-drift.md      schéma SQLite, types, index
│   ├── 03-workflows.md              parcours métier, opération par opération
│   └── le-classeur-de-l-hotel.html  présentation sans jargon, fichier autonome
│                                    à envoyer à qui doit comprendre le système
├── backend/
│   ├── .venv/                       Python 3.11
│   ├── alembic/versions/            migrations
│   └── app/
│       ├── core/                    config, génération d'UUID v7
│       ├── db/                      base déclarative, mixins
│       ├── models/                  66 tables SQLAlchemy
│       ├── api/  schemas/  services/  sync/
│       └── tests/
└── frontend/
    └── lib/data/local/
        ├── columns.dart             mixins de colonnes communes
        ├── enums.dart               énumérations (miroir du serveur)
        ├── database.dart            base Drift, pragmas, index
        └── tables/                  65 tables Drift
```

## Backend

```bash
cd backend
.venv/Scripts/activate            # Windows
cp .env.example .env              # puis renseigner DATABASE_URL et SECRET_KEY

alembic upgrade head              # crée le schéma
uvicorn app.main:app --reload
pytest                            # tests purs, sans base
```

**Le `.env` est obligatoire.** `SECRET_KEY` n'a pas de valeur par défaut : sans
elle, le serveur refuse de démarrer avec un message qui dit quoi faire. Une clé
par défaut connue de tous rendrait les jetons JWT forgeables par quiconque a lu
le dépôt. La générer avec :

```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Hors `ENV=dev`, une valeur d'exemple ou de moins de 32 caractères est refusée.

**Prérequis : PostgreSQL 13 ou supérieur** (`gen_random_uuid()` en natif).
PostgreSQL 18 est installé sur la machine de développement ; le service
`postgresql-x64-18` doit être démarré. Les migrations n'ont pas encore été
jouées contre une vraie base.

Tests :

```bash
pytest                            # tests purs uniquement
TEST_DATABASE_URL=postgresql+asyncpg://... pytest   # + tests marqués `db`
```

Les tests marqués `@pytest.mark.db` sont ignorés tant que `TEST_DATABASE_URL`
est absent, pour qu'un `pytest` sur une machine sans base reste vert au lieu de
produire des erreurs de connexion qu'on apprend vite à ignorer.

Migrations :

```bash
alembic revision --autogenerate -m "message"
alembic upgrade head
alembic downgrade -1
alembic history
```

L'URL de connexion vient de `app/core/config.py` (fichier `.env`), pas
d'`alembic.ini` — une seule source de vérité, pour qu'une migration ne puisse
pas se jouer sur une base différente de celle que sert l'API.

## Frontend

```bash
cd frontend
flutter pub get
dart run build_runner build     # génère database.g.dart
flutter test                    # 36 tests
```

Trois façons de lancer l'application, par ordre d'utilité :

| Cible | Commande | Pour quoi |
|---|---|---|
| Appareil Android | `flutter run -d <appareil>` | **la vraie cible.** Tactile, impression, vrai stockage hors ligne |
| Navigateur | `flutter run -d chrome` | itérer vite sur la mise en page — redimensionner dans les outils de développement pour simuler une tablette |
| Windows desktop | `flutter run -d windows` | la base est un fichier `.sqlite` ouvrable dans DB Browser pendant que l'application tourne |

**Windows desktop exige Visual Studio avec la charge de travail C++** (plusieurs
gigaoctets). Sans elle, `flutter run -d windows` échoue sur
`Unable to find suitable Visual Studio toolchain`. Ce n'est pas un prérequis du
projet : un appareil Android branché en USB suffit, et c'est de toute façon la
plateforme de production.

**Le navigateur n'est qu'un outil de mise en page.** La base y vit dans
IndexedDB via SQLite compilé en WebAssembly, pas dans un fichier : le web ne
prouve donc rien sur le comportement hors ligne réel. Les deux fichiers
nécessaires (`web/sqlite3.wasm`, `web/drift_worker.js`) sont versionnés et
doivent être remis à jour si `drift` ou `sqlite3` changent de version majeure.
Le choix de l'implémentation se fait dans `lib/data/local/connection/`.

Après toute modification d'une table Drift, relancer `build_runner`.

## État d'avancement

| Étape | État |
|---|---|
| Choix techniques et modèle de données | fait — `docs/01-modele-de-donnees.md` |
| Schéma serveur (66 tables SQLAlchemy) | fait |
| Migrations Alembic + triggers de synchronisation | fait, non exécutées (PostgreSQL absent) |
| Schéma local Drift (65 tables + clés étrangères) | fait — `docs/02-base-locale-drift.md` |
| Moteur de synchronisation | à faire |
| API REST | à faire |
| Moteur d'impression localisée | à faire |
| Interfaces Flutter par rôle | à faire |

## Décisions structurantes

Détaillées dans `docs/01-modele-de-donnees.md`. Les quatre principales :

1. **L'état d'une chambre tient sur trois axes**, pas un — occupation,
   propreté, hors service. La pastille de couleur de l'écran §5.2 est calculée
   à l'affichage. Sinon réception et housekeeping s'écrasent mutuellement à
   chaque synchronisation.
2. **Le routage d'impression vit dans le modèle de données** : la station de
   préparation est portée par l'article du menu, ce qui rend la règle R1
   (cuisine ≠ bar) structurellement impossible à violer.
3. **Le folio est le centre de la facturation.** Toute charge y atterrit ; la
   facture n'est qu'un gel du folio à un instant donné.
4. **La synchronisation s'appuie sur une séquence globale**, jamais sur
   `updated_at` — les horloges des tablettes dérivent et les transactions
   concurrentes ne committent pas dans l'ordre où elles écrivent.
