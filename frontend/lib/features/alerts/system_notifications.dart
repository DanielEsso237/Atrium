/// Les notifications du systeme : ce qui previent l'agent quand l'application
/// n'est pas devant lui -- tablette en veille, autre application ouverte.
///
/// Il n'y a pas de serveur de notifications : la tablette travaille hors
/// ligne, et c'est elle qui calcule ses alertes depuis sa base. Pour qu'elle
/// continue de les calculer une fois en arriere-plan, un service au premier
/// plan (« Atrium veille ») garde l'application en vie tant qu'un agent est
/// connecte ; Android tuerait sinon le processus au bout de quelques minutes,
/// et avec lui toute alerte a venir.
///
/// Android seulement : c'est la tablette de l'hotel. Ailleurs (navigateur,
/// poste de developpement), tout est sans effet et le bandeau suffit.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/queries/alert_queries.dart';

/// Comment une alerte doit se signaler, une fois le niveau de l'evenement
/// et le choix de l'agent appliques.
class SignalVoulu {
  const SignalVoulu({
    required this.gravite,
    required this.son,
    required this.vibration,
    this.discret = false,
  });

  final NiveauAlerte gravite;
  final bool son;
  final bool vibration;

  /// Ni bandeau ni bruit : une ligne dans le volet, sans plus.
  final bool discret;
}

abstract class NotificationsSysteme {
  /// Prepare les canaux ; `surTouche` recoit la cle et l'ecran de l'alerte
  /// touchee dans le volet.
  Future<void> preparer(void Function(String cle, String? route) surTouche);

  /// Demarre ou arrete la veille en arriere-plan.
  Future<void> veiller(bool actif);

  Future<void> montrer(Alerte alerte, SignalVoulu signal);

  /// Retire l'alerte de cette cle : la situation est reglee.
  Future<void> retirer(String cle);

  /// Retire les alertes du volet : l'agent est revenu devant l'ecran, le
  /// bandeau prend le relais.
  Future<void> effacer();
}

/// Les canaux d'Android : le son et la vibration d'un canal sont figes a sa
/// creation, d'ou un canal par combinaison.
enum _Canal {
  discret('atrium_discret', 'Alertes discrètes', 'Sans bruit ni bandeau.'),
  muet('atrium_muet', 'Alertes sans son', 'Le son est coupé pour l’agent.'),
  vibration(
    'atrium_vibration',
    'Alertes en vibration',
    'Le son est coupé, la vibration reste.',
  ),
  sonore('atrium_sonore', 'Alertes sonores', 'Carillon, sans vibration.'),
  sonoreVibration(
    'atrium_sonore_vibration',
    'Alertes sonores et vibrantes',
    'Carillon et vibration.',
  ),
  critique(
    'atrium_critique',
    'Alertes critiques',
    'Alarme répétée jusqu’à ce qu’on ouvre l’alerte.',
  ),
  critiqueVibration(
    'atrium_alarmevibration',
    'Alertes critiques vibrantes',
    'Alarme répétée et vibration.',
  );

  const _Canal(this.id, this.nom, this.description);

  final String id;
  final String nom;
  final String description;

  bool get son => this == sonore || this == sonoreVibration || alarme;
  bool get vibre =>
      this == vibration || this == sonoreVibration || this == critiqueVibration;

  /// L'alarme des alertes critiques, sur le flux du reveil.
  bool get alarme => this == critique || this == critiqueVibration;

  static _Canal pour(SignalVoulu s) {
    if (s.discret) return discret;
    if (!s.son) return s.vibration ? vibration : muet;
    if (s.gravite == NiveauAlerte.critique) {
      return s.vibration ? critiqueVibration : critique;
    }
    return s.vibration ? sonoreVibration : sonore;
  }
}

class NotificationsAndroid implements NotificationsSysteme {
  final _greffon = FlutterLocalNotificationsPlugin();
  bool _pret = false;

  /// Le dernier recu : le centre d'alertes se reconstruit a chaque
  /// connexion, et l'ancien ne doit plus repondre.
  void Function(String cle, String? route)? _surTouche;
  bool _permissionDemandee = false;

  static const _icone = 'ic_notification';
  static const _idVeille = 7700;
  static const _bleu = Color(0xFF143894);
  static final _motif = Int64List.fromList(const [0, 700, 250, 700, 250, 700]);

