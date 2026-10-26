/// Les tablettes de l'hotel et les blocages de leur file d'envoi.
///
/// Ce que l'ecran Tablettes lit : la liste descendue du serveur
/// (`devices`, `sync_blocks`), pour qui porte `sync.monitor`. Un blocage ne
/// se voyait que sur la tablette elle-meme ; ici, l'administration et la
/// direction le voient de n'importe quel poste.
library;

import 'dart:convert';

import '../database.dart';

/// Une ecriture refusee par le serveur, telle qu'une tablette l'a annoncee.
class BlocageVu {
  const BlocageVu({
    required this.id,
    required this.table,
    required this.operation,
    required this.bloqueLe,
    required this.derriere,
    required this.ouvert,
    this.raison,
    this.auteur,
    this.montant,
    this.leveLe,
    this.resolution,
  });

  final String id;
  final String table;
  final String operation;
  final DateTime bloqueLe;

  /// Les ecritures qui attendaient derriere, au dernier rapport.
  final int derriere;
  final bool ouvert;
  final String? raison;

  /// Le code de l'agent dont l'ecriture est refusee.
  final String? auteur;

  /// Le montant de l'ecriture, quand elle en porte un.
  final int? montant;
  final DateTime? leveLe;

  /// `SENT` : l'ecriture est passee. `REMOVED` : elle a quitte la file.
  final String? resolution;

  /// Ce que l'ecriture faisait, dit comme a la reception.
  String get quoi => switch (table) {
    'payments' => 'Encaissement',
    'folio_items' => 'Consommation',
    'folios' => 'Ardoise',
    'reservation_rooms' => 'Arrivée ou départ',
    'reservations' => 'Réservation',
    'guests' => 'Fiche client',
    'cash_sessions' => 'Caisse',
    'orders' => 'Commande',
    'housekeeping_tasks' => 'Ménage',
    'maintenance_tickets' => 'Panne',
    'users' => 'Agent',
    'expenses' => 'Dépense',
    'stock_movements' => 'Mouvement de stock',
    'inventories' => 'Inventaire',
    'invoices' => 'Facture',
    _ => table,
  };
}

/// Une tablette, et ce qui bloque (ou a bloque) sa file.
class TabletteSuivie {
  const TabletteSuivie({
    required this.id,
    required this.nom,
    required this.estCelleCi,
    required this.blocages,
    this.version,
    this.vueLe,
  });

  final String id;
  final String nom;

  /// La tablette sur laquelle on lit l'ecran.
  final bool estCelleCi;
  final String? version;
  final DateTime? vueLe;

  /// Les blocages en cours d'abord, puis ceux leves depuis une semaine.
  final List<BlocageVu> blocages;

  bool get bloquee => blocages.any((b) => b.ouvert);
}

extension TablettesQueries on AtriumDatabase {
  /// Les tablettes bloquees en tete, puis les autres par nom.
  Stream<List<TabletteSuivie>> watchTablettes() {
    return customSelect(
      '''
      SELECT d.id AS id, d.name AS nom, d.app_version AS version,
             d.last_seen_at AS vue,
             d.id = (SELECT device_id FROM sync_statuses WHERE id = 1) AS ici
        FROM devices d
       WHERE d.deleted_at IS NULL
      UNION
      -- Une tablette annoncee par son blocage seulement : sa fiche n'est pas
      -- encore descendue, son blocage doit se voir quand meme.
      SELECT b.device_id, NULL, NULL, NULL,
             b.device_id = (SELECT device_id FROM sync_statuses WHERE id = 1)
        FROM sync_blocks b
       WHERE b.device_id NOT IN (SELECT id FROM devices)
      ''',
      readsFrom: {devices, syncBlocks, syncStatuses},
    ).watch().asyncMap((tablettes) async {
      final blocages = await customSelect(
        '''
        SELECT b.id AS id, b.device_id AS tablette, b.entity_table AS t,
               b.operation AS op, b.reason AS raison, b.payload AS contenu,
               b.pending_behind AS derriere, b.blocked_at AS bloque,
               b.status AS statut, b.resolved_at AS leve,
               b.resolution AS resolution, u.employee_code AS auteur
          FROM sync_blocks b
          LEFT JOIN users u ON u.id = b.author_id
         WHERE b.deleted_at IS NULL
         ORDER BY b.status = 'OPEN' DESC, b.blocked_at DESC
        ''',
        readsFrom: {syncBlocks, users},
      ).get();
      final parTablette = <String, List<BlocageVu>>{};
      for (final b in blocages) {
        parTablette
            .putIfAbsent(b.read<String>('tablette'), () => [])
            .add(
              BlocageVu(
                id: b.read<String>('id'),
                table: b.read<String>('t'),
                operation: b.read<String>('op'),
                raison: b.readNullable<String>('raison'),
                auteur: b.readNullable<String>('auteur'),
                montant: _montant(b.readNullable<String>('contenu')),
                derriere: b.read<int>('derriere'),
                bloqueLe: b.read<DateTime>('bloque'),
                ouvert: b.read<String>('statut') == 'OPEN',
                leveLe: b.readNullable<DateTime>('leve'),
                resolution: b.readNullable<String>('resolution'),
              ),
            );
      }
      final liste = [
        for (final t in tablettes)
          TabletteSuivie(
            id: t.read<String>('id'),
            nom:
                t.readNullable<String>('nom') ??
                'Tablette ${t.read<String>('id').substring(32).toUpperCase()}',
            estCelleCi: t.readNullable<bool>('ici') ?? false,
            version: t.readNullable<String>('version'),
            vueLe: t.readNullable<DateTime>('vue'),
            blocages: parTablette[t.read<String>('id')] ?? const [],
          ),
      ];
      liste.sort((a, b) {
        if (a.bloquee != b.bloquee) return a.bloquee ? -1 : 1;
        return a.nom.compareTo(b.nom);
      });
      return liste;
    });
  }
}

/// Le montant d'une ecriture refusee, quand son contenu en porte un.
int? _montant(String? contenu) {
  if (contenu == null) return null;
  try {
    final p = jsonDecode(contenu);
    if (p is! Map) return null;
    final m = p['amount'];
    return m is int ? m : null;
  } on FormatException {
    return null;
  }
}
