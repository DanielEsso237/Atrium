/// Tableau de bord tactile (cahier des charges, paragraphe 5.1).
///
/// Six tuiles chiffrees, puis six gros boutons vers les modules. C'est le
/// premier ecran apres la connexion, et le seul que tout le monde voit quel
/// que soit son role.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formats.dart';
import '../../core/theme.dart';
import '../../core/widgets/module_scaffold.dart';
import '../../data/local/database_provider.dart';
import '../../data/local/queries/dashboard_queries.dart';
import '../auth/session.dart';
import '../sync/sync_status.dart';

final dashboardProvider = StreamProvider<DashboardSummary>(
  (ref) => ref.watch(databaseProvider).watchDashboard(),
);

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resume = ref.watch(dashboardProvider);
    final session = ref.watch(sessionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hotel Atrium'),
        actions: [
          const PendingWritesBadge(),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                formatLongDate(DateTime.now()),
                style: const TextStyle(fontSize: 17),
              ),
            ),
          ),
          if (session.estConnecte) ...[
            // Dire honnetement ou en est la tablette. L'etat vient du dernier
            // echange, pas de la connexion : sinon un agent doit se
            // deconnecter et se reconnecter pour que l'application remarque
            // que le serveur est revenu, ce que personne ne fera en service.
            // Tant qu'aucun echange n'a rien appris, on retombe sur ce que
            // disait l'authentification.
            Builder(
              builder: (context) {
                final enLigne = ref.watch(syncProvider).joignable ?? session.online;

                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: Tooltip(
                      message: enLigne
                          ? 'Dernier echange avec le serveur : reussi'
                          : 'Serveur injoignable — la tablette travaille seule '
                                'et garde ses ecritures',
                      child: Chip(
                        avatar: Icon(
                          enLigne ? Icons.cloud_done : Icons.cloud_off,
                          size: 20,
                        ),
                        label: Text(enLigne ? 'En ligne' : 'Hors ligne'),
                        backgroundColor: enLigne
                            ? null
                            : Theme.of(context).colorScheme.tertiaryContainer,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
          if (session.estConnecte)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Chip(
                  avatar: const Icon(Icons.person_outline, size: 20),
                  label: Text(session.nomAffiche),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Se deconnecter',
            iconSize: 28,
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(sessionProvider.notifier).deconnecter(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            resume.when(
              loading: () => const _TuilesSquelette(),
              error: (e, _) => _Erreur(message: '$e'),
              data: (r) => _Tuiles(resume: r),
            ),
            const SizedBox(height: 32),
            const _Modules(),
          ],
        ),
      ),
    );
  }
}

class _Tuiles extends StatelessWidget {
  const _Tuiles({required this.resume});

  final DashboardSummary resume;

  @override
  Widget build(BuildContext context) {
    final taux = resume.tauxOccupation;

    return _Grille(
      enfants: [
        _Tuile(
          icone: Icons.bed_outlined,
          titre: 'Chambres',
          valeur: '${resume.chambresOccupees} / ${resume.chambresTotal}',
          detail: taux == null ? null : '$taux % d\'occupation',
          couleur: CouleursEtat.occupee,
        ),
        _Tuile(
          icone: Icons.event_outlined,
          titre: 'Reservations',
          valeur: '${resume.reservationsActives}',
          detail: 'en cours',
          couleur: CouleursEtat.reservee,
          route: '/reservations',
        ),
        _Tuile(
          icone: Icons.login_outlined,
          titre: 'Arrivees',
          valeur: '${resume.arriveesDuJour}',
          detail: 'attendues aujourd\'hui',
          couleur: CouleursEtat.disponible,
        ),
        _Tuile(
          icone: Icons.logout_outlined,
          titre: 'Departs',
          valeur: '${resume.departsDuJour}',
          detail: 'prevus aujourd\'hui',
          couleur: CouleursEtat.maintenance,
        ),
        _Tuile(
          icone: Icons.payments_outlined,
          titre: 'CA du jour',
          valeur: formatAmountShort(resume.caDuJour),
          detail: 'journee hoteliere',
          couleur: const Color(0xFF00695C),
        ),
        _Tuile(
          icone: Icons.cleaning_services_outlined,
          titre: 'A nettoyer',
          valeur: '${resume.chambresANettoyer}',
          detail: 'chambres sales',
          couleur: CouleursEtat.nettoyage,
        ),
      ],
    );
  }
}

class _Grille extends StatelessWidget {
  const _Grille({required this.enfants});

  final List<Widget> enfants;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, contraintes) {
        // Trois colonnes sur une tablette tenue en paysage, deux en portrait
        // ou sur un ecran de 10 pouces. En dessous, une seule : mieux vaut
        // faire defiler que rendre les chiffres illisibles.
        final colonnes = contraintes.maxWidth >= 1000
            ? 3
            : contraintes.maxWidth >= 620
            ? 2
            : 1;

        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: colonnes,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: colonnes == 1 ? 3.4 : 2.1,
          children: enfants,
        );
      },
    );
  }
}

