# Setup backend — Hotel Atrium

Guide pour faire tourner l'API en local sur Windows, avec les pièges rencontrés et comment les éviter.

## 1. Faire tourner la base

### Se mettre à jour en local avec `git pull`

```powershell
git checkout main
git pull
```

Récupère les derniers commits de l'équipe avant de partir sur une nouvelle branche.

### Créer la branche `fix/hotel-scoping`

```powershell
git checkout -b fix/hotel-scoping
```

Toutes les modifications (points 2 et 3) vivent sur cette branche, jamais directement sur `main`.

### Installer les dépendances

```powershell
cd backend
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

Le `venv` est un environnement Python isolé, propre à ce projet — ça évite de mélanger les versions de paquets entre projets.

> **Piège connu — bcrypt** : `passlib` peut afficher `(trapped) error reading bcrypt version` au premier `python -m app.db.seed`. C'est une incompatibilité connue entre `passlib` et les versions récentes de `bcrypt` (≥ 4.1) ; l'erreur est piégée et n'empêche rien de fonctionner, mais pour la faire taire :
> ```powershell
> pip install "bcrypt==4.0.1"
> ```
> Et épingler `bcrypt==4.0.1` dans `requirements.txt` pour que ça ne revienne pas.

### Démarrer PostgreSQL

Ouvre un PowerShell **en administrateur** et lance :

```powershell
Start-Service postgresql-x64-18
```

C'est le service Windows qui fait tourner le moteur de base de données en arrière-plan. Sans lui, rien d'autre ne peut fonctionner.

> **Piège connu — nom du service** : si `Start-Service` répond qu'il ne trouve pas le service, le nom exact peut varier selon la version installée. Vérifie-le d'abord :
> ```powershell
> Get-Service *postgres*
> ```
> et utilise le nom exact retourné.

### Ajouter `psql` au PATH (si nécessaire)

Si `psql` n'est pas reconnu comme commande, son dossier `bin` n'est pas dans le PATH.

**Pour la session en cours :**
```powershell
$env:Path += ";C:\Program Files\PostgreSQL\18\bin"
```

**De façon permanente** (recommandé) : menu Démarrer → "variables d'environnement" → Modifier les variables d'environnement système → Variables d'environnement → `Path` → Modifier → Nouveau → `C:\Program Files\PostgreSQL\18\bin`. Redémarre ensuite tous les terminaux ouverts.

### Créer le rôle et la base

Connecte-toi d'abord à `psql` (en tant que `postgres`) :

```powershell
psql -U postgres -h localhost
```

Puis, **une fois dans l'invite `postgres=#`** (ces commandes ne fonctionnent pas directement dans PowerShell) :

```sql
CREATE ROLE atrium LOGIN PASSWORD 'ton-mot-de-passe';
CREATE DATABASE atrium OWNER atrium;
```

`atrium` est l'utilisateur PostgreSQL que l'API va utiliser pour se connecter — distinct de ton compte Windows.

### Configurer `.env`

```powershell
cd backend
cp .env.example .env
```

Puis édite `.env` et renseigne :

- `DATABASE_URL=postgresql+asyncpg://atrium:ton-mot-de-passe@localhost:5432/atrium`
- `SECRET_KEY=` — génère-la avec `python -c "import secrets; print(secrets.token_urlsafe(48))"` (voir `app/core/config.py` : sans ça, le serveur refuse carrément de démarrer, c'est volontaire).

> **Piège connu — `.env` non chargé** : `Settings` (Pydantic) charge `.env` depuis le **répertoire de travail courant**, pas depuis l'emplacement de `config.py`. Le fichier doit donc être dans `backend/`, là où tu lances `alembic` et `uvicorn` — pas à la racine du dépôt. Vérifie aussi :
> - pas de guillemets autour de la valeur (`DATABASE_URL=postgresql+...`, pas `DATABASE_URL="postgresql+..."`)
> - pas d'espace autour du `=`
>
> Pour confirmer que la bonne valeur est chargée :
> ```powershell
> python -c "from app.core.config import settings; print(settings.database_url)"
> ```
> Si tu vois `change-me` au lieu de ton mot de passe, c'est que le `.env` n'a pas été trouvé et que la valeur par défaut codée en dur est utilisée.

### Jouer les migrations

```powershell
.venv\Scripts\activate
alembic upgrade head
```

Alembic lit les fichiers de `backend/alembic/versions/` et les applique dans l'ordre pour créer les tables, les vues (`v_room_status`, `v_occupancy`, `v_daily_revenue`) et les triggers de synchronisation.

> **Piège connu — authentification échouée** : si `alembic upgrade head` échoue avec `FATAL: authentification par mot de passe échouée`, le mot de passe dans `.env` ne correspond pas à celui du rôle PostgreSQL. Réinitialise-le pour être sûr :
> ```powershell
> psql -U postgres -h localhost -c "ALTER ROLE atrium WITH PASSWORD 'ton-mot-de-passe';"
> ```

### Vérifier les tables

```powershell
psql -U atrium -d atrium
```
```sql
\dt
```

Tu dois voir les 66 tables du modèle (hotels, rooms, reservations, folios…).

### Vérifier les triggers

```sql
SELECT tgname FROM pg_trigger WHERE tgname LIKE 'trg%_sync';
```

106 lignes attendues (53 tables synchronisées × 2 triggers chacune — un pour INSERT/UPDATE, un pour DELETE, voir la migration `0002_sync_sequence_triggers.py`).

> **À vérifier si le compte est inférieur** : si tu obtiens moins de 106 lignes, groupe par table pour repérer lesquelles ont un trigger manquant :
> ```sql
> SELECT tgrelid::regclass AS table_name, count(*)
> FROM pg_trigger
> WHERE tgname LIKE 'trg%_sync'
> GROUP BY tgrelid::regclass
> ORDER BY count(*) ASC;
> ```
> Si chaque table listée n'a qu'1 trigger au lieu de 2, la migration `0002_sync_sequence_triggers.py` n'a probablement créé qu'un seul type de trigger par table — vérifie son contenu et si elle a été rejouée jusqu'au bout (`alembic current` vs la dernière révision du dossier `versions/`).

### Charger le jeu de données de démo

```powershell
python -m app.db.seed
```

Ça crée l'hôtel, les 18 chambres, les rôles/permissions et l'utilisateur `ADMIN01` / `ChangeMe123!`.

### Lancer le serveur et tester

```powershell
uvicorn app.main:app --reload
```

Ouvre `http://localhost:8000/docs` (pas `http://localhost:8000/` tout court, qui renvoie normalement `{"detail":"Not Found"}` puisqu'aucune route n'y est définie).

Dans Swagger, teste `POST /api/v1/auth/login` ("Try it out") avec :
```json
{"employee_code": "ADMIN01", "password": "ChangeMe123!"}
```

Tu dois recevoir un `access_token`.
