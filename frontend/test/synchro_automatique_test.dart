/// La descente automatique ne relit que si le serveur signale un changement.
///
/// Retour du 23 octobre : « implementer la synchro automatique ». Relire les
/// vingt-neuf routes toutes les trente secondes aurait fait mouliner les
/// tablettes en continu ; `suivre` demande d'abord ce qui a change.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/remote/remote_providers.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/sync/sync_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

class _ApiMuette extends ApiClient {
  _ApiMuette() : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async => {};
}

/// Un serveur dont on regle la reponse a `/sync/changes`, curseur par
/// curseur, et qui note ce qu'on lui demande.
class _Serveur extends FakeCatalogApi {
  _Serveur();

  final demandes = <String>[];

  /// Le curseur que rend une relecture complete (`since` absent).
  String curseurNeuf = 'c1';
  final reponses = <String, RemoteChanges>{};
  bool horsLigne = false;

  @override
  Future<RemoteChanges?> fetchChanges(String? since) async {
    if (horsLigne) throw const ApiException(ApiFailure.offline, 'couloir');
    demandes.add('changes ${since ?? '-'}');
    if (since == null) {
      return RemoteChanges(cursor: curseurNeuf, fullResync: true);
    }
    return reponses[since] ?? RemoteChanges(cursor: since, fullResync: false);
  }

  @override
  Future<List<RemoteGuest>> fetchGuests() async {
    demandes.add('GET /guests');
    return const [];
  }
}

void main() {
  late AtriumDatabase db;
  late _Serveur serveur;
  late ProviderContainer container;

  setUp(() async {
    db = AtriumDatabase.memory();
    await seedDemoData(db);
    serveur = _Serveur();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(_ApiMuette()),
        catalogApiProvider.overrideWithValue(serveur),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    return db.close();
  });

  SyncNotifier sync() => container.read(syncProvider.notifier);

  test('rien de neuf : un aller-retour, aucune relecture', () async {
    await sync().refresh();
    serveur.demandes.clear();

    await sync().suivre();

    expect(serveur.demandes, ['changes c1']);
  });

  test('un changement fait relire, puis le curseur repart du neuf', () async {
    await sync().refresh();
    serveur.reponses['c1'] = const RemoteChanges(
      cursor: 'c2',
      fullResync: false,
      tables: {'guests'},
    );
    serveur.curseurNeuf = 'c3';
    serveur.demandes.clear();

    await sync().suivre();
    expect(serveur.demandes, containsAllInOrder(['changes c1', 'GET /guests']));

    // La relecture a pris son curseur avant de lire : c'est de lui que
    // repart le tour suivant.
    serveur.demandes.clear();
    await sync().suivre();
    expect(serveur.demandes, ['changes c3']);
  });

  test('sans curseur, le premier tour relit tout', () async {
    await sync().suivre();

    expect(serveur.demandes, containsAllInOrder(['changes -', 'GET /guests']));
  });

  test('une ligne retiree sur le serveur se retire ici', () async {
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    // Partie au serveur : plus rien ne la protege.
    await db.customStatement("UPDATE outbox_entries SET status = 'ACKED'");
    await db.customStatement("UPDATE guests SET sync_state = 'synced'");
    await sync().refresh();
    serveur.reponses['c1'] = RemoteChanges(
      cursor: 'c2',
      fullResync: false,
      tables: const {'guests'},
      removed: {
        'guests': [client.id],
      },
    );

    await sync().suivre();

    final ligne = await (db.select(
      db.guests,
    )..where((g) => g.id.equals(client.id))).getSingle();
    expect(ligne.deletedAt, isNotNull);
  });

  test('une ligne qui attend d etre envoyee n est pas retiree', () async {
    final client = await GuestRepository(
      db,
    ).create(firstName: 'Awa', lastName: 'Diallo');
    final descente = container.read(descenteProvider);

    await descente.appliquerRetraits({
      'guests': [client.id],
    });

    final ligne = await (db.select(
      db.guests,
    )..where((g) => g.id.equals(client.id))).getSingle();
    expect(ligne.deletedAt, isNull);
  });

  test('hors ligne, le tour passe sans bruit', () async {
    await sync().refresh();
    serveur.horsLigne = true;

    await sync().suivre();

    expect(container.read(syncProvider).running, isFalse);
  });
}