class _Tuile extends StatelessWidget {
  const _Tuile({
    required this.icone,
    required this.titre,
    required this.valeur,
    required this.couleur,
    this.detail,
    this.route,
  });

  final IconData icone;
  final String titre;
  final String valeur;
  final String? detail;
  final Color couleur;

  /// Une tuile qui mene quelque part devient cliquable. Les autres restent
  /// purement informatives — pas de faux bouton.
  final String? route;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;

    final contenu = Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: couleur.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icone, color: couleur, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  titre.toUpperCase(),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: schema.outline,
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    valeur,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: schema.outline),
                  ),
              ],
            ),
          ),
          if (route != null)
            Icon(Icons.chevron_right, color: schema.outline, size: 26),
        ],
      ),
    );

    if (route == null) return Card(child: contenu);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: () => context.go(route!), child: contenu),
    );
  }
}

class _Modules extends StatelessWidget {
  const _Modules();

  @override
  Widget build(BuildContext context) {
    const modules = [
      (Icons.room_service_outlined, 'Reception', '/chambres'),
      (Icons.restaurant_outlined, 'Restaurant', null),
      (Icons.build_outlined, 'Maintenance', null),
      (Icons.cleaning_services_outlined, 'Housekeeping', null),
      (Icons.people_outline, 'Clients', '/clients'),
      (Icons.receipt_long_outlined, 'Factures', '/factures'),
    ];

    return _Grille(
      enfants: [
        for (final (icone, label, route) in modules)
          _BoutonModule(icone: icone, label: label, route: route),
      ],
    );
  }
}

class _BoutonModule extends StatelessWidget {
  const _BoutonModule({
    required this.icone,
    required this.label,
    required this.route,
  });

  final IconData icone;
  final String label;
  final String? route;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final actif = route != null;

    return Material(
      color: actif ? schema.primary : schema.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(rayonCarte),
      child: InkWell(
        borderRadius: BorderRadius.circular(rayonCarte),
        // TODO(api) : les cinq autres modules arrivent avec leurs ecrans.
        onTap: actif ? () => context.go(route!) : null,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(
                icone,
                size: 34,
                color: actif ? schema.onPrimary : schema.outline,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: actif ? schema.onPrimary : schema.outline,
                  ),
                ),
              ),
              if (!actif)
                Text(
                  'a venir',
                  style: TextStyle(fontSize: 14, color: schema.outline),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TuilesSquelette extends StatelessWidget {
  const _TuilesSquelette();

  @override
  Widget build(BuildContext context) => _Grille(
    enfants: List.generate(
      6,
      (_) => Card(
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ),
      ),
    ),
  );
}

class _Erreur extends StatelessWidget {
  const _Erreur({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: schema.error, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                'Lecture de la base impossible.\n$message',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
