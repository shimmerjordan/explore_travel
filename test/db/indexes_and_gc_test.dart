import 'package:drift/native.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDb db;
  setUp(() => db = AppDb.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<Set<String>> indexNames() async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
        .get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  Future<String> plan(String sql) async {
    final rows = await db.customSelect('EXPLAIN QUERY PLAN $sql').get();
    return rows.map((r) => r.read<String>('detail')).join(' | ');
  }

  group('secondary indexes', () {
    test('热路径读者都有索引', () async {
      final names = await indexNames();
      expect(
          names,
          containsAll([
            'idx_track_points_layer_time',
            'idx_fog_tiles_layer_zoom',
            'idx_journal_time',
            'idx_journal_layer',
            'idx_journal_uuid',
            'idx_track_points_lat_lng',
            'idx_peer_locations_time',
            'idx_fog_erases_layer',
          ]));
    });

    test('fog_tiles 按 layer+zoom 查询走索引而非全表扫描', () async {
      final p = await plan(
          'SELECT * FROM fog_tiles WHERE layer_id IN (1,2) AND zoom = 14');
      expect(p, contains('idx_fog_tiles_layer_zoom'));
      expect(p, isNot(contains('SCAN fog_tiles')));
    });

    test('fog_tiles 视口范围查询走索引', () async {
      final p = await plan('SELECT * FROM fog_tiles WHERE layer_id IN (1) '
          'AND zoom = 14 AND tile_x BETWEEN 10 AND 20 AND tile_y BETWEEN 5 AND 9');
      expect(p, contains('idx_fog_tiles_layer_zoom'));
    });

    test('最近手账按时间倒序不再临时排序', () async {
      final p = await plan(
          'SELECT * FROM journal_entries ORDER BY time DESC LIMIT 100');
      expect(p, contains('idx_journal_time'));
      expect(p, isNot(contains('TEMP B-TREE')));
    });

    test('橡皮擦 bbox 扫描走 lat/lng 索引', () async {
      final p = await plan('SELECT id FROM track_points '
          'WHERE lat BETWEEN 30.0 AND 30.1 AND lng BETWEEN 104.0 AND 104.1');
      expect(p, contains('idx_track_points_lat_lng'));
    });
  });

  group('peer_locations', () {
    PeerLocationsCompanion row(String peer, DateTime t) =>
        PeerLocationsCompanion.insert(
            peerId: peer, lat: 30, lng: 104, time: t);

    test('窗口查询只返回窗口内、按时间升序', () async {
      final base = DateTime(2026, 9, 1, 12);
      await db.into(db.peerLocations).insert(row('a', base));
      await db
          .into(db.peerLocations)
          .insert(row('b', base.add(const Duration(hours: 2))));
      await db
          .into(db.peerLocations)
          .insert(row('a', base.add(const Duration(hours: 1))));
      await db
          .into(db.peerLocations)
          .insert(row('a', base.add(const Duration(days: 3))));

      final got = await db.peerLocationsBetween(
          base.subtract(const Duration(minutes: 1)),
          base.add(const Duration(hours: 3)));
      expect(got.map((r) => r.time).toList(),
          [base, base.add(const Duration(hours: 1)), base.add(const Duration(hours: 2))]);
    });

    test('GC 只删过期行，没有过期行时零写入', () async {
      final now = DateTime.now();
      await db
          .into(db.peerLocations)
          .insert(row('a', now.subtract(const Duration(days: 40))));
      await db
          .into(db.peerLocations)
          .insert(row('a', now.subtract(const Duration(days: 1))));

      expect(await db.gcPeerLocations(keep: const Duration(days: 30)), 1);
      expect(await db.gcPeerLocations(keep: const Duration(days: 30)), 0);
      final left = await db.select(db.peerLocations).get();
      expect(left.length, 1);
      expect(left.single.time.isAfter(now.subtract(const Duration(days: 2))),
          isTrue);
    });
  });

  group('FogEngine batch writes', () {
    Future<int> newLayer() => db.insertLayer(TrackLayersCompanion.insert(
        name: 'L', colorValue: 0xFF00BCD4, createdAt: DateTime.now()));

    int popcount(List<int> b) => b.fold(0, (n, v) {
          var x = v;
          while (x != 0) {
            n++;
            x &= x - 1;
          }
          return n;
        });

    test('同一线段重复 reveal 是幂等的：第二次不写库、不发事件', () async {
      final lid = await newLayer();
      final fog = FogEngine(db);
      final events = <List<FogTile>>[];
      final sub = fog.changes.listen(events.add);

      await fog.revealLine(
          lat0: 30.0, lng0: 104.0, lat1: 30.0, lng1: 104.002,
          radiusMeters: 12, layerId: lid);
      await Future<void>.delayed(Duration.zero);
      final first = await db.fogTilesForLayers([lid], FogEngine.tileZoom);
      expect(first, isNotEmpty);
      expect(events.length, 1);
      expect(events.single.length, first.length);

      await fog.revealLine(
          lat0: 30.0, lng0: 104.0, lat1: 30.0, lng1: 104.002,
          radiusMeters: 12, layerId: lid);
      await Future<void>.delayed(Duration.zero);
      final second = await db.fogTilesForLayers([lid], FogEngine.tileZoom);
      expect(events.length, 1, reason: '位图没变就不该再发 delta');
      for (final a in first) {
        final b = second.singleWhere(
            (t) => t.tileX == a.tileX && t.tileY == a.tileY);
        expect(b.bitmap, a.bitmap);
        expect(b.updatedAt, a.updatedAt, reason: '未变的行不该刷新 updatedAt');
      }
      await sub.cancel();
    });

    test('后一次 reveal 与前一次取并集，且事件里的位图与库中一致', () async {
      final lid = await newLayer();
      final fog = FogEngine(db);
      await fog.revealPoint(lat: 30.0, lng: 104.0, radiusMeters: 15, layerId: lid);
      final before = await db.fogTilesForLayers([lid], FogEngine.tileZoom);
      final bitsBefore = before.fold(0, (n, t) => n + popcount(t.bitmap));

      final events = <FogTile>[];
      final sub = fog.changes.listen(events.addAll);
      await fog.revealPoint(
          lat: 30.0001, lng: 104.0001, radiusMeters: 15, layerId: lid);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      final after = await db.fogTilesForLayers([lid], FogEngine.tileZoom);
      final bitsAfter = after.fold(0, (n, t) => n + popcount(t.bitmap));
      expect(bitsAfter, greaterThan(bitsBefore));
      for (final t in before) {
        final now = after.singleWhere(
            (x) => x.tileX == t.tileX && x.tileY == t.tileY);
        for (var i = 0; i < t.bitmap.length; i++) {
          expect(now.bitmap[i] & t.bitmap[i], t.bitmap[i],
              reason: '旧位不能丢');
        }
      }
      for (final e in events) {
        final row = after.singleWhere(
            (x) => x.tileX == e.tileX && x.tileY == e.tileY);
        expect(e.bitmap, row.bitmap);
      }
    });

    test('erase 仍逐块记录擦除掩码并清位', () async {
      final lid = await newLayer();
      final fog = FogEngine(db);
      await fog.revealPoint(lat: 30.0, lng: 104.0, radiusMeters: 20, layerId: lid);
      await fog.erase(lat: 30.0, lng: 104.0, radiusMeters: 40, layerId: lid);
      final tiles = await db.fogTilesForLayers([lid], FogEngine.tileZoom);
      expect(tiles.fold(0, (n, t) => n + popcount(t.bitmap)), 0);
      final masks = await db.select(db.fogErases).get();
      expect(masks, isNotEmpty);
      expect(masks.fold(0, (n, m) => n + popcount(m.mask)), greaterThan(0));
    });
  });
}
