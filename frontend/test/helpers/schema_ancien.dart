/// Ramener une base neuve a l'etat d'une tablette deja deployee.
///
/// Les tests de migration creent une base au schema courant, puis retirent
/// ce qu'une ancienne version n'avait pas. Chaque colonne ajoutee depuis doit
/// disparaitre aussi, sinon le pas de migration la recree et SQLite refuse
/// (« duplicate column name ») : la liste vit ici, une fois.
library;

import 'package:atrium/data/local/database.dart';

/// Les colonnes ajoutees a partir de chaque schema.
const _ajouteesAuSchema = <int, List<(String, String)>>{
  20: [('outbox_entries', 'group_keys')],
  21: [
    ('devices', 'revoked_at'),
    ('devices', 'revoked_by'),
    ('devices', 'revocation_reason'),
  ],
};

/// Retire les colonnes posterieures au schema [version].
Future<void> retirerColonnesApres(AtriumDatabase base, int version) async {
  for (final MapEntry(key: schema, value: colonnes)
      in _ajouteesAuSchema.entries) {
    if (schema <= version) continue;
    for (final (table, colonne) in colonnes) {
      await base.customStatement('ALTER TABLE $table DROP COLUMN $colonne');
    }
  }
}
