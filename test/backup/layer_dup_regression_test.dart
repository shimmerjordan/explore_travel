import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';

/// Regression for the "同步前一个图层，拉完一堆重复图层，轨迹没应用" report.
///
/// Root cause: a polluted cloud carries several same-named layers with
/// DIFFERENT uuids (old churn). The layer merge correctly collapses them to one
/// local layer — but track/journal/fog rows still reference the folded-away
/// archive ids. `remapLayerId` used to return the RAW archive id when the uuid
/// wasn't found locally, orphaning those rows; `ensureLayersForContent` then
/// recreated a phantom "图层 N" per orphan id — re-inflating the duplication AND
/// scattering the tracks onto layers the user never made.
///
/// The fix: the merge records archiveId→localId for every collapse/name-match/
/// insert, and remap falls back to that (then the default layer) instead of a
/// non-existent id. So after import there must be exactly ONE layer and every
/// track must sit on it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDb db;
  late BackupService svc;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDb.forTesting(NativeDatabase.memory());
    svc = BackupService(db);
  });
  tearDown(() async => db.close());

  List<int> enc(Object o) => utf8.encode(jsonEncode(o));

  /// A cloud whose meta.zip carries FIVE "默认图层" (distinct/absent uuids, ids
  /// 1..5 as some past device numbered them) plus tracks spread across all five
  /// archive ids — exactly the churned-cloud shape the user hit.
  Map<String, List<int>> pollutedArchive() {
    final layers = [
      for (final (i, uuid) in [
        (1, 'default-layer'),
        (2, 'dup-a'),
        (3, 'dup-b'),
        (4, 'dup-c'),
        (5, ''), // an empty-uuid historical copy
      ])
        {
          'uuid': uuid,
          'id': i,
          'name': '默认图层',
          'colorValue': 0xFF00BCD4,
          'visible': true,
          'createdAt': '2026-03-01T00:00:00.000',
          'updatedAt': '2026-06-01T12:00:00.000',
        }
    ];
    final points = [
      for (var id = 1; id <= 5; id++)
        {
          'uuid': 'tp-$id',
          'lat': 30.6 + id * 0.001,
          'lng': 104.0 + id * 0.001,
          'time': '2026-06-01T12:0$id:00.000',
          'layerId': id,
        }
    ];
    return {
      'manifest.json': enc({'version': 3, 'modules': []}),
      'layers/layers.json': enc(layers),
      'track_points/2026-06.jsonl':
          utf8.encode(points.map(jsonEncode).join('\n')),
    };
  }

  test('polluted cloud (5×默认图层 + 轨迹跨5个id) → ONE layer, NO orphan tracks',
      () async {
    // The device before syncing: exactly one default layer (id 1).
    final before = await db.allLayers();
    expect(before.length, 1, reason: 'onCreate seeds a single default layer');

    await svc.importFromFiles(
      pollutedArchive(),
      modules: {'layers', 'track_points'},
    );

    final layers = await db.allLayers();
    // 1) No duplication: the five same-named copies collapse to one.
    expect(layers.length, 1,
        reason: '5 个同名默认图层必须折叠成 1 个，实际=${layers.map((l) => '${l.id}:${l.name}').toList()}');
    // 2) No phantom "图层 N" recovery layers.
    expect(layers.where((l) => l.name.startsWith('图层 ')), isEmpty,
        reason: 'ensureLayersForContent 不应重建幻影图层');

    // 3) Every track landed on a REAL, existing layer (item 3: 路径应用了).
    final layerIds = layers.map((l) => l.id).toSet();
    final points = await db.select(db.trackPoints).get();
    expect(points.length, 5);
    for (final p in points) {
      expect(layerIds.contains(p.layerId), isTrue,
          reason: 'track ${p.uuid} 落在不存在的图层 ${p.layerId} 上（孤儿）');
    }
    // And that layer is the surviving default.
    expect(points.map((p) => p.layerId).toSet(), {layers.single.id});
  });

  test('a genuinely DISTINCT layer is NOT collapsed into the default',
      () async {
    final files = pollutedArchive();
    // Add a real second layer + a track on it.
    final layers = (jsonDecode(utf8.decode(files['layers/layers.json']!))
        as List)
      ..add({
        'uuid': 'layer-hike',
        'id': 9,
        'name': '徒步路线',
        'colorValue': 0xFF11AA22,
        'visible': true,
        'createdAt': '2026-03-01T00:00:00.000',
        'updatedAt': '2026-06-01T12:00:00.000',
      });
    files['layers/layers.json'] = enc(layers);
    files['track_points/2026-06.jsonl'] = utf8.encode([
      ...('12345'.split('').map((d) => {
            'uuid': 'tp-$d',
            'lat': 30.6,
            'lng': 104.0,
            'time': '2026-06-01T12:0$d:00.000',
            'layerId': int.parse(d),
          })),
      {
        'uuid': 'tp-hike',
        'lat': 30.7,
        'lng': 104.1,
        'time': '2026-06-01T13:00:00.000',
        'layerId': 9,
      },
    ].map(jsonEncode).join('\n'));

    await svc.importFromFiles(files, modules: {'layers', 'track_points'});

    final byName = <String, List<TrackLayer>>{};
    for (final l in await db.allLayers()) {
      (byName[l.name] ??= []).add(l);
    }
    expect(byName['默认图层']?.length, 1, reason: '默认图层折叠成 1');
    expect(byName['徒步路线']?.length, 1, reason: '独立图层保留');
    expect(byName.keys.where((n) => n.startsWith('图层 ')), isEmpty);

    // The hike track must be on the hike layer, not the default.
    final hike = byName['徒步路线']!.single;
    final points = await db.select(db.trackPoints).get();
    final hikePt = points.firstWhere((p) => p.uuid == 'tp-hike');
    expect(hikePt.layerId, hike.id);
    // No orphans anywhere.
    final layerIds = (await db.allLayers()).map((l) => l.id).toSet();
    expect(points.every((p) => layerIds.contains(p.layerId)), isTrue);
  });
}
