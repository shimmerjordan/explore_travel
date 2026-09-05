/// 总结卡要展示的东西，从已有的统计里挑出来、按一段时间范围收敛。
///
/// 刻意做成不依赖 Flutter 的纯数据装配：卡片长什么样是 UI 的事，"这段时间到底
/// 发生了什么"是这里的事，后者可以单独测。
library;

import 'dart:math' as math;

import '../../core/geo_math.dart' show haversineMeters;

/// 卡片覆盖的时间范围。[title] 是给人看的标题（「2026 年」「7 月 9 日的旅程」）。
class SummaryRange {
  final DateTime from;
  final DateTime to;
  final String title;
  const SummaryRange(
      {required this.from, required this.to, required this.title});

  bool contains(DateTime t) => !t.isBefore(from) && !t.isAfter(to);

  /// 某一整年。
  factory SummaryRange.year(int year) => SummaryRange(
        from: DateTime(year),
        to: DateTime(year + 1).subtract(const Duration(microseconds: 1)),
        title: '$year 年',
      );
}

/// 卡片上的一处地点：名字 + 停留时长（秒）。
class SummaryPlace {
  final String name;
  final int dwellSeconds;
  const SummaryPlace(this.name, this.dwellSeconds);
}

/// 归一化到 0..1 的一个轨迹点，已按范围内所有点的包围盒等比缩放并居中。
/// y 轴已翻转成"上北下南"的绘制坐标。
class SummaryShapePoint {
  final double x;
  final double y;

  /// 与上一个点是否连成一段（间隔太久就断开，避免画出跨城直线）。
  final bool connected;
  const SummaryShapePoint(this.x, this.y, {required this.connected});
}

class SummaryCardData {
  final SummaryRange range;

  /// 米。
  final double totalMeters;
  final int recordedDays;
  final int longestStreakDays;
  final List<String> countries;

  /// 24 格，按小时的活动强度，已归一化到 0..1（全零表示没有数据）。
  final List<double> hourly;

  /// 按停留时长排序的前几处地点。
  final List<SummaryPlace> places;

  /// 轨迹形状。空表示这段范围没有轨迹点（例如整段历史都是 FOW 位图导入的）——
  /// 卡片这时不画形状，而不是画一张空图。
  final List<SummaryShapePoint> shape;

  const SummaryCardData({
    required this.range,
    required this.totalMeters,
    required this.recordedDays,
    required this.longestStreakDays,
    required this.countries,
    required this.hourly,
    required this.places,
    required this.shape,
  });

  bool get hasShape => shape.length >= 2;

  /// 这段范围里一个点都没有——卡片该说"这段时间还没有记录"，而不是摆一排 0。
  bool get isEmpty => totalMeters <= 0 && recordedDays == 0 && shape.isEmpty;

  /// 把轨迹点归一化进 0..1 的正方形（等比，留边）。
  ///
  /// [gapSeconds] 之外的相邻点断开：跨城的一次移动不该在卡片上连成一条直线，
  /// 与里程统计里 30 分钟的切段口径一致。
  static List<SummaryShapePoint> buildShape(
    List<({double lat, double lng, DateTime time})> points, {
    int gapSeconds = 1800,
    int maxPoints = 4000,
  }) {
    if (points.length < 2) return const [];
    final sorted = [...points]..sort((a, b) => a.time.compareTo(b.time));
    // 抽稀：卡片只有一千多像素宽，几万个点画上去既慢又没有信息增量。
    final step = (sorted.length / maxPoints).ceil().clamp(1, 1 << 30);
    final kept = <({double lat, double lng, DateTime time})>[];
    for (var i = 0; i < sorted.length; i += step) {
      kept.add(sorted[i]);
    }
    if (kept.last != sorted.last) kept.add(sorted.last);

    var minLat = kept.first.lat, maxLat = kept.first.lat;
    var minLng = kept.first.lng, maxLng = kept.first.lng;
    for (final p in kept) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
    }
    // 经度按纬度收缩，否则高纬度的形状会被横向拉扁。
    final latSpan = (maxLat - minLat).abs();
    final lngSpan = (maxLng - minLng).abs();
    final midLatRad = ((minLat + maxLat) / 2) * math.pi / 180.0;
    final lngScale = math.cos(midLatRad).abs().clamp(0.05, 1.0);
    final w = lngSpan * lngScale;
    final h = latSpan;
    final span = (w > h ? w : h);
    if (span <= 0) return const []; // 全程站在原地，没有形状可言

    final out = <SummaryShapePoint>[];
    DateTime? prev;
    for (final p in kept) {
      final nx = ((p.lng - minLng) * lngScale - w / 2) / span + 0.5;
      final ny = 0.5 - ((p.lat - minLat) - h / 2) / span; // 上北
      final connected = prev != null &&
          p.time.difference(prev).inSeconds.abs() <= gapSeconds;
      out.add(SummaryShapePoint(nx, ny, connected: connected));
      prev = p.time;
    }
    return out;
  }

  /// 相邻点距离之和，用于没有 [FootprintSummary] 可用时（单段旅程）现算里程。
  static double pathMeters(
    List<({double lat, double lng, DateTime time})> points, {
    int gapSeconds = 1800,
    double maxSpeedMps = 83.3, // 300 km/h
  }) {
    if (points.length < 2) return 0;
    final sorted = [...points]..sort((a, b) => a.time.compareTo(b.time));
    var sum = 0.0;
    for (var i = 1; i < sorted.length; i++) {
      final a = sorted[i - 1], b = sorted[i];
      final dt = b.time.difference(a.time).inSeconds;
      if (dt <= 0 || dt > gapSeconds) continue;
      final d = haversineMeters(a.lat, a.lng, b.lat, b.lng);
      if (d / dt > maxSpeedMps) continue; // 与足迹统计同一条噪点规则
      sum += d;
    }
    return sum;
  }

  /// 把小时直方图归一化到 0..1。
  static List<double> normalizeHourly(List<int> hourly) {
    if (hourly.length != 24) return List<double>.filled(24, 0);
    final peak = hourly.fold<int>(0, (m, v) => v > m ? v : m);
    if (peak <= 0) return List<double>.filled(24, 0);
    return [for (final v in hourly) v / peak];
  }
}
