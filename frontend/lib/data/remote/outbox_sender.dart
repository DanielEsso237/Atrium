/// Le moteur qui vide la file d'envoi (6.3).
///
/// `outbox_entries` se remplit depuis le premier jour ; ce fichier est ce qui
/// la vide enfin. Trois regles le gouvernent.
///
/// **L'ordre est sacre.** Les entrees partent par identifiant croissant, une
/// par une, jamais en parallele. Une consommation ne peut pas remonter avant
/// l'arrivee qui a ouvert l'ardoise, ni une reservation avant le client
/// qu'elle designe. La file *est* l'ordre des evenements ; la respecter suffit
/// a ce que le serveur voie la meme histoire que la tablette.
///
/// **Un echec arrete tout.** Pas de « on saute celle-la et on continue » : si
/// l'entree 12 echoue, l'entree 13 parle probablement de la meme reservation
/// et echouerait aussi, ou pire, reussirait et laisserait le serveur dans un
/// etat que personne n'a jamais voulu. On s'arrete, on garde la file intacte,
/// on reessaiera.
///
/// **Le renvoi est sans danger.** C'est ce qu'Oriol a livre : les ecritures
/// acceptent l'identifiant de la tablette et repondent `200` sur un renvoi,
/// sans jamais `409`. Une reponse perdue dans le couloir n'est donc plus un
/// probleme -- on renvoie, et rien n'est compte deux fois.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../local/database.dart';
import '../local/enums.dart';
import 'api_client.dart';

/// Les tables que la file sait remonter.
///
/// La liste sert aussi de garde-fou : le nom de table vient de la base et
/// finit dans un `UPDATE`, donc il ne part que s'il est dans cet ensemble
/// ecrit a la main.
const _tablesConnues = {
  'guests',
  'reservations',
  'reservation_rooms',
  'folios',
  'folio_items',
  'payments',
};

/// Une requete prete a partir.
///
/// `chemin` s'ecrit **sans** `/api/v1` : le prefixe est deja dans le `baseUrl`
/// du client. L'ajouter ici donnait `/api/v1/api/v1/guests`, donc un 404 sur
/// la premiere entree, donc toute la file bloquee derriere elle.
class _Envoi {
  const _Envoi(this.chemin, this.corps);
  final String chemin;
  final Map<String, Object?> corps;
}

/// Pourquoi le moteur s'est arrete.
enum DrainStop {
  /// File vide : tout est remonte.
  termine,

  /// Serveur injoignable. Etat normal d'une tablette dans un couloir, pas une
  /// erreur a afficher en rouge.
  horsLigne,

  /// Session expiree ou refusee. Il faut se reconnecter.
  sessionInvalide,

  /// Le serveur a refuse une entree pour de bon. Celle-ci attend une decision
  /// humaine ; la file reste bloquee derriere elle, volontairement.
  bloque,
}

/// Ce qu'un passage de la file a donne.
class DrainReport {
  const DrainReport({
    required this.envoyees,
    required this.restantes,
    required this.arret,
    this.detail,
  });

  final int envoyees;
  final int restantes;
  final DrainStop arret;

  /// Le message du serveur, quand c'est lui qui a arrete le passage.
  final String? detail;

  bool get tout => arret == DrainStop.termine;

  /// Le serveur a-t-il repondu ? `null` quand on ne peut pas savoir.
  ///
  /// Une file vide ne fait partir aucune requete : le passage reussit sans
  /// rien apprendre de l'etat du reseau. Confondre ce cas avec « en ligne »
  /// ferait afficher un indicateur vert a une tablette debranchee, ce qui est
  /// pire que pas d'indicateur du tout.
  bool? get joignable {
    if (envoyees > 0) return true;
    switch (arret) {
      // Un refus vient du serveur : il a donc bien repondu.
      case DrainStop.bloque:
      case DrainStop.sessionInvalide:
        return true;
      case DrainStop.horsLigne:
        return false;
      case DrainStop.termine:
        return null;
    }
  }

