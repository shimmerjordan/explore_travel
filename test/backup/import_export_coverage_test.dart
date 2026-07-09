import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/sync/onedrive_sync_engine.dart';

import '../support/roundtrip_harness.dart';

/// Full-coverage sweep of the import/export module: the restore-vs-sync
/// semantics for EVERY tombstone producer, restore edge cases (idempotency,
/// mixed archive/local tombstones, clearBeforeImport, the LWW boundary), the
/// real SyncEngine end-to-end path, per-column field fidelity, and import
/// robustness (empty / newer-version / selective / no-wipe-on-empty). Pairs
/// with `restore_resurrects_deletes_test.dart` (the focused repro) and the
/// harness round-trips.
Future<int> _addJournal(
  AppDb d,
  String uuid, {
  required int layerId,
  String title = 't',
  String content = '',
  String media = '',
  String level = 'public',
  String? owner,
  DateTime? updatedAt,
}) =>
    d.insertJournal(JournalEntriesCompanion.insert(
      uuid: Value(uuid),
      time: DateTime(2026, 1, 1),
      lat: 1,
      lng: 2,
      title: title,
      richContent: Value(content),
      mediaPaths: Value(media),
      level: Value(level),
      ownerPeerId: Value(owner),
      updatedAt: Value(updatedAt),
      layerId: layerId,
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDb db;
  late BackupService svc;
  late int defId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDb.forTesting(NativeDatabase.memory());
    svc = BackupService(db);
    defId = (await db.allLayers()).first.id;
  });
  tearDown(() async => db.close());

  Future<int> jcount() async => (await db
          .customSelect('SELECT count(*) c FROM journal_entries')
          .getSingle())
      .read<int>('c');
  Future<Set<String>> juuids() async =>
      (await db.select(db.journalEntries).get()).map((j) => j.uuid).toSet();

  // ───────────────────────────────────────────────────────────────────────
  group('A. restore 模式：补齐生产者与边界', () {
    test('A1 layers：deleteLayer 后 restore 复活图层；默认 sync 不复活', () async {
      final lid = await db.insertLayer(TrackLayersCompanion.insert(
        uuid: const Value('lay-x'),
        name: '西藏线',
        colorValue: 0xFF112233,
        createdAt: DateTime(2026, 5, 1),
      ));
      final files = await svc.exportToFiles({'layers'});

      await db.deleteLayer(lid); // → tombstone track_layers[lay-x]
      Future<Set<String>> layerUuids() async =>
          (await db.allLayers()).map((l) => l.uuid).toSet();
      expect(await layerUuids(), isNot(contains('lay-x')));
      expect(await db.tombstonedUuids('track_layers'), contains('lay-x'));

      await svc.importFromFiles(files, modules: {'layers'});
      expect(await layerUuids(), isNot(contains('lay-x')),
          reason: 'sync 语义：图层墓碑阻止复活');

      await svc.importFromFiles(files, modules: {'layers'}, restore: true);
      expect(await layerUuids(), contains('lay-x'), reason: '恢复语义：图层必须回来');
      expect(await db.tombstonedUuids('track_layers'), isEmpty);
    });

    test('A2 restore 幂等：连续 restore 两次不产生重复', () async {
      final id = await _addJournal(db, 'j-1', layerId: defId);
      final files = await svc.exportToFiles({'journal'});
      await db.deleteJournalById(id);

      await svc.importFromFiles(files, modules: {'journal'}, restore: true);
      await svc.importFromFiles(files, modules: {'journal'}, restore: true);
      expect(await jcount(), 1, reason: '第二次 restore 不得重复插入');
    });

    test('A3 restore 混合：本地独有墓碑复活、归档自带墓碑仍删', () async {
      await _addJournal(db, 'j-local', layerId: defId);
      final arch = await _addJournal(db, 'j-arch', layerId: defId);
      await db
          .deleteJournalById(arch); // deleted BEFORE export → in archive tombs
      final files = await svc.exportToFiles({'journal'}); // carries j-arch tomb

      final localId =
          (await db.select(db.journalEntries).get()).single.id; // j-local
      await db
          .deleteJournalById(localId); // local-only tombstone (not in archive)
      expect(await jcount(), 0);

      await svc.importFromFiles(files, modules: {'journal'}, restore: true);
      expect(await juuids(), {'j-local'},
          reason: '本地独有墓碑的 j-local 复活；归档携带墓碑的 j-arch 不复活');
      expect(await db.tombstonedUuids('journal_entries'), {'j-arch'},
          reason: 'j-local 的墓碑被清；j-arch 的墓碑保留');
    });

    test('A4 restore + clearBeforeImport：清空本地后从归档整体恢复', () async {
      await _addJournal(db, 'j-1', layerId: defId);
      await _addJournal(db, 'j-2', layerId: defId);
      final files = await svc.exportToFiles({'journal'}); // both in archive

      final id2 = (await db.select(db.journalEntries).get())
          .firstWhere((j) => j.uuid == 'j-2')
          .id;
      await db.deleteJournalById(id2); // local tombstone for j-2
      await _addJournal(db, 'j-extra',
          layerId: defId); // local-only, NOT in archive
      expect(await juuids(), {'j-1', 'j-extra'});

      await svc.importFromFiles(files,
          modules: {'journal'}, clearBeforeImport: true, restore: true);
      expect(await juuids(), {'j-1', 'j-2'},
          reason: 'clear 抹掉 j-extra，归档恢复 j-1 与被删的 j-2');
      expect(await db.tombstonedUuids('journal_entries'), isEmpty);
    });

    test('A5 restore 不越权 LWW：更旧归档副本不覆盖更新的本地编辑', () async {
      await _addJournal(db, 'x',
          layerId: defId, title: 'old', updatedAt: DateTime(2026, 1, 1));
      final files =
          await svc.exportToFiles({'journal'}); // archive title=old(T1)

      await db.applyJournalUpdateByUuid(
          'x',
          JournalEntriesCompanion(
            title: const Value('new'),
            updatedAt: Value(DateTime(2026, 6, 1)),
          )); // local edit, newer(T2)

      await svc.importFromFiles(files, modules: {'journal'}, restore: true);
      final row = (await db.select(db.journalEntries).get()).single;
      expect(row.title, 'new', reason: 'restore 只放宽墓碑，不改 LWW：更新的本地编辑仍胜出');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('A6. 端到端（SyncEngine 真实分片路径）restore', () {
    ProviderContainer containerFor(AppDb d) => ProviderContainer(overrides: [
          dbProvider.overrideWithValue(d),
          backupServiceProvider.overrideWithValue(BackupService(d)),
        ]);
    const mods = {'journal', 'layers'};

    test('syncUp → 删手账 → syncDown(restore) 把它带回来', () async {
      final c = containerFor(db);
      addTearDown(c.dispose);
      final storage = FakeSyncStorage();
      final id = await _addJournal(db, 'j-e2e', layerId: defId, title: '端到端');

      await c.read(syncEngineProvider).syncUp(modules: mods, storage: storage);
      await db.deleteJournalById(id);
      expect(await jcount(), 0);

      final summary = await c.read(syncEngineProvider).syncDown(
          modules: mods,
          clearBeforeImport: false,
          restore: true,
          storage: storage);
      expect(summary, isNotNull);
      expect(await jcount(), 1, reason: '走真实 syncDown 分片路径，手账应恢复');
      expect(await db.tombstonedUuids('journal_entries'), isEmpty);
    });

    test('对照：syncDown(默认 sync) 不复活本地删除（保留反复活保证）', () async {
      final d2 = AppDb.forTesting(NativeDatabase.memory());
      final c2 = containerFor(d2);
      addTearDown(() async {
        c2.dispose();
        await d2.close();
      });
      final storage = FakeSyncStorage();
      final def2 = (await d2.allLayers()).first.id;
      final id = await _addJournal(d2, 'j-sync', layerId: def2);

      await c2.read(syncEngineProvider).syncUp(modules: mods, storage: storage);
      await d2.deleteJournalById(id);

      await c2
          .read(syncEngineProvider)
          .syncDown(modules: mods, clearBeforeImport: false, storage: storage);
      final n = (await d2
              .customSelect('SELECT count(*) c FROM journal_entries')
              .getSingle())
          .read<int>('c');
      expect(n, 0, reason: 'sync 语义：本地墓碑阻止云端旧副本复活');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('B. 字段保真（export→import 保留所有列）', () {
    test('B1 journal：mediaPaths/level/ownerPeerId/richContent/updatedAt 全保真',
        () async {
      final t = DateTime(2026, 3, 15, 9, 30);
      await _addJournal(db, 'jf',
          layerId: defId,
          title: '标题🍜',
          content: '正文<b>富文本</b>\n第二行',
          media: 'a.jpg\nb.png',
          level: 'private',
          owner: 'peer-9',
          updatedAt: t);
      final files = await svc.exportToFiles({'journal'});

      final d2 = AppDb.forTesting(NativeDatabase.memory());
      addTearDown(() async => d2.close());
      await BackupService(d2).importFromFiles(files, modules: {'journal'});
      final r = (await d2.select(d2.journalEntries).get()).single;
      expect(r.uuid, 'jf');
      expect(r.title, '标题🍜');
      expect(r.richContent, '正文<b>富文本</b>\n第二行');
      expect(r.mediaPaths, 'a.jpg\nb.png');
      expect(r.level, 'private');
      expect(r.ownerPeerId, 'peer-9');
      expect(r.updatedAt, t);
    });

    test('B2 layers：colorValue/visible/tag/path* 样式字段全保真', () async {
      await db.insertLayer(TrackLayersCompanion.insert(
        uuid: const Value('lay-s'),
        name: '样式层',
        colorValue: 0xFFABCDEF,
        visible: const Value(false),
        tag: const Value('测试标签'),
        createdAt: DateTime(2026, 2, 2),
        pathColor: const Value(0xFF010203),
        pathOpacity: const Value(0.5),
        pathWidth: const Value(3.5),
      ));
      final files = await svc.exportToFiles({'layers'});

      final d2 = AppDb.forTesting(NativeDatabase.memory());
      addTearDown(() async => d2.close());
      await BackupService(d2).importFromFiles(files, modules: {'layers'});
      final l = (await d2.allLayers()).firstWhere((x) => x.uuid == 'lay-s');
      expect(l.colorValue, 0xFFABCDEF);
      expect(l.visible, isFalse);
      expect(l.tag, '测试标签');
      expect(l.pathColor, 0xFF010203);
      expect(l.pathOpacity, 0.5);
      expect(l.pathWidth, 3.5);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('C. 导入边界 / 健壮性', () {
    List<int> enc(Object o) => utf8.encode(jsonEncode(o));
    List<int> manifest([int v = BackupService.archiveVersion]) => enc({
          'version': v,
          'exportedAt': '2026-01-01T00:00:00.000',
          'modules': ['journal'],
        });
    Map<String, dynamic> journalRow(String uuid) => {
          'uuid': uuid,
          'time': '2026-01-01T00:00:00.000',
          'lat': 1.0,
          'lng': 2.0,
          'title': uuid,
          'richContent': '',
          'mediaPaths': '',
          'layerId': 1,
          'level': 'public',
          'ownerPeerId': null,
          'updatedAt': null,
        };

    test('C1 clearBeforeImport 但归档图层为空 → 不清空本地图层', () async {
      await db.insertLayer(TrackLayersCompanion.insert(
        uuid: const Value('keep-me'),
        name: '别删我',
        colorValue: 0xFF000000,
        createdAt: DateTime(2026, 1, 1),
      ));
      final files = <String, List<int>>{
        'manifest.json': manifest(),
        'layers/layers.json': utf8.encode('[]'),
      };
      await svc.importFromFiles(files,
          modules: {'layers'}, clearBeforeImport: true);
      expect((await db.allLayers()).map((l) => l.uuid), contains('keep-me'),
          reason: '空图层列表不得触发清空（否则地图全空）');
    });

    test('C2 manifest 版本高于支持版本 → 仍前向兼容导入', () async {
      final files = <String, List<int>>{
        'manifest.json': manifest(BackupService.archiveVersion + 99),
        'journal/entries.jsonl': enc(journalRow('future')),
      };
      final s = await svc.importFromFiles(files, modules: {'journal'});
      expect(await jcount(), 1);
      expect(s.errors, isEmpty);
    });

    test('C3 选择性导入：只选 journal，归档里的 song 不入库', () async {
      final files = <String, List<int>>{
        'manifest.json': manifest(),
        'journal/entries.jsonl': enc(journalRow('only-j')),
        'song_favorites/favorites.jsonl': enc({
          'uuid': 'skip-s',
          'songId': '1',
          'title': 's',
          'artist': 'a',
          'coverUrl': null,
          'source': 'gd',
          'addedAt': '2026-01-01T00:00:00.000',
          'lat': null,
          'lng': null,
        }),
      };
      await svc.importFromFiles(files, modules: {'journal'});
      expect(await jcount(), 1);
      expect((await db.select(db.songFavorites).get()), isEmpty,
          reason: '未选中的模块必须被忽略');
    });

    test('C4 完全空的 files → 抛 FormatException（不是备份）', () async {
      await expectLater(
        svc.importFromFiles(<String, List<int>>{}, modules: {'journal'}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
