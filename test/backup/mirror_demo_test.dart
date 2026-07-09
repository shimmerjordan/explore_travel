import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:explore_journal/services/sync/local_folder_storage.dart';
import 'package:explore_journal/services/sync/onedrive_sync_engine.dart';

/// Human-readable end-to-end DEMO (item 5 — real verification, not assumptions).
///
/// Reproduces the user's exact scenario THROUGH the real "导出到本地文件夹 /
/// 从本地文件夹导入" pipeline (identical to OneDrive syncUp/syncDown):
///   1. a device whose layer table got polluted (5 同名默认图层 + tracks on each)
///   2. syncUp → a real local folder (prints the resulting Sync-folder tree)
///   3. a clean device syncDown from that folder (prints its final layers +
///      where every track landed)
///
/// Passing proves: no duplicate layers, no phantom 图层 N, every track applied
/// to a real visible layer. Run with `-r expanded` to read the printout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const modules = {'layers', 'track_points', 'fog_tiles'};

  test('DEMO: polluted device → local folder → clean device (真实往返)',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tmp = await Directory.systemTemp.createTemp('ej_mirror_demo');
    final storage = LocalFolderStorage(tmp.path);

    // ── Device A — polluted: 1 real default + 4 churned same-name copies,
    //    with tracks spread across ALL of them (the shape that used to explode
    //    into "图层 2/3/4/5" on the receiving device). ────────────────────────
    final dbA = AppDb.forTesting(NativeDatabase.memory());
    final cA = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(dbA),
      backupServiceProvider.overrideWithValue(BackupService(dbA)),
    ]);
    // default layer id 1 already exists (uuid=default-layer). Add 4 dup copies.
    final dupIds = <int>[1];
    for (final u in ['dup-a', 'dup-b', 'dup-c', 'dup-d']) {
      dupIds.add(await dbA.insertLayer(TrackLayersCompanion.insert(
        uuid: Value(u),
        name: '默认图层', // same name, different uuid — the churn
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 3, 1),
        updatedAt: Value(DateTime(2026, 6, 1)),
      )));
    }
    // one track on each of the five layer ids
    await dbA.insertPoints([
      for (final id in dupIds)
        TrackPointsCompanion.insert(
          uuid: Value('tp-$id'),
          lat: 30.6 + id * 0.001,
          lng: 104.0 + id * 0.001,
          time: DateTime(2026, 6, 1, 12, id),
          layerId: id,
        ),
    ]);
    // a little fog so the folder grows a fow/ tree too
    final bmp = Uint8List(FogEngine.bitmapBytes);
    FogEngine.setBit(bmp, 3, 4);
    await FogEngine(dbA).importBlocks(layerId: 1, blocks: [
      (tileX: 100, tileY: 200, blockX: 3, blockY: 4, bitmap: bmp),
    ]);

    stderr.writeln('\n════════ 设备A（脏）：${(await dbA.allLayers()).length} 个图层 ════════');
    for (final l in await dbA.allLayers()) {
      stderr.writeln('  图层 id=${l.id} uuid=${l.uuid} name=${l.name}');
    }

    // ── 导出到本地文件夹（= syncUp，与 OneDrive 同一条流水线）──────────────────
    await cA.read(syncEngineProvider).syncUp(modules: modules, storage: storage);

    stderr.writeln('\n════════ 本地文件夹结构（与 OneDrive Sync 目录一致）════════');
    final files = await tmp
        .list(recursive: true)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final rel = f.path.substring(tmp.path.length + 1);
      stderr.writeln('  $rel  (${await f.length()} B)');
    }

    // ── Device B — clean: only its own default layer. Pull from the folder. ──
    final dbB = AppDb.forTesting(NativeDatabase.memory());
    final cB = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(dbB),
      backupServiceProvider.overrideWithValue(BackupService(dbB)),
    ]);
    stderr.writeln('\n════════ 设备B（干净）导入前：${(await dbB.allLayers()).length} 个图层 ════════');

    await cB
        .read(syncEngineProvider)
        .syncDown(modules: modules, clearBeforeImport: false, storage: storage);

    final bLayers = await dbB.allLayers();
    stderr.writeln('\n════════ 设备B 导入后：${bLayers.length} 个图层 ════════');
    for (final l in bLayers) {
      stderr.writeln('  图层 id=${l.id} uuid=${l.uuid} name=${l.name} visible=${l.visible}');
    }
    final pts = await dbB.select(dbB.trackPoints).get();
    final byLayer = <int, int>{};
    for (final p in pts) {
      byLayer[p.layerId] = (byLayer[p.layerId] ?? 0) + 1;
    }
    stderr.writeln('  轨迹点归属：$byLayer （共 ${pts.length} 点）');
    final ids = bLayers.map((l) => l.id).toSet();
    stderr.writeln('  孤儿轨迹（落在不存在图层）：'
        '${pts.where((p) => !ids.contains(p.layerId)).length}');
    stderr.writeln('════════════════════════════════════════════════\n');

    // ── The proof ────────────────────────────────────────────────────────────
    expect(bLayers.length, 1, reason: '5 个同名默认图层折叠成 1，无重复');
    expect(bLayers.where((l) => l.name.startsWith('图层 ')), isEmpty,
        reason: '无幻影恢复图层');
    expect(pts.length, 5, reason: '5 个轨迹点全部导入');
    expect(pts.every((p) => ids.contains(p.layerId)), isTrue,
        reason: '每个轨迹点都落在真实图层上（路径可见）');

    cA.dispose();
    cB.dispose();
    await dbA.close();
    await dbB.close();
    await tmp.delete(recursive: true);
  });
}
