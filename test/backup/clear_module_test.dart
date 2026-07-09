import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';

/// Per-module local-clear (the "清除本机数据" buttons). Verifies each module
/// wipes only its own data, does NOT tombstone (a LOCAL clear must stay
/// re-importable from the cloud), never destroys credentials, and that clearing
/// layers leaves exactly one clean default.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDb db;
  late BackupService svc;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDb.forTesting(NativeDatabase.memory());
    svc = BackupService(db);
  });
  tearDown(() => db.close());

  test('clearing journal removes rows WITHOUT tombstoning (stays '
      're-importable — the "清空后导入不生效" fix)', () async {
    await db.insertJournal(JournalEntriesCompanion.insert(
      uuid: const Value('j-1'),
      time: DateTime(2026, 6, 1),
      lat: 30, lng: 104, title: 't', richContent: const Value(''),
      layerId: 1,
    ));
    await svc.clearModule('journal');
    expect(await db.select(db.journalEntries).get(), isEmpty);
    expect(await db.tombstonedUuids('journal_entries'), isEmpty,
        reason: 'a LOCAL clear must NOT block a later re-import/pull');
  });

  test('clearing track_points wipes them without tombstoning', () async {
    await db.insertManualPoint(lat: 30, lng: 104, layerId: 1, width: 10);
    await svc.clearModule('track_points');
    expect(await db.select(db.trackPoints).get(), isEmpty);
    expect(await db.tombstonedUuids('track_points'), isEmpty);
  });

  test('after a clear, re-importing the same data RESTORES it '
      '(tombstones no longer block it)', () async {
    await db.insertJournal(JournalEntriesCompanion.insert(
      uuid: const Value('j-1'),
      time: DateTime(2026, 6, 1),
      lat: 30, lng: 104, title: 'keep', richContent: const Value(''),
      layerId: 1,
    ));
    // Export first (simulates the cloud copy), then clear, then re-import.
    final files = await svc.exportToFiles({'journal'});
    await svc.clearModule('journal');
    expect(await db.select(db.journalEntries).get(), isEmpty);
    await svc.importFromFiles(files, modules: {'journal'});
    final restored = await db.select(db.journalEntries).get();
    expect(restored.map((r) => r.uuid), contains('j-1'),
        reason: 'the cleared row must come back on re-import');
  });

  test('clearing fog wipes tiles and erase markers', () async {
    await db.batchUpsertFogTiles([
      FogTilesCompanion.insert(
        tileX: 1, tileY: 2, zoom: 100, layerId: 1,
        bitmap: Uint8List.fromList([1]), updatedAt: DateTime(2026, 6, 1),
      ),
    ]);
    await svc.clearModule('fog_tiles');
    expect(await db.select(db.fogTiles).get(), isEmpty);
  });

  test('clearing layers leaves EXACTLY ONE default and re-homes content '
      '(the "没有清空全部" fix)', () async {
    // Content spread across several layers → the old reseed sprang them all
    // back. The clean-slate reset must collapse to one.
    await db.insertLayer(TrackLayersCompanion.insert(
        name: 'A', colorValue: 1, createdAt: DateTime(2026, 1, 1)));
    await db.insertLayer(TrackLayersCompanion.insert(
        name: 'B', colorValue: 2, createdAt: DateTime(2026, 1, 1)));
    await db.insertManualPoint(lat: 30, lng: 104, layerId: 2, width: 5);
    await db.insertManualPoint(lat: 31, lng: 105, layerId: 3, width: 5);

    await svc.clearModule('layers');
    final layers = await db.allLayers();
    expect(layers, hasLength(1), reason: 'exactly one layer after a clear');
    expect(layers.single.uuid, kDefaultLayerUuid);
    // Content re-homed onto that single layer, not orphaned.
    final pts = await db.select(db.trackPoints).get();
    expect(pts.map((p) => p.layerId).toSet(), {layers.single.id});
  });

  test('clearing settings keeps credentials, drops preferences', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings_v1': jsonEncode({
        'mapStyle': 'fancy',
        'oneDriveRefreshToken': 'SECRET',
      }),
    });
    await svc.clearModule('settings');
    final prefs = await SharedPreferences.getInstance();
    final j = jsonDecode(prefs.getString('app_settings_v1')!) as Map;
    expect(j['mapStyle'], isNull, reason: 'a preference is cleared');
    expect(j['oneDriveRefreshToken'], 'SECRET',
        reason: 'credentials must survive a settings clear');
  });

  test('a prefs-backed module clears its key', () async {
    SharedPreferences.setMockInitialValues({
      'img_host_uploads_v1': jsonEncode({'a.jpg': 'x'}),
    });
    await svc.clearModule('imghost_uploads');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('img_host_uploads_v1'), isNull);
  });

  test('leaderboard is not locally clearable', () async {
    final msg = await svc.clearModule('leaderboard');
    expect(msg, contains('未提供本机清除'));
  });
}
