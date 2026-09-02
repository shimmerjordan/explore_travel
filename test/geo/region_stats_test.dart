import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/geo/flag_emoji.dart';
import 'package:explore_journal/services/geo/region_stats.dart';

const dayMs = Duration.millisecondsPerDay;

/// n fixes at (lat,lng), one per day starting at [day0].
({List<double> lats, List<double> lngs, List<int> times}) fixes(
  List<(double, double, int)> spec, {
  int perDay = 1,
}) {
  final lats = <double>[], lngs = <double>[], times = <int>[];
  for (final (lat, lng, day) in spec) {
    for (var i = 0; i < perDay; i++) {
      lats.add(lat);
      lngs.add(lng);
      times.add(day * dayMs + 10 * 3600 * 1000 + i * 1000);
    }
  }
  return (lats: lats, lngs: lngs, times: times);
}

void main() {
  group('flag emoji', () {
    test('Chinese names and ISO codes both resolve', () {
      expect(flagEmojiFor('中国'), '🇨🇳');
      expect(flagEmojiFor('日本'), '🇯🇵');
      expect(flagEmojiForCode('FR'), '🇫🇷');
      // Alias from the boundary asset.
      expect(flagEmojiFor('China'), '🇨🇳');
    });

    test('unknown or empty names yield an empty string, never a broken glyph',
        () {
      expect(flagEmojiFor(''), '');
      expect(flagEmojiFor('未知'), '');
      expect(flagEmojiFor('浙江省'), '');
      expect(flagEmojiForCode('X'), '');
      expect(flagEmojiForCode('中国'), '');
    });

    test('a longer official form falls back to the name it contains', () {
      expect(isoCodeFor('中华人民共和国'), 'CN');
      // The more specific entry wins over the shorter one inside it.
      expect(isoCodeFor('中国香港特别行政区'), 'HK');
    });
  });

  group('aggregateCells', () {
    test('groups by ~5 km cell, counts DISTINCT days, keeps the centroid', () {
      // Two fixes in one cell on the same day + one the next day, then a far
      // away cell.
      final f = fixes([
        (31.20, 121.40, 20000),
        (31.21, 121.41, 20000),
        (31.20, 121.40, 20001),
        (30.00, 120.00, 20000),
      ]);
      final cells = aggregateCells(
          lats: f.lats, lngs: f.lngs, times: f.times, tzOffsetMs: 8 * 3600000);
      expect(cells.length, 2);
      final busy = cells.first;
      expect(busy.days.length, 2, reason: '3 fixes but only 2 distinct days');
      expect(busy.points, 3);
      expect(busy.lat, closeTo((31.20 + 31.21 + 31.20) / 3, 1e-9));
      expect(cells.last.days.length, 1);
    });

    test('sorted by day count, so partial naming spends the network well', () {
      final f = fixes([
        for (var d = 0; d < 3; d++) (10.0, 10.0, 20000 + d),
        for (var d = 0; d < 9; d++) (20.0, 20.0, 20000 + d),
      ]);
      final cells = aggregateCells(
          lats: f.lats, lngs: f.lngs, times: f.times, tzOffsetMs: 0);
      expect(cells.first.days.length, 9);
      expect(cells.last.days.length, 3);
    });

    test('local midnight decides the day, not UTC', () {
      // 2024-01-01 23:30 Shanghai = 15:30 UTC — same local day as 08:00.
      const utcNoonBefore = 1704110400000; // 2024-01-01 08:00 +08
      const utcLateEvening = 1704166200000; // 2024-01-01 23:30 +08
      const nextMorning = 1704175200000; // 2024-01-02 02:00 +08
      final cells = aggregateCells(
        lats: const [31.2, 31.2, 31.2],
        lngs: const [121.4, 121.4, 121.4],
        times: const [utcNoonBefore, utcLateEvening, nextMorning],
        tzOffsetMs: 8 * 3600000,
      );
      expect(cells.single.days.length, 2);
    });
  });

  group('foldRegions', () {
    List<CellAgg> cellsFor(List<(double, double, int)> spec) {
      final f = fixes(spec);
      return aggregateCells(
          lats: f.lats, lngs: f.lngs, times: f.times, tzOffsetMs: 8 * 3600000);
    }

    test('cells of one city merge; days union without double counting', () {
      // Two cells of Shanghai sharing a day, plus one Huzhou day.
      final cells = cellsFor([
        (31.20, 121.40, 20000),
        (31.30, 121.55, 20000), // same day, different cell
        (31.30, 121.55, 20001),
        (30.86, 120.09, 20005),
      ]);
      final names = {
        for (final c in cells)
          c.key: c.lat > 31 ? '中国|上海市|上海市' : '中国|浙江省|湖州市',
      };
      final regions = foldRegions(cells, names);
      expect(regions.length, 2);
      final sh = regions.first;
      expect(sh.displayName, '上海市');
      expect(sh.dayCount, 2, reason: 'the shared day counts once');
      expect(sh.cellCount, 2);
      expect(sh.points, 3);
      expect(sh.flag, '🇨🇳');
      // Extent covers whole cells, so the centroid sits inside it.
      expect(sh.lat, inInclusiveRange(sh.minLat, sh.maxLat));
      expect(sh.lng, inInclusiveRange(sh.minLng, sh.maxLng));
      expect(regions.last.displayName, '湖州市');
    });

    test('unnamed cells are skipped, not lumped into a blank region', () {
      final cells = cellsFor([(31.2, 121.4, 20000), (48.85, 2.35, 20001)]);
      final regions = foldRegions(cells, {cells.first.key: '中国|上海市|上海市'});
      expect(regions.length, 1);
      expect(regions.single.displayName, '上海市');
    });

    test('falls back to province, then country, when the city is unknown', () {
      final cells = cellsFor([(48.85, 2.35, 20000), (35.6, 139.7, 20001)]);
      final regions = foldRegions(cells, {
        cells[0].key: '法国||',
        cells[1].key: '日本|东京都|',
      });
      final byName = {for (final r in regions) r.displayName: r};
      expect(byName.keys, containsAll(['法国', '东京都']));
      expect(byName['法国']!.flag, '🇫🇷');
      expect(byName['东京都']!.flag, '🇯🇵');
    });

    test('label appends the country only when abroad', () {
      final cells = cellsFor([(35.6, 139.7, 20000)]);
      final r = foldRegions(cells, {cells.single.key: '日本|东京都|东京'}).single;
      expect(r.labelWith(homeCountry: '中国'), '东京 · 日本');
      expect(r.labelWith(homeCountry: '日本'), '东京');
      expect(r.labelWith(), '东京');
    });

    test('regions come back busiest-first', () {
      final cells = cellsFor([
        for (var d = 0; d < 2; d++) (10.0, 10.0, 20000 + d),
        for (var d = 0; d < 7; d++) (20.0, 20.0, 20000 + d),
      ]);
      final names = {
        for (final c in cells) c.key: c.lat > 15 ? '中国|A|多' : '中国|B|少',
      };
      final regions = foldRegions(cells, names);
      expect(regions.map((r) => r.displayName).toList(), ['多', '少']);
    });
  });

  test('label size grows with days, log-scaled and bounded', () {
    expect(regionLabelSize(0, 100), 11);
    expect(regionLabelSize(100, 100), closeTo(30, 1e-9));
    final few = regionLabelSize(3, 100), many = regionLabelSize(40, 100);
    expect(few, greaterThan(11));
    expect(many, greaterThan(few));
    // Log scaling: 40 days is 13× the days of 3 but nowhere near 13× the size.
    expect(many / few, lessThan(2.2));
  });
}
