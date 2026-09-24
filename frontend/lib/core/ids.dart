/// Generation des identifiants, cote tablette.
///
/// Pendant du module serveur `backend/app/core/ids.py`, et pour la meme
/// raison : **les cles primaires sont generees par la tablette, jamais par le
/// serveur**. C'est ce qui permet de creer une reservation, de l'imprimer et
/// de la facturer pendant une coupure Wi-Fi, sans jamais attendre un
/// aller-retour reseau.
///
/// UUID v7 plutot que v4 : les 48 premiers bits sont l'horodatage Unix en
/// millisecondes, donc les cles restent croissantes dans le temps. Les
/// insertions se font en fin d'index B-tree au lieu de fragmenter l'arbre, et
/// `ORDER BY id` a un sens.
library;

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Un nouvel identifiant, au format canonique a 36 caracteres.
String newId() => _uuid.v7();
