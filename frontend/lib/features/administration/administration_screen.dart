/// L'administration de l'hotel : points de vente, regle des arrhes, agents,
/// roles, plafonds des clients.
///
/// Reservee a l'administrateur (`users.write`, voir `router.dart`) : chaque
/// section ecrit des reglages que le serveur refuse a tout autre agent. Les
/// ouvrir a la reception, ce serait lui laisser produire des ecritures qui
/// bloqueraient sa file d'envoi.
///
/// Une section par sujet, dans des onglets : l'administrateur y vient pour
/// une chose precise, pas pour parcourir tout le parametrage.
library;

import 'package:flutter/material.dart';

import '../../core/ui/icons.dart';
import '../../core/widgets/module_scaffold.dart';
import 'agents_section.dart';
import 'credit_limits_section.dart';
import 'deposit_section.dart';
import 'outlets_section.dart';
import 'roles_section.dart';
import 'stay_rules_section.dart';

class AdministrationScreen extends StatelessWidget {
  const AdministrationScreen({super.key});

  static const _sections = <(String, IconData, Widget)>[
    ('Points de vente', PhosphorIconsLight.storefront, OutletsSection()),
    ('Arrhes', PhosphorIconsLight.coins, DepositSection()),
    ('Départ', PhosphorIconsLight.clock, StayRulesSection()),
    ('Agents', PhosphorIconsLight.usersThree, AgentsSection()),
    ('Rôles', PhosphorIconsLight.identificationCard, RolesSection()),
    ('Plafonds clients', PhosphorIconsLight.scales, CreditLimitsSection()),
  ];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _sections.length,
      child: ModuleScaffold(
        title: 'Administration',
        subtitle: 'Réglages de l’hôtel, réservés à l’administrateur',
        body: Column(
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final (libelle, icone, _) in _sections)
                  Tab(icon: Icon(icone, size: 20), text: libelle),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [for (final (_, _, contenu) in _sections) contenu],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
