/// Les reglages de l'hotel : la regle des arrhes, le depart, les alertes.
///
/// La regle vit dans `settings`, cle `reservation.deposit_rule`, au format
/// fixe cote serveur (`services/deposit.py`) :
///
///     {"mode": "FIXED", "amount": 20000}     somme fixe en FCFA
///     {"mode": "PERCENT", "rate_bp": 3000}   30 % du sejour, en points de base
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/ids.dart';
import '../../core/prolongation.dart';
import '../local/database.dart';
import '../local/enums.dart';
import '../local/queries/alert_queries.dart';
import 'outbox.dart';

const depositRuleKey = 'reservation.deposit_rule';

/// Le niveau de chaque evenement d'alerte, pour tout l'hotel : remonte au
/// serveur (`PUT /settings/notification-levels`) et redescend sur chaque
/// tablette.
const notificationLevelsKey = 'notifications.levels';

/// Les preferences d'alerte d'un agent (portee `USER`). Elles restent sur la
/// tablette : la file les acquitte sans les envoyer.
const agentNotificationsKey = 'notifications.agent';

/// Heure de depart de l'hotel (entier, 0 a 23) et prix de l'heure
/// supplementaire (FCFA entiers). Deux reglages a valeur simple : la valeur
/// JSON est le nombre lui-meme.
const stayCheckoutHourKey = 'stay.checkout_hour';
const stayExtraHourPriceKey = 'stay.extra_hour_price';

/// Les reglages du depart : jusqu'a quelle heure, et combien l'heure de plus.
///
/// Un prix a zero veut dire « la prolongation n'est pas facturee » : la
/// tablette ne la propose alors jamais, plutot que de poser une ligne a zero.
class StayRules {
  const StayRules({
    this.checkoutHour = heureDepartParDefaut,
    this.extraHourPrice = 0,
  });

  final int checkoutHour;
  final int extraHourPrice;

  bool get billsExtraHours => extraHourPrice > 0;

  @override
  bool operator ==(Object other) =>
      other is StayRules &&
      other.checkoutHour == checkoutHour &&
      other.extraHourPrice == extraHourPrice;

  @override
  int get hashCode => Object.hash(checkoutHour, extraHourPrice);
}

/// La regle des arrhes : une somme fixe, ou un pourcentage du sejour.
class DepositRule {
  const DepositRule.fixed(int this.amount) : mode = 'FIXED', rateBp = null;
  const DepositRule.percent(int this.rateBp) : mode = 'PERCENT', amount = null;

  final String mode;

  /// FCFA, en mode FIXED.
  final int? amount;

  /// Points de base, en mode PERCENT : 3000 = 30 %.
  final int? rateBp;

  bool get isFixed => mode == 'FIXED';

  /// Les arrhes dues pour un sejour de `stayTotal`.
  ///
  /// Recopie de `deposit_from_rule` cote serveur, a la lettre : jamais plus
  /// que le sejour, arrondi a l'entier inferieur, en entiers de bout en bout.
  int depositFor(int stayTotal) {
    final brut = isFixed ? amount! : stayTotal * rateBp! ~/ 10000;
    if (brut <= 0) return 0;
    return brut < stayTotal ? brut : stayTotal;
  }

  Map<String, Object> toJson() => isFixed
      ? {'mode': 'FIXED', 'amount': amount!}
      : {'mode': 'PERCENT', 'rate_bp': rateBp!};

  /// `null` pour une regle absente ou mal formee -- comme le serveur, qui la
  /// lit alors comme « pas d'arrhes ».
  static DepositRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final montant = raw['amount'];
    final taux = raw['rate_bp'];
    return switch (raw['mode']) {
      'FIXED' when montant is int && montant > 0 => DepositRule.fixed(montant),
      'PERCENT' when taux is int && taux > 0 && taux <= 10000 =>
        DepositRule.percent(taux),
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is DepositRule &&
      other.mode == mode &&
      other.amount == amount &&
      other.rateBp == rateBp;

  @override
  int get hashCode => Object.hash(mode, amount, rateBp);
}

/// Le niveau de chaque evenement : celui de l'administration, sinon le
/// defaut du catalogue.
class NiveauxAlertes {
  const NiveauxAlertes([this._choisis = const {}]);

  final Map<TypeEvenement, NiveauSignal> _choisis;

  NiveauSignal de(TypeEvenement type) => _choisis[type] ?? type.niveauParDefaut;

  NiveauxAlertes avec(TypeEvenement type, NiveauSignal niveau) =>
      NiveauxAlertes({..._choisis, type: niveau});

  /// Tous les evenements, explicitement : un defaut qui changerait dans une
  /// version future ne doit pas changer ce que l'administrateur a vu et
  /// valide.
  Map<String, String> toJson() => {
    for (final t in TypeEvenement.values) t.code: de(t).code,
  };

  /// Un code inconnu (une tablette plus recente) ou un niveau mal forme est
  /// ignore : l'evenement garde son defaut.
  static NiveauxAlertes fromJson(Object? raw) {
    if (raw is! Map) return const NiveauxAlertes();
    return NiveauxAlertes({
      for (final MapEntry(:key, :value) in raw.entries)
        ?TypeEvenement.depuisCode('$key'): ?NiveauSignal.depuisCode(value),
    });
  }

