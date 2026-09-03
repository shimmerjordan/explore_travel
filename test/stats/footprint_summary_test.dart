import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/stats/footprint_summary.dart';

FootprintInput input(List<(double lat, double lng, DateTime t, int layer)> pts,
    {int tzOffsetMs = 8 * 3600 * 1000, CountryBoxTable? countries}) {
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
    countries: countries,
  );
}

/// A toy table in the asset's shape: a big box (中国) with a smaller one
/// (澳门) nested inside it, and a disjoint one (泰国).
final toyCountries = CountryBoxTable.fromCountriesJson({
  'countries': {
    '中国': {'bbox': [18.0, 73.0, 53.5, 135.0], 'grid': 24},
    '澳门': {'bbox': [22.1, 113.5, 22.3, 113.7]},
    '泰国': {'bbox': [5.6, 97.3, 20.5, 105.6]},
    '坏数据': {'bbox': [1, 2]}, // short bbox → skipped
  },
});

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

  group('CountryBoxTable', () {
    test('parses the asset shape and skips short bboxes', () {
      expect(toyCountries.length, 3);
      expect(toyCountries.names, ['中国', '澳门', '泰国']);
      expect(toyCountries.bounds.length, 12);
    });

    test('smallest containing box wins; nothing → null', () {
      expect(toyCountries.countryAt(30.0, 104.0), '中国');
      expect(toyCountries.countryAt(22.2, 113.6), '澳门'); // inside both
      expect(toyCountries.countryAt(13.7, 100.5), '泰国');
      expect(toyCountries.countryAt(0.0, -160.0), isNull);
      expect(CountryBoxTable.empty.countryAt(30.0, 104.0), isNull);
    });

    test('reads the real bundled asset (same file CountryLookup loads)', () {
      final raw = File('assets/boundaries/countries.json').readAsStringSync();
      final table = CountryBoxTable.fromCountriesJson(
          jsonDecode(raw) as Map<String, dynamic>);
      expect(table.length, greaterThan(20));
      expect(table.countryAt(39.9, 116.4), '中国'); // 北京
      expect(table.countryAt(35.7, 139.7), '日本'); // 东京
      expect(table.countryAt(0.0, -160.0), isNull); // mid-Pacific
    });

    test('survives the compute() map form', () {
      final m = input([(30.0, 104.0, at(2026, 8, 20, 9), 1)],
              countries: toyCountries)
          .toMap();
      expect(m['countryNames'], toyCountries.names);
      final back = FootprintInput.fromMap(m).countries!;
      expect(back.names, toyCountries.names);
      expect(back.bounds, toyCountries.bounds);
      expect(FootprintInput.fromMap(input([]).toMap()).countries, isNull);
    });
  });

  group('days per country', () {
    test('a day counts for every country with a fix that day', () {
      final s = computeFootprint(input([
        // 20th: morning in 中国, evening in 泰国 (a flight, not counted as km).
        (30.0, 104.0, at(2026, 8, 20, 9), 1),
        (30.0001, 104.0, at(2026, 8, 20, 9, 30), 1),
        (13.7, 100.5, at(2026, 8, 20, 21), 1),
        // 21st: 泰国 only.
        (13.7, 100.5, at(2026, 8, 21, 8), 1),
        // 22nd: out at sea → no country.
        (0.0, -160.0, at(2026, 8, 22, 8), 1),
      ], countries: toyCountries));
      expect(s.dayCountries, {
        '2026-08-20': ['中国', '泰国'],
        '2026-08-21': ['泰国'],
      });
      expect(s.daysPerCountry, {'中国': 1, '泰国': 2});
      expect(s.recordedDays, 3); // the sea day still counts as recorded
    });

    test('one lookup per 2-hour slot: the first fix of a slot decides', () {
      // Slot 08–10 starts in 中国; a later fix in the same slot sits in 澳门
      // and is skipped (the old UI pass sampled slots the same way). The
      // 10–12 slot starts in 澳门 → both countries land on the day.
      final s = computeFootprint(input([
        (30.0, 104.0, at(2026, 8, 20, 8), 1),
        (22.2, 113.6, at(2026, 8, 20, 9, 30), 1),
        (22.2, 113.6, at(2026, 8, 20, 10, 5), 1),
      ], countries: toyCountries));
      expect(s.dayCountries['2026-08-20'], ['中国', '澳门']);
      final only = computeFootprint(input([
        (30.0, 104.0, at(2026, 8, 20, 8), 1),
        (22.2, 113.6, at(2026, 8, 20, 9, 30), 1),
      ], countries: toyCountries));
      expect(only.dayCountries['2026-08-20'], ['中国']);
    });

    test('layers are sampled separately within the same slot', () {
      final s = computeFootprint(input([
        (30.0, 104.0, at(2026, 8, 20, 8), 1),
        (13.7, 100.5, at(2026, 8, 20, 8, 10), 2),
      ], countries: toyCountries));
      expect(s.dayCountries['2026-08-20'], ['中国', '泰国']);
    });

    test('the slot follows the LOCAL day like dayKey does', () {
      // 23:30 UTC+8 on the 20th; the next fix at 00:30 UTC+8 is the 21st.
      final s = computeFootprint(input([
        (30.0, 104.0, at(2026, 8, 20, 23, 30), 1),
        (30.0, 104.0, at(2026, 8, 21, 0, 30), 1),
      ], countries: toyCountries));
      expect(s.dayCountries.keys, ['2026-08-20', '2026-08-21']);
      expect(s.daysPerCountry, {'中国': 2});
    });

    test('no table → no countries; json round-trips both ways', () {
      final bare = computeFootprint(input([
        (30.0, 104.0, at(2026, 8, 20, 9), 1),
      ]));
      expect(bare.dayCountries, isEmpty);
      expect(bare.daysPerCountry, isEmpty);

      final s = computeFootprint(input([
        (30.0, 104.0, at(2026, 8, 20, 9), 1),
      ], countries: toyCountries));
      final j = s.toJson();
      final back = FootprintSummary.fromJson(j.map((k, v) => MapEntry(k, v)));
      expect(back.dayCountries, {'2026-08-20': ['中国']});
      // A snapshot persisted before the field existed still restores.
      final old = FootprintSummary.fromJson(
          (j..remove('dayCountries')).map((k, v) => MapEntry(k, v)));
      expect(old.dayCountries, isEmpty);
      expect(old.totalMeters, s.totalMeters);
    });
  });
}
