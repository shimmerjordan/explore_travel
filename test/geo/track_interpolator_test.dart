import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/geo/track_interpolator.dart';
import 'package:explore_journal/services/location/point_filter.dart';

void main() {
  late AppDb db;
  setUp(() => db = AppDb.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final t0 = DateTime(2026, 8, 20, 10, 0);
  Future<void> put(double lat, double lng, Duration dt, {int flags = 0}) =>
      db.insertPoint(TrackPointsCompanion.insert(
          lat: lat,
          lng: lng,
          time: t0.add(dt),
          layerId: 1,
          flags: Value(flags)));

  test('midway between two fixes interpolates linearly', () async {
    await put(30.0, 104.0, Duration.zero);
    await put(30.002, 104.002, const Duration(minutes: 10));
    final r = await TrackInterpolator.positionAt(
        db, t0.add(const Duration(minutes: 5)));
    expect(r, isNotNull);
    expect(r!.source, 'interpolated');
    expect(r.lat, closeTo(30.001, 1e-9));
    expect(r.lng, closeTo(104.001, 1e-9));
    expect(r.gap, const Duration(minutes: 5));
  });

  test('only a point before → nearest', () async {
    await put(30.0, 104.0, Duration.zero);
    final r = await TrackInterpolator.positionAt(
        db, t0.add(const Duration(minutes: 12)));
    expect(r!.source, 'nearest');
    expect(r.lat, 30.0);
    expect(r.gap, const Duration(minutes: 12));
  });

  test('nothing within tolerance → null', () async {
    await put(30.0, 104.0, Duration.zero);
    final r = await TrackInterpolator.positionAt(
        db, t0.add(const Duration(minutes: 45)));
    expect(r, isNull);
  });

  test('anomaly-flagged points are ignored', () async {
    await put(30.0, 104.0, Duration.zero);
    await put(45.0, 120.0, const Duration(minutes: 4),
        flags: PointFlags.anomaly); // teleport, flagged
    final r = await TrackInterpolator.positionAt(
        db, t0.add(const Duration(minutes: 5)));
    expect(r!.source, 'nearest');
    expect(r.lat, 30.0);
  });

  test('a big jump between the two fixes snaps to the nearer side', () async {
    // 10 km apart in 10 min = 60 km/h: a car ride. The photo at minute 2 was
    // most likely taken near the start, not on the highway.
    await put(30.0, 104.0, Duration.zero);
    await put(30.09, 104.0, const Duration(minutes: 10));
    final r = await TrackInterpolator.positionAt(
        db, t0.add(const Duration(minutes: 2)));
    expect(r!.source, 'nearest');
    expect(r.lat, 30.0);
  });
}