  @override
  bool operator ==(Object other) =>
      other is NiveauxAlertes &&
      TypeEvenement.values.every((t) => other.de(t) == de(t));

  @override
  int get hashCode => Object.hashAll(TypeEvenement.values.map(de));
}

/// Ce qu'un agent a choisi pour lui-meme.
class PreferencesAlertes {
  const PreferencesAlertes({this.sonCoupe = false});

  /// Plus aucune sonnerie pour cet agent ; le bandeau et la vibration
  /// restent, pour que l'alerte ne passe pas inapercue pour autant.
  final bool sonCoupe;

  static PreferencesAlertes fromJson(Object? raw) =>
      PreferencesAlertes(sonCoupe: raw is Map && raw['sound_muted'] == true);

  @override
  bool operator ==(Object other) =>
      other is PreferencesAlertes && other.sonCoupe == sonCoupe;

  @override
  int get hashCode => sonCoupe.hashCode;
}

class SettingsRepository with OutboxWriter {
  SettingsRepository(this.db, {this.hotelId = defaultHotelId});

  @override
  final AtriumDatabase db;
  final String hotelId;

  static const defaultHotelId = '01920000-0000-7000-8000-000000000001';

  Stream<DepositRule?> watchDepositRule() {
    return (db.select(db.settings)..where(_regle))
        .watchSingleOrNull()
        .map((r) => r?.value == null ? null : DepositRule.fromJson(jsonDecode(r!.value!)));
  }

  Future<DepositRule?> depositRule() async {
    final r = await (db.select(db.settings)..where(_regle)).getSingleOrNull();
    return r?.value == null ? null : DepositRule.fromJson(jsonDecode(r!.value!));
  }

  /// Fixe la regle, ou la retire avec `null`.
  Future<void> setDepositRule(DepositRule? rule) async {
    final existante = await (db.select(
      db.settings,
    )..where(_regle)).getSingleOrNull();
    final id = existante?.id ?? newId();
    final valeur = rule?.toJson();
    final now = DateTime.now().toUtc();

    await writeAndEnqueue(
      table: 'settings',
      id: id,
      operation: SyncOp.UPDATE,
      payload: {'id': id, 'key': depositRuleKey, 'value': valeur},
      action: () async {
        await db
            .into(db.settings)
            .insertOnConflictUpdate(
              SettingsCompanion.insert(
                id: id,
                createdAt: existante?.createdAt ?? now,
                updatedAt: now,
                hotelId: hotelId,
                key: depositRuleKey,
                value: Value(valeur == null ? null : jsonEncode(valeur)),
                label: const Value('Regle des arrhes'),
                syncState: const Value(SyncState.pending),
              ),
            );
      },
    );
  }

  // --- Depart et prolongation ------------------------------------------------

  Stream<StayRules> watchStayRules() {
    return (db.select(db.settings)..where(_reglesDeDepart)).watch().map(_regles);
  }

  Future<StayRules> stayRules() async {
    return _regles(await (db.select(db.settings)..where(_reglesDeDepart)).get());
  }

  /// Fixe l'heure de depart et le prix de l'heure supplementaire.
  ///
  /// Refuse ce qui n'a pas de sens plutot que de le ranger : une heure de
  /// depart a 25 h ou un prix negatif seraient lus tels quels a chaque depart.
  ///
  /// Les deux reglages restent sur la tablette : le serveur n'a pas encore de
  /// route pour eux, et la file les acquitte sans les envoyer (voir
  /// `OutboxSender._envoiPour`).
  Future<void> setStayRules(StayRules regles) async {
    if (regles.checkoutHour < 0 || regles.checkoutHour > 23) {
      throw StateError("L'heure de depart doit etre comprise entre 0 et 23.");
    }
    if (regles.extraHourPrice < 0) {
      throw StateError("Le prix de l'heure ne peut pas etre negatif.");
    }
    await _ecrire(
      stayCheckoutHourKey,
      regles.checkoutHour,
      'Heure de depart',
    );
    await _ecrire(
      stayExtraHourPriceKey,
      regles.extraHourPrice,
      "Prix de l'heure supplementaire",
    );
  }

