import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/sync/onedrive_sync_engine.dart';

import '../support/roundtrip_harness.dart';

/// 会分片的 DB 模块（track_points 按年、chat 按 peer、song_favorites）深度往返 +
/// 分片路由 + 合并/去重/删除传播测试。
///
/// 分片 / diff 语义走双设备 [SyncEngine]（真实上传/下载的碎片就是断言对象）；
/// 保真 / 去重 / 删除这类只关心行内容的走 [BackupService] 直调，更直接。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 双设备同时持有内存库会触发 drift 的多库告警——测试里无害。
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // 往返各表所需的最小模块集合。leaderboard/tombstones 由 export/import 自动折入。
  const trackModules = {'layers', 'track_points'};
  const chatModules = {'chat_messages'};
  const fullModules = {
    'layers',
    'journal',
    'track_points',
    'chat_messages',
    'song_favorites',
  };

  /// 在 [db] 里补种指定年份的一个轨迹点（不改 harness）。返回该点 uuid。
  Future<String> seedYearPoint(AppDb db,
      {required int year, required int layerId, double? width}) async {
    final uuid = 'tp-$year';
    await db.insertPoints([
      TrackPointsCompanion.insert(
        uuid: Value(uuid),
        lat: 30.0 + year * 0.0001,
        lng: 104.0 + year * 0.0001,
        time: DateTime(year, 6, 15, 10),
        width: Value(width),
        layerId: layerId,
      ),
    ]);
    return uuid;
  }

  group('track_points 按年分片 + 只回传变化年份（双设备 SyncEngine）', () {
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
    });

    tearDown(() async {
      cA.dispose();
      cB.dispose();
      await dbA.close();
      await dbB.close();
    });

    test('三个年份的点分别落到独立 tracks/<year>.zip；跨年往返全部保真且 layerId 正确重映射',
        () async {
      final layers = await seedRealisticData(dbA); // 5 个点均在 2026-06
      // 补种 2024（徒步图层）与 2025（通勤图层）各一个点。
      final tp2024 = await seedYearPoint(dbA,
          year: 2024, layerId: layers.hikeId, width: 8);
      final tp2025 =
          await seedYearPoint(dbA, year: 2025, layerId: layers.workId);

      await cA.read(syncEngineProvider).syncUp(modules: trackModules);

      // 每年一个 zip 分片（源码 _shardFor：track_points/<yyyy-mm> → tracks/<yyyy>.zip）。
      expect(storage.store.containsKey('tracks/2024.zip'), isTrue);
      expect(storage.store.containsKey('tracks/2025.zip'), isTrue);
      expect(storage.store.containsKey('tracks/2026.zip'), isTrue);

      await cB
          .read(syncEngineProvider)
          .syncDown(modules: trackModules, clearBeforeImport: false);

      final pointsB = await dbB.select(dbB.trackPoints).get();
      // 5(seed) + 2(补种) = 7，uuid 集合完整保真。
      expect(pointsB.length, 7);
      expect(pointsB.map((p) => p.uuid).toSet(),
          {'tp-h0', 'tp-h1', 'tp-h2', 'tp-w0', 'tp-w1', tp2024, tp2025});

      // layerId 重映射：跨设备 autoincrement 不同，按 uuid 归位到对应图层。
      final layersB = await dbB.allLayers();
      final hikeB = layersB.firstWhere((l) => l.uuid == 'layer-hike');
      final workB = layersB.firstWhere((l) => l.uuid == 'layer-work');
      expect(pointsB.firstWhere((p) => p.uuid == tp2024).layerId, hikeB.id);
      expect(pointsB.firstWhere((p) => p.uuid == tp2025).layerId, workB.id);
      // seed 里徒步点也应落在徒步图层。
      expect(pointsB.firstWhere((p) => p.uuid == 'tp-h0').layerId, hikeB.id);
    });

    test('增量：只改动当年（2026）的点，syncDown 只拉变化年份的 tracks/2026.zip，'
        '往年分片不再下载', () async {
      final layers = await seedRealisticData(dbA);
      await seedYearPoint(dbA, year: 2024, layerId: layers.hikeId, width: 8);
      await seedYearPoint(dbA, year: 2025, layerId: layers.workId);

      await cA.read(syncEngineProvider).syncUp(modules: trackModules);
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: trackModules, clearBeforeImport: false);
      final before = (await dbB.select(dbB.trackPoints).get()).length;
      expect(before, 7);

      // A 只在 2026 追加一个新点 → 只有 tracks/2026.zip 的 md5 变化。
      await dbA.insertPoints([
        TrackPointsCompanion.insert(
          uuid: const Value('tp-new-2026'),
          lat: 30.9,
          lng: 104.9,
          time: DateTime(2026, 8, 1, 9),
          layerId: layers.hikeId,
        ),
      ]);
      await cA.read(syncEngineProvider).syncUp(modules: trackModules);

      // B 第二次拉取：只应请求变化的年份分片。
      storage.getLog.clear();
      await cB
          .read(syncEngineProvider)
          .syncDown(modules: trackModules, clearBeforeImport: false);

      final fetchedTracks =
          storage.getLog.where((k) => k.startsWith('tracks/')).toList();
      expect(fetchedTracks, ['tracks/2026.zip'],
          reason: '未变化的 2024/2025 分片本地基线哈希与云端一致，必须被 diff 跳过');
      expect(storage.getLog, isNot(contains('tracks/2024.zip')));
      expect(storage.getLog, isNot(contains('tracks/2025.zip')));

      // 新点确实到达 B，且总数 +1。
      final after = await dbB.select(dbB.trackPoints).get();
      expect(after.length, 8);
      expect(after.map((p) => p.uuid), contains('tp-new-2026'));
    });
  });

  group('chat_messages 按 peer 分片（双设备 SyncEngine）', () {
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
    });

    tearDown(() async {
      cA.dispose();
      cB.dispose();
      await dbA.close();
      await dbB.close();
    });

    test('多个 peer 分到不同 chat/<peer>.zip；空 peerId 落到 _unknown；往返后按 peer 分组保真',
        () async {
      final t = DateTime(2026, 6, 1, 12);
      await seedRealisticData(dbA); // peer-1 已有 2 条
      // peer-2 一条 + 空 peerId 一条。
      await dbA.into(dbA.chatMessages).insert(ChatMessagesCompanion.insert(
            uuid: const Value('c-p2'),
            peerId: 'peer-2',
            author: '甲',
            content: '另一群',
            time: t,
            outbound: true,
          ));
      await dbA.into(dbA.chatMessages).insert(ChatMessagesCompanion.insert(
            uuid: const Value('c-unknown'),
            peerId: '', // 空 peerId
            author: '匿名',
            content: '孤儿消息',
            time: t,
            outbound: false,
          ));

      await cA.read(syncEngineProvider).syncUp(modules: chatModules);

      // 每个 peer 一个 zip；空 peerId → '_unknown'（源码 backup_service 约 340 行）。
      expect(storage.store.containsKey('chat/peer-1.zip'), isTrue);
      expect(storage.store.containsKey('chat/peer-2.zip'), isTrue);
      expect(storage.store.containsKey('chat/_unknown.zip'), isTrue);

      await cB
          .read(syncEngineProvider)
          .syncDown(modules: chatModules, clearBeforeImport: false);

      final msgsB = await dbB.select(dbB.chatMessages).get();
      expect(msgsB.length, 4);
      // 按 peer 分组保真：peer-1 两条、peer-2 一条、空 peer 一条。
      final byPeer = <String, int>{};
      for (final m in msgsB) {
        byPeer[m.peerId] = (byPeer[m.peerId] ?? 0) + 1;
      }
      expect(byPeer, {'peer-1': 2, 'peer-2': 1, '': 1},
          reason: '空 peerId 分片名为 _unknown，但导回的行 peerId 仍是空串');
      expect(msgsB.map((m) => m.uuid).toSet(),
          {'c-1', 'c-2', 'c-p2', 'c-unknown'});
    });
  });

  group('uuid 去重：同一份导出 import 两次不产生重复（BackupService 直调）', () {
    late AppDb dbA;
    late BackupService svcA;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dbA = AppDb.forTesting(NativeDatabase.memory());
      svcA = BackupService(dbA);
      await seedRealisticData(dbA);
    });

    tearDown(() async => dbA.close());

    test('track_points / chat_messages / song_favorites 第二次导入零新增', () async {
      final files = await svcA.exportToFiles(fullModules);

      SharedPreferences.setMockInitialValues({});
      final dbB = AppDb.forTesting(NativeDatabase.memory());
      final svcB = BackupService(dbB);
      addTearDown(() async => dbB.close());

      await svcB.importFromFiles(files, modules: fullModules);
      final once = await snapshotDb(dbB);
      await svcB.importFromFiles(files, modules: fullModules);
      final twice = await snapshotDb(dbB);

      for (final tbl in ['track_points', 'chat_messages', 'song_favorites']) {
        expect(twice.counts[tbl], once.counts[tbl],
            reason: '$tbl 第二次导入必须零新增（uuid 去重）');
        expect(twice.uuids[tbl], once.uuids[tbl],
            reason: '$tbl uuid 集合不变');
      }
      // 首次导入已精确镜像 seed。
      expect(once.counts['track_points'], 5);
      expect(once.counts['chat_messages'], 2);
      expect(once.counts['song_favorites'], 2);
    });
  });

  group('track_points width 字段保真（BackupService 直调）', () {
    test('徒步点 width=8 保留，通勤点 width=null 不被拍平成默认', () async {
      SharedPreferences.setMockInitialValues({});
      final dbA = AppDb.forTesting(NativeDatabase.memory());
      final svcA = BackupService(dbA);
      addTearDown(() async => dbA.close());
      await seedRealisticData(dbA);

      final files = await svcA.exportToFiles(fullModules);

      SharedPreferences.setMockInitialValues({});
      final dbB = AppDb.forTesting(NativeDatabase.memory());
      final svcB = BackupService(dbB);
      addTearDown(() async => dbB.close());
      await svcB.importFromFiles(files, modules: fullModules);

      final pointsB = await dbB.select(dbB.trackPoints).get();
      final byUuid = {for (final p in pointsB) p.uuid: p};
      // 徒步点：seed 写入 width=8（RealColumn → 8.0）。
      expect(byUuid['tp-h0']!.width, 8.0);
      expect(byUuid['tp-h1']!.width, 8.0);
      expect(byUuid['tp-h2']!.width, 8.0);
      // 通勤点：seed 未给 width → null，往返后仍是 null。
      expect(byUuid['tp-w0']!.width, isNull,
          reason: 'null width 必须原样保留，不被拍平成图层默认宽度');
      expect(byUuid['tp-w1']!.width, isNull);
    });
  });

  group('删除传播（tombstone）：被删的 uuid 导入到另一设备后不复活（BackupService 直调）',
      () {
    late AppDb dbA;
    late BackupService svcA;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dbA = AppDb.forTesting(NativeDatabase.memory());
      svcA = BackupService(dbA);
      await seedRealisticData(dbA);
    });

    tearDown(() async => dbA.close());

    test('删掉一条 track_point 与一条 song_favorite 后，设备 B 上对应行被删且不复活',
        () async {
      // B 先拿到 A 的完整基线（模拟早先已同步）。
      final baseline = await svcA.exportToFiles(fullModules);
      SharedPreferences.setMockInitialValues({});
      final dbB = AppDb.forTesting(NativeDatabase.memory());
      final svcB = BackupService(dbB);
      addTearDown(() async => dbB.close());
      await svcB.importFromFiles(baseline, modules: fullModules);

      final b0 = await snapshotDb(dbB);
      expect(b0.uuids['track_points'], contains('tp-h0'));
      expect(b0.uuids['song_favorites'], contains('s-1'));

      // A 用真正的删除方法（会记 tombstone）：
      //  - track_point 无 delete-by-id，用 erasePointsAround 圈掉 tp-h0(30.6,104.0)。
      //  - song_favorite 用 deleteSongFavoriteById。
      await dbA.erasePointsAround(30.6, 104.0, 30);
      final s1 = (await dbA.select(dbA.songFavorites).get())
          .firstWhere((f) => f.uuid == 's-1');
      await dbA.deleteSongFavoriteById(s1.id);

      // 仅圈掉 tp-h0，其余徒步点仍在。
      final aPoints = await dbA.select(dbA.trackPoints).get();
      expect(aPoints.map((p) => p.uuid), isNot(contains('tp-h0')));
      expect(aPoints.length, 4);

      // 携带 tombstone 的新导出，导入到已有这些行的 B。
      final withDeletes = await svcA.exportToFiles(fullModules);
      await svcB.importFromFiles(withDeletes, modules: fullModules);

      final b1 = await snapshotDb(dbB);
      expect(b1.uuids['track_points'], isNot(contains('tp-h0')),
          reason: 'tombstone 导入时会删掉 B 上已存在的 tp-h0');
      expect(b1.uuids['song_favorites'], isNot(contains('s-1')));
      // 其它行不受影响。
      expect(b1.uuids['track_points'],
          {'tp-h1', 'tp-h2', 'tp-w0', 'tp-w1'});
      expect(b1.uuids['song_favorites'], {'s-2'});

      // 再导入一次：被删的 uuid 不得复活。
      await svcB.importFromFiles(withDeletes, modules: fullModules);
      final b2 = await snapshotDb(dbB);
      expect(b2.uuids['track_points'], isNot(contains('tp-h0')),
          reason: '重复导入不得让被删的点复活');
      expect(b2.uuids['song_favorites'], isNot(contains('s-1')));
      expect(b2.counts, b1.counts);
    });
  });
}
