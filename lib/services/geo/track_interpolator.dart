import 'package:drift/drift.dart';
import '../../data/db/database.dart';
import '../location/point_filter.dart';

/// 由时间反推位置：一张照片只有拍摄时间、没有 GPS 时，用前后最近的轨迹点插值出
/// 它大概在哪。借鉴 Dawarich「Enrich Photos」：前后都有点就线性插值，只有一侧
/// 就取最近点，超出容差就放弃——宁可让用户手选，也不要把照片钉到几公里外。
class InterpolatedPosition {
  final double lat;
  final double lng;

  /// `interpolated`（两侧插值）| `nearest`（单侧最近点）。
  final String source;

  /// 与最近一个轨迹点的时间差（绝对值）。UI 拿它提示「由轨迹推算（±3 分）」。
  final Duration gap;
  const InterpolatedPosition(this.lat, this.lng,
      {required this.source, required this.gap});
}

class TrackInterpolator {
  static const Duration defaultTolerance = Duration(minutes: 30);

  /// 在 [t] 前后各找一个非噪点的轨迹点（不限图层：拍照的人只有一个）。
  static Future<InterpolatedPosition?> positionAt(
    AppDb db,
    DateTime t, {
    Duration tolerance = defaultTolerance,
  }) async {
    final lo = t.subtract(tolerance);
    final hi = t.add(tolerance);
    final before = await (db.select(db.trackPoints)
          ..where((p) =>
              p.time.isBetweenValues(lo, t) &
              p.flags.equals(0))
          ..orderBy([(p) => OrderingTerm.desc(p.time)])
          ..limit(1))
        .getSingleOrNull();
    final after = await (db.select(db.trackPoints)
          ..where((p) =>
              p.time.isBiggerThanValue(t) &
              p.time.isSmallerOrEqualValue(hi) &
              p.flags.equals(0))
          ..orderBy([(p) => OrderingTerm.asc(p.time)])
          ..limit(1))
        .getSingleOrNull();
    return interpolate(t, before, after);
  }

  /// 纯函数部分，方便单测。
  static InterpolatedPosition? interpolate(
      DateTime t, TrackPoint? before, TrackPoint? after) {
    if (before != null && after != null) {
      final span = after.time.difference(before.time).inMilliseconds;
      if (span <= 0) {
        return InterpolatedPosition(before.lat, before.lng,
            source: 'nearest', gap: t.difference(before.time).abs());
      }
      // 前后两点隐含速度超过快走（> 200 m/min ≈ 12 km/h）且拉开了 > 500 m，
      // 中间大概率是坐车/断录；人几乎不会在车上拍手账照片，插值会把它钉到
      // 半路上。退化为取时间上更近的一侧。
      final dist = PointFilter.haversineMeters(
          before.lat, before.lng, after.lat, after.lng);
      final minutes = span / 60000.0;
      if (dist > 200 * minutes && dist > 500) {
        final nearBefore = t.difference(before.time).abs() <=
            after.time.difference(t).abs();
        final p = nearBefore ? before : after;
        return InterpolatedPosition(p.lat, p.lng,
            source: 'nearest', gap: t.difference(p.time).abs());
      }
      final f = (t.difference(before.time).inMilliseconds / span)
          .clamp(0.0, 1.0);
      final gap = [
        t.difference(before.time).abs(),
        after.time.difference(t).abs(),
      ].reduce((a, b) => a < b ? a : b);
      return InterpolatedPosition(
        before.lat + (after.lat - before.lat) * f,
        before.lng + (after.lng - before.lng) * f,
        source: 'interpolated',
        gap: gap,
      );
    }
    final p = before ?? after;
    if (p == null) return null;
    return InterpolatedPosition(p.lat, p.lng,
        source: 'nearest', gap: t.difference(p.time).abs());
  }
}