  Future<void> _ecrire(String key, int valeur, String label) async {
    final existante =
        await (db.select(db.settings)..where(
              (s) =>
                  s.key.equals(key) &
                  s.scope.equalsValue(SettingScope.GLOBAL) &
                  s.scopeId.isNull() &
                  s.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    final id = existante?.id ?? newId();
    final now = DateTime.now().toUtc();

    await writeAndEnqueue(
      table: 'settings',
      id: id,
      operation: SyncOp.UPDATE,
      payload: {'id': id, 'key': key, 'value': valeur},
      action: () async {
        await db
            .into(db.settings)
            .insertOnConflictUpdate(
              SettingsCompanion.insert(
                id: id,
                createdAt: existante?.createdAt ?? now,
                updatedAt: now,
                hotelId: hotelId,
                key: key,
                value: Value(jsonEncode(valeur)),
                label: Value(label),
                syncState: const Value(SyncState.pending),
              ),
            );
      },
    );
  }

  // --- Les alertes -----------------------------------------------------------

  Stream<NiveauxAlertes> watchNiveauxAlertes() {
    return (db.select(db.settings)..where(_niveaux)).watchSingleOrNull().map(
      (r) => r?.value == null
          ? const NiveauxAlertes()
          : NiveauxAlertes.fromJson(jsonDecode(r!.value!)),
    );
  }

  /// Fixe le niveau de tous les evenements d'un coup : le serveur remplace
  /// le tout, et un renvoi du meme corps ne change rien.
  Future<void> setNiveauxAlertes(NiveauxAlertes niveaux) async {
    final existante = await (db.select(
      db.settings,
    )..where(_niveaux)).getSingleOrNull();
    final id = existante?.id ?? newId();
    final valeur = niveaux.toJson();
    final now = DateTime.now().toUtc();

    await writeAndEnqueue(
      table: 'settings',
      id: id,
      operation: SyncOp.UPDATE,
      payload: {'id': id, 'key': notificationLevelsKey, 'value': valeur},
      action: () async {
        await db
            .into(db.settings)
            .insertOnConflictUpdate(
              SettingsCompanion.insert(
                id: id,
                createdAt: existante?.createdAt ?? now,
                updatedAt: now,
                hotelId: hotelId,
                key: notificationLevelsKey,
                value: Value(jsonEncode(valeur)),
                label: const Value('Niveaux des alertes'),
                syncState: const Value(SyncState.pending),
              ),
            );
      },
    );
  }

  Stream<PreferencesAlertes> watchPreferencesAlertes(String agentId) {
    return (db.select(
      db.settings,
    )..where((s) => _preferences(s, agentId))).watchSingleOrNull().map(
      (r) => r?.value == null
          ? const PreferencesAlertes()
          : PreferencesAlertes.fromJson(jsonDecode(r!.value!)),
    );
  }

  /// Coupe ou retablit le son des alertes pour cet agent, sur cette
  /// tablette. Ecrit dans la file comme le reste, qui l'acquitte sans
  /// l'envoyer (voir `OutboxSender._envoiPour`).
  Future<void> setSonCoupe(String agentId, bool coupe) async {
    final existante = await (db.select(
      db.settings,
    )..where((s) => _preferences(s, agentId))).getSingleOrNull();
    final id = existante?.id ?? newId();
    final valeur = {'sound_muted': coupe};
    final now = DateTime.now().toUtc();

    await writeAndEnqueue(
      table: 'settings',
      id: id,
      operation: SyncOp.UPDATE,
      payload: {'id': id, 'key': agentNotificationsKey, 'value': valeur},
      action: () async {
        await db
            .into(db.settings)
            .insertOnConflictUpdate(
              SettingsCompanion.insert(
                id: id,
                createdAt: existante?.createdAt ?? now,
                updatedAt: now,
                hotelId: hotelId,
                key: agentNotificationsKey,
                value: Value(jsonEncode(valeur)),
                scope: const Value(SettingScope.USER),
                scopeId: Value(agentId),
                label: const Value("Alertes de l'agent"),
                syncState: const Value(SyncState.pending),
              ),
            );
      },
    );
  }

  /// Une valeur absente ou mal formee garde le defaut : midi, et pas de
  /// facturation.
  StayRules _regles(List<SettingRow> lignes) {
    int? lire(String key) {
      for (final l in lignes) {
        if (l.key != key || l.value == null) continue;
        final v = jsonDecode(l.value!);
        return v is int ? v : null;
      }
      return null;
    }

    final heure = lire(stayCheckoutHourKey);
    final prix = lire(stayExtraHourPriceKey);
    return StayRules(
      checkoutHour: heure != null && heure >= 0 && heure <= 23
          ? heure
          : heureDepartParDefaut,
      extraHourPrice: prix != null && prix > 0 ? prix : 0,
    );
  }

  Expression<bool> _reglesDeDepart($SettingsTable s) =>
      s.key.isIn([stayCheckoutHourKey, stayExtraHourPriceKey]) &
      s.scope.equalsValue(SettingScope.GLOBAL) &
      s.scopeId.isNull() &
      s.deletedAt.isNull();

  Expression<bool> _niveaux($SettingsTable s) =>
      s.key.equals(notificationLevelsKey) &
      s.scope.equalsValue(SettingScope.GLOBAL) &
      s.scopeId.isNull() &
      s.deletedAt.isNull();

  Expression<bool> _preferences($SettingsTable s, String agentId) =>
      s.key.equals(agentNotificationsKey) &
      s.scope.equalsValue(SettingScope.USER) &
      s.scopeId.equals(agentId) &
      s.deletedAt.isNull();

  Expression<bool> _regle($SettingsTable s) =>
      s.key.equals(depositRuleKey) &
      s.scope.equalsValue(SettingScope.GLOBAL) &
      s.scopeId.isNull() &
      s.deletedAt.isNull();
}
