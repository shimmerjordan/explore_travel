import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:explore_journal/app/startup_maintenance.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDb db;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDb.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<int> insertLayerWithEmptyUuid() async {
    final id = await db.into(db.trackLayers).insert(TrackLayersCompanion.insert(
        name: 'x', colorValue: 0xFF000000, createdAt: DateTime.now()));
    await db.customUpdate("UPDATE track_layers SET uuid = '' WHERE id = ?",
        variables: [Variable.withInt(id)]);
    return id;
  }

  Future<String> uuidOf(int id) async =>
      (await (db.select(db.trackLayers)..where((t) => t.id.equals(id)))
              .getSingle())
          .uuid;

  test('首次启动回填空 uuid 并记下 schema 版本标记', () async {
    final id = await insertLayerWithEmptyUuid();
    final prefs = await SharedPreferences.getInstance();
    expect(StartupMaintenance.needsHeal(prefs, db.schemaVersion), isTrue);

    await runStartupDbMaintenance(db, prefs: prefs, probe: false);

    expect(await uuidOf(id), isNotEmpty);
    expect(StartupMaintenance.needsHeal(prefs, db.schemaVersion), isFalse);
    expect(prefs.getInt(StartupMaintenance.prefsKey), db.schemaVersion);
  });

  test('同一 schema 版本的后续启动不再跑全表回填', () async {
    final prefs = await SharedPreferences.getInstance();
    await runStartupDbMaintenance(db, prefs: prefs, probe: false);

    final id = await insertLayerWithEmptyUuid();
    await runStartupDbMaintenance(db, prefs: prefs, probe: false);
    expect(await uuidOf(id), isEmpty, reason: '已标记过的版本不该再扫表');
  });

  test('schema 升级后重新跑一次', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(StartupMaintenance.prefsKey, db.schemaVersion - 1);
    final id = await insertLayerWithEmptyUuid();
    await runStartupDbMaintenance(db, prefs: prefs, probe: false);
    expect(await uuidOf(id), isNotEmpty);
    expect(prefs.getInt(StartupMaintenance.prefsKey), db.schemaVersion);
  });

  test('孤儿图层自愈每次启动都跑（不受标记影响）', () async {
    final prefs = await SharedPreferences.getInstance();
    await runStartupDbMaintenance(db, prefs: prefs, probe: false);

    // 造一个引用了不存在图层的点。
    await db.into(db.trackPoints).insert(TrackPointsCompanion.insert(
        layerId: 777, lat: 30, lng: 104, time: DateTime.now(), flags: const Value(0)));
    final before = (await db.allLayers()).map((l) => l.id).toSet();
    expect(before, isNot(contains(777)));

    await runStartupDbMaintenance(db, prefs: prefs, probe: false);
    final after = (await db.allLayers()).map((l) => l.id).toSet();
    expect(after, contains(777));
  });

  test('过期的队友轨迹在启动时被清理', () async {
    final prefs = await SharedPreferences.getInstance();
    await db.into(db.peerLocations).insert(PeerLocationsCompanion.insert(
        peerId: 'p',
        lat: 30,
        lng: 104,
        time: DateTime.now().subtract(const Duration(days: 45))));
    await runStartupDbMaintenance(db, prefs: prefs, probe: false);
    expect(await db.select(db.peerLocations).get(), isEmpty);
  });
}
