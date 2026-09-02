import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/stats/footprint_summary.dart';

FootprintInput input(List<(double lat, double lng, DateTime t, int layer)> pts,
    {int tzOffsetMs = 8 * 3600 * 1000}) {
  pts.sort((a, b) {
    final c = a.$4.compareTo(b.$4);
    return c != 0 ? c : a.$3.compareTo(b.$3);
  });
  return FootprintInput(
    Float64List.fromList([for (final p in pts) p.$1]),
    Float64List.fromList([for (final p in pts) p.$2]),
    Int64List.fromList([for (final p in pts) p.$3.millisecondsSinceEpoch]),
    Int32List.fromList([for (final p in pts) p.$4]),
    tzOffsetMs,
  );
}

void main() {
  // All times constructed as UTC so the +8 h offset is deterministic.
  DateTime at(int y, int m, int d, int h, [int min = 0]) =>
      DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 8));

  test('empty', () {
    final s = computeFootprint(input([]));
    expect(s.totalMeters, 0);
    expect(s.recordedDays, 0);
    expect(s.currentStreak(DateTime(2026, 8, 27)), 0);
    expect(s.longestStreak, 0);
  });

  test('a 1 km walk sums to ~1 km on its local day', () {
    // 0.009° lat ≈ 1000 m, in ten 1-minute steps.
    final s = computeFootprint(input([
      for (var i = 0; i <= 10; i++)
        (30.0 + 0.0009 * i, 104.0, at(2026, 8, 20, 9, i), 1),
    ]));
    expect(s.totalMeters, closeTo(1000, 15));
    expect(s.dailyMeters.keys, ['2026-08-20']);
    expect(s.hourly[9], 11);
    expect(s.metersInYear(2026), closeTo(1000, 15));
    expect(s.metersInMonth(2026, 8), closeTo(1000, 15));
    expect(s.metersInMonth(2026, 7), 0);
  });

  test('a gap over 30 min and a GPS jump are not counted', () {
    final s = computeFootprint(input([
      (30.0, 104.0, at(2026, 8, 20, 9), 1),
      (30.5, 104.0, at(2026, 8, 20, 10), 1), // 55 km after 60 min: gap → skip
      (30.5, 104.0, at(2026, 8, 20, 10, 1), 1),
      (31.5, 104.0, at(2026, 8, 20, 10, 2), 1), // 111 km in 1 min → jump
    ]));
    expect(s.totalMeters, 0);
    expect(s.recordedDays, 1);
  });

  test('different layers never chain', () {
    final s = computeFootprint(input([
      (30.0, 104.0, at(2026, 8, 20, 9), 1),
      (30.009, 104.0, at(2026, 8, 20, 9, 5), 2),
    ]));
    expect(s.totalMeters, 0);
  });

  test('local-day bucketing respects the offset (23:30 UTC+8 is same day)', () {
    final s = computeFootprint(input([
      (30.0, 104.0, at(2026, 8, 20, 23, 30), 1),
      (30.001, 104.0, at(2026, 8, 20, 23, 40), 1),
    ]));
    expect(s.dailyMeters.keys, ['2026-08-20']);
  });

  test('streaks', () {
    final s = computeFootprint(input([
      for (final d in [10, 11, 12, 15, 16, 17, 18])
        (30.0, 104.0, at(2026, 8, d, 9), 1),
    ]));
    expect(s.recordedDays, 7);
    expect(s.longestStreak, 4);
    // "Today" = 19th with no fix yet → streak continues from the 18th.
    expect(s.currentStreak(DateTime(2026, 8, 19, 12)), 4);
    expect(s.currentStreak(DateTime(2026, 8, 18, 12)), 4);
    expect(s.currentStreak(DateTime(2026, 8, 21, 12)), 0);
  });

  test('longestDay and json round trip', () {
    final s = computeFootprint(input([
      (30.0, 104.0, at(2026, 8, 20, 9), 1),
      (30.009, 104.0, at(2026, 8, 20, 9, 10), 1),
      (30.0, 104.0, at(2026, 8, 21, 9), 1),
      (30.0009, 104.0, at(2026, 8, 21, 9, 10), 1),
    ]));
    expect(s.longestDay!.key, '2026-08-20');
    final back = FootprintSummary.fromJson(
        (s.toJson()).map((k, v) => MapEntry(k, v)));
    expect(back.totalMeters, closeTo(s.totalMeters, 1e-6));
    expect(back.hourly, s.hourly);
    expect(back.first, s.first);
  });
}
