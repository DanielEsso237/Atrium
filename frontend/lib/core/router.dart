/// Routes de l'application.
///
/// Les ecrans de l'application. La redirection vers la connexion est posee au
/// niveau du routeur et non dans chaque ecran : sur une tablette en mode
/// kiosque, un ecran accessible sans session serait une porte ouverte.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_screen.dart';
import '../features/auth/session.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/guests/guests_screen.dart';
import '../features/rooms/room_board_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // `refreshListenable` redemande la redirection a chaque changement de
  // session : la connexion et la deconnexion n'ont donc pas a naviguer
  // elles-memes, elles changent l'etat et le routeur suit.
  final session = ValueNotifier<bool>(false);
  ref.listen<SessionState>(
    sessionProvider,
    (_, suivant) => session.value = suivant.estConnecte,
    fireImmediately: true,
  );
  ref.onDispose(session.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: session,
    redirect: (context, etat) {
      final connecte = ref.read(sessionProvider).estConnecte;
      final surConnexion = etat.matchedLocation == '/connexion';

      if (!connecte) return surConnexion ? null : '/connexion';
      if (surConnexion) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/connexion',
        builder: (_, _) => const LoginScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (_, _) => const DashboardScreen(),
      ),
      GoRoute(
        path: '/chambres',
        builder: (_, _) => const RoomBoardScreen(),
      ),
      GoRoute(
        path: '/clients',
        builder: (_, _) => const GuestsScreen(),
      ),
    ],
  );
});
