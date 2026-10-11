/// La synchronisation ne reste jamais « en cours » pour toujours.
///
/// Vecu le 11 octobre : ngrok coupe, reconnexion hors ligne, ngrok relance.
/// La tablette repassait en ligne, mais le depart saisi ensuite restait dans
/// la file, et le bouton Synchroniser tournait sans fin.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/outbox_sender.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/sync/sync_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un envoi dont on choisit chaque issue, et qui compte ses passages.
class _Envoi extends OutboxSender {
  _Envoi(AtriumDatabase db, this.issue)
    : super(
        db: db,
        api: ApiClient(baseUrl: 'http://serveur.invalide', tokens: const TokenStore()),
      );

  DrainReport Function() issue;
  var passages = 0;

  @override
  Future<DrainReport> drain({int max = 200}) async {
    passages++;
    return issue();
  }
}

/// Une session qu'on fait passer en ligne a la main.
class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();

  void passerEnLigne() => state = const SessionState(online: true);
}

void main() {
  late AtriumDatabase db;

  setUp(() => db = AtriumDatabase.memory());
  tearDown(() => db.close());

  test('une erreur pendant la remontee rend la main', () async {
    final envoi = _Envoi(db, () => throw StateError('panne imprevue'));
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        outboxSenderProvider.overrideWithValue(envoi),
      ],
    );
    addTearDown(c.dispose);

    final rapport = await c.read(syncProvider.notifier).push();
    expect(rapport.arret, DrainStop.horsLigne);
    expect(c.read(syncProvider).running, isFalse);

    // La tentative suivante part vraiment, au lieu de voir un echange en
    // cours et d'abandonner.
    await c.read(syncProvider.notifier).push();
    expect(envoi.passages, 2);
  });

  test('le retour en ligne relance la remontee arretee', () async {
    final envoi = _Envoi(
      db,
      () => const DrainReport(
        envoyees: 0,
        restantes: 1,
        arret: DrainStop.sessionInvalide,
      ),
    );
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        outboxSenderProvider.overrideWithValue(envoi),
        pendingWritesProvider.overrideWith((ref) => Stream.value(1)),
        sessionProvider.overrideWith(_Session.new),
      ],
    );
    addTearDown(c.dispose);
    c.listen(syncSchedulerProvider, (_, _) {});
    c.listen(pendingWritesProvider, (_, _) {});

    // Hors ligne et sans jeton : le premier essai prend « session
    // invalide », et l'automatisme s'arrete.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(envoi.passages, 1);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(envoi.passages, 1, reason: 'arrete, il ne retente pas seul');

    // La session repasse en ligne : l'automatisme repart.
    envoi.issue = () => const DrainReport(
      envoyees: 1,
      restantes: 0,
      arret: DrainStop.termine,
    );
    (c.read(sessionProvider.notifier) as _Session).passerEnLigne();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(envoi.passages, 2);
  });
}
