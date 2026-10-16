/// L'onglet Personnel (demande du 15 octobre) : chaque agent, son role, ses
/// points de vente, et ce qu'il genere sur une periode.
///
/// Le chiffre d'affaires d'un agent est ce qu'il a porte sur les ardoises
/// (`folio_items.posted_by`) -- consommations, nuitees, arrivees directes --,
/// hors lignes annulees. L'encaisse est ce qu'il a recu
/// (`payments.received_by`), remboursements deduits. Les deux se datent de
/// la journee hoteliere, jamais du calendrier.
///
/// La tablette ne connait que ce qui y est descendu : ce que les autres
/// postes ont saisi arrive par la descente (ardoises, ventes des points de
/// vente, encaissements), sur la fenetre des rapports.
library;

import 'package:drift/drift.dart';

import '../../../core/business_day.dart';
import '../../../core/formats.dart';
import '../database.dart';

/// Un agent et ce qu'il a fait sur la periode.
class AgentPersonnel {
  const AgentPersonnel({
    required this.id,
    required this.code,
    required this.nom,
    required this.actif,
    required this.roles,
    required this.pointsDeVente,
    required this.chiffreAffaires,
    required this.ventes,
    required this.encaisse,
    required this.caisses,
    required this.ecartCaisse,
    this.derniereConnexion,
  });

  final String id;
  final String code;
  final String nom;
  final bool actif;

  /// Les libelles de ses roles.
  final List<String> roles;

  /// Les points de vente auxquels il est rattache ; vide : tout l'hotel.
  final List<String> pointsDeVente;

  final int chiffreAffaires;

  /// Les ardoises sur lesquelles il a porte quelque chose.
  final int ventes;
  final int encaisse;

  /// Les caisses qu'il a ouvertes sur la periode, et l'ecart cumule de
  /// celles qu'il a fermees.
  final int caisses;
  final int ecartCaisse;
  final DateTime? derniereConnexion;
}

/// La part d'un point de vente dans le chiffre d'affaires d'un agent.
class PartAgent {
  const PartAgent({required this.libelle, required this.montant});

  final String libelle;
  final int montant;
}

