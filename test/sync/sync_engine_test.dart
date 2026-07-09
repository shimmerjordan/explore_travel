import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:explore_journal/services/fog/fow_compat.dart'
    show buildFowTile, parseFowTile, tileIdToFilename, looksLikeFowTileName;
import 'package:explore_journal/services/sync/onedrive_sync_engine.dart';

import '../support/roundtrip_harness.dart' show FakeSyncStorage;

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

    test('erase masks ride with the fog index shard', () {
      expect(SyncEngine.shardFor('fog/erases.jsonl'), 'fogindex.zip');
    });

    test('native FoW tiles are their own shard (raw 1:1, never zipped)', () {
      expect(SyncEngine.shardFor('fow/uuid-1/27ealorjwsxw'),
          'fow/uuid-1/27ealorjwsxw');
    });

    test('fog blocks group into spatial shards under fog/<layer>/', () {
      expect(SyncEngine.shardFor('fog/3/100_200_15.bin'), startsWith('fog/3/'));
      expect(SyncEngine.shardFor('fog/3/100_200_15.bin'), endsWith('.zip'));
    });

    test('track points shard per year (monthly entries inside)', () {
      expect(SyncEngine.shardFor('track_points/2026-06.jsonl'),
          'tracks/2026.zip');
      expect(SyncEngine.shardFor('track_points/2026-11.jsonl'),
          'tracks/2026.zip');
      expect(SyncEngine.shardFor('track_points/2025-01.jsonl'),
          'tracks/2025.zip');
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

    test('fog blocks 16×16 FOW tiles apart share a shard; farther do not', () {
      // Block-global coords: one FOW tile = 128 blocks, shard cell = 2^11
      // blocks = 16 FOW tiles.
      expect(SyncEngine.shardFor('fog/1/0_0_100.bin'),
          SyncEngine.shardFor('fog/1/2047_2047_100.bin'));
      expect(SyncEngine.shardFor('fog/1/0_0_100.bin'),
          isNot(SyncEngine.shardFor('fog/1/2048_0_100.bin')));
      // Layers never share fog shards.
      expect(SyncEngine.shardFor('fog/1/0_0_100.bin'),
          isNot(SyncEngine.shardFor('fog/2/0_0_100.bin')));
    });
  });

  group('SyncEngine.splitOversized (deterministic part split)', () {
    Map<String, List<int>> entriesOfSize(int count, int size) => {
          for (var i = 0; i < count; i++)
            'fog/1/${i.toString().padLeft(4, '0')}.bin': List.filled(size, i & 0xFF),
        };

    test('small shards pass through untouched', () {
      final grouped = {
        'fog/1/0_0.zip': entriesOfSize(10, 1024),
      };
      final out = SyncEngine.splitOversized(grouped);
      expect(out.keys, ['fog/1/0_0.zip']);
      expect(out['fog/1/0_0.zip']!.length, 10);
    });

    test('oversized shards split into .pN.zip parts, no entry lost', () {
      // 10 entries × 4 MiB = 40 MiB raw > 24 MiB cap → 2 parts.
      final grouped = {
        'fog/1/0_0.zip': entriesOfSize(10, 4 << 20),
      };
      final out = SyncEngine.splitOversized(grouped);
      expect(out.keys.every((k) => k.startsWith('fog/1/0_0.p')), isTrue);
      expect(out.keys.length, greaterThan(1));
      final merged = <String>{};
      for (final part in out.values) {
        merged.addAll(part.keys);
      }
      expect(merged.length, 10,
          reason: 'every entry lands in exactly one part');
    });

    test('same input → identical part layout (MD5-diff friendly)', () {
      final a = SyncEngine.splitOversized(
          {'fog/1/0_0.zip': entriesOfSize(10, 4 << 20)});
      final b = SyncEngine.splitOversized(
          {'fog/1/0_0.zip': entriesOfSize(10, 4 << 20)});
      expect(a.keys.toList(), b.keys.toList());
      for (final k in a.keys) {
        expect(a[k]!.keys.toList(), b[k]!.keys.toList());
      }
    });

    test('a single entry bigger than the cap keeps the ORIGINAL shard name',
        () {
      // One 30 MiB entry can't split — must ship whole and must NOT be
      // renamed .p0 (the rename flip-flopped as the shard crossed the cap).
      final out = SyncEngine.splitOversized({
        'fogindex.zip': {'fog/index.json': List.filled(30 << 20, 1)},
      });
      expect(out.keys.single, 'fogindex.zip');
      expect(out.values.single.length, 1);
    });

    test('a shard that shrinks back under the cap reuses the plain name', () {
      final big = SyncEngine.splitOversized(
          {'fog/1/0_0.zip': entriesOfSize(10, 4 << 20)});
      expect(big.keys, isNot(contains('fog/1/0_0.zip')));
      final small = SyncEngine.splitOversized(
          {'fog/1/0_0.zip': entriesOfSize(2, 1 << 20)});
      expect(small.keys.single, 'fog/1/0_0.zip');
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

    test('per-point trail width survives the round-trip', () async {
      final lid = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'W',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 24),
      ));
      await dbA.insertManualPoint(lat: 30.0, lng: 104.0, layerId: lid, width: 80);
      await dbA.insertPoint(TrackPointsCompanion.insert(
        lat: 30.001,
        lng: 104.001,
        time: DateTime(2026, 6, 24, 12),
        layerId: lid,
      )); // no width → must stay null after restore

      await cA
          .read(syncEngineProvider)
          .syncUp(modules: const {'layers', 'track_points'});
      await cB.read(syncEngineProvider).syncDown(
            modules: const {'layers', 'track_points'},
            clearBeforeImport: false,
          );

      final pointsB = await dbB.select(dbB.trackPoints).get();
      expect(pointsB.length, 2);
      expect(pointsB.map((p) => p.width).toSet(), {80.0, null},
          reason: 'painted width sticks; legacy null stays null');
    });

    test('deleting a track point propagates through sync (增量减) and does '
        'not resurrect on the deleting device either', () async {
      final lid = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'DEL',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 24),
      ));
      await dbA.insertManualPoint(lat: 30.0, lng: 104.0, layerId: lid, width: 10);
      await dbA.insertManualPoint(lat: 31.0, lng: 105.0, layerId: lid, width: 10);
      const modules = {'layers', 'track_points'};

      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect((await dbB.select(dbB.trackPoints).get()).length, 2);

      // A erases one point locally → tombstone recorded.
      await dbA.erasePointsAround(30.0, 104.0, 50);
      expect((await dbA.select(dbA.trackPoints).get()).length, 1);

      // The user-reported bug: syncing down BEFORE uploading used to
      // resurrect the deleted point from the stale cloud copy.
      await cA
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect((await dbA.select(dbA.trackPoints).get()).length, 1,
          reason: 'local tombstone must block resurrection from old cloud');

      // Upload the deletion, then device B pulls: the point must vanish.
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      final pointsB = await dbB.select(dbB.trackPoints).get();
      expect(pointsB.length, 1,
          reason: 'tombstone must delete the row on the other device');
      expect(pointsB.single.lat, 31.0);
    });

    test('erasing fog wins over an older cloud copy (LWW by updatedAt)',
        () async {
      final lid = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'FOGDEL',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 24),
      ));
      const modules = {'layers', 'fog_tiles'};
      final fogA = FogEngine(dbA);
      await fogA.revealPoint(
          lat: 30.0, lng: 104.0, radiusMeters: 30, layerId: lid);
      final before = await dbA.fogTilesForLayers([lid], FogEngine.tileZoom);
      expect(before.any((t) => t.bitmap.any((b) => b != 0)), isTrue);

      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);

      // drift stores DateTime at second precision — make the erase land in
      // a strictly newer second than the reveal.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await fogA.erase(lat: 30.0, lng: 104.0, radiusMeters: 60, layerId: lid);
      bool allZero(List<FogTile> rows) =>
          rows.every((t) => t.bitmap.every((b) => b == 0));
      expect(allZero(await dbA.fogTilesForLayers([lid], FogEngine.tileZoom)),
          isTrue);

      // Down BEFORE up: the stale cloud bitmap must NOT overwrite the
      // fresher local erase (this was the resurrection path).
      await cA
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect(allZero(await dbA.fogTilesForLayers([lid], FogEngine.tileZoom)),
          isTrue, reason: 'older cloud copy must lose the LWW to a fresh erase');

      // Up then down on B: the erase propagates.
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      // Note: layer ids may differ across devices; check all fog rows on B.
      final rowsB = await dbB.select(dbB.fogTiles).get();
      expect(rowsB.every((t) => t.bitmap.every((b) => b == 0)), isTrue,
          reason: 'the erase must propagate to the other device');
    });

    test('journal edits and layer style edits propagate (row-level LWW)',
        () async {
      const modules = {'layers', 'journal'};
      final lid = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'EDIT_ME',
        colorValue: 0xFF111111,
        createdAt: DateTime(2026, 6, 1),
      ));
      await dbA.insertJournal(JournalEntriesCompanion.insert(
        time: DateTime(2026, 6, 1, 8),
        lat: 30.0,
        lng: 104.0,
        title: 'v1-title',
        richContent: const Value(''),
        layerId: lid,
      ));

      // Both devices know the v1 copies.
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect((await dbB.select(dbB.journalEntries).get()).single.title,
          'v1-title');

      // A edits both (the UI stamps updatedAt; updateLayer stamps itself).
      await (dbA.update(dbA.journalEntries)
            ..where((j) => j.title.equals('v1-title')))
          .write(JournalEntriesCompanion(
        title: const Value('v2-title'),
        updatedAt: Value(DateTime.now()),
      ));
      final layerA = (await dbA.allLayers()).firstWhere((l) => l.id == lid);
      await dbA.updateLayer(layerA.copyWith(colorValue: 0xFF222222));

      // The old dedup-by-uuid import skipped every known row — the exact
      // "pulled from OneDrive but nothing updates" report.
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect((await dbB.select(dbB.journalEntries).get()).single.title,
          'v2-title', reason: 'journal edits must apply on the other device');
      expect(
          (await dbB.allLayers())
              .firstWhere((l) => l.name == 'EDIT_ME')
              .colorValue,
          0xFF222222,
          reason: 'layer style edits must apply on the other device');

      // And LWW must protect a NEWER local edit from an older cloud copy:
      // B re-edits later; pulling A's (older) v2 must not clobber it.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await (dbB.update(dbB.journalEntries)
            ..where((j) => j.title.equals('v2-title')))
          .write(JournalEntriesCompanion(
        title: const Value('v3-title-from-B'),
        updatedAt: Value(DateTime.now()),
      ));
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect((await dbB.select(dbB.journalEntries).get()).single.title,
          'v3-title-from-B',
          reason: 'an older cloud copy must lose LWW to a newer local edit');
    });

    test('two devices exploring the SAME block merge by union — '
        'neither side\'s pixels are lost', () async {
      const modules = {'layers', 'fog_tiles'};
      final lid = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'UNION',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 1),
      ));
      // Share the layer so both devices reveal under the same uuid.
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      final lidB =
          (await dbB.allLayers()).firstWhere((l) => l.name == 'UNION').id;

      // ~100 m apart → same 64×64-px FOW block (~610 m), different pixels.
      await FogEngine(dbA)
          .revealPoint(lat: 30.0, lng: 104.0, radiusMeters: 10, layerId: lid);
      await FogEngine(dbB).revealPoint(
          lat: 30.0009, lng: 104.0, radiusMeters: 10, layerId: lidB);

      int pop(List<FogTile> rows) => rows.fold(
          0,
          (s, t) => s +
              t.bitmap.fold<int>(
                  0, (x, b) => x + b.toRadixString(2).replaceAll('0', '').length));
      final popA0 = pop(await dbA.fogTilesForLayers([lid], FogEngine.tileZoom));
      final popB0 =
          pop(await dbB.fogTilesForLayers([lidB], FogEngine.tileZoom));
      expect(popA0, greaterThan(0));
      expect(popB0, greaterThan(0));

      // The old whole-block LWW made whichever side synced later swallow the
      // other's exploration. Union must keep both.
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      final popB1 =
          pop(await dbB.fogTilesForLayers([lidB], FogEngine.tileZoom));
      expect(popB1, popA0 + popB0,
          reason: 'B must hold the union of both explorations');

      await cB.read(syncEngineProvider).syncUp(modules: modules);
      await cA
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      final popA1 = pop(await dbA.fogTilesForLayers([lid], FogEngine.tileZoom));
      expect(popA1, popB1, reason: 'A must converge to the same union');
    });

    test('fog erased on one device disappears on the other, and '
        're-exploring AFTER the erase resurrects legitimately', () async {
      const modules = {'layers', 'fog_tiles'};
      final lid = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'MASK',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 1),
      ));
      await FogEngine(dbA)
          .revealPoint(lat: 30.0, lng: 104.0, radiusMeters: 30, layerId: lid);
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      final lidB =
          (await dbB.allLayers()).firstWhere((l) => l.name == 'MASK').id;
      bool anyLit(List<FogTile> rows) =>
          rows.any((t) => t.bitmap.any((b) => b != 0));
      expect(anyLit(await dbB.fogTilesForLayers([lidB], FogEngine.tileZoom)),
          isTrue);

      // B erases (strictly newer second than A's reveal) and uploads.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await FogEngine(dbB)
          .erase(lat: 30.0, lng: 104.0, radiusMeters: 60, layerId: lidB);
      await cB.read(syncEngineProvider).syncUp(modules: modules);

      // A pulls: the erase mask must clear A's older pixels, even though
      // A's own copy of the block still carries them.
      await cA
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect(anyLit(await dbA.fogTilesForLayers([lid], FogEngine.tileZoom)),
          isFalse, reason: 'the erase must reach the other device');

      // A re-explores AFTER the erase → newer block ts → survives the mask
      // on both devices.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await FogEngine(dbA)
          .revealPoint(lat: 30.0, lng: 104.0, radiusMeters: 10, layerId: lid);
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect(anyLit(await dbB.fogTilesForLayers([lidB], FogEngine.tileZoom)),
          isTrue,
          reason: 're-exploration after the erase must propagate back');
    });

    test('rows re-attach to the uuid-matched layer when autoincrement ids '
        'differ across devices', () async {
      const modules = {'layers', 'journal', 'track_points'};
      // Skew B's autoincrement so A's layer id collides with an UNRELATED
      // local layer.
      final decoyB = await dbB.insertLayer(TrackLayersCompanion.insert(
        name: 'B_DECOY',
        colorValue: 0xFFCCCCCC,
        createdAt: DateTime(2026, 5, 1),
      ));
      final lidA = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'TRAVEL',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 1),
      ));
      await dbA.insertJournal(JournalEntriesCompanion.insert(
        time: DateTime(2026, 6, 1, 9),
        lat: 30.0,
        lng: 104.0,
        title: 'remap-me',
        richContent: const Value(''),
        layerId: lidA,
      ));
      await dbA.insertManualPoint(
          lat: 30.0, lng: 104.0, layerId: lidA, width: 12);

      await cA.read(syncEngineProvider).syncUp(modules: modules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);

      final travelB =
          (await dbB.allLayers()).firstWhere((l) => l.name == 'TRAVEL');
      expect(travelB.id, isNot(lidA),
          reason: 'precondition: ids must actually differ for this test');
      final journalB = (await dbB.select(dbB.journalEntries).get()).single;
      expect(journalB.layerId, travelB.id,
          reason: 'journal must attach to the uuid-matched layer, not the '
              'raw foreign id');
      final pointB = (await dbB.select(dbB.trackPoints).get()).single;
      expect(pointB.layerId, travelB.id,
          reason: 'track points must remap the same way');
      expect(pointB.layerId, isNot(decoyB),
          reason: 'nothing may land on the unrelated local layer');
    });

    test('syncDown diffs against the local baseline — unchanged FoW tiles '
        'are never re-downloaded, only changed ones fetch', () async {
      const modules = {'layers', 'fog_tiles'};
      final lid = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'PULLDIFF',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 1),
      ));
      final bmp = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(bmp, 5, 6);
      await FogEngine(dbA).importBlocks(layerId: lid, blocks: [
        (tileX: 10, tileY: 20, blockX: 3, blockY: 4, bitmap: bmp),
      ]);
      await cA.read(syncEngineProvider).syncUp(modules: modules);

      // First pull on a fresh device fetches the tile.
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect(storage.getLog.any((k) => k.startsWith('fow/')), isTrue);

      // Second pull: B's baseline now reproduces the identical FoW bytes —
      // the tile must NOT be requested again (this was "对所有碎片文件做
      // 请求太慢": every pull re-downloaded every tile).
      storage.getLog.clear();
      final again = await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      expect(again, isNotNull);
      expect(storage.getLog.where((k) => k.startsWith('fow/')), isEmpty,
          reason: 'unchanged tiles must be skipped by the pull diff');

      // A explores a DIFFERENT FoW tile → only that tile downloads.
      final bmp2 = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(bmp2, 1, 1);
      await FogEngine(dbA).importBlocks(layerId: lid, blocks: [
        (tileX: 11, tileY: 20, blockX: 0, blockY: 0, bitmap: bmp2),
      ]);
      await cA.read(syncEngineProvider).syncUp(modules: modules);
      storage.getLog.clear();
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);
      final uuidA = (await dbA.allLayers())
          .firstWhere((l) => l.name == 'PULLDIFF')
          .uuid;
      final fetchedFow =
          storage.getLog.where((k) => k.startsWith('fow/')).toList();
      expect(fetchedFow, ['fow/$uuidA/${tileIdToFilename(20 * 512 + 11)}'],
          reason: 'exactly the ONE changed tile downloads, nothing else');
      // And the new block actually landed.
      final rowsB = await dbB.select(dbB.fogTiles).get();
      expect(rowsB.any((t) => t.tileX == 11 * 128 && t.tileY == 20 * 128),
          isTrue);
    });

    test('pulling into a device that ALREADY has overlapping history: '
        'A-only rows land on B, B-only rows survive', () async {
      const modules = {'layers', 'journal', 'track_points'};
      // Shared history: the same journal row exists on both devices (same
      // uuid, as if they synced long ago).
      Future<void> seedShared(AppDb d) => d.insertJournal(
            JournalEntriesCompanion.insert(
              uuid: const Value('shared-j'),
              time: DateTime(2026, 5, 1),
              lat: 30,
              lng: 104,
              title: 'shared',
              richContent: const Value(''),
              layerId: 1,
            ),
          );
      await seedShared(dbA);
      await seedShared(dbB);
      // B-only local row that must not be touched.
      await dbB.insertJournal(JournalEntriesCompanion.insert(
        uuid: const Value('b-only'),
        time: DateTime(2026, 5, 2),
        lat: 31,
        lng: 105,
        title: 'b-only',
        richContent: const Value(''),
        layerId: 1,
      ));
      // A-only content: a journal row and a track point.
      await dbA.insertJournal(JournalEntriesCompanion.insert(
        uuid: const Value('a-only'),
        time: DateTime(2026, 6, 1),
        lat: 32,
        lng: 106,
        title: 'a-only',
        richContent: const Value(''),
        layerId: 1,
      ));
      await dbA.insertManualPoint(lat: 32, lng: 106, layerId: 1, width: 10);

      await cA.read(syncEngineProvider).syncUp(modules: modules);
      final summary = await cB
          .read(syncEngineProvider)
          .syncDown(modules: modules, clearBeforeImport: false);

      final titles =
          (await dbB.select(dbB.journalEntries).get()).map((r) => r.title);
      expect(titles, containsAll(['shared', 'b-only', 'a-only']),
          reason: 'A-only content must land, B-only must survive');
      expect((await dbB.select(dbB.trackPoints).get()).length, 1,
          reason: 'the A-only track point must arrive');
      expect(summary!.errors, isEmpty,
          reason: 'no module may silently fail: ${summary.errors}');
    });

    test('a cloud still in the OLD zip-shard layout (pre-FoW-native) '
        'imports fully on the new client', () async {
      // Hand-build what the previous engine version uploaded: zip shards
      // with legacy entry paths + the shard→md5 index.
      Uint8List zipOf(Map<String, List<int>> entries) {
        final a = Archive();
        for (final e in entries.entries) {
          a.addFile(ArchiveFile(e.key, e.value.length, e.value));
        }
        return Uint8List.fromList(ZipEncoder().encode(a)!);
      }

      final bmp = Uint8List(512)..[3] = 0x0F;
      final meta = zipOf({
        'manifest.json': utf8.encode(jsonEncode({'version': 2})),
        'layers/layers.json': utf8.encode(jsonEncode([
          {
            'uuid': 'old-layer',
            'name': 'OLD_CLOUD',
            'colorValue': 0xFF445566,
            'visible': true,
            'tag': null,
            'createdAt': '2026-01-01T00:00:00',
          }
        ])),
      });
      final journal = zipOf({
        'journal/entries.jsonl': utf8.encode(jsonEncode({
          'uuid': 'old-j',
          'time': '2026-01-03T08:00:00',
          'lat': 30.0,
          'lng': 104.0,
          'title': 'from old cloud',
          'richContent': '',
          'mediaPaths': '',
          'layerId': 1,
          'level': 'public',
          'ownerPeerId': null,
        })),
      });
      final tracks = zipOf({
        'track_points/2026-01.jsonl': utf8.encode(jsonEncode({
          'uuid': 'old-p',
          'lat': 30.5,
          'lng': 104.5,
          'time': '2026-01-03T09:00:00',
          'layerId': 1,
        })),
      });
      final fogShard = zipOf({'fog/1/1283_2564_100.bin': bmp});
      final fogIndex = zipOf({
        'fog/index.json': utf8.encode(jsonEncode([
          {
            'layerId': 1,
            'tileX': 1283,
            'tileY': 2564,
            'zoom': 100,
            'updatedAt': '2026-01-03T09:00:00',
          }
        ])),
      });
      storage.store['meta.zip'] = meta;
      storage.store['journal.zip'] = journal;
      storage.store['tracks/2026.zip'] = tracks;
      storage.store['fog/1/0_1.zip'] = fogShard;
      storage.store['fogindex.zip'] = fogIndex;
      storage.store['.ej_index.json'] =
          Uint8List.fromList(utf8.encode(jsonEncode({
        'meta.zip': 'x1',
        'journal.zip': 'x2',
        'tracks/2026.zip': 'x3',
        'fog/1/0_1.zip': 'x4',
        'fogindex.zip': 'x5',
      })));

      final summary = await cB.read(syncEngineProvider).syncDown(
            modules: const {
              'layers',
              'journal',
              'track_points',
              'fog_tiles'
            },
            clearBeforeImport: false,
          );

      expect(summary, isNotNull);
      expect(summary!.errors, isEmpty, reason: '${summary.errors}');
      expect((await dbB.allLayers()).map((l) => l.name), contains('OLD_CLOUD'));
      expect((await dbB.select(dbB.journalEntries).get()).single.title,
          'from old cloud');
      expect((await dbB.select(dbB.trackPoints).get()).single.uuid, 'old-p');
      final fog = (await dbB.select(dbB.fogTiles).get()).single;
      expect(fog.tileX, 1283);
      expect(fog.bitmap[3], 0x0F);
    });

    test('cloud fog files are NATIVE Fog of World tiles (raw, 1:1), and a '
        'hand-copied FoW tile imports onto the default layer', () async {
      const modules = {'layers', 'fog_tiles'};
      final lid = await dbA.insertLayer(TrackLayersCompanion.insert(
        name: 'FOW_NATIVE',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 1),
      ));
      final bmp = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(bmp, 5, 6);
      await FogEngine(dbA).importBlocks(layerId: lid, blocks: [
        (tileX: 10, tileY: 20, blockX: 3, blockY: 4, bitmap: bmp),
      ]);
      await cA.read(syncEngineProvider).syncUp(modules: modules);

      // The cloud folder must hold a raw FoW tile file whose obfuscated name
      // decodes to tile (10,20) and whose bytes parse as a FoW tile with our
      // block — i.e. it can be dropped straight into a FoW Sync folder.
      final fowKeys =
          storage.store.keys.where((k) => k.startsWith('fow/')).toList();
      expect(fowKeys, hasLength(1));
      final name = fowKeys.single.split('/').last;
      expect(looksLikeFowTileName(name), isTrue);
      final tile = parseFowTile(name, storage.store[fowKeys.single]!);
      expect((tile.tileX, tile.tileY), (10, 20));
      expect(tile.blocks, hasLength(1));
      expect(tile.blocks.single.bx, 3);
      expect(tile.blocks.single.by, 4);

      // Interop the OTHER way: a tile named/encoded by FoW itself (no layer
      // segment, as if hand-copied from a FoW Sync folder) imports onto the
      // default layer.
      final foreign = buildFowTile(100, 200, {
        (7, 8): (Uint8List(FogEngine.bitmapBytes)..[0] = 0x80),
      });
      final foreignName = tileIdToFilename(200 * 512 + 100);
      await BackupService(dbB).importFromFiles({
        'manifest.json': utf8.encode(jsonEncode({'version': 3})),
        'fow/$foreignName': foreign,
      }, modules: const {
        'fog_tiles'
      });
      final rowsB = await dbB.select(dbB.fogTiles).get();
      expect(rowsB, hasLength(1));
      expect(rowsB.single.tileX, 100 * 128 + 7);
      expect(rowsB.single.tileY, 200 * 128 + 8);
      final defaultLayerB =
          (await dbB.allLayers()).map((l) => l.id).reduce((a, b) => a < b ? a : b);
      expect(rowsB.single.layerId, defaultLayerB,
          reason: 'layer-less FoW tiles land on the default layer');
    });
  });
}
