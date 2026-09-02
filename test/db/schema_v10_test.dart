import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/data/db/database.dart';

/// v10: track_points.flags + places/visits + the secondary indexes every
/// analytic reader relies on. Also pins the dedup key + cleanPoints helpers.
void main() {
  late AppDb db;
  setUp(() => db = AppDb.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('indexes exist after open', () async {
    final rows = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='index'").get();
    final names = rows.map((r) => r.read<String>('name')).toSet();
    expect(names, containsAll([
      'idx_track_points_layer_time',
      'idx_track_points_time',
      'idx_visits_started',
      'idx_visits_place',
    ]));
  });

  test('flags defaults to 0 and survives a round trip', () async {
    await db.insertPoint(TrackPointsCompanion.insert(
        lat: 30, lng: 104, time: DateTime(2026, 8, 1), layerId: 1));
    await db.insertPoint(TrackPointsCompanion.insert(
        lat: 31,
        lng: 104,
        time: DateTime(2026, 8, 2),
        layerId: 1,
        flags: const Value(1)));
    final all = await db.pointsForLayer(1);
    expect(all.map((p) => p.flags), [0, 1]);
    final clean = await db.cleanPoints([1]);
    expect(clean.length, 1);
    expect(clean.single.lat, 30);
  });

  test('cleanPoints windows by time and orders by (layer, time)', () async {
    for (final (layer, day) in [(2, 3), (1, 2), (1, 1), (2, 1)]) {
      await db.insertPoint(TrackPointsCompanion.insert(
          lat: 30, lng: 104, time: DateTime(2026, 8, day), layerId: layer));
    }
    final got = await db.cleanPoints([1, 2],
        from: DateTime(2026, 8, 1), to: DateTime(2026, 8, 2));
    expect(got.map((p) => (p.layerId, p.time.day)).toList(),
        [(1, 1), (1, 2), (2, 1)]);
  });

  test('pointDedupKeys reflects existing rows', () async {
    final t = DateTime(2026, 8, 1, 12);
    await db.insertPoint(TrackPointsCompanion.insert(
        lat: 30.123456, lng: 104.654321, time: t, layerId: 1));
    final keys =
        await db.pointDedupKeys(1, DateTime(2026, 8, 1), DateTime(2026, 8, 2));
    expect(keys, {AppDb.pointDedupKey(t, 30.123456, 104.654321)});
    // Different layer → not a duplicate.
    expect(await db.pointDedupKeys(2, DateTime(2026, 8, 1), DateTime(2026, 8, 2)),
        isEmpty);
  });

  test('places/visits tables are writable', () async {
    final pid = await db.into(db.places).insert(PlacesCompanion.insert(
        name: '家', lat: 30, lng: 104, createdAt: DateTime(2026, 8, 1)));
    await db.into(db.visits).insert(VisitsCompanion.insert(
      placeId: Value(pid),
      layerId: 1,
      startedAt: DateTime(2026, 8, 1, 8),
      endedAt: DateTime(2026, 8, 1, 9),
      lat: 30,
      lng: 104,
      radius: 40,
      pointCount: 12,
      createdAt: DateTime(2026, 8, 1, 9),
    ));
    final v = await db.select(db.visits).get();
    expect(v.single.status, 0);
    expect(v.single.placeId, pid);
  });
}