  @override
  String toString() =>
      'DrainReport($envoyees envoyees, $restantes restantes, $arret'
      '${detail == null ? '' : ' : $detail'})';
}

/// Vide `outbox_entries` vers le serveur.
class OutboxSender {
  OutboxSender({required this.db, required this.api});

  final AtriumDatabase db;
  final ApiClient api;

  /// Remonte les ecritures en attente, dans l'ordre, jusqu'au premier echec.
  ///
  /// `max` borne un passage pour qu'une file longue -- une tablette restee
  /// hors ligne tout un week-end -- ne monopolise pas l'application. Le
  /// passage suivant reprendra ou celui-ci s'est arrete.
  Future<DrainReport> drain({int max = 200}) async {
    var envoyees = 0;

    while (envoyees < max) {
      final entree = await _prochaine();
      if (entree == null) {
        return DrainReport(
          envoyees: envoyees,
          restantes: 0,
          arret: DrainStop.termine,
        );
      }

      final _Envoi? envoi;
      try {
        envoi = await _envoiPour(entree);
      } catch (e) {
        await _marquerEchouee(entree, 'Entree illisible : $e');
        return DrainReport(
          envoyees: envoyees,
          restantes: await _restantes(),
          arret: DrainStop.bloque,
          detail: 'Entree illisible : $e',
        );
      }

      // Rien a envoyer pour cette entree : elle est notee et on passe. Le seul
      // cas aujourd'hui est l'attribution de chambre, que le contrat ne sait
      // pas encore recevoir -- voir `_envoiPour`.
      if (envoi == null) {
        await _marquerAcquittee(entree, toucherLaLigne: false);
        continue;
      }

      try {
        await api.post(envoi.chemin, body: envoi.corps);
      } on ApiException catch (e) {
        return _apresEchec(entree, e, envoyees);
      }

      await _marquerAcquittee(entree);
      envoyees++;
    }

    return DrainReport(
      envoyees: envoyees,
      restantes: await _restantes(),
      arret: DrainStop.termine,
    );
  }

  /// Traduit l'echec en decision : reessayer plus tard, ou bloquer.
  Future<DrainReport> _apresEchec(
    OutboxEntryRow entree,
    ApiException e,
    int envoyees,
  ) async {
    switch (e.failure) {
      // Pannes passageres : la file reste intacte et PENDING. On ne compte
      // meme pas ca comme une erreur de l'entree -- elle n'a rien fait de mal.
      case ApiFailure.offline:
      case ApiFailure.server:
        await _compterTentative(entree, e.message);
        return DrainReport(
          envoyees: envoyees,
          restantes: await _restantes(),
          arret: DrainStop.horsLigne,
          detail: e.message,
        );

      // Se reconnecter peut debloquer ; le client HTTP a deja tente de
      // rafraichir le jeton avant d'en arriver la.
      case ApiFailure.unauthorized:
      case ApiFailure.locked:
        await _compterTentative(entree, e.message);
        return DrainReport(
          envoyees: envoyees,
          restantes: await _restantes(),
          arret: DrainStop.sessionInvalide,
          detail: e.message,
        );

      // Refus de fond. Renvoyer ne changerait rien : l'entree est marquee et
      // la file s'arrete derriere elle. Un `conflict` est ici un vrai conflit
      // d'etat, puisque le contrat garantit qu'un renvoi ne recoit pas 409.
      case ApiFailure.forbidden:
      case ApiFailure.notFound:
      case ApiFailure.conflict:
      case ApiFailure.invalid:
        await _marquerEchouee(entree, e.message);
        return DrainReport(
          envoyees: envoyees,
          restantes: await _restantes(),
          arret: DrainStop.bloque,
          detail: e.message,
        );
    }
  }

  // --- La file ---------------------------------------------------------------

