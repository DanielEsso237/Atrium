/// Rend neuve une tablette de developpement.
///
/// L'application recreait a chaque lancement, en mode developpement, un jeu
/// de demonstration : des clients (Rokia Toure, Paul Ouattara...), huit
/// sejours en cours, des ardoises. Ces donnees n'existaient que sur la
/// tablette : des qu'on y touchait, le serveur repondait « reservation
/// introuvable » et la file d'envoi se bloquait. Vider le navigateur ne
/// servait a rien -- tout revenait au lancement suivant.
///
/// Le jeu est supprime. Une tablette qui en porte encore la marque (le
/// reglage `demo.activite`) est une tablette de developpement : toute son
/// activite locale est effacee, file d'envoi comprise, et les chambres
/// redeviennent libres et propres. Elle repart comme neuve et redescend ce
/// que le serveur contient. Une tablette installee a l'hotel n'a jamais eu
/// ce jeu : elle n'est pas touchee.
library;

import 'database.dart';

/// Le compte de demonstration du restaurant, retire des comptes de depart.
const _restau01 = '01920000-0000-7000-8000-000000050004';

/// L'activite locale, des tables qui referencent vers celles qui sont
/// referencees.
const _activite = [
  'order_item_options',
  'order_items',
  'orders',
  'invoice_lines',
  'invoices',
  'payments',
  'folio_items',
  'folios',
  'cash_sessions',
  'housekeeping_task_items',
  'housekeeping_tasks',
  'amenity_consumptions',
  'maintenance_interventions',
  'maintenance_tickets',
  'stay_nights',
  'reservation_guests',
  'signatures',
  'reservation_rooms',
  'reservations',
  'guest_documents',
  'attachments',
  'file_uploads',
  'notifications',
  'outbox_entries',
  'guests',
];

/// Rend `true` si la tablette a ete remise a neuf.
Future<bool> purgeDemoActivity(AtriumDatabase db) async {
  // Le compte RESTAU01 n'existe plus nulle part : on le retire partout.
  await db.customStatement(
    "DELETE FROM user_roles WHERE user_id = '$_restau01'",
  );
  await db.customStatement(
    "DELETE FROM user_outlets WHERE user_id = '$_restau01'",
  );
  await db.customStatement("DELETE FROM users WHERE id = '$_restau01'");

  final marque = await db
      .customSelect(
        "SELECT 1 FROM settings WHERE key = 'demo.activite' LIMIT 1",
      )
      .getSingleOrNull();
  if (marque == null) return false;

  // Au demarrage, avant tout ecran : aucun flux a prevenir. Les cles
  // etrangeres sont suspendues le temps du grand menage, pour ne pas
  // dependre d'un ordre de suppression parfait.
  await db.customStatement('PRAGMA foreign_keys = OFF');
  try {
    await db.transaction(() async {
      for (final table in _activite) {
        await db.customStatement('DELETE FROM $table');
      }
      await db.customStatement(
        "UPDATE rooms SET occupancy_status = 'VACANT', "
        "housekeeping_status = 'CLEAN'",
      );
      await db.customStatement(
        "DELETE FROM settings WHERE key = 'demo.activite'",
      );
    });
  } finally {
    await db.customStatement('PRAGMA foreign_keys = ON');
  }
  return true;
}
