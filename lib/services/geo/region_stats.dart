import 'dart:math' as math;

import 'flag_emoji.dart';

/// Per-administrative-region roll-up behind the 3D 区域点云 view.
///
/// Two stages, deliberately separated so the expensive half is pure and the
/// slow half is cached:
///
///  1. [aggregateCells] — every track point falls into a [cellDeg] grid cell
///     (~5 km); a cell carries the set of DAYS it was seen on plus its point
///     count and centroid. Pure, allocation-light, `compute()`-safe.
///  2. the caller names each cell (reverse geocoding, cached on disk — see
///     `GeocodingService`, which is offline-first) and [foldRegions] folds
///     the cells into one entry per 国家|省|市.
///
/// Day counts, not point counts, drive the label size: sampling rate varies
/// wildly (driving through a city at 1 Hz beats living there on foot), while
/// "how many different days was I here" is what the user actually means by
/// 去过得多.
class CellAgg {
  final int qLat, qLng;

  /// Local-time day indices (days since epoch).
  final Set<int> days;
  final int points;

  /// Centroid of the points in this cell.
  final double lat, lng;

  const CellAgg({
    required this.qLat,
    required this.qLng,
    required this.days,
    required this.points,
    required this.lat,
    required this.lng,
  });

  /// Key for the name cache — stable across runs and grid-aligned.
  String get key => '$qLat,$qLng';
}

/// Default grid: 0.05° ≈ 5.5 km N-S. Fine enough that a city is many cells
/// (so a boundary cell mis-assigned barely moves the total) and coarse
/// enough that a year of travel is hundreds of cells, not thousands.
const double kRegionCellDeg = 0.05;

/// Days since the epoch in LOCAL time — [tzOffsetMs] is normally
/// `DateTime.now().timeZoneOffset.inMilliseconds`. Taken as a parameter so
/// this stays pure and testable.
int dayIndexOf(int epochMs, int tzOffsetMs) =>
    (epochMs + tzOffsetMs) ~/ Duration.millisecondsPerDay;

/// Fold raw fixes into grid cells. [times] are epoch ms, parallel to
/// [lats]/[lngs].
List<CellAgg> aggregateCells({
  required List<double> lats,
  required List<double> lngs,
  required List<int> times,
  required int tzOffsetMs,
  double cellDeg = kRegionCellDeg,
}) {
  final n = math.min(lats.length, math.min(lngs.length, times.length));
  final days = <int, Set<int>>{};
  final counts = <int, int>{};
  final sumLat = <int, double>{};
  final sumLng = <int, double>{};
  final qLatOf = <int, int>{};
  final qLngOf = <int, int>{};
  for (var i = 0; i < n; i++) {
    final lat = lats[i], lng = lngs[i];
    if (lat.isNaN || lng.isNaN) continue;
    final qLat = (lat / cellDeg).floor();
    final qLng = (lng / cellDeg).floor();
    // Pack the cell into one int key (qLng is ±7200 at 0.05°).
    final k = qLat * 100000 + qLng;
    (days[k] ??= <int>{}).add(dayIndexOf(times[i], tzOffsetMs));
    counts[k] = (counts[k] ?? 0) + 1;
    sumLat[k] = (sumLat[k] ?? 0) + lat;
    sumLng[k] = (sumLng[k] ?? 0) + lng;
    qLatOf[k] = qLat;
    qLngOf[k] = qLng;
  }
  final out = <CellAgg>[];
  for (final k in counts.keys) {
    final c = counts[k]!;
    out.add(CellAgg(
      qLat: qLatOf[k]!,
      qLng: qLngOf[k]!,
      days: days[k]!,
      points: c,
      lat: sumLat[k]! / c,
      lng: sumLng[k]! / c,
    ));
  }
  // Most-visited first: that is also the order worth spending network
  // geocoding on when only some cells can be named this session.
  out.sort((a, b) {
    final d = b.days.length.compareTo(a.days.length);
    return d != 0 ? d : b.points.compareTo(a.points);
  });
  return out;
}

/// One administrative region as shown in the cloud.
class RegionStat {
  final String country, province, city;

