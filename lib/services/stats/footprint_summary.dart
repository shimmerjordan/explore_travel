import 'dart:typed_data';

import '../location/point_filter.dart';
import 'footprint_stats.dart';

/// Everything the 足迹 stats tab shows, computed from packed point arrays so
/// it can run in `compute()`. Distances follow [pathDistanceMeters]'s rules
/// (no bridging across > 30 min gaps, no > 300 km/h jumps).
class FootprintSummary {
  /// yyyy-mm-dd → metres.
  final Map<String, double> dailyMeters;

  /// 24 bins: clean fixes per local hour-of-day.
  final List<int> hourly;
  final int pointCount;
  final DateTime? first;
  final DateTime? last;

  const FootprintSummary({
    required this.dailyMeters,
    required this.hourly,
    required this.pointCount,
    required this.first,
    required this.last,
  });

  static const empty = FootprintSummary(
      dailyMeters: {}, hourly: [], pointCount: 0, first: null, last: null);

  double get totalMeters => dailyMeters.values.fold(0.0, (a, b) => a + b);

  double metersInYear(int year) {
    final p = '$year-';
    var s = 0.0;
    for (final e in dailyMeters.entries) {
      if (e.key.startsWith(p)) s += e.value;
    }
    return s;
  }

  double metersInMonth(int year, int month) {
    final p = '$year-${month.toString().padLeft(2, '0')}-';
    var s = 0.0;
    for (final e in dailyMeters.entries) {
      if (e.key.startsWith(p)) s += e.value;
    }
    return s;
  }

  /// Days with any recorded fix (a day with points but 0 m still counts).
  int get recordedDays => dailyMeters.length;

  /// Consecutive recorded days ending today or yesterday (a day that hasn't
  /// produced a fix yet doesn't break the streak).
  int currentStreak(DateTime now) {
    var d = DateTime(now.year, now.month, now.day);
    if (!dailyMeters.containsKey(dayKey(d))) {
      d = d.subtract(const Duration(days: 1));
      if (!dailyMeters.containsKey(dayKey(d))) return 0;
    }
    var n = 0;
    while (dailyMeters.containsKey(dayKey(d))) {
      n++;
      d = d.subtract(const Duration(days: 1));
    }
    return n;
  }

  int get longestStreak {
    if (dailyMeters.isEmpty) return 0;
    final days = dailyMeters.keys.map(DateTime.parse).toList()..sort();
    var best = 1, run = 1;
    for (var i = 1; i < days.length; i++) {
      if (days[i].difference(days[i - 1]).inDays == 1) {
        run++;
        if (run > best) best = run;
      } else {
        run = 1;
      }
    }
    return best;
  }

  /// The day with the most distance.
  MapEntry<String, double>? get longestDay {
    MapEntry<String, double>? best;
    for (final e in dailyMeters.entries) {
      if (best == null || e.value > best.value) best = e;
    }
    return best;
  }

  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, Object?> toJson() => {
        'daily': dailyMeters,
        'hourly': hourly,
        'points': pointCount,
        'first': first?.millisecondsSinceEpoch,
        'last': last?.millisecondsSinceEpoch,
      };

  static FootprintSummary fromJson(Map<String, dynamic> j) => FootprintSummary(
        dailyMeters: (j['daily'] as Map)
            .map((k, v) => MapEntry(k.toString(), (v as num).toDouble())),
        hourly: (j['hourly'] as List).map((e) => (e as num).toInt()).toList(),
        pointCount: (j['points'] as num?)?.toInt() ?? 0,
        first: j['first'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((j['first'] as num).toInt()),
        last: j['last'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((j['last'] as num).toInt()),
      );
}

/// Packed input: parallel arrays sorted by (layer, time) — what
/// `AppDb.cleanPoints` returns, flattened.
class FootprintInput {
  final Float64List lat, lng;
  final Int64List timeMs;
  final Int32List layer;

  /// Local-time offset (ms) to bucket UTC instants into calendar days. Passed
  /// in because isolates don't know the main isolate's timezone reliably.
  final int tzOffsetMs;
  const FootprintInput(this.lat, this.lng, this.timeMs, this.layer, this.tzOffsetMs);

  Map<String, Object> toMap() => {
        'lat': lat,
        'lng': lng,
        'timeMs': timeMs,
        'layer': layer,
        'tz': tzOffsetMs,
      };
  static FootprintInput fromMap(Map<String, Object> m) => FootprintInput(
        m['lat'] as Float64List,
        m['lng'] as Float64List,
        m['timeMs'] as Int64List,
        m['layer'] as Int32List,
        m['tz'] as int,
      );
}

Map<String, Object?> computeFootprintFromMap(Map<String, Object> m) =>
    computeFootprint(FootprintInput.fromMap(m)).toJson();

FootprintSummary computeFootprint(FootprintInput input) {
  final n = input.lat.length;
  if (n == 0) return FootprintSummary.empty;
  final daily = <String, double>{};
  final hourly = List<int>.filled(24, 0);
  int? minT, maxT;
  String keyOf(int tMs) {
    final local = DateTime.fromMillisecondsSinceEpoch(tMs + input.tzOffsetMs, isUtc: true);
    return FootprintSummary.dayKey(local);
  }

  for (var i = 0; i < n; i++) {
    final t = input.timeMs[i];
    if (minT == null || t < minT) minT = t;
    if (maxT == null || t > maxT) maxT = t;
    final local = DateTime.fromMillisecondsSinceEpoch(t + input.tzOffsetMs, isUtc: true);
    hourly[local.hour]++;
    daily.putIfAbsent(FootprintSummary.dayKey(local), () => 0.0);
    if (i == 0 || input.layer[i] != input.layer[i - 1]) continue;
    final dt = t - input.timeMs[i - 1];
    if (dt <= 0 || dt > kMaxGapMs) continue;
    final d = PointFilter.haversineMeters(
        input.lat[i - 1], input.lng[i - 1], input.lat[i], input.lng[i]);
    final kmh = d / 1000 / (dt / 3600000);
    if (kmh > kMaxSpeedKmh) continue;
    // Attribute the segment to the day of its END fix (a midnight walk lands
    // on the day you arrived — Dawarich partitions by the later row too).
    final k = keyOf(t);
    daily[k] = (daily[k] ?? 0) + d;
  }
  return FootprintSummary(
    dailyMeters: daily,
    hourly: hourly,
    pointCount: n,
    first: DateTime.fromMillisecondsSinceEpoch(minT!),
    last: DateTime.fromMillisecondsSinceEpoch(maxT!),
  );
}
