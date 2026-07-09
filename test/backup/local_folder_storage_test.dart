import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/sync/local_folder_storage.dart';
import 'package:explore_journal/services/sync/onedrive_sync_engine.dart';

import '../support/roundtrip_harness.dart';

/// Proves item 4: "导出到本地文件夹 / 从本地文件夹导入" runs the EXACT SyncEngine
/// pipeline as OneDrive, just writing to a real on-disk folder. Because it's
/// the same code path, a round-trip here is a faithful stand-in for a OneDrive
/// round-trip — which is the whole point (reproduce sync bugs with no network).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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

  late Directory tempRoot;
  late AppDb dbA;
  late AppDb dbB;
  late ProviderContainer cA;
  late ProviderContainer cB;

  ProviderContainer containerFor(AppDb db) => ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        backupServiceProvider.overrideWithValue(BackupService(db)),
      ]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempRoot = await Directory.systemTemp.createTemp('ej_sync_mirror_test');
    dbA = AppDb.forTesting(NativeDatabase.memory());
    dbB = AppDb.forTesting(NativeDatabase.memory());
    cA = containerFor(dbA);
    cB = containerFor(dbB);
    await seedRealisticData(dbA);
  });

  tearDown(() async {
    cA.dispose();
    cB.dispose();
    await dbA.close();
    await dbB.close();
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  test('export writes a real folder structurally identical to a Sync folder',
      () async {
    final storage = LocalFolderStorage(tempRoot.path);
    await cA.read(syncEngineProvider).syncUp(modules: modules, storage: storage);

    // The engine's index + content shards are real files on disk now.
    expect(await File('${tempRoot.path}/.ej_index.json').exists(), isTrue);
    expect(await File('${tempRoot.path}/meta.zip').exists(), isTrue);
    expect(await File('${tempRoot.path}/journal.zip').exists(), isTrue);
    // Native FoW tiles live under fow/<layer>/… just like the cloud folder.
    final fowDir = Directory('${tempRoot.path}/fow');
    expect(await fowDir.exists(), isTrue);
    final fowFiles =
        await fowDir.list(recursive: true).where((e) => e is File).length;
    expect(fowFiles, greaterThan(0), reason: '迷雾应导出为原生 FoW 瓦片文件');
  });

  test('folder round-trip mirrors device A onto B with NO duplication',
      () async {
    final storage = LocalFolderStorage(tempRoot.path);
    await cA.read(syncEngineProvider).syncUp(modules: modules, storage: storage);

    // B pulls TWICE — the classic duplication trap.
    await cB
        .read(syncEngineProvider)
        .syncDown(modules: modules, clearBeforeImport: false, storage: storage);
    final afterFirst = await snapshotDb(dbB);
    await cB
        .read(syncEngineProvider)
        .syncDown(modules: modules, clearBeforeImport: false, storage: storage);
    final afterSecond = await snapshotDb(dbB);

    // Idempotent: the second pull changes nothing.
    expect(afterSecond.counts, afterFirst.counts);
    // B mirrors A's row counts exactly (no dup, no loss).
    final a = await snapshotDb(dbA);
    for (final entry in expectedSeedCounts.entries) {
      expect(afterSecond.counts[entry.key], entry.value,
          reason: '${entry.key}: B 应与种子一致');
      expect(afterSecond.counts[entry.key], a.counts[entry.key],
          reason: '${entry.key}: B 应与 A 一致');
    }
    // Critically: exactly the 3 seeded layers, no phantom "图层 N".
    expect(afterSecond.counts['track_layers'], 3);
    final phantom = (await dbB.allLayers())
        .where((l) => l.name.startsWith('图层 '))
        .toList();
    expect(phantom, isEmpty, reason: '不应出现幻影恢复图层');
    // And every track sits on a real layer (item 3: 路径应用到正确图层).
    final ids = (await dbB.allLayers()).map((l) => l.id).toSet();
    final pts = await dbB.select(dbB.trackPoints).get();
    expect(pts.every((p) => ids.contains(p.layerId)), isTrue);
  });
}
