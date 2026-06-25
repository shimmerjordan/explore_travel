import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:explore_journal/services/sync/onedrive_sync_engine.dart';
import 'package:explore_journal/services/sync/sync_storage.dart';

/// In-memory [SyncStorage] — a Map plus call counters. Stands in for any real
/// transport so we can drive the whole shard/diff/merge pipeline with zero
/// network. Honours the contract: missing read → null, delete is idempotent.
class FakeSyncStorage implements SyncStorage {
  final Map<String, Uint8List> store = {};
  int puts = 0, gets = 0, deletes = 0;

  @override
  Future<void> putSyncFile(String rel, List<int> bytes,
      {CancelToken? cancelToken}) async {
    puts++;
    store[rel] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> getSyncFile(String rel, {CancelToken? cancelToken}) async {
    gets++;
    return store[rel];
  }

  @override
  Future<void> deleteSyncFile(String rel, {CancelToken? cancelToken}) async {
    deletes++;
    store.remove(rel);
  }
}

void main() {
  // The round-trip group spins up two in-memory AppDb instances (device A and
  // device B). They use separate executors, so drift's "multiple databases"
  // race heuristic doesn't apply here.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('SyncStorage contract (FakeSyncStorage)', () {
    test('missing read returns null, not a throw', () async {
      final s = FakeSyncStorage();
      expect(await s.getSyncFile('nope.zip'), isNull);
    });

    test('put then get round-trips the exact bytes', () async {
      final s = FakeSyncStorage();
      await s.putSyncFile('a/b.zip', [1, 2, 3, 250]);
      expect(await s.getSyncFile('a/b.zip'), Uint8List.fromList([1, 2, 3, 250]));
    });

    test('delete of a missing file is a no-op (idempotent)', () async {
      final s = FakeSyncStorage();
      await s.deleteSyncFile('ghost.zip'); // must not throw
      expect(await s.getSyncFile('ghost.zip'), isNull);
    });
  });

  group('SyncEngine.shardFor routing (pure)', () {
    test('fog index has its own shard', () {
      expect(SyncEngine.shardFor('fog/index.json'), 'fogindex.zip');
    });

    test('fog blocks group into spatial shards under fog/<layer>/', () {
      expect(SyncEngine.shardFor('fog/3/100_200_15.bin'), startsWith('fog/3/'));
      expect(SyncEngine.shardFor('fog/3/100_200_15.bin'), endsWith('.zip'));
    });

    test('track points shard per month', () {
      expect(SyncEngine.shardFor('track_points/2026-06.jsonl'),
          'tracks/2026-06.zip');
    });

    test('chat shards per peer', () {
      expect(SyncEngine.shardFor('chat_messages/peerABC.jsonl'),
          'chat/peerABC.zip');
    });

    test('journal collapses to a single shard', () {
      expect(SyncEngine.shardFor('journal/entries.jsonl'), 'journal.zip');
    });

    test('everything else (layers, settings, manifest) lands in meta.zip', () {
      expect(SyncEngine.shardFor('layers/layers.json'), 'meta.zip');
      expect(SyncEngine.shardFor('manifest.json'), 'meta.zip');
      expect(SyncEngine.shardFor('settings/app_settings.json'), 'meta.zip');
    });
  });

  group('SyncEngine round-trip through a swappable transport', () {
    late AppDb dbA;
    late AppDb dbB;
    late FakeSyncStorage storage;
    late ProviderContainer cA;
    late ProviderContainer cB;

    ProviderContainer containerFor(AppDb db) => ProviderContainer(overrides: [
          dbProvider.overrideWithValue(db),
          // No leaderboard → avoids SharedPreferences in a unit test.
          backupServiceProvider.overrideWithValue(BackupService(db)),
          syncStorageProvider.overrideWithValue(storage),
        ]);

    setUp(() {
      dbA = AppDb.forTesting(NativeDatabase.memory());
      dbB = AppDb.forTesting(NativeDatabase.memory());
      storage = FakeSyncStorage();
      cA = containerFor(dbA);
      cB = containerFor(dbB);
    });

    tearDown(() async {
      cA.dispose();
      cB.dispose();
      await dbA.close();
      await dbB.close();
    });

    const modules = {'layers', 'fog_tiles'};

    test('syncUp packs shards + index; incremental syncUp skips unchanged '
        'content shards; syncDown into a fresh DB restores the data', () async {
      // Seed device A with a distinctively-named layer + a fog tile under it.
      // Layers route into meta.zip; fog routes into stable fog/* shards.
      final lid = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'ROUNDTRIP_LAYER',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 24),
      ));
      final bmp = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(bmp, 5, 6);
      await FogEngine(dbA).importBlocks(layerId: lid, blocks: [
        (tileX: 10, tileY: 20, blockX: 3, blockY: 4, bitmap: bmp),
      ]);

      // ── syncUp ──────────────────────────────────────────────────────────
      final up1 = await cA.read(syncEngineProvider).syncUp(modules: modules);
      expect(up1.uploaded, greaterThanOrEqualTo(2),
          reason: 'first sync uploads meta + fog shards');
      expect(storage.store.containsKey('.ej_index.json'), isTrue,
          reason: 'the shard index must be written');
      expect(storage.store.containsKey('meta.zip'), isTrue,
          reason: 'layers route into meta.zip');

      // ── incremental: meta.zip carries a fresh manifest timestamp so it
      //    always re-uploads, but the deterministic fog shards must NOT. ────
      final up2 = await cA.read(syncEngineProvider).syncUp(modules: modules);
      expect(up2.uploaded, lessThan(up1.uploaded),
          reason: 'unchanged fog shards must not be re-sent (md5 diff)');
      expect(up2.unchanged, greaterThan(0),
          reason: 'the stable fog shards count as unchanged');

      // ── syncDown into a different DB via the SAME transport ─────────────
      final summary = await cB.read(syncEngineProvider).syncDown(
            modules: modules,
            clearBeforeImport: false,
          );
      expect(summary, isNotNull, reason: 'a populated remote must import');

      final layersB = await dbB.allLayers();
      expect(layersB.any((l) => l.name == 'ROUNDTRIP_LAYER'), isTrue,
          reason: 'the layer must survive export→shard→transport→import');
    });
  });
}