  /// Le drapeau `FLAG_INSISTENT` d'Android : le son boucle jusqu'a ce que
  /// l'agent ouvre ou balaie la notification.
  static final _insistant = Int32List.fromList(const [4]);

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  AndroidFlutterLocalNotificationsPlugin? get _plateforme => _greffon
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<void> preparer(
    void Function(String cle, String? route) surTouche,
  ) async {
    _surTouche = surTouche;
    if (!_android || _pret) return;
    try {
      await _greffon.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(_icone),
        ),
        onDidReceiveNotificationResponse: (reponse) {
          final brut = reponse.payload;
          if (brut == null) return;
          final contenu = jsonDecode(brut);
          if (contenu is! Map) return;
          _surTouche?.call('${contenu['cle']}', contenu['route'] as String?);
        },
      );
      final plateforme = _plateforme;
      for (final c in _Canal.values) {
        await plateforme?.createNotificationChannel(
          AndroidNotificationChannel(
            c.id,
            c.nom,
            description: c.description,
            importance: c == _Canal.discret
                ? Importance.low
                : c.alarme
                ? Importance.max
                : Importance.high,
            playSound: c.son,
            sound: c.son ? _sonnerie(c) : null,
            enableVibration: c.vibre,
            vibrationPattern: c.vibre ? _motif : null,
            audioAttributesUsage: c.alarme
                ? AudioAttributesUsage.alarm
                : AudioAttributesUsage.notificationEvent,
          ),
        );
      }
      await plateforme?.createNotificationChannel(
        const AndroidNotificationChannel(
          'atrium_veille',
          'Veille des alertes',
          description: 'Garde les alertes actives en arrière-plan.',
          importance: Importance.min,
          playSound: false,
          enableVibration: false,
          showBadge: false,
        ),
      );
      _pret = true;
    } catch (e) {
      debugPrint('[Alertes] notifications indisponibles : $e');
    }
  }

  static RawResourceAndroidNotificationSound _sonnerie(_Canal c) =>
      RawResourceAndroidNotificationSound(
        c.alarme ? 'alerte_critique' : 'alerte_urgente',
      );

  @override
  Future<void> veiller(bool actif) async {
    if (!_android || !_pret) return;
    try {
      final plateforme = _plateforme;
      if (!actif) {
        await plateforme?.stopForegroundService();
        return;
      }
      // Android 13 et plus : sans cette permission, ni la veille ni aucune
      // alerte n'apparait. Demandee une fois, a la premiere connexion.
      if (!_permissionDemandee) {
        _permissionDemandee = true;
        await plateforme?.requestNotificationsPermission();
      }
      await plateforme?.startForegroundService(
        id: _idVeille,
        title: 'Alertes actives',
        body: 'Atrium vous prévient même quand l’application est fermée.',
        notificationDetails: const AndroidNotificationDetails(
          'atrium_veille',
          'Veille des alertes',
          icon: _icone,
          color: _bleu,
          importance: Importance.min,
          priority: Priority.min,
          ongoing: true,
          playSound: false,
          enableVibration: false,
          showWhen: false,
        ),
        // Pas de redemarrage par Android : un service relance sans
        // l'application ne surveillerait rien, et pretendrait le contraire.
        startType: AndroidServiceStartType.startNotSticky,
        foregroundServiceTypes: {
          AndroidServiceForegroundType.foregroundServiceTypeSpecialUse,
        },
      );
    } catch (e) {
      debugPrint('[Alertes] veille indisponible : $e');
    }
  }

  @override
  Future<void> montrer(Alerte alerte, SignalVoulu signal) async {
    if (!_android || !_pret) return;
    final canal = _Canal.pour(signal);
    try {
      await _greffon.show(
        id: _idPour(alerte.cle),
        title: alerte.titre,
        body: alerte.corps,
        payload: jsonEncode({'cle': alerte.cle, 'route': alerte.route}),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            canal.id,
            canal.nom,
            channelDescription: canal.description,
            icon: _icone,
            color: _bleu,
            importance: canal == _Canal.discret
                ? Importance.low
                : canal.alarme
                ? Importance.max
                : Importance.high,
            priority: canal == _Canal.discret ? Priority.low : Priority.max,
            playSound: canal.son,
            sound: canal.son ? _sonnerie(canal) : null,
            enableVibration: canal.vibre,
            vibrationPattern: canal.vibre ? _motif : null,
            audioAttributesUsage: canal.alarme
                ? AudioAttributesUsage.alarm
                : AudioAttributesUsage.notificationEvent,
            category: canal.alarme ? AndroidNotificationCategory.alarm : null,
            additionalFlags: canal.alarme ? _insistant : null,
            styleInformation: BigTextStyleInformation(alerte.corps),
            ticker: alerte.titre,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Alertes] notification impossible : $e');
    }
  }

  @override
  Future<void> retirer(String cle) async {
    if (!_android || !_pret) return;
    try {
      await _greffon.cancel(id: _idPour(cle));
    } catch (e) {
      debugPrint('[Alertes] retrait impossible : $e');
    }
  }

  @override
  Future<void> effacer() async {
    if (!_android || !_pret) return;
    try {
      // Pas `cancelAll` : il retirerait aussi la notification de la veille,
      // et Android arreterait de proteger le processus.
      final actives = await _plateforme?.getActiveNotifications() ?? const [];
      for (final n in actives) {
        if (n.id == null || n.id == _idVeille) continue;
        await _greffon.cancel(id: n.id!);
      }
    } catch (e) {
      debugPrint('[Alertes] effacement impossible : $e');
    }
  }

  /// Un identifiant stable pour une cle : une alerte rappelee remplace sa
  /// notification au lieu d'en empiler une seconde.
  static int _idPour(String cle) {
    var h = 0x811c9dc5;
    for (final u in utf8.encode(cle)) {
      h = ((h ^ u) * 0x01000193) & 0x7fffffff;
    }
    return h == _idVeille || h == 0 ? h + 1 : h;
  }
}

/// Remplacable dans les tests, ou il n'y a pas de volet de notifications.
final notificationsSystemeProvider = Provider<NotificationsSysteme>(
  (ref) => NotificationsAndroid(),
);
