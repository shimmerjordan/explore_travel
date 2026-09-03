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

  /// yyyy-mm-dd → countries with at least one fix that day (sorted). Empty
  /// when the input carried no [CountryBoxTable].
  final Map<String, List<String>> dayCountries;

  const FootprintSummary({
    required this.dailyMeters,
    required this.hourly,
    required this.pointCount,
    required this.first,
    required this.last,
    this.dayCountries = const {},
  });

  static const empty = FootprintSummary(
      dailyMeters: {}, hourly: [], pointCount: 0, first: null, last: null);

  double get totalMeters => dailyMeters.values.fold(0.0, (a, b) => a + b);

  /// Country → number of days with a fix there (Dawarich: "≥1 point that day").
  Map<String, int> get daysPerCountry {
    final out = <String, int>{};
    for (final cs in dayCountries.values) {
      for (final c in cs) {
        out[c] = (out[c] ?? 0) + 1;
      }
    }
    return out;
  }

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
        'dayCountries': dayCountries,
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
        // Snapshots written before this field existed simply have none.
        dayCountries: (j['dayCountries'] as Map?)?.map((k, v) => MapEntry(
                k.toString(), (v as List).map((e) => e.toString()).toList())) ??
            const {},
      );
}

/// Coarse lat/lng → country table in a form `compute()` can carry: parallel
/// arrays, nothing but strings and doubles.
///
/// 与 `CountryLookup` 读的是同一份 assets/boundaries/countries.json，判定规则
/// 也相同（取面积最小的包含框；都不含则「未知」→ 这里返回 null）。不直接把
/// CountryLookup 递进 isolate，是因为它的框表是私有字段、又挂着 Flutter 资源
/// 加载；统计这边只要「坐标 → 国家名」一件事，平行数组既能原样进 compute() 的
/// 入参，也让这份逻辑保持纯 Dart、测试可以喂一张假表。
class CountryBoxTable {
  final List<String> names;

  /// n × 4: minLat, minLng, maxLat, maxLng — the order `bbox` uses in the asset.
  final Float64List bounds;
  const CountryBoxTable(this.names, this.bounds);

  static final empty = CountryBoxTable(const [], Float64List(0));

  /// Parse the asset document: `{"countries": {"<name>": {"bbox": [4 nums]}}}`.
  /// Entries with a short bbox are skipped, exactly as `CountryLookup` does.
  factory CountryBoxTable.fromCountriesJson(Map<String, dynamic> j) {
    final countries = (j['countries'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final names = <String>[];
    final bounds = <double>[];
    for (final e in countries.entries) {
      final bbox = ((e.value as Map)['bbox'] as List?)?.cast<num>();
      if (bbox == null || bbox.length < 4) continue;
      names.add(e.key);
      bounds.addAll([
        bbox[0].toDouble(),
        bbox[1].toDouble(),
        bbox[2].toDouble(),
        bbox[3].toDouble(),
      ]);
    }
    return CountryBoxTable(names, Float64List.fromList(bounds));
  }

  int get length => names.length;

  /// Smallest-area box containing the point; null when none does.
  String? countryAt(double lat, double lng) {
    var best = -1;
    var bestArea = double.infinity;
    for (var i = 0; i < names.length; i++) {
      final o = i << 2;
      if (lat < bounds[o] || lat > bounds[o + 2]) continue;
      if (lng < bounds[o + 1] || lng > bounds[o + 3]) continue;
      final area = (bounds[o + 2] - bounds[o]) * (bounds[o + 3] - bounds[o + 1]);
      if (area < bestArea) {
        bestArea = area;
        best = i;
      }
    }
    return best < 0 ? null : names[best];
  }
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

  /// Optional: enables the days-per-country pass.
  final CountryBoxTable? countries;
  const FootprintInput(this.lat, this.lng, this.timeMs, this.layer, this.tzOffsetMs,
      {this.countries});

  Map<String, Object> toMap() => {
        'lat': lat,
        'lng': lng,
        'timeMs': timeMs,
        'layer': layer,
        'tz': tzOffsetMs,
        if (countries != null) 'countryNames': countries!.names,
        if (countries != null) 'countryBounds': countries!.bounds,
      };
  static FootprintInput fromMap(Map<String, Object> m) => FootprintInput(
        m['lat'] as Float64List,
        m['lng'] as Float64List,
        m['timeMs'] as Int64List,
        m['layer'] as Int32List,
        m['tz'] as int,
        countries: m['countryNames'] == null
            ? null
            : CountryBoxTable((m['countryNames'] as List).cast<String>(),
                m['countryBounds'] as Float64List),
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

  // Days per country: ONE bbox lookup per (day, 2-hour slot, layer) — a day
  // counts for a country if any sample lands in it (Dawarich: "≥1 point that
  // day"); >500 km/h fixes are already gone. 每个时段只查一次，是因为 bbox 查询
  // 要扫整张表，几十万个点逐个查太贵；点已按（图层, 时间）排好序，所以同一
  // 时段的点一定连续，记住上一个时段即可去重。时段号 = 本地毫秒 ~/ 2h，与
  // 「本地日期 + 小时 ~/ 2」一一对应（UTC 日界正好落在 86400000 的整数倍上）。
  final countries = input.countries;
  final lookupCountries = countries != null && countries.length > 0;
  final dayCountries = <String, Set<String>>{};
  var lastSlot = -1, lastSlotLayer = 0;

  for (var i = 0; i < n; i++) {
    final t = input.timeMs[i];
    if (minT == null || t < minT) minT = t;
    if (maxT == null || t > maxT) maxT = t;
    final shifted = t + input.tzOffsetMs;
    final local = DateTime.fromMillisecondsSinceEpoch(shifted, isUtc: true);
    hourly[local.hour]++;
    daily.putIfAbsent(FootprintSummary.dayKey(local), () => 0.0);
    if (lookupCountries) {
      final slot = shifted ~/ 7200000;
      if (slot != lastSlot || input.layer[i] != lastSlotLayer) {
        lastSlot = slot;
        lastSlotLayer = input.layer[i];
        final c = countries.countryAt(input.lat[i], input.lng[i]);
        if (c != null) {
          (dayCountries[FootprintSummary.dayKey(local)] ??= {}).add(c);
        }
      }
    }
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
    // Sorted so the persisted snapshot is deterministic.
    dayCountries: {
      for (final e in dayCountries.entries) e.key: (e.value.toList()..sort()),
    },
  );
}