  /// Local-time day indices, unioned over the region's cells.
  final Set<int> days;
  final int points;
  final int cellCount;

  /// Point-weighted centroid, and the region's extent in degrees.
  final double lat, lng;
  final double minLat, maxLat, minLng, maxLng;

  const RegionStat({
    required this.country,
    required this.province,
    required this.city,
    required this.days,
    required this.points,
    required this.cellCount,
    required this.lat,
    required this.lng,
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });

  String get key => '$country|$province|$city';
  int get dayCount => days.length;

  /// The most specific name we have: 市 → 省 → 国.
  String get displayName => city.isNotEmpty
      ? city
      : province.isNotEmpty
          ? province
          : country;

  /// Flag between the words, as asked: 上海市 🇨🇳 — empty when unknown.
  String get flag => flagEmojiFor(country);

  /// '上海市' under its own country, '东京都 · 日本' abroad — resolved by the
  /// caller, which knows the user's home country.
  String labelWith({String? homeCountry}) =>
      homeCountry == null || country == homeCountry || country.isEmpty
          ? displayName
          : '$displayName · $country';
}

/// Fold named cells into regions. [names] maps [CellAgg.key] to the
/// '国家|省|市' string the geocoder produced; cells with no entry (never
/// resolved, offline and outside every country bbox) are skipped.
List<RegionStat> foldRegions(
  List<CellAgg> cells,
  Map<String, String> names, {
  double cellDeg = kRegionCellDeg,
}) {
  final acc = <String, _Acc>{};
  for (final c in cells) {
    final raw = names[c.key];
    if (raw == null || raw.isEmpty) continue;
    final parts = raw.split('|');
    final country = parts.isNotEmpty ? parts[0] : '';
    final province = parts.length > 1 ? parts[1] : '';
    final city = parts.length > 2 ? parts[2] : '';
    if (country.isEmpty && province.isEmpty && city.isEmpty) continue;
    final a = acc.putIfAbsent(
        '$country|$province|$city', () => _Acc(country, province, city));
    a.add(c, cellDeg);
  }
  final out = acc.values.map((a) => a.build()).toList()
    ..sort((x, y) {
      final d = y.dayCount.compareTo(x.dayCount);
      return d != 0 ? d : y.points.compareTo(x.points);
    });
  return out;
}

class _Acc {
  final String country, province, city;
  final Set<int> days = {};
  int points = 0;
  int cells = 0;
  double wLat = 0, wLng = 0;
  double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
  _Acc(this.country, this.province, this.city);

  void add(CellAgg c, double cellDeg) {
    days.addAll(c.days);
    points += c.points;
    cells++;
    wLat += c.lat * c.points;
    wLng += c.lng * c.points;
    // Extent covers the whole cell, not just its centroid.
    final lo = c.qLat * cellDeg, hi = lo + cellDeg;
    final lo2 = c.qLng * cellDeg, hi2 = lo2 + cellDeg;
    minLat = math.min(minLat, lo);
    maxLat = math.max(maxLat, hi);
    minLng = math.min(minLng, lo2);
    maxLng = math.max(maxLng, hi2);
  }

  RegionStat build() => RegionStat(
        country: country,
        province: province,
        city: city,
        days: days,
        points: points,
        cellCount: cells,
        lat: points > 0 ? wLat / points : (minLat + maxLat) / 2,
        lng: points > 0 ? wLng / points : (minLng + maxLng) / 2,
        minLat: minLat,
        maxLat: maxLat,
        minLng: minLng,
        maxLng: maxLng,
      );
}

/// Label size for a region, in logical px: log-scaled between the quietest
/// and the busiest place on screen so 上海市 towers over 镇江市 without the
/// long tail becoming unreadable.
double regionLabelSize(int dayCount, int maxDayCount,
    {double min = 11, double max = 30}) {
  if (dayCount <= 0 || maxDayCount <= 0) return min;
  final t = math.log(1 + dayCount) / math.log(1 + math.max(maxDayCount, 1));
  return min + (max - min) * t.clamp(0.0, 1.0);
}
