/// Ouverture de la base, selon la plateforme.
///
/// Le mobile ouvre un vrai fichier SQLite ; le navigateur ouvre SQLite
/// compile en WebAssembly, stocke dans IndexedDB. L'export conditionnel
/// ci-dessous choisit l'implementation a la compilation : `database.dart` ne
/// connait qu'une fonction, `ouvrirBase()`.
///
/// Le web n'est **pas** une cible de production : les tablettes du parc sont
/// des Android. C'est un outil de developpement — on redimensionne la fenetre
/// du navigateur pour voir une mise en page de 10 pouces sans brancher
/// d'appareil ni lancer d'emulateur. Le stockage y est different (IndexedDB et
/// non un fichier), donc le web ne prouve rien sur le comportement hors ligne
/// reel : pour cela, il faut un vrai appareil.
library;

export 'native.dart' if (dart.library.js_interop) 'web.dart';
