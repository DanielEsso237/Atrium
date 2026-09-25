@echo off
REM Lance Atrium dans Chrome, toujours sur le meme port.
REM
REM Le port n'est pas un detail : la base locale du navigateur est cloisonnee
REM par origine. `flutter run` en choisit un au hasard a chaque lancement,
REM donc chaque demarrage ouvrait une base neuve et tout ce qui avait ete
REM saisi restait dans l'ancienne -- intact, mais introuvable.
REM
REM Utiliser ce script plutot que `flutter run` a la main.
flutter run -d chrome --web-port=8080 %*
