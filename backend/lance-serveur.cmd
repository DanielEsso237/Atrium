@echo off
REM Lance le serveur Atrium et le publie sur Internet par ngrok.
REM
REM Les tablettes joignent le serveur par son domaine ngrok fixe, de
REM n'importe quel reseau : plus d'adresse IP a recopier a chaque changement
REM de Wi-Fi, plus de pare-feu Windows a regler (c'est ce PC qui ouvre la
REM connexion vers ngrok, rien n'entre de l'exterieur).
REM
REM Une fois pour toutes :
REM   - ngrok installe, et `ngrok config add-authtoken <jeton>` fait ;
REM   - dans backend\.env : NGROK_DOMAIN=<votre-domaine>.ngrok-free.app
REM     (le domaine fixe gratuit, tableau de bord ngrok > Domains), et
REM     NGROK_EXE=<chemin de ngrok.exe> si ngrok n'est pas dans le PATH.
REM Puis la tablette se compile avec
REM   --dart-define=ATRIUM_API=https://<votre-domaine>.ngrok-free.app/api/v1
REM
REM Usage : lance-serveur.cmd [domaine]   (le domaine passe en argument
REM l'emporte sur celui du .env)

setlocal
cd /d "%~dp0"

set "NGROK_DOMAIN="
set "NGROK_EXE=ngrok"
for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
  if /i "%%a"=="NGROK_DOMAIN" set "NGROK_DOMAIN=%%b"
  if /i "%%a"=="NGROK_EXE" set "NGROK_EXE=%%b"
)
if not "%~1"=="" set "NGROK_DOMAIN=%~1"
if "%NGROK_DOMAIN%"=="" (
  echo Aucun domaine ngrok : ajoutez NGROK_DOMAIN=... dans backend\.env
  exit /b 1
)

"%NGROK_EXE%" version >nul 2>nul
if errorlevel 1 (
  echo ngrok est introuvable : indiquez le chemin de ngrok.exe dans backend\.env (NGROK_EXE=...)
  exit /b 1
)

REM La base d'abord : un serveur lance sur un schema en retard repond 500 a
REM la premiere synchronisation, et la tablette le lit comme une panne.
.venv\Scripts\python -m alembic upgrade head
if errorlevel 1 (
  echo La base ne repond pas. PostgreSQL est-il demarre ? Apres un arret
  echo brutal, il peut mettre plusieurs minutes a accepter les connexions.
  exit /b 1
)

REM Sur 127.0.0.1 seulement : ngrok est la seule porte d'entree. Le port
REM 8001, parce que le 8000 est pris par un autre serveur sur ce PC.
start "Atrium - serveur" .venv\Scripts\python -m uvicorn app.main:app --host 127.0.0.1 --port 8001

echo.
echo Serveur : https://%NGROK_DOMAIN%/docs
echo Tablette : --dart-define=ATRIUM_API=https://%NGROK_DOMAIN%/api/v1
echo Fermer cette fenetre coupe l'acces des tablettes ; fermer l'autre
echo arrete le serveur.
echo.
"%NGROK_EXE%" http 127.0.0.1:8001 --url=https://%NGROK_DOMAIN%
