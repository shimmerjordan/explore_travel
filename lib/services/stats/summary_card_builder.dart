/// 把库里的原料装配成一张总结卡的数据。
///
/// 与 [SummaryCardData] 的分工：那边是"卡片需要什么"（纯结构 + 几何），这边是
/// "从这个应用的表里怎么取"。放在 services 而不是 UI 里，是为了两个入口
/// （足迹页的年度卡、回放页的旅程卡）共用同一套口径。
library;

import '../../data/db/database.dart';
import 'footprint_summary.dart';
import 'summary_card_data.dart';

typedef SummaryPoint = ({double lat, double lng, DateTime time});

abstract final class SummaryCardBuilder {
  /// 年度卡：里程、天数、连续天数、国家都来自已经算好的 [FootprintSummary]
  /// （与足迹页显示的是同一份数字，不重算，避免两处对不上）。
  static SummaryCardData year({
    required int year,
    required FootprintSummary summary,
    required List<SummaryPoint> pointsInYear,
    required List<SummaryPlace> places,
  }) {
    final range = SummaryRange.year(year);
    final prefix = '$year-';
    final days = summary.dailyMeters.keys.where((k) => k.startsWith(prefix));
    final countries = <String>{
      for (final e in summary.dayCountries.entries)
        if (e.key.startsWith(prefix)) ...e.value,
    }.toList()
      ..sort();
    return SummaryCardData(
      range: range,
      totalMeters: summary.metersInYear(year),
      recordedDays: days.length,
      longestStreakDays: _longestStreak(days.toList()),
      countries: countries,
      hourly: SummaryCardData.normalizeHourly(summary.hourly),
      places: places,
      shape: SummaryCardData.buildShape(pointsInYear),
    );
  }

  /// 旅程卡：一段记录（或合并记录）。这里没有现成的 [FootprintSummary]，
  /// 里程与作息就地从点算，规则与足迹统计一致（见 [SummaryCardData.pathMeters]）。
  static SummaryCardData trip({
    required String title,
    required DateTime from,
    required DateTime to,
    required List<SummaryPoint> points,
    required List<SummaryPlace> places,
  }) {
    final hourly = List<int>.filled(24, 0);
    final days = <String>{};
    for (final p in points) {
      hourly[p.time.hour]++;
      days.add(_dayKey(p.time));
    }
    return SummaryCardData(
      range: SummaryRange(from: from, to: to, title: title),
      totalMeters: SummaryCardData.pathMeters(points),
      recordedDays: days.length,
      longestStreakDays: _longestStreak(days.toList()),
      countries: const [], // 单段旅程不做国家归属：一次出行通常就一个国家
      hourly: SummaryCardData.normalizeHourly(hourly),
      places: places,
      shape: SummaryCardData.buildShape(points),
    );
  }

  /// 由 visits + places 折出「待得最久」的前 [limit] 处。
  /// 只算已确认或自动识别的到访（status 2 = 用户否掉的，排除）。
  static List<SummaryPlace> placesFrom(
    List<Visit> visits,
    List<Place> places, {
    required DateTime from,
    required DateTime to,
    int limit = 3,
  }) {
    final byId = {for (final p in places) p.id: p};
    final dwell = <int, int>{};
    for (final v in visits) {
      if (v.status == 2 || v.placeId == null) continue;
      if (v.startedAt.isBefore(from) || v.startedAt.isAfter(to)) continue;
      dwell[v.placeId!] = (dwell[v.placeId!] ?? 0) +
          v.endedAt.difference(v.startedAt).inSeconds;
    }
    final out = <SummaryPlace>[];
    final ids = dwell.keys.toList()
      ..sort((a, b) => dwell[b]!.compareTo(dwell[a]!));
    for (final id in ids) {
      final name = byId[id]?.name;
      if (name == null || !isNamedPlace(name)) continue;
      out.add(SummaryPlace(name, dwell[id]!));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// 到访引擎给反查不到名字的地点起名「未命名地点」或「<城市> · 未命名地点」
  /// （visit_engine.dart）。这种名字放上要发出去的卡片没有意义——时间轴页
  /// 也是这么判的。
  static bool isNamedPlace(String name) {
    final n = name.trim();
    return n.isNotEmpty && !n.endsWith('未命名地点');
  }

  static String _dayKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// 最长连续有记录的天数。与 [FootprintSummary.longestStreak] 同一算法，
  /// 只是作用在筛过的日期子集上。
  static int _longestStreak(List<String> dayKeys) {
    if (dayKeys.isEmpty) return 0;
    final days = dayKeys.map(DateTime.parse).toList()..sort();
    var best = 1, run = 1;
    for (var i = 1; i < days.length; i++) {
      final gap = days[i].difference(days[i - 1]).inDays;
      if (gap == 1) {
        run++;
        if (run > best) best = run;
      } else if (gap > 1) {
        run = 1;
      }
    }
    return best;
  }
}