  Future<OutboxEntryRow?> _prochaine() {
    return (db.select(db.outboxEntries)
          ..where(
            (e) => e.status.isInValues([
              OutboxStatus.PENDING,
              OutboxStatus.FAILED,
            ]),
          )
          ..orderBy([(e) => OrderingTerm(expression: e.id)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<int> _restantes() async {
    final r = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM outbox_entries "
          "WHERE status IN ('PENDING','FAILED')",
          readsFrom: {db.outboxEntries},
        )
        .getSingle();
    return r.read<int>('n');
  }

  /// Acquitte l'entree, et passe la ligne metier en `synced`.
  ///
  /// Les deux dans la meme transaction : une entree acquittee dont la ligne
  /// serait restee `pending` ferait croire a un desaccord avec le serveur qui
  /// n'existe pas.
  Future<void> _marquerAcquittee(
    OutboxEntryRow entree, {
    bool toucherLaLigne = true,
  }) {
    return db.transaction(() async {
      await (db.update(
        db.outboxEntries,
      )..where((e) => e.id.equals(entree.id))).write(
        OutboxEntriesCompanion(
          status: const Value(OutboxStatus.ACKED),
          lastAttemptAt: Value(DateTime.now().toUtc()),
        ),
      );

      if (toucherLaLigne && _tablesConnues.contains(entree.entityTable)) {
        // `customStatement` attend des valeurs brutes, pas des `Variable`.
        // Le nom de table vient de `_tablesConnues`, jamais de l'entree seule.
        await db.customStatement(
          "UPDATE ${entree.entityTable} SET sync_state = 'synced' WHERE id = ?",
          [entree.entityId],
        );
      }
    });
  }

  Future<void> _marquerEchouee(OutboxEntryRow entree, String raison) {
    return (db.update(db.outboxEntries)..where((e) => e.id.equals(entree.id)))
        .write(
          OutboxEntriesCompanion(
            status: const Value(OutboxStatus.FAILED),
            attempts: Value(entree.attempts + 1),
            lastError: Value(raison),
            lastAttemptAt: Value(DateTime.now().toUtc()),
          ),
        );
  }

  /// Compte la tentative sans condamner l'entree : elle reste `PENDING`.
  Future<void> _compterTentative(OutboxEntryRow entree, String raison) {
    return (db.update(db.outboxEntries)..where((e) => e.id.equals(entree.id)))
        .write(
          OutboxEntriesCompanion(
            attempts: Value(entree.attempts + 1),
            lastError: Value(raison),
            lastAttemptAt: Value(DateTime.now().toUtc()),
          ),
        );
  }

  // --- De la file au contrat -------------------------------------------------

  /// Construit la requete correspondant a une entree.
  ///
  /// C'est une **traduction**, pas un reenvoi du message stocke. La file garde
  /// l'etat local complet d'une ligne ; le serveur, lui, attend la forme du
  /// contrat, qui n'est pas la meme : il deduit `hotel_id` du jeton, calcule
  /// le code client, range `folio_id` dans le chemin. Poster la file telle
  /// quelle enverrait des champs inconnus et en oublierait d'obligatoires.
  ///
  /// Renvoie `null` quand le contrat n'a pas d'endpoint pour l'entree.
  Future<_Envoi?> _envoiPour(OutboxEntryRow entree) async {
    final p = jsonDecode(entree.payload) as Map<String, dynamic>;

    switch (entree.entityTable) {
      case 'guests':
        return _Envoi('/guests', _sansNuls({
          'id': p['id'],
          'first_name': p['first_name'],
          'last_name': p['last_name'],
          'phone': p['phone'],
          'email': p['email'],
          'nationality': p['nationality'],
          'id_document_type': p['id_document_type'],
          'id_document_number': p['id_document_number'],
        }));

      case 'reservations':
        return _Envoi('/reservations', _sansNuls({
          'id': p['id'],
          'guest_id': p['guest_id'],
          'adults': p['adults'],
          'children': p['children'],
          'rooms': _lignes(p),
        }));

      case 'reservation_rooms':
        return _ligneDeSejour(p);

      case 'folio_items':
        final folioId = p['folio_id'];
        if (folioId == null) return null;
        return _Envoi('/folios/$folioId/items', _sansNuls({
          'id': p['id'],
          'category': p['category'],
          'label': p['label'],
          'quantity': p['quantity'],
          'unit_price': p['unit_price'],
        }));

      case 'payments':
        final folioId = p['folio_id'];
        if (folioId == null) return null;
        return _Envoi('/folios/$folioId/payments', _sansNuls({
          'id': p['id'],
          'method': p['method'],
          'amount': p['amount'],
          'reference': p['reference'],
        }));

      case 'folios':
        // Seule fermeture pour l'instant ; le folio nait au check-in.
        if (p['status'] != 'CLOSED') return null;
        return _Envoi('/folios/${p['id']}/close', const {});

      default:
        return null;
    }
  }

  /// Les lignes de chambre d'une reservation, mises a la forme du contrat.
  ///
  /// `arrival_date` et `departure_date` sont **obligatoires** sur chaque ligne
  /// cote serveur alors qu'elles vivent sur le dossier cote tablette : on les
  /// recopie ici. Sans ca, toute reservation partait en 422.
  List<Map<String, Object?>> _lignes(Map<String, dynamic> p) {
    final brutes = (p['rooms'] as List?) ?? const [];
    return [
      for (final l in brutes.cast<Map<String, dynamic>>())
        _sansNuls({
          'id': l['id'],
          'room_type_id': l['room_type_id'],
          'arrival_date': l['arrival_date'] ?? p['arrival_date'],
          'departure_date': l['departure_date'] ?? p['departure_date'],
          'adults': l['adults'] ?? p['adults'],
          'children': l['children'] ?? p['children'],
          'nightly_rate': l['nightly_rate'],
        }),
    ];
  }

  /// Arrivee, depart, ou attribution de chambre.
  ///
  /// Les deux premieres ont un endpoint, qui veut l'identifiant du dossier en
  /// plus de celui de la ligne -- la file ne garde que le second, on va
  /// chercher le premier dans la base.
  Future<_Envoi?> _ligneDeSejour(Map<String, dynamic> p) async {
    final lineId = p['id'] as String?;
    if (lineId == null) return null;

    final ligne = await db
        .customSelect(
          'SELECT reservation_id, room_id FROM reservation_rooms WHERE id = ?',
          variables: [Variable.withString(lineId)],
          readsFrom: {db.reservationRooms},
        )
        .getSingleOrNull();
    if (ligne == null) return null;

    final resId = ligne.read<String>('reservation_id');
    final chemin = '/reservations/$resId/rooms/$lineId';

    switch (p['status']) {
      case 'CHECKED_IN':
        return _Envoi('$chemin/check-in', _sansNuls({
          'folio_id': p['folio_id'],
          // L'attribution de chambre n'a pas d'endpoint a elle ; c'est ici
          // qu'elle remonte, ce qui suffit puisque le serveur n'a besoin de
          // connaitre la chambre qu'a l'arrivee.
          'room_id': p['room_id'] ?? ligne.read<String?>('room_id'),
        }));

      case 'CHECKED_OUT':
        return _Envoi('$chemin/check-out', const {});

      // Attribution seule : le contrat ne la recoit pas encore
      // (`ReservationRoomUpdate` n'a pas de `room_id`). Elle repartira avec le
      // check-in ci-dessus. Ticket ouvert cote backend.
      default:
        return null;
    }
  }

  /// Retire les cles nulles.
  ///
  /// Une cle absente laisse le serveur decider ; une cle a `null` lui demande
  /// d'effacer la valeur. Sur un renvoi, la nuance decide entre « ne touche a
  /// rien » et « vide ce champ ».
  Map<String, Object?> _sansNuls(Map<String, Object?> m) {
    return {
      for (final e in m.entries)
        if (e.value != null) e.key: e.value,
    };
  }
}
