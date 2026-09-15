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
cp .env.example .env              # puis renseigner DATABASE_URL

alembic upgrade head              # crée le schéma
uvicorn app.main:app --reload     # (à venir)
```

**Prérequis : PostgreSQL 13 ou supérieur** (`gen_random_uuid()` en natif).
Non installé sur la machine de développement à ce jour.

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
flutter test                    # 7 tests : schéma, index, montants, clés étrangères
flutter run -d windows
```

Développer sur **Windows desktop** : la base Drift est alors un fichier
`.sqlite` ouvrable dans DB Browser pendant que l'application tourne. On ne
branche une tablette Android que pour tester le tactile et l'impression.

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
