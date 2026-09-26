/// L'ordre pousser-puis-tirer, verifie de bout en bout.
///
/// C'est l'invariant qui tient tout le mode hors connexion. La descente
/// **ecrase** ; la montee non. Tirer avant de pousser ferait remplacer par la
/// version du serveur une modification que la tablette n'a pas encore
/// envoyee — et le serveur, par construction, est en retard sur elle.
///
/// Ce test ne regarde pas l'ordre des appels mais leur **effet** : une
/// ecriture locale en attente doit etre partie *avant* que la descente ne
/// touche sa ligne. C'est la propriete qui compte ; l'ordre des appels n'en
/// est que le moyen.
library;

import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/enums.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/remote/api_client.dart';
import 'package:atrium/data/remote/catalog_api.dart';
import 'package:atrium/data/remote/remote_providers.dart';
import 'package:atrium/data/remote/token_store.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/features/sync/sync_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_catalog_api.dart';

/// Note l'ordre des evenements : ce qui est envoye, ce qui est lu.
class _Journal {
  final evenements = <String>[];
}

class _ApiQuiNote extends ApiClient {
  _ApiQuiNote(this.journal)
    : super(baseUrl: 'http://localhost', tokens: const TokenStore());

  final _Journal journal;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    journal.evenements.add('POST $path');
    return {};
  }
}

class _CatalogueQuiNote extends FakeCatalogApi {
  const _CatalogueQuiNote(this.journal, {super.guests});

  final _Journal journal;

  @override
  Future<List<RemoteRoom>> fetchRooms() async {
    journal.evenements.add('GET /rooms');
    return const [];
  }

  @override
  Future<List<RemoteGuest>> fetchGuests() async {
    journal.evenements.add('GET /guests');
    return guests;
  }
}

void main() {
  late AtriumDatabase db;
  late _Journal journal;
  late ProviderContainer container;

  setUp(() async {
    db = AtriumDatabase.memory();
    await db.customStatement('PRAGMA foreign_keys = ON');
    await seedDemoData(db);
    journal = _Journal();
  });

  tearDown(() {
    container.dispose();
    return db.close();
  });

  void monter({List<RemoteGuest> auServeur = const []}) {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(_ApiQuiNote(journal)),
        catalogApiProvider.overrideWithValue(
          _CatalogueQuiNote(journal, guests: auServeur),
        ),
      ],
    );
  }

  test('la montee precede la descente', () async {
    // Un client cree localement, donc une entree dans la file.
    final client = await GuestRepository(db).create(
      firstName: 'Awa',
      lastName: 'Diallo',
    );
    monter();

    await container.read(syncProvider.notifier).refresh();

    final envoi = journal.evenements.indexOf('POST /guests');
    final lecture = journal.evenements.indexOf('GET /guests');

    expect(envoi, isNonNegative, reason: 'la file doit avoir ete videe');
    expect(lecture, isNonNegative, reason: 'la descente doit avoir eu lieu');
    expect(
      envoi,
      lessThan(lecture),
      reason: 'tirer avant de pousser ecraserait ce qui n\'est pas parti',
    );
    expect(client.id, isNotEmpty);
  });

  test('le referentiel descend avant les donnees metier', () async {
    // Une reservation s'accroche a une categorie de chambre : lire les
    // categories apres ferait ecarter la ligne.
    monter();

    await container.read(syncProvider.notifier).refresh();

    expect(
      journal.evenements.indexOf('GET /rooms'),
      lessThan(journal.evenements.indexOf('GET /guests')),
    );
  });

  test('une ecriture partie cesse d etre protegee, et la descente la met a jour',
      () async {
    // Les deux moitiees de la regle, dans un seul parcours : le client part,
    // sa ligne n'est plus en attente, donc la version du serveur s'applique.
    final client = await GuestRepository(db).create(
      firstName: 'Awa',
      lastName: 'SAISIE LOCALE',
    );

    monter(
      auServeur: [
        RemoteGuest(
          id: client.id,
          code: client.code,
          firstName: 'Awa',
          lastName: 'VERSION SERVEUR',
        ),
      ],
    );

    await container.read(syncProvider.notifier).refresh();

    final apres = await (db.select(
      db.guests,
    )..where((g) => g.id.equals(client.id))).getSingle();

    expect(apres.lastName, 'VERSION SERVEUR');
    expect(apres.syncState, SyncState.synced);
  });
}
