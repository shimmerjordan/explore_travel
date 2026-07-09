import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';

/// Merge-semantics tests that hit [BackupService.importFromFiles] directly —
/// no sync engine, no transport — so every module's row-level behaviour
/// (LWW, dedup, fault tolerance, prefs-backed modules) is pinned on its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDb db;
  late BackupService svc;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDb.forTesting(NativeDatabase.memory());
    svc = BackupService(db);
  });

  tearDown(() async {
    await db.close();
  });

  List<int> jsonBytes(Object o) => utf8.encode(jsonEncode(o));
  List<int> manifest({int version = 3}) => jsonBytes({'version': version});
  List<int> jsonl(List<Object> rows) =>
      utf8.encode(rows.map((r) => r is String ? r : jsonEncode(r)).join('\n'));

  Map<String, Object?> journalRow(String uuid, String title,
          {int layerId = 1, String? updatedAt}) =>
      {
        'uuid': uuid,
        'time': '2026-06-01T08:00:00',
        'lat': 30.0,
        'lng': 104.0,
        'title': title,
        'richContent': '',
        'mediaPaths': '',
        'layerId': layerId,
        'level': 'public',
        'ownerPeerId': null,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };

  group('row-level fault tolerance（坏行不拖垮模块）', () {
    test('a corrupt journal line is skipped, the rows after it still import',
        () async {
      final files = <String, List<int>>{
        'manifest.json': manifest(),
        'journal/entries.jsonl': jsonl([
          journalRow('j-1', 'first'),
          // lat is null — the old code threw here and lost every later row.
          {...journalRow('j-2', 'broken'), 'lat': null},
          journalRow('j-3', 'third'),
        ]),
      };
      final s = await svc.importFromFiles(files, modules: {'journal'});
      final titles =
          (await db.select(db.journalEntries).get()).map((r) => r.title);
      expect(titles, containsAll(['first', 'third']));
      expect(titles, isNot(contains('broken')));
      expect(s.imported['journal'], 2);
      expect(s.errors['journal'], contains('1 行损坏'));
    });

    test('a non-JSON layers row is skipped, later layers still import',
        () async {
      final files = <String, List<int>>{
        'manifest.json': manifest(),
        'layers/layers.json': jsonBytes([
          {
            'uuid': 'l-good',
            'name': 'GOOD',
            'colorValue': 1,
            'visible': true,
            'createdAt': '2026-06-01T00:00:00',
          },
          // createdAt as a list makes DateTime.tryParse(...toString()) fine,
          // so break it harder: colorValue map → `as num?` throws.
          {
            'uuid': 'l-bad',
            'name': 'BAD',
            'colorValue': {'nope': true},
            'visible': true,
            'createdAt': '2026-06-01T00:00:00',
          },
          {
            'uuid': 'l-good2',
            'name': 'GOOD2',
            'colorValue': 2,
            'visible': true,
            'createdAt': '2026-06-01T00:00:00',
          },
        ]),
      };
      final s = await svc.importFromFiles(files, modules: {'layers'});
      final names = (await db.allLayers()).map((l) => l.name);
      expect(names, containsAll(['GOOD', 'GOOD2']));
      expect(names, isNot(contains('BAD')));
      expect(s.errors['layers'], contains('1 行损坏'));
    });

    test('a corrupt track point is skipped, the batch still lands', () async {
      final files = <String, List<int>>{
        'manifest.json': manifest(),
        'track_points/2026-06.jsonl': jsonl([
          {
            'uuid': 'p-1',
            'lat': 30.0,
            'lng': 104.0,
            'time': '2026-06-01T08:00:00',
            'layerId': 1,
          },
          'this is not json at all',
          {
            'uuid': 'p-2',
            'lat': 30.1,
            'lng': 104.1,
            'time': '2026-06-01T09:00:00',
            'layerId': 1,
          },
        ]),
      };
      final s = await svc.importFromFiles(files, modules: {'track_points'});
      expect((await db.select(db.trackPoints).get()).length, 2);
      expect(s.errors['track_points'], contains('1 行损坏'));
    });
  });

  group('legacy v2 archives（老布局云端/备份仍可导入）', () {
    test('fog/<layerId>/*.bin + v1 index + no id/updatedAt fields', () async {
      final bmp = Uint8List(512)..[0] = 0xAA;
      final files = <String, List<int>>{
        'manifest.json': manifest(version: 2),
        'layers/layers.json': jsonBytes([
          {
            // v2 layers had no 'id' and no 'updatedAt'.
            'uuid': 'legacy-layer',
            'name': 'LEGACY',
            'colorValue': 0xFF112233,
            'visible': true,
            'tag': null,
            'createdAt': '2026-01-01T00:00:00',
          },
        ]),
        'journal/entries.jsonl': jsonl([
          // v2 journal rows had no 'updatedAt'.
          journalRow('legacy-j', 'legacy entry'),
        ]),
        'track_points/2026-01.jsonl': jsonl([
          {
            'uuid': 'legacy-p',
            'lat': 31.0,
            'lng': 105.0,
            'time': '2026-01-02T10:00:00',
            'accuracy': 5.0,
            'layerId': 1,
          },
        ]),
        'fog/1/1283_2564_100.bin': bmp,
        'fog/index.json': jsonBytes([
          {
            'layerId': 1,
            'tileX': 1283,
            'tileY': 2564,
            'zoom': 100,
            'updatedAt': '2026-01-02T10:00:00',
          },
        ]),
      };
      final s = await svc.importFromFiles(files,
          modules: {'layers', 'journal', 'track_points', 'fog_tiles'});

      expect((await db.allLayers()).map((l) => l.name), contains('LEGACY'));
      expect((await db.select(db.journalEntries).get()).single.title,
          'legacy entry');
      expect((await db.select(db.trackPoints).get()).single.uuid, 'legacy-p');
      final fog = (await db.select(db.fogTiles).get()).single;
      expect(fog.tileX, 1283);
      expect(fog.bitmap[0], 0xAA);
      expect(fog.updatedAt, DateTime.parse('2026-01-02T10:00:00'),
          reason: 'v1 sidecar timestamp must be preserved');
      expect(s.errors, isEmpty);
    });
  });

  group('settings LWW（应用设置按时间戳合并）', () {
    final cloudSettings = utf8.encode(jsonEncode({'mapStyle': 'cloudy'}));

    test('fresh device applies cloud settings and adopts its timestamp',
        () async {
      final s = await svc.importFromFiles({
        'manifest.json': manifest(),
        'settings/app_settings.json': cloudSettings,
        'settings/meta.json': jsonBytes({'updatedAt': '2026-06-01T00:00:00'}),
      }, modules: {
        'settings'
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_settings_v1'), contains('cloudy'));
      expect(prefs.getString('settings_updated_at'),
          startsWith('2026-06-01T00:00:00'));
      expect(s.imported['settings'], 1);
    });

    test('NEWER local settings survive an older cloud copy', () async {
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({'mapStyle': 'localnew'}),
        'settings_updated_at': '2026-06-02T00:00:00',
      });
      final s = await svc.importFromFiles({
        'manifest.json': manifest(),
        'settings/app_settings.json': cloudSettings,
        'settings/meta.json': jsonBytes({'updatedAt': '2026-06-01T00:00:00'}),
      }, modules: {
        'settings'
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_settings_v1'), contains('localnew'),
          reason: 'older cloud settings must NOT clobber newer local ones');
      expect(s.skipped['settings'], 1);
    });

    test('newer cloud settings replace older local ones', () async {
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({'mapStyle': 'localold'}),
        'settings_updated_at': '2026-05-01T00:00:00',
      });
      await svc.importFromFiles({
        'manifest.json': manifest(),
        'settings/app_settings.json': cloudSettings,
        'settings/meta.json': jsonBytes({'updatedAt': '2026-06-01T00:00:00'}),
      }, modules: {
        'settings'
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_settings_v1'), contains('cloudy'));
      expect(prefs.getString('settings_updated_at'),
          startsWith('2026-06-01T00:00:00'));
    });

    test('explicit restore (clearBeforeImport) forces the cloud copy',
        () async {
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({'mapStyle': 'localnew'}),
        'settings_updated_at': '2026-06-02T00:00:00',
      });
      await svc.importFromFiles(
        {
          'manifest.json': manifest(),
          'settings/app_settings.json': cloudSettings,
          'settings/meta.json':
              jsonBytes({'updatedAt': '2026-06-01T00:00:00'}),
        },
        modules: {'settings'},
        clearBeforeImport: true,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_settings_v1'), contains('cloudy'));
    });

    test('legacy archive without meta.json: applies on a fresh device, '
        'keeps local once the user has edited settings', () async {
      // Fresh device → apply.
      await svc.importFromFiles({
        'manifest.json': manifest(version: 2),
        'settings/app_settings.json': cloudSettings,
      }, modules: {
        'settings'
      });
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_settings_v1'), contains('cloudy'));

      // Edited-locally device → keep local.
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({'mapStyle': 'localnew'}),
        'settings_updated_at': '2026-06-02T00:00:00',
      });
      final s = await svc.importFromFiles({
        'manifest.json': manifest(version: 2),
        'settings/app_settings.json': cloudSettings,
      }, modules: {
        'settings'
      });
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_settings_v1'), contains('localnew'));
      expect(s.skipped['settings'], 1);
    });

    test('a restore must NOT wipe local credentials (exports scrub secrets '
        'to null — the OneDrive token used to vanish on every restore)',
        () async {
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({
          'mapStyle': 'localold',
          'oneDriveRefreshToken': 'KEEP-ME',
          'webdavPass': 'ALSO-KEEP',
        }),
        'settings_updated_at': '2026-05-01T00:00:00',
      });
      await svc.importFromFiles({
        'manifest.json': manifest(),
        // What a real export looks like: secrets scrubbed to null.
        'settings/app_settings.json': utf8.encode(jsonEncode({
          'mapStyle': 'cloudy',
          'oneDriveRefreshToken': null,
          'webdavPass': null,
        })),
        'settings/meta.json': jsonBytes({'updatedAt': '2026-06-01T00:00:00'}),
      }, modules: {
        'settings'
      });
      final prefs = await SharedPreferences.getInstance();
      final applied =
          jsonDecode(prefs.getString('app_settings_v1')!) as Map;
      expect(applied['mapStyle'], 'cloudy',
          reason: 'non-secret fields must apply');
      expect(applied['oneDriveRefreshToken'], 'KEEP-ME',
          reason: 'the local OneDrive login must survive a restore');
      expect(applied['webdavPass'], 'ALSO-KEEP');
    });

    test('forced restore (clearBeforeImport) keeps credentials too',
        () async {
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({
          'mapStyle': 'localnew',
          'oneDriveRefreshToken': 'KEEP-ME',
        }),
        'settings_updated_at': '2026-06-02T00:00:00',
      });
      await svc.importFromFiles(
        {
          'manifest.json': manifest(),
          'settings/app_settings.json': utf8.encode(jsonEncode(
              {'mapStyle': 'cloudy', 'oneDriveRefreshToken': null})),
          'settings/meta.json':
              jsonBytes({'updatedAt': '2026-06-01T00:00:00'}),
        },
        modules: {'settings'},
        clearBeforeImport: true,
      );
      final prefs = await SharedPreferences.getInstance();
      final applied =
          jsonDecode(prefs.getString('app_settings_v1')!) as Map;
      expect(applied['mapStyle'], 'cloudy');
      expect(applied['oneDriveRefreshToken'], 'KEEP-ME');
    });

    test('a scrubFailed settings stub never overwrites local settings',
        () async {
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({'mapStyle': 'mine'}),
      });
      final s = await svc.importFromFiles({
        'manifest.json': manifest(),
        'settings/app_settings.json':
            utf8.encode(jsonEncode({'scrubFailed': true})),
        'settings/meta.json': jsonBytes({'updatedAt': '2027-01-01T00:00:00'}),
      }, modules: {
        'settings'
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_settings_v1'), contains('mine'));
      expect(s.skipped['settings'], 1);
    });

    test('exportToFiles ships settings/meta.json with the LWW stamp',
        () async {
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({'mapStyle': 'mine'}),
        'settings_updated_at': '2026-06-03T00:00:00',
      });
      final files = await svc.exportToFiles({'settings'});
      expect(files, contains('settings/app_settings.json'));
      final meta = jsonDecode(utf8.decode(files['settings/meta.json']!))
          as Map<String, dynamic>;
      expect(meta['updatedAt'], '2026-06-03T00:00:00');
    });
  });

  group('imghost registry merge（图床记录不再被覆盖丢失）', () {
    test('local and cloud registries union, cloud wins per key', () async {
      SharedPreferences.setMockInitialValues({
        'img_host_uploads_v1':
            jsonEncode({'local.jpg': 'L', 'both.jpg': 'LOCAL'}),
      });
      await svc.importFromFiles({
        'manifest.json': manifest(),
        'imghost_uploads/registry.json':
            jsonBytes({'cloud.jpg': 'C', 'both.jpg': 'CLOUD'}),
      }, modules: {
        'imghost_uploads'
      });
      final prefs = await SharedPreferences.getInstance();
      final merged =
          jsonDecode(prefs.getString('img_host_uploads_v1')!) as Map;
      expect(merged['local.jpg'], 'L',
          reason: 'local-only records must survive the merge');
      expect(merged['cloud.jpg'], 'C');
      expect(merged['both.jpg'], 'CLOUD');
    });

    test('clearBeforeImport replaces the registry outright', () async {
      SharedPreferences.setMockInitialValues({
        'img_host_uploads_v1': jsonEncode({'local.jpg': 'L'}),
      });
      await svc.importFromFiles(
        {
          'manifest.json': manifest(),
          'imghost_uploads/registry.json': jsonBytes({'cloud.jpg': 'C'}),
        },
        modules: {'imghost_uploads'},
        clearBeforeImport: true,
      );
      final prefs = await SharedPreferences.getInstance();
      final merged =
          jsonDecode(prefs.getString('img_host_uploads_v1')!) as Map;
      expect(merged.containsKey('local.jpg'), isFalse);
      expect(merged['cloud.jpg'], 'C');
    });
  });

  group('partial sync sets（diff 拉取只带部分分片）', () {
    test('a file set WITHOUT manifest.json still imports (diffed pull may '
        'skip the meta shard)', () async {
      final s = await svc.importFromFiles({
        'journal/entries.jsonl': jsonl([journalRow('pj-1', 'partial')]),
      }, modules: {
        'journal'
      });
      expect((await db.select(db.journalEntries).get()).single.title,
          'partial');
      expect(s.imported['journal'], 1);
    });

    test('a completely foreign file set is still rejected', () async {
      expect(
        () => svc.importFromFiles({
          'random.txt': utf8.encode('hello'),
        }, modules: {
          'journal'
        }),
        throwsFormatException,
      );
    });
  });

  group('merge into a device that already has data', () {
    test('known uuids without timestamps stay put; unknown rows insert',
        () async {
      await db.insertJournal(JournalEntriesCompanion.insert(
        uuid: const Value('j-known'),
        time: DateTime(2026, 6, 1),
        lat: 30,
        lng: 104,
        title: 'local title',
        richContent: const Value(''),
        layerId: 1,
      ));
      final s = await svc.importFromFiles({
        'manifest.json': manifest(),
        'journal/entries.jsonl': jsonl([
          journalRow('j-known', 'cloud title'), // no updatedAt → no info
          journalRow('j-new', 'brand new'),
        ]),
      }, modules: {
        'journal'
      });
      final rows = await db.select(db.journalEntries).get();
      expect(rows.firstWhere((r) => r.uuid == 'j-known').title, 'local title',
          reason: 'timestamp-less known rows must not be overwritten');
      expect(rows.map((r) => r.title), contains('brand new'));
      expect(s.imported['journal'], 1);
      expect(s.skipped['journal'], 1);
    });

    test('duplicate local uuids do not abort the journal module', () async {
      // Two clones of the same uuid (historical double-import).
      for (var i = 0; i < 2; i++) {
        await db.insertJournal(JournalEntriesCompanion.insert(
          uuid: const Value('dup'),
          time: DateTime(2026, 6, 1),
          lat: 30,
          lng: 104,
          title: 'clone $i',
          richContent: const Value(''),
          layerId: 1,
        ));
      }
      final s = await svc.importFromFiles({
        'manifest.json': manifest(),
        'journal/entries.jsonl': jsonl([
          journalRow('dup', 'newer cloud', updatedAt: '2026-06-05T00:00:00'),
          journalRow('after-dup', 'must still import'),
        ]),
      }, modules: {
        'journal'
      });
      expect(
          (await db.select(db.journalEntries).get()).map((r) => r.title),
          contains('must still import'),
          reason: 'the row after the dup must not be lost');
      expect(s.errors['journal'], anyOf(isNull, contains('行损坏')));
    });
  });

  group('clearBeforeImport replaces local content', () {
    test('local rows vanish, archive rows land', () async {
      await db.insertJournal(JournalEntriesCompanion.insert(
        uuid: const Value('old-local'),
        time: DateTime(2026, 5, 1),
        lat: 30,
        lng: 104,
        title: 'doomed',
        richContent: const Value(''),
        layerId: 1,
      ));
      await svc.importFromFiles(
        {
          'manifest.json': manifest(),
          'journal/entries.jsonl': jsonl([journalRow('fresh', 'restored')]),
        },
        modules: {'journal'},
        clearBeforeImport: true,
      );
      final rows = await db.select(db.journalEntries).get();
      expect(rows.map((r) => r.title), ['restored']);
    });
  });

  group('layer dedup by name（uuid 分叉的同名图层不再无限重复）', () {
    Map<String, Object?> layerRow(String uuid, String name,
            {String? updatedAt}) =>
        {
          'uuid': uuid,
          'id': 1,
          'name': name,
          'colorValue': 0xFF00BCD4,
          'visible': true,
          'tag': null,
          'createdAt': '2026-06-01T00:00:00',
          if (updatedAt != null) 'updatedAt': updatedAt,
        };

    test('a same-named layer with a DIFFERENT uuid reuses the local layer '
        'and converges its uuid — no duplicate', () async {
      // Fresh DB: default layer id 1, uuid 'default-layer', name '默认图层'.
      final before = await db.allLayers();
      expect(before, hasLength(1));
      expect(before.single.name, '默认图层');

      // Cloud carries the "same" default layer minted with a foreign uuid
      // (the pre-stable-uuid history that caused unbounded duplication).
      await svc.importFromFiles({
        'manifest.json': manifest(),
        'layers/layers.json':
            jsonBytes([layerRow('foreign-default-uuid', '默认图层')]),
      }, modules: {'layers'});

      final after = await db.allLayers();
      expect(after, hasLength(1), reason: 'name-match reused, no duplicate');
      expect(after.single.uuid, 'foreign-default-uuid',
          reason: 'local uuid converges to the incoming one so future pulls '
              'match by uuid and never duplicate again');
    });

    test('importing the same divergent-uuid layer TWICE stays at one layer',
        () async {
      final files = {
        'manifest.json': manifest(),
        'layers/layers.json':
            jsonBytes([layerRow('foreign-default-uuid', '默认图层')]),
      };
      await svc.importFromFiles(files, modules: {'layers'});
      await svc.importFromFiles(files, modules: {'layers'});
      expect(await db.allLayers(), hasLength(1),
          reason: 'second pull matches by the now-converged uuid');
    });

    test('a cloud carrying MANY same-named layers collapses to one '
        '(incoming-incoming dedup — polluted cloud)', () async {
      // The cloud itself holds 5 "默认图层" (old churn). A single pull must not
      // reproduce that pollution locally.
      await svc.importFromFiles({
        'manifest.json': manifest(),
        'layers/layers.json': jsonBytes([
          for (var i = 0; i < 5; i++) layerRow('churn-uuid-$i', '默认图层'),
        ]),
      }, modules: {'layers'});
      final after = await db.allLayers();
      expect(after.where((l) => l.name == '默认图层'), hasLength(1),
          reason: 'five cloud copies fold onto the single local default');
    });

    test('a genuinely new-named layer is still inserted', () async {
      await svc.importFromFiles({
        'manifest.json': manifest(),
        'layers/layers.json':
            jsonBytes([layerRow('brand-new-uuid', '徒步路线')]),
      }, modules: {'layers'});
      final after = await db.allLayers();
      expect(after, hasLength(2));
      expect(after.map((l) => l.name).toSet(), {'默认图层', '徒步路线'});
    });

    test('an empty-uuid incoming layer name-matches instead of '
        'inserting a fresh copy every pull', () async {
      final files = {
        'manifest.json': manifest(),
        'layers/layers.json': jsonBytes([layerRow('', '默认图层')]),
      };
      await svc.importFromFiles(files, modules: {'layers'});
      await svc.importFromFiles(files, modules: {'layers'});
      expect(await db.allLayers(), hasLength(1),
          reason: 'empty-uuid used to insert unconditionally on every pull');
    });
  });
}
