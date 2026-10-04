/// Le choix clair / sombre de l'agent.
///
/// Par defaut l'appareil decide (clair le jour, sombre le soir). Un bouton
/// permet d'imposer l'un ou l'autre : une reception en plein soleil veut le
/// clair a 20 h, un veilleur de nuit le sombre a 6 h. Le choix est garde sur
/// la tablette, dans le magasin deja utilise pour la session.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _cle = 'atrium.theme';

class ThemeModeNotifier extends Notifier<ThemeMode> {
  final _magasin = const FlutterSecureStorage();

  @override
  ThemeMode build() {
    _relire();
    return ThemeMode.system;
  }

  Future<void> _relire() async {
    try {
      final v = await _magasin.read(key: _cle);
      final mode = ThemeMode.values.where((m) => m.name == v).firstOrNull;
      if (mode != null) state = mode;
    } catch (_) {
      // Un magasin illisible ne doit pas empecher l'application de s'ouvrir :
      // on reste sur le choix de l'appareil.
    }
  }

  Future<void> choisir(ThemeMode mode) async {
    state = mode;
    try {
      await _magasin.write(key: _cle, value: mode.name);
    } catch (_) {}
  }

  /// Passe au mode oppose de ce qui est affiche.
  void basculer(Brightness affiche) =>
      choisir(affiche == Brightness.dark ? ThemeMode.light : ThemeMode.dark);
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
