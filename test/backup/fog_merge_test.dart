import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:explore_journal/services/fog/fow_compat.dart'
    show tileIdToFilename, looksLikeFowTileName, parseFowTile;

import '../support/roundtrip_harness.dart';

/// 迷雾（fog）模块 备份/同步 合并语义的深度往返单元测试。
///
/// 这里走的是 **真实** 的 `BackupService.exportToFiles → importFromFiles`：
/// `exportToFiles` 产出的 path→bytes map 与一次 OneDrive/WebDAV/NAS 上传
/// 逐字节一致，把同一份 map 喂回 `importFromFiles` 就是一次下拉合并。所以
/// 这里的往返能覆盖真实的位并集 / 擦除掩码 / 图层重映射 / 幂等，而不是靠
/// 手搓归档去骗过导入逻辑。
///
/// 覆盖点（对应任务 1-5）：
///   1. 位并集：两设备各探索同一 block 的不同 bit → import 后按位 OR。
///   2. 擦除掩码（增量减）：比擦除更早的 cloud 副本里被擦的 bit 要清掉；
///      擦除之后又重新探索（block updatedAt > erasedAt）的 block 要保留。
///   3. 原生 FoW 直传：导出为 `fow/<layerUuid>/<obfuscatedName>`，zoom=100
///      block 粒度，1:1 可被 FoW 解析。
///   4. 图层归属：迷雾块随图层 uuid 重映射到目标设备本地 layerId。
///   5. 幂等：同一份导出连续 import 两次，fog 行数不增、bit 不变。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 位并集/擦除测试会同时开两个内存库（设备 A + 设备 B）；它们用各自独立
  // 的 executor，drift 的“多数据库”竞态启发式在这里不适用。
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const fogModules = {'layers', 'fog_tiles'};

  // 一个 FOW block 的 DB 主键坐标： dbX = fowTile*128 + block。
  int dbCoord(int fowTile, int block) => fowTile * FogEngine.tileWidth + block;

  // 读出某层某 block 内所有被点亮的像素坐标集合，便于逐 bit 断言并集/擦除。
  Future<Set<(int, int)>> litPixels(
      AppDb db, int layerId, int dbX, int dbY) async {
    final t = await db.getFogTile(dbX, dbY, FogEngine.tileZoom, layerId);
    if (t == null) return {};
    final bmp = Uint8List.fromList(t.bitmap);
    final out = <(int, int)>{};
    for (var py = 0; py < FogEngine.bitmapWidth; py++) {
      for (var px = 0; px < FogEngine.bitmapWidth; px++) {
        if (FogEngine.isSet(bmp, px, py)) out.add((px, py));
      }
    }
    return out;
  }

  // 一个 512 字节 bitmap，只点亮给定像素。
  Uint8List bmpWith(List<(int, int)> pixels) {
    final b = Uint8List(FogEngine.bitmapBytes);
    for (final (px, py) in pixels) {
      FogEngine.setBit(b, px, py);
    }
    return b;
  }

  Future<int> insertSharedLayer(AppDb db, String uuid, String name) =>
      db.insertLayer(TrackLayersCompanion.insert(
        uuid: Value(uuid),
        name: name,
        colorValue: 0xFF00BCD4,
        createdAt: DateTime(2026, 6, 1),
        updatedAt: Value(DateTime(2026, 6, 1)),
      ));

  group('1. 位并集：同一 block 的不同 bit 在 import 后按位 OR', () {
    late AppDb dbA;
    late AppDb dbB;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      dbA = AppDb.forTesting(NativeDatabase.memory());
      dbB = AppDb.forTesting(NativeDatabase.memory());
    });
    tearDown(() async {
      await dbA.close();
      await dbB.close();
    });

    test('A 点亮 (1,1)、B 点亮 (2,2)，A→B 导入后 B 持有两者的并集，'
        '任一侧的探索都不丢', () async {
      // 两设备共享同一图层 uuid（迷雾块靠 uuid 归属，不靠自增 id）。
      final lidA = await insertSharedLayer(dbA, 'shared-union', '并集');
      final lidB = await insertSharedLayer(dbB, 'shared-union', '并集');
      // 同一 FOW block：fowTile(50,60) block(7,8)。
      const fowTx = 50, fowTy = 60, bx = 7, by = 8;
      await FogEngine(dbA).importBlocks(layerId: lidA, blocks: [
        (tileX: fowTx, tileY: fowTy, blockX: bx, blockY: by,
          bitmap: bmpWith([(1, 1)])),
      ]);
      await FogEngine(dbB).importBlocks(layerId: lidB, blocks: [
        (tileX: fowTx, tileY: fowTy, blockX: bx, blockY: by,
          bitmap: bmpWith([(2, 2)])),
      ]);

      final files = await BackupService(dbA).exportToFiles(fogModules);
      final summary = await BackupService(dbB)
          .importFromFiles(files, modules: fogModules);
      expect(summary.errors, isEmpty, reason: '${summary.errors}');

      final dbX = dbCoord(fowTx, bx);
      final dbY = dbCoord(fowTy, by);
      // 实际行为：合并 = 本地 bits(2,2) | 云端 bits(1,1)，两侧都保留。
      expect(await litPixels(dbB, lidB, dbX, dbY), {(1, 1), (2, 2)},
          reason: 'B 必须持有两台设备探索的并集');
    });
  });

  group('2. 擦除掩码（增量减）: 更早的 cloud 副本被擦，但擦后重探的 block 保留',
      () {
    // 关键时间线（均在 gcFogErases 的 180 天保留窗口内，避免被清）：
    //   tExplore  2026-06-01  最初探索
    //   tErase    2026-06-15  橡皮擦擦掉某些 bit（recordFogErase 记 mask+at）
    //   tReexplore 2026-06-20 擦除之后重新探索
    final tExplore = DateTime(2026, 6, 1);
    final tErase = DateTime(2026, 6, 15);
    final tReexplore = DateTime(2026, 6, 20);

    late AppDb cloud; // 导出端：擦掉 (6,6)，只剩 (5,5)，并带 erase 掩码
    late AppDb local; // 导入端：仍持有擦除前的完整 block {(5,5),(6,6)}

    // fowTile(70,80) block(9,10) → 一个确定的 block。
    const fowTx = 70, fowTy = 80, bx = 9, by = 10;
    final int dbX = dbCoord(fowTx, bx);
    final int dbY = dbCoord(fowTy, by);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      cloud = AppDb.forTesting(NativeDatabase.memory());
      local = AppDb.forTesting(NativeDatabase.memory());

      // ── 导出端 cloud：block 只剩 (5,5)（(6,6) 已被橡皮擦擦掉），
      //    block updatedAt = tErase，并记录一条擦掉 (6,6) 的 erase 掩码。
      final lidC = await insertSharedLayer(cloud, 'shared-erase', '擦除');
      await cloud.upsertFogTile(FogTilesCompanion.insert(
        tileX: dbX,
        tileY: dbY,
        zoom: FogEngine.tileZoom,
        layerId: lidC,
        bitmap: bmpWith([(5, 5)]),
        updatedAt: tErase,
      ));
      await cloud.recordFogErase(
          dbX, dbY, FogEngine.tileZoom, lidC, bmpWith([(6, 6)]),
          at: tErase);
    });
    tearDown(() async {
      await cloud.close();
      await local.close();
    });

    test('本地 block 比擦除更早（updatedAt < erasedAt）→ 被擦的 bit 清掉',
        () async {
      // 导入端 local：完整 block {(5,5),(6,6)}，updatedAt=tExplore < tErase。
      final lidL = await insertSharedLayer(local, 'shared-erase', '擦除');
      await local.upsertFogTile(FogTilesCompanion.insert(
        tileX: dbX,
        tileY: dbY,
        zoom: FogEngine.tileZoom,
        layerId: lidL,
        bitmap: bmpWith([(5, 5), (6, 6)]),
        updatedAt: tExplore,
      ));

      final files = await BackupService(cloud).exportToFiles(fogModules);
      final summary = await BackupService(local)
          .importFromFiles(files, modules: fogModules);
      expect(summary.errors, isEmpty, reason: '${summary.errors}');

      // 实际行为：cloudErase.erasedAt(tErase) > 本地 block.updatedAt(tExplore)
      // → 本地 bits &= ~mask，(6,6) 被清；再 union 云端 {(5,5)} → 只剩 (5,5)。
      expect(await litPixels(local, lidL, dbX, dbY), {(5, 5)},
          reason: '更早的本地副本里被擦的 bit 必须被 cloud 擦除掩码清掉');
    });

    test('本地 block 在擦除之后重新探索（updatedAt > erasedAt）→ 整块保留，'
        '擦除掩码不生效（规则是 block 级，不是 bit 级）', () async {
      // 导入端 local：擦除之后（tReexplore > tErase）重新探索过这个 block，
      // 且仍持有 {(5,5),(6,6)}。
      final lidL = await insertSharedLayer(local, 'shared-erase', '擦除');
      await local.upsertFogTile(FogTilesCompanion.insert(
        tileX: dbX,
        tileY: dbY,
        zoom: FogEngine.tileZoom,
        layerId: lidL,
        bitmap: bmpWith([(5, 5), (6, 6)]),
        updatedAt: tReexplore,
      ));

      final files = await BackupService(cloud).exportToFiles(fogModules);
      final summary = await BackupService(local)
          .importFromFiles(files, modules: fogModules);
      expect(summary.errors, isEmpty, reason: '${summary.errors}');

      // 实际行为：本地 block.updatedAt(tReexplore) >= cloudErase.erasedAt(tErase)
      // → `ce.erasedAt.isAfter(lo.updatedAt)` 为 false，擦除掩码整体不作用于
      // 本地 block，(6,6) 随整块一起保留。注意：精确规则是 **block 粒度** ——
      // 只要该 block 在擦除之后被写过一次（updatedAt 更新），该 block 内的 bit
      // 都不会被这条 cloud 擦除掩码裁剪，即便其中某个 bit 正是当初被擦的那个。
      expect(await litPixels(local, lidL, dbX, dbY), {(5, 5), (6, 6)},
          reason: '擦除之后重新探索的 block 必须整块躲过 cloud 擦除掩码');
    });
  });

  group('3. 原生 FoW 直传：fow/<layerUuid>/<obfuscatedName>，zoom=100 block 粒度',
      () {
    late AppDb db;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = AppDb.forTesting(NativeDatabase.memory());
      await seedRealisticData(db);
    });
    tearDown(() async => db.close());

    test('导出产出以图层 uuid 命名的原生 FoW 瓦片，且 1:1 可被 FoW 解析回同一 block',
        () async {
      final files = await BackupService(db).exportToFiles(fogModules);

      // seed 在 uuid=layer-hike 的图层上探索了 fowTile(100,200) block(3,4)。
      final fowKeys = files.keys.where((k) => k.startsWith('fow/')).toList();
      expect(fowKeys, isNotEmpty, reason: '迷雾必须以原生 FoW 瓦片导出');
      // 路径形如 fow/<layerUuid>/<obfuscatedName>，携带图层 uuid 段。
      expect(fowKeys.every((k) => k.split('/').length == 3), isTrue);
      final hikeKey = fowKeys.firstWhere((k) => k.split('/')[1] == 'layer-hike');
      final name = hikeKey.split('/').last;
      expect(looksLikeFowTileName(name), isTrue,
          reason: '文件名必须是 FoW 混淆瓦片名');
      // 名字 1:1 解码回 (tileX=100, tileY=200)。
      expect(name, tileIdToFilename(200 * 512 + 100));

      // 字节 1:1 —— 用 FoW 自己的解析器解回同一个 block(3,4)。
      final tile = parseFowTile(
          name, Uint8List.fromList(files[hikeKey]!));
      expect((tile.tileX, tile.tileY), (100, 200));
      expect(tile.blocks.map((b) => (b.bx, b.by)), contains((3, 4)));

      // 同时带 fog/index.json 侧车（block 粒度、zoom=100、按 uuid 归属）。
      expect(files.containsKey('fog/index.json'), isTrue);
    });
  });

  group('4. 图层归属：迷雾块随图层 uuid 重映射到目标设备本地 layerId', () {
    late AppDb cloud;
    late AppDb local;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      cloud = AppDb.forTesting(NativeDatabase.memory());
      local = AppDb.forTesting(NativeDatabase.memory());
    });
    tearDown(() async {
      await cloud.close();
      await local.close();
    });

    test('两设备自增 id 不同的情况下，迷雾块落到 uuid 匹配的本地图层，'
        '不落到自增 id 相同的无关图层', () async {
      // cloud：default(id1) + travel(id2)，迷雾在 travel 上。
      final lidCloud = await insertSharedLayer(cloud, 'travel-uuid', '旅行');
      const fowTx = 12, fowTy = 34, bx = 1, by = 2;
      await FogEngine(cloud).importBlocks(layerId: lidCloud, blocks: [
        (tileX: fowTx, tileY: fowTy, blockX: bx, blockY: by,
          bitmap: bmpWith([(3, 3)])),
      ]);

      // local：先插一个 decoy 图层把自增 id 顶偏 —— 让 cloud 的 travel 原始
      // id(2) 在 local 上恰好撞上一个无关图层。
      final decoy = await insertSharedLayer(local, 'decoy-uuid', '无关');
      expect(decoy, lidCloud,
          reason: '前置条件：decoy 的本地 id 必须等于 cloud 里 travel 的原始 id');

      final files = await BackupService(cloud).exportToFiles(fogModules);
      final summary = await BackupService(local)
          .importFromFiles(files, modules: fogModules);
      expect(summary.errors, isEmpty, reason: '${summary.errors}');

      // 导入 layers 后 local 上新建的 travel 图层拿到一个新自增 id（≠2）。
      final travelLocal =
          (await local.allLayers()).firstWhere((l) => l.uuid == 'travel-uuid');
      expect(travelLocal.id, isNot(lidCloud),
          reason: '前置条件：两侧 id 必须真的不同才验证得了重映射');

      final rows = await local.select(local.fogTiles).get();
      expect(rows, hasLength(1));
      // 实际行为：迷雾块 layerId 被重映射到 uuid 匹配的本地图层。
      expect(rows.single.layerId, travelLocal.id,
          reason: '迷雾块必须挂到 uuid 匹配的本地图层');
      expect(rows.single.layerId, isNot(decoy),
          reason: '绝不能挂到自增 id 相同的无关图层');
    });
  });

  group('5. 幂等：同一份导出连续 import 两次，fog 行数不增、bit 不变', () {
    late AppDb src;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      src = AppDb.forTesting(NativeDatabase.memory());
      await seedRealisticData(src);
    });
    tearDown(() async => src.close());

    test('第二次相同导入是 no-op（fog 行数与每行 bitmap 完全不变）', () async {
      final files = await BackupService(src).exportToFiles(fogModules);

      SharedPreferences.setMockInitialValues({});
      final dst = AppDb.forTesting(NativeDatabase.memory());
      addTearDown(() async => dst.close());
      final svc = BackupService(dst);

      await svc.importFromFiles(files, modules: fogModules);
      final onceSnap = await snapshotDb(dst);
      final onceRows = {
        for (final r in await dst.select(dst.fogTiles).get())
          '${r.layerId}/${r.tileX}_${r.tileY}': Uint8List.fromList(r.bitmap),
      };
      // seed 播了 2 个迷雾块。
      expect(onceSnap.counts['fog_tiles'], 2);

      await svc.importFromFiles(files, modules: fogModules);
      final twiceSnap = await snapshotDb(dst);
      final twiceRows = {
        for (final r in await dst.select(dst.fogTiles).get())
          '${r.layerId}/${r.tileX}_${r.tileY}': Uint8List.fromList(r.bitmap),
      };

      expect(twiceSnap.counts['fog_tiles'], onceSnap.counts['fog_tiles'],
          reason: '第二次相同导入不得新增 fog 行');
      expect(twiceRows.keys.toSet(), onceRows.keys.toSet(),
          reason: 'block 身份集合不变');
      for (final k in onceRows.keys) {
        expect(twiceRows[k], onceRows[k], reason: '$k 的 bitmap 必须逐字节不变');
      }
    });
  });
}
