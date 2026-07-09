import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/sync/onedrive_sync_engine.dart';

import '../support/roundtrip_harness.dart';

/// The end-to-end guard the isolated import tests were missing: seed realistic
/// data, run the REAL export, then the REAL import, and prove the data
/// survives, merges, and — critically — does NOT duplicate on repeated pulls.
///
/// Every DB-backed module + every prefs-backed module goes through the wire.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Drift complains when several in-memory DBs live at once (device A + B).
  // Harmless in tests.
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // Everything except the two auto-required modules (leaderboard, tombstones),
  // which importFromFiles/exportToFiles fold in themselves.
  const modules = {
    'journal',
    'layers',
    'fog_tiles',
    'song_favorites',
    'track_points',
    'chat_messages',
    'planner_history',
    'settings',
    'imghost_uploads',
    'geocode_cache',
    'learned_regions',
  };

  group('full-dataset export → import round-trip（真实往返·全模块）', () {
    late AppDb dbA;
    late BackupService svcA;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dbA = AppDb.forTesting(NativeDatabase.memory());
      svcA = BackupService(dbA);
      await seedRealisticData(dbA);
    });

    tearDown(() async => dbA.close());

    test('a fresh device restores every module byte-for-byte', () async {
      final snapA = await snapshotDb(dbA);
      // Sanity: the seed produced what we think it did.
      for (final e in expectedSeedCounts.entries) {
        expect(snapA.counts[e.key], e.value, reason: 'seed ${e.key}');
      }

      // Upload = capture the file map. It embeds the prefs modules too, so it
      // is a complete point-in-time snapshot independent of the live prefs.
      final files = await svcA.exportToFiles(modules);

      // Fresh device B: brand-new DB, empty prefs.
      SharedPreferences.setMockInitialValues({});
      final dbB = AppDb.forTesting(NativeDatabase.memory());
      final svcB = BackupService(dbB);
      addTearDown(() async => dbB.close());

      final summary =
          await svcB.importFromFiles(files, modules: modules);
      expect(summary.errors, isEmpty, reason: 'no module may error: ${summary.errors}');

      final snapB = await snapshotDb(dbB);
      expect(snapB.counts, snapA.counts, reason: 'row counts must match');
      expect(snapB.uuids, snapA.uuids, reason: 'identities must match');

      // Content spot-checks across modules.
      final journals = await dbB.select(dbB.journalEntries).get();
      expect(journals.map((j) => j.title).toSet(), {'成都', '重庆', '上班路上'});
      final layers = await dbB.allLayers();
      expect(layers.map((l) => l.name).toSet(),
          {'默认图层', '徒步路线', '通勤'});

      // Journal → layer remap survived (j-2 lives on 徒步路线, not id 2 blindly).
      final hike = layers.firstWhere((l) => l.uuid == 'layer-hike');
      expect(journals.firstWhere((j) => j.uuid == 'j-2').layerId, hike.id);

      // Prefs-backed modules restored.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPlannerKey), isNotNull);
      expect(jsonDecode(prefs.getString(kImgHostKey)!),
          {'a.jpg': 'https://img/a', 'b.jpg': 'https://img/b'});
      expect(jsonDecode(prefs.getString(kGeocodeKey)!),
          {'cell-1': '成都市', 'cell-2': '重庆市'});
      final settings =
          jsonDecode(prefs.getString(kSettingsKey)!) as Map<String, dynamic>;
      expect(settings['mapStyle'], 'dark');
      // Secret must NOT ride along in a backup (scrubbed on export).
      expect(settings['oneDriveRefreshToken'], isNull,
          reason: 'credentials are scrubbed from exports');
    });

    test('importing the SAME upload twice does not duplicate anything '
        '(idempotent pull — the layer-dup regression)', () async {
      final files = await svcA.exportToFiles(modules);

      SharedPreferences.setMockInitialValues({});
      final dbB = AppDb.forTesting(NativeDatabase.memory());
      final svcB = BackupService(dbB);
      addTearDown(() async => dbB.close());

      await svcB.importFromFiles(files, modules: modules);
      final once = await snapshotDb(dbB);
      await svcB.importFromFiles(files, modules: modules);
      final twice = await snapshotDb(dbB);

      expect(twice.counts, once.counts,
          reason: 'a second identical pull must add zero rows');
      // Layers specifically: the historical bug grew this on every pull.
      expect(twice.counts['track_layers'], 3);
      expect(once.counts, expectedSeedCounts,
          reason: 'first pull already mirrors the seed exactly');
    });

    test('data-loss recovery: wiping a table (no tombstone) then re-importing '
        'restores it', () async {
      final files = await svcA.exportToFiles(modules);

      // Simulate corruption / fresh reinstall of ONE module — a raw delete
      // with NO tombstone (unlike a deliberate user delete, which SHOULD
      // propagate and is covered separately).
      await dbA.customStatement('DELETE FROM journal_entries');
      await dbA.customStatement('DELETE FROM journal_fts');
      expect((await snapshotDb(dbA)).counts['journal_entries'], 0);

      await svcA.importFromFiles(files, modules: {'journal'});
      final after = await snapshotDb(dbA);
      expect(after.counts['journal_entries'], 3, reason: 'restored');
      expect(after.uuids['journal_entries'], {'j-1', 'j-2', 'j-3'});
    });

    test('a deliberate delete (tombstoned) is NOT resurrected by re-import '
        '(增量减 contract)', () async {
      // Delete a journal the proper way — it records a tombstone.
      final j = (await dbA.select(dbA.journalEntries).get())
          .firstWhere((e) => e.uuid == 'j-2');
      await dbA.deleteJournalById(j.id);
      final files = await svcA.exportToFiles(modules); // carries the tombstone

      SharedPreferences.setMockInitialValues({});
      final dbB = AppDb.forTesting(NativeDatabase.memory());
      final svcB = BackupService(dbB);
      addTearDown(() async => dbB.close());

      await svcB.importFromFiles(files, modules: modules);
      final b = await snapshotDb(dbB);
      expect(b.uuids['journal_entries'], {'j-1', 'j-3'},
          reason: 'the tombstoned j-2 must stay deleted, not resurrect');
    });
  });

  group('two-device SyncEngine round-trip（真实分片同步·幂等）', () {
    late AppDb dbA;
    late AppDb dbB;
    late FakeSyncStorage storage;
    late ProviderContainer cA;
    late ProviderContainer cB;

    ProviderContainer containerFor(AppDb db) => ProviderContainer(overrides: [
          dbProvider.overrideWithValue(db),
          backupServiceProvider.overrideWithValue(BackupService(db)),
          syncStorageProvider.overrideWithValue(storage),
        ]);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dbA = AppDb.forTesting(NativeDatabase.memory());
      dbB = AppDb.forTesting(NativeDatabase.memory());
      storage = FakeSyncStorage();
      cA = containerFor(dbA);
      cB = containerFor(dbB);
      await seedRealisticData(dbA);
    });

    tearDown(() async {
      cA.dispose();
      cB.dispose();
      await dbA.close();
      await dbB.close();
    });

    test('A uploads, B pulls twice → B mirrors A with no duplication on the '
        'second pull', () async {
      await cA.read(syncEngineProvider).syncUp(modules: modules);

      await cB.read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      final firstPull = await snapshotDb(dbB);

      await cB.read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      final secondPull = await snapshotDb(dbB);

      expect(secondPull.counts, firstPull.counts,
          reason: 'the second pull must be a no-op, not a duplicator');
      // B holds A's layers (3) — default converged by uuid, two inserted.
      expect(firstPull.counts['track_layers'], 3);
      expect(firstPull.uuids['journal_entries'], {'j-1', 'j-2', 'j-3'});
      expect(firstPull.counts['track_points'], 5);
    });

    test('round-trips survive a THIRD device joining late', () async {
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB.read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      // B edits nothing, uploads back — must not corrupt the cloud.
      await cB.read(syncEngineProvider).syncUp(modules: modules);

      final dbC = AppDb.forTesting(NativeDatabase.memory());
      final cC = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(dbC),
        backupServiceProvider.overrideWithValue(BackupService(dbC)),
        syncStorageProvider.overrideWithValue(storage),
      ]);
      addTearDown(() async {
        cC.dispose();
        await dbC.close();
      });
      await cC.read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      final c = await snapshotDb(dbC);
      expect(c.counts['track_layers'], 3);
      expect(c.uuids['journal_entries'], {'j-1', 'j-2', 'j-3'});
    });
  });
}
