/// La fenetre d'arrivee s'affiche quand le client a deja ses photos.
///
/// Vecu le 11 octobre : un client avec les photos de sa CNI, et la fenetre
/// d'arrivee restait blanche. L'apercu se mesurait avec un LayoutBuilder, que
/// la fenetre de dialogue ne sait pas mesurer (largeur intrinseque).
library;

import 'dart:typed_data';

import 'package:atrium/core/theme.dart';
import 'package:atrium/core/tokens.dart';
import 'package:atrium/data/local/database.dart';
import 'package:atrium/data/local/database_provider.dart';
import 'package:atrium/data/local/files/photo_files.dart';
import 'package:atrium/data/local/queries/access_queries.dart';
import 'package:atrium/data/local/seed.dart';
import 'package:atrium/data/local/seed_accounts.dart';
import 'package:atrium/data/repositories/guest_repository.dart';
import 'package:atrium/data/repositories/id_photo_repository.dart';
import 'package:atrium/data/repositories/repository_providers.dart';
import 'package:atrium/features/auth/session.dart';
import 'package:atrium/features/guests/id_photos.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Un disque en memoire.
class _Disque implements PhotoFiles {
  final _fichiers = <String, Uint8List>{};

  @override
  bool get available => true;

  @override
  Future<void> write(String relativePath, Uint8List bytes) async =>
      _fichiers[relativePath] = bytes;

  @override
  Future<Uint8List?> read(String relativePath) async => _fichiers[relativePath];

  @override
  Future<void> delete(String relativePath) async =>
      _fichiers.remove(relativePath);
}

class _Session extends SessionNotifier {
  _Session(this.session);
  final SessionState session;

  @override
  SessionState build() => session;
}

void main() {
  testWidgets('la paire de photos s affiche dans une fenetre de dialogue',
      (tester) async {
    final db = AtriumDatabase.memory();
    final disque = _Disque();
    final photos = IdPhotoRepository(db, disque);
    late String client;
    late SessionState session;
    await tester.runAsync(() async {
      await seedDemoData(db);
      await seedAccounts(db);
      client = (await GuestRepository(db).create(
        firstName: 'Awa',
        lastName: 'Diallo',
      )).id;
      final jpeg = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 320, height: 200)),
      );
      await photos.save(guestId: client, side: IdPhotoSide.front, jpeg: jpeg);
      final agent = await (db.select(
        db.users,
      )..where((u) => u.employeeCode.equals('ADMIN01'))).getSingle();
      session = SessionState(
        agent: agent,
        online: true,
        acces: await accessProfileFor(db, agent.id),
      );
    });
    AtriumPalette.current = AtriumPalette.light;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          idPhotoRepositoryProvider.overrideWithValue(photos),
          sessionProvider.overrideWith(() => _Session(session)),
        ],
        child: MaterialApp(
          theme: themeAtrium(),
          // Comme la fenetre d'arrivee : un AlertDialog, qui mesure son
          // contenu par sa largeur intrinseque.
          home: Scaffold(
            body: AlertDialog(
              title: const Text('Arrivée'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [IdPhotoPair(guestId: client)],
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }

    expect(tester.takeException(), isNull);
    expect(find.text('Recto'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    await tester.runAsync(db.close);
    await tester.pumpWidget(const SizedBox());
  });
}
