import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';

import '../support/roundtrip_harness.dart';

/// Deep round-trip merge tests for the SharedPreferences-backed backup
/// modules — planner_history / settings / imghost_uploads / geocode_cache /
/// learned_regions. Unlike [backup_service_merge_test.dart] (which hand-crafts
/// import file maps), these drive the REAL [BackupService.exportToFiles] on a
/// "device A" and feed its output into [BackupService.importFromFiles] on a
/// "device B", so the export scrub + import merge are exercised together, the
/// way a real sync does it.
///
/// prefs is a single process-wide mock, so the A→B pattern is: seed device A's
/// prefs → export (this snapshots A's prefs into the file map) → reset the mock
/// to device B's prefs → import. Assertions are pinned to what the source in
/// lib/services/backup/backup_service.dart actually does (verified by reading
/// the import handlers), noted inline where it might surprise.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Several in-memory DBs coexist (device A + device B). Harmless in tests.
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// Export [modules] from a device whose prefs are exactly [aPrefs].
  /// Returns the path→bytes map a real upload would push.
  Future<Map<String, List<int>>> exportFrom(
      Map<String, Object> aPrefs, Set<String> modules) async {
    SharedPreferences.setMockInitialValues(aPrefs);
    final db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    return BackupService(db).exportToFiles(modules);
  }

  /// Import [files] into a fresh device whose prefs start as [bPrefs].
  Future<(SharedPreferences, ImportSummary)> importInto(
    Map<String, Object> bPrefs,
    Map<String, List<int>> files,
    Set<String> modules, {
    bool clearBeforeImport = false,
  }) async {
    SharedPreferences.setMockInitialValues(bPrefs);
    final db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final summary = await BackupService(db).importFromFiles(files,
        modules: modules, clearBeforeImport: clearBeforeImport);
    final prefs = await SharedPreferences.getInstance();
    return (prefs, summary);
  }

  group('planner_history 合并（按 id 并集，相同 id 由导入方覆盖）', () {
    const mods = {'planner_history'};

    test('两设备各持不同 id 的 session → import 后按 id 取并集', () async {
      final files = await exportFrom({
        kPlannerKey: jsonEncode([
          {'id': 'a-only', 'title': '川西行', 'days': 5},
          {'id': 'shared', 'title': 'A 版共享', 'days': 3},
        ]),
      }, mods);

      final (prefs, summary) = await importInto({
        kPlannerKey: jsonEncode([
          {'id': 'b-only', 'title': '滇西行', 'days': 7},
          {'id': 'shared', 'title': 'B 版共享', 'days': 9},
        ]),
      }, files, mods);

      final merged = (jsonDecode(prefs.getString(kPlannerKey)!) as List)
          .cast<Map<String, dynamic>>();
      expect(merged.map((e) => e['id']).toSet(), {'a-only', 'b-only', 'shared'},
          reason: '不同 id 的 session 应并集保留');
      // imported 计数 = 被导入文件里的 session 数（a-only + shared = 2），
      // 不是合并后的总数（源码 summary.imported = merged.length）。
      expect(summary.imported['planner_history'], 2);
    });

    test('相同 id → 导入方（云端）覆盖本地版本（源码：imported sessions winning ties）',
        () async {
      final files = await exportFrom({
        kPlannerKey: jsonEncode([
          {'id': 'shared', 'title': 'A 版共享', 'days': 3},
        ]),
      }, mods);

      final (prefs, _) = await importInto({
        kPlannerKey: jsonEncode([
          {'id': 'shared', 'title': 'B 版共享', 'days': 9},
        ]),
      }, files, mods);

      final merged = (jsonDecode(prefs.getString(kPlannerKey)!) as List)
          .cast<Map<String, dynamic>>();
      expect(merged, hasLength(1));
      expect(merged.single['title'], 'A 版共享',
          reason: '相同 id 时被导入的一方（云端）覆盖本地');
      expect(merged.single['days'], 3);
    });

    test('clearBeforeImport → 本地整表被云端替换', () async {
      final files = await exportFrom({
        kPlannerKey: jsonEncode([
          {'id': 'a-only', 'title': '川西行', 'days': 5},
        ]),
      }, mods);

      final (prefs, _) = await importInto({
        kPlannerKey: jsonEncode([
          {'id': 'b-only', 'title': '滇西行', 'days': 7},
        ]),
      }, files, mods, clearBeforeImport: true);

      final merged = (jsonDecode(prefs.getString(kPlannerKey)!) as List)
          .cast<Map<String, dynamic>>();
      expect(merged.map((e) => e['id']), ['a-only'],
          reason: 'clearBeforeImport 下本地记录被清空，只留云端');
    });
  });

  group('settings LWW（经真实 export→import 路径）', () {
    const mods = {'settings'};

    test('云端更新时间更晚 → 应用云端设置并采用其时间戳', () async {
      final files = await exportFrom({
        kSettingsKey: jsonEncode({'mapStyle': 'cloudy'}),
        kSettingsUpdatedAtKey: '2026-06-02T00:00:00.000',
      }, mods);

      final (prefs, summary) = await importInto({
        kSettingsKey: jsonEncode({'mapStyle': 'localold'}),
        kSettingsUpdatedAtKey: '2026-06-01T00:00:00.000',
      }, files, mods);

      final applied =
          jsonDecode(prefs.getString(kSettingsKey)!) as Map<String, dynamic>;
      expect(applied['mapStyle'], 'cloudy');
      expect(prefs.getString(kSettingsUpdatedAtKey),
          startsWith('2026-06-02T00:00:00'));
      expect(summary.imported['settings'], 1);
    });

    test('本地更新时间更晚 → 保留本地，跳过云端', () async {
      final files = await exportFrom({
        kSettingsKey: jsonEncode({'mapStyle': 'cloudy'}),
        kSettingsUpdatedAtKey: '2026-06-01T00:00:00.000',
      }, mods);

      final (prefs, summary) = await importInto({
        kSettingsKey: jsonEncode({'mapStyle': 'localnew'}),
        kSettingsUpdatedAtKey: '2026-06-02T00:00:00.000',
      }, files, mods);

      final applied =
          jsonDecode(prefs.getString(kSettingsKey)!) as Map<String, dynamic>;
      expect(applied['mapStyle'], 'localnew',
          reason: '更旧的云端设置不得覆盖更新的本地设置');
      expect(summary.skipped['settings'], 1);
    });

    test('本地密钥经真实 scrub 导出后，导入时被移植回来（绝不被抹为 null）', () async {
      // 导出方本身持有真密钥；exportToFiles 的 _scrubSettings 会把它抹成 null，
      // 因此文件里 token=null。导入方本地已有自己的 token，源码会把本地值移植回
      // 云端为 null 的密钥字段——这条走的是真实 scrub + 移植合流路径。
      final files = await exportFrom({
        kSettingsKey: jsonEncode({
          'mapStyle': 'cloudy',
          'oneDriveRefreshToken': 'A-DEVICE-TOKEN',
          'webdavPass': 'A-DEVICE-PASS',
        }),
        kSettingsUpdatedAtKey: '2026-06-02T00:00:00.000',
      }, mods);

      // 文件里的密钥必须已被抹除（回归：备份曾把凭据带出）。
      final exported = jsonDecode(
          utf8.decode(files['settings/app_settings.json']!)) as Map;
      expect(exported['oneDriveRefreshToken'], isNull,
          reason: '导出必须 scrub 掉密钥');
      expect(exported['webdavPass'], isNull);

      final (prefs, _) = await importInto({
        kSettingsKey: jsonEncode({
          'mapStyle': 'localold',
          'oneDriveRefreshToken': 'KEEP-ME',
          'webdavPass': 'ALSO-KEEP',
        }),
        kSettingsUpdatedAtKey: '2026-06-01T00:00:00.000',
      }, files, mods);

      final applied =
          jsonDecode(prefs.getString(kSettingsKey)!) as Map<String, dynamic>;
      expect(applied['mapStyle'], 'cloudy', reason: '非密钥字段照常应用');
      expect(applied['oneDriveRefreshToken'], 'KEEP-ME',
          reason: '本地 OneDrive 登录不得被 restore 抹掉');
      expect(applied['webdavPass'], 'ALSO-KEEP');
    });
  });

  group('imghost_uploads registry 并集（冲突时云端 per-key 获胜）', () {
    const mods = {'imghost_uploads'};

    test('本地与云端 registry 按 key 并集，冲突键取云端值', () async {
      final files = await exportFrom({
        kImgHostKey: jsonEncode({'cloud.jpg': 'C', 'both.jpg': 'CLOUD'}),
      }, mods);

      final (prefs, _) = await importInto({
        kImgHostKey: jsonEncode({'local.jpg': 'L', 'both.jpg': 'LOCAL'}),
      }, files, mods);

      final merged = jsonDecode(prefs.getString(kImgHostKey)!) as Map;
      expect(merged['local.jpg'], 'L', reason: '仅本地存在的记录必须保留');
      expect(merged['cloud.jpg'], 'C');
      // 源码 merged = {...local, ...cloud}，云端最后展开 → 冲突键云端胜。
      expect(merged['both.jpg'], 'CLOUD', reason: '冲突键由云端覆盖');
    });
  });

  group('geocode_cache / learned_regions 导入为整体覆盖（非合并）', () {
    test('geocode_cache 导入直接以云端整体覆盖，本地独有键丢失', () async {
      final files = await exportFrom({
        kGeocodeKey: jsonEncode({'cell-1': '成都市', 'cell-3': '云端独有'}),
      }, {'geocode_cache'});

      final (prefs, summary) = await importInto({
        kGeocodeKey: jsonEncode({'cell-1': '旧值', 'cell-2': '本地独有'}),
      }, files, {'geocode_cache'});

      final applied = jsonDecode(prefs.getString(kGeocodeKey)!) as Map;
      // 源码：prefs.setString(raw) —— 整体覆盖，没有并集。
      expect(applied.keys.toSet(), {'cell-1', 'cell-3'},
          reason: '整体覆盖，本地独有的 cell-2 被丢弃');
      expect(applied['cell-1'], '成都市');
      expect(applied.containsKey('cell-2'), isFalse);
      expect(summary.imported['geocode_cache'], 1);
    });

    test('learned_regions 导入直接以云端整体覆盖', () async {
      final files = await exportFrom({
        kLearnedRegionsKey: jsonEncode([
          {'name': '四川'}
        ]),
      }, {'learned_regions'});

      final (prefs, summary) = await importInto({
        kLearnedRegionsKey: jsonEncode([
          {'name': '云南'}
        ]),
      }, files, {'learned_regions'});

      final applied = (jsonDecode(prefs.getString(kLearnedRegionsKey)!) as List)
          .cast<Map<String, dynamic>>();
      expect(applied.map((e) => e['name']), ['四川'],
          reason: '整体覆盖：本地的“云南”不会被合并进来');
      expect(summary.imported['learned_regions'], 1);
    });
  });

  group('5 个 prefs 模块真实往返保真（seed → export → 清空 → import 到 fresh 设备）', () {
    test('全部模块正确恢复；settings 密钥因 scrub 不恢复（这是正确行为）', () async {
      const mods = {
        'planner_history',
        'settings',
        'imghost_uploads',
        'geocode_cache',
        'learned_regions',
      };

      // ── device A: seed 真实数据（含 5 个 prefs 模块）并导出 ──
      SharedPreferences.setMockInitialValues({});
      final dbA = AppDb.forTesting(NativeDatabase.memory());
      addTearDown(() async => dbA.close());
      await seedRealisticData(dbA);
      final files = await BackupService(dbA).exportToFiles(mods);

      // ── device B: 全新设备，空 prefs，导入 ──
      SharedPreferences.setMockInitialValues({});
      final dbB = AppDb.forTesting(NativeDatabase.memory());
      addTearDown(() async => dbB.close());
      final summary =
          await BackupService(dbB).importFromFiles(files, modules: mods);
      expect(summary.errors, isEmpty,
          reason: '任何 prefs 模块都不应报错: ${summary.errors}');

      final prefs = await SharedPreferences.getInstance();

      // planner_history：两个 session 完整恢复。
      final planner = (jsonDecode(prefs.getString(kPlannerKey)!) as List)
          .cast<Map<String, dynamic>>();
      expect(planner.map((e) => e['id']).toSet(), {'plan-1', 'plan-2'});
      expect(planner.map((e) => e['title']).toSet(), {'川西行', '滇西行'});

      // settings：非密钥字段恢复；密钥因 scrub 且 fresh 设备无本地可移植 → 仍为 null。
      final settings =
          jsonDecode(prefs.getString(kSettingsKey)!) as Map<String, dynamic>;
      expect(settings['mapStyle'], 'dark');
      expect(settings['trailWidth'], 8.0);
      expect(settings['oneDriveRefreshToken'], isNull,
          reason: 'fresh 设备无本地密钥可移植，scrub 后保持 null（正确）');
      // settings_updated_at 侧车恢复到 seed 的时间戳。
      expect(prefs.getString(kSettingsUpdatedAtKey),
          startsWith(DateTime(2026, 6, 1, 12).toIso8601String()));

      // imghost / geocode / learned_regions 逐一恢复。
      expect(jsonDecode(prefs.getString(kImgHostKey)!),
          {'a.jpg': 'https://img/a', 'b.jpg': 'https://img/b'});
      expect(jsonDecode(prefs.getString(kGeocodeKey)!),
          {'cell-1': '成都市', 'cell-2': '重庆市'});
      expect(
          (jsonDecode(prefs.getString(kLearnedRegionsKey)!) as List)
              .cast<Map<String, dynamic>>()
              .map((e) => e['name']),
          ['四川', '重庆']);
    });
  });
}
