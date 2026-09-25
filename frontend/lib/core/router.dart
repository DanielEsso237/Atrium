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
import '../features/billing/folios_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/guests/guests_screen.dart';
import '../features/housekeeping/housekeeping_screen.dart';
import '../features/reservations/new_reservation_screen.dart';
import '../features/reservations/reservations_screen.dart';
import '../features/rooms/room_board_screen.dart';

/// La permission qu'exige chaque zone de l'application (3.4).
///
/// Poser la regle ici plutot que dans chaque ecran : un ecran ajoute plus tard
/// sans sa verification serait une porte ouverte, et personne ne s'en
/// apercevrait avant la mise en service.
///
/// Les reservations relevent de `rooms.read` faute de permission dediee cote
/// serveur : elles sont le travail de la reception, qui voit deja le plan. A
/// revoir le jour ou `reservations.read` existera.
const _permissionParZone = <String, String>{
  '/chambres': 'rooms.read',
  '/reservations': 'rooms.read',
  '/clients': 'guests.read',
  '/factures': 'folio.read',
  '/menage': 'housekeeping.read',
};

/// La permission exigee par un chemin, sous-routes comprises.
///
/// Publique pour etre testable : c'est la barriere reelle de l'application,
/// celle qui tient meme si un ecran oublie de se cacher.
String? permissionPour(String chemin) {
  for (final entree in _permissionParZone.entries) {
    if (chemin == entree.key || chemin.startsWith('${entree.key}/')) {
      return entree.value;
    }
  }
  return null;
}

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
      final session = ref.read(sessionProvider);
      final surConnexion = etat.matchedLocation == '/connexion';

      if (!session.estConnecte) return surConnexion ? null : '/connexion';

      // Chacun ouvre sur son outil de travail : le receptionniste sur le plan
      // des chambres, l'administrateur sur le tableau de bord. On verifie
      // quand meme le droit, sinon un accueil mal parametre enverrait l'agent
      // sur un ecran qui le renvoie aussitot -- une boucle infinie.
      if (surConnexion) {
        final accueil = session.acces.homeRoute;
        final requise = accueil == null ? null : permissionPour(accueil);
        final autorise = requise == null || session.acces.peut(requise);
        return autorise ? (accueil ?? '/') : '/';
      }

      // Un metier qui a son propre ecran d'accueil n'a rien a faire sur le
      // tableau de bord : il n'y verrait qu'un seul bouton, celui d'ou il
      // vient. La femme de chambre y arrivait par la fleche retour, ce qui
      // lui donnait un detour vers un carrefour a une seule sortie.
      final accueil = session.acces.homeRoute;
      if (accueil != null && accueil != '/' && etat.matchedLocation == '/') {
        return accueil;
      }

      // Le tableau de bord reste ouvert aux autres : c'est le point de repli
      // de cette regle, il ne peut pas etre lui-meme refuse.
      final requise = permissionPour(etat.matchedLocation);
      if (requise != null && !session.acces.peut(requise)) return '/';

      return null;
    },
    routes: [
      GoRoute(path: '/connexion', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/', builder: (_, _) => const DashboardScreen()),
      GoRoute(path: '/chambres', builder: (_, _) => const RoomBoardScreen()),
      GoRoute(path: '/clients', builder: (_, _) => const GuestsScreen()),
      GoRoute(path: '/factures', builder: (_, _) => const FoliosScreen()),
      GoRoute(path: '/menage', builder: (_, _) => const HousekeepingScreen()),
      GoRoute(
        path: '/reservations',
        builder: (_, _) => const ReservationsScreen(),
        routes: [
          GoRoute(
            path: 'nouvelle',
            // `?client=` pre-selectionne le client quand on arrive depuis sa
            // fiche, et reste facultatif quand on part d'une page blanche.
            builder: (_, state) => NewReservationScreen(
              guestId: state.uri.queryParameters['client'],
            ),
          ),
        ],
      ),
    ],
  );
});