extension PersonnelQueries on AtriumDatabase {
  /// Les agents de l'hotel, ceux qui vendent le plus d'abord.
  Stream<List<AgentPersonnel>> watchPersonnel({
    required DateTime du,
    required DateTime au,
  }) {
    return customSelect(
      '''
      SELECT u.id, u.employee_code, u.first_name, u.last_name, u.is_active,
             u.last_login_at,
             (SELECT GROUP_CONCAT(r.label, '|')
                FROM user_roles ur JOIN roles r ON r.id = ur.role_id
               WHERE ur.user_id = u.id) AS roles,
             (SELECT GROUP_CONCAT(o.label, '|')
                FROM user_outlets uo JOIN outlets o ON o.id = uo.outlet_id
               WHERE uo.user_id = u.id AND o.deleted_at IS NULL) AS points,
             (SELECT COALESCE(SUM(fi.amount), 0) FROM folio_items fi
               WHERE fi.posted_by = u.id AND fi.deleted_at IS NULL
                 AND fi.is_void = 0
                 AND fi.business_date BETWEEN ?1 AND ?2) AS ca,
             (SELECT COUNT(DISTINCT fi.folio_id) FROM folio_items fi
               WHERE fi.posted_by = u.id AND fi.deleted_at IS NULL
                 AND fi.is_void = 0
                 AND fi.business_date BETWEEN ?1 AND ?2) AS ventes,
             (SELECT COALESCE(SUM(CASE WHEN p.is_refund = 1
                                       THEN -p.amount ELSE p.amount END), 0)
                FROM payments p
               WHERE p.received_by = u.id AND p.deleted_at IS NULL
                 AND p.business_date BETWEEN ?1 AND ?2) AS encaisse,
             (SELECT COUNT(*) FROM cash_sessions c
               WHERE c.user_id = u.id AND c.deleted_at IS NULL
                 AND c.opened_at >= ?3 AND c.opened_at < ?4) AS caisses,
             (SELECT COALESCE(SUM(c.variance), 0) FROM cash_sessions c
               WHERE c.user_id = u.id AND c.deleted_at IS NULL
                 AND c.status = 'CLOSED'
                 AND c.opened_at >= ?3 AND c.opened_at < ?4) AS ecart
        FROM users u
       WHERE u.deleted_at IS NULL
       ORDER BY ca DESC, u.last_name, u.first_name
      ''',
      variables: [
        Variable.withString(formatIsoDate(du)),
        Variable.withString(formatIsoDate(au)),
        // Une caisse n'a pas de journee hoteliere : elle se range par
        // l'instant de son ouverture, entre la bascule du premier jour et
        // celle du lendemain du dernier. A 3 h, on est encore la veille.
        Variable<DateTime>(
          DateTime(du.year, du.month, du.day, heureBasculeParDefaut).toUtc(),
        ),
        Variable<DateTime>(
          DateTime(au.year, au.month, au.day + 1, heureBasculeParDefaut)
              .toUtc(),
        ),
      ],
      readsFrom: {
        users,
        userRoles,
        roles,
        userOutlets,
        outlets,
        folioItems,
        payments,
        cashSessions,
      },
    ).watch().map(
      (rangs) => [
        for (final r in rangs)
          AgentPersonnel(
            id: r.read<String>('id'),
            code: r.read<String>('employee_code'),
            nom:
                '${r.read<String>('first_name')} ${r.read<String>('last_name')}'
                    .trim(),
            actif: r.read<bool>('is_active'),
            roles: _liste(r.readNullable<String>('roles')),
            pointsDeVente: _liste(r.readNullable<String>('points')),
            chiffreAffaires: r.read<int>('ca'),
            ventes: r.read<int>('ventes'),
            encaisse: r.read<int>('encaisse'),
            caisses: r.read<int>('caisses'),
            ecartCaisse: r.read<int>('ecart'),
            derniereConnexion: r.readNullable<DateTime>('last_login_at'),
          ),
      ],
    );
  }

  /// Le chiffre d'affaires de chaque agent, point de vente par point de
  /// vente ; ce qui n'en vient pas (nuitees, arrivees directes) se range
  /// sous « Hébergement ». La cle est l'agent.
  Stream<Map<String, List<PartAgent>>> watchPartsAgents({
    required DateTime du,
    required DateTime au,
  }) {
    return customSelect(
      '''
      SELECT fi.posted_by AS agent,
             COALESCE(o.label, 'Hébergement') AS libelle,
             SUM(fi.amount) AS montant
        FROM folio_items fi
        LEFT JOIN outlets o
               ON fi.source_table = 'outlets' AND o.id = fi.source_id
       WHERE fi.posted_by IS NOT NULL AND fi.deleted_at IS NULL
         AND fi.is_void = 0
         AND fi.business_date BETWEEN ?1 AND ?2
       GROUP BY fi.posted_by, libelle
       ORDER BY montant DESC
      ''',
      variables: [
        Variable.withString(formatIsoDate(du)),
        Variable.withString(formatIsoDate(au)),
      ],
      readsFrom: {folioItems, outlets},
    ).watch().map((rangs) {
      final parts = <String, List<PartAgent>>{};
      for (final r in rangs) {
        parts
            .putIfAbsent(r.read<String>('agent'), () => [])
            .add(
              PartAgent(
                libelle: r.read<String>('libelle'),
                montant: r.read<int>('montant'),
              ),
            );
      }
      return parts;
    });
  }
}

List<String> _liste(String? valeur) => valeur == null || valeur.isEmpty
    ? const []
    : (valeur.split('|').toSet().toList()..sort());
