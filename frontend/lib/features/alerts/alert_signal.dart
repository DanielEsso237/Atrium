/// Le signal physique d'une alerte : sonnerie et vibration.
///
/// Tout est rattrape : une tablette sans vibreur, un navigateur qui bloque
/// le son, une plateforme sans greffon -- l'alerte reste a l'ecran, seul le
/// signal manque. Un signal qui ferait tomber l'ecran serait pire que pas de
/// signal du tout.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vibration/vibration.dart';

import '../../data/local/queries/alert_queries.dart';

abstract class SignalAlerte {
  Future<void> emettre(NiveauAlerte niveau);

  /// Coupe une sonnerie en cours.
  Future<void> arreter();
}

class SignalAppareil implements SignalAlerte {
  AudioPlayer? _lecteur;
  bool? _vibreur;
  bool _amplitude = false;

  @override
  Future<void> emettre(NiveauAlerte niveau) async {
    await Future.wait([_vibrer(niveau), _sonner(niveau)]);
  }

  Future<void> _vibrer(NiveauAlerte niveau) async {
    try {
      if (_vibreur == null) {
        _vibreur = await Vibration.hasVibrator();
        _amplitude = await Vibration.hasAmplitudeControl();
      }
      if (_vibreur != true) {
        // Le retour haptique du systeme, faute de mieux.
        await HapticFeedback.heavyImpact();
        return;
      }
      switch (niveau) {
        case NiveauAlerte.info:
          await Vibration.vibrate(duration: 180);
        case NiveauAlerte.urgente:
          await Vibration.vibrate(
            pattern: const [0, 450, 180, 450],
            intensities: _amplitude ? const [0, 255, 0, 255] : const [],
          );
        case NiveauAlerte.critique:
          await Vibration.vibrate(
            pattern: const [0, 900, 250, 900, 250, 900],
            intensities: _amplitude
                ? const [0, 255, 0, 255, 0, 255]
                : const [],
          );
      }
    } catch (e) {
      debugPrint('[Alertes] vibration indisponible : $e');
    }
  }

  Future<void> _sonner(NiveauAlerte niveau) async {
    if (niveau == NiveauAlerte.info) return;
    final critique = niveau == NiveauAlerte.critique;
    try {
      final lecteur = _lecteur ??= AudioPlayer(playerId: 'atrium-alertes');
      await lecteur.stop();
      await lecteur.play(
        AssetSource(
          critique ? 'sounds/alerte_critique.wav' : 'sounds/alerte_urgente.wav',
        ),
        volume: 1,
        // Le flux d'alarme pour le critique : il sonne fort meme quand le
        // volume des medias est baisse. Le flux des notifications pour le
        // reste, comme un message.
        ctx: AudioContext(
          android: AudioContextAndroid(
            contentType: AndroidContentType.sonification,
            usageType: critique
                ? AndroidUsageType.alarm
                : AndroidUsageType.notificationEvent,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Alertes] son indisponible : $e');
    }
  }

  @override
  Future<void> arreter() async {
    try {
      await _lecteur?.stop();
      if (_vibreur == true) await Vibration.cancel();
    } catch (_) {
      // Rien a couper.
    }
  }
}

/// Remplacable dans les tests, ou il n'y a ni haut-parleur ni vibreur.
final signalAlerteProvider = Provider<SignalAlerte>((ref) => SignalAppareil());
