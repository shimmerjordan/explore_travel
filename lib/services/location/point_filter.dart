import 'dart:math' as math;

/// GPS 噪点判定（录制与导入共用）。规则移植自 Dawarich `Points::AnomalyFilter`
/// 的保守子集：
///
///   * **drop** —— 根本不该进库的点：Null Island (0,0) 附近、坐标越界、
///     精度差到没有信息量（> [maxAccuracyMeters]）。
///   * **anomaly** —— 进库但打标记（`track_points.flags & 1`）：相对上一保留点
///     的隐含速度超过 [maxSpeedMps]（默认 250 m/s ≈ 900 km/h，民航巡航之上），
///     或同一时间戳却位移 > 1 km。热图 / 到访 / 统计默认排除它们，但数据不丢，
///     用户随时能回看。**标记不删**是 Dawarich 踩过坑之后的选择。
///
/// 纯函数、无 IO，方便单测；调用方自己维护"上一保留点"。
enum PointVerdict { keep, drop, anomaly }

class PointSample {
  final double lat;
  final double lng;
  final int timeMs;
  final double? accuracy;
  const PointSample(this.lat, this.lng, this.timeMs, {this.accuracy});
}

class PointFilter {
  /// 精度阈值。Dawarich 用 10 km，但手机上 >500 m 的点基本只出现在室内
  /// 基站定位，画出来就是一团错位的斑，比丢掉更糟。
  static const double maxAccuracyMeters = 500;

  /// 隐含速度上限（m/s）。
  static const double maxSpeedMps = 250;

  /// 隐含速度判定只在两点间隔不超过这个时长时才可信（间隔太长本来就没法算）。
  static const int speedWindowMs = 3600 * 1000;

  /// 同时间戳允许的最大位移（米）。
  static const double sameStampJumpMeters = 1000;

  /// Null Island 保护半径（度）。(0,0) 附近 5 km 内一律视为无效。
  static const double nullIslandDeg = 0.05;

  static PointVerdict judge(PointSample cur, {PointSample? prev}) {
    if (cur.lat.isNaN ||
        cur.lng.isNaN ||
        cur.lat.abs() > 90 ||
        cur.lng.abs() > 180) {
      return PointVerdict.drop;
    }
    if (cur.lat.abs() < nullIslandDeg && cur.lng.abs() < nullIslandDeg) {
      return PointVerdict.drop;
    }
    final acc = cur.accuracy;
    if (acc != null && acc.isFinite && acc > maxAccuracyMeters) {
      return PointVerdict.drop;
    }
    if (prev == null) return PointVerdict.keep;

    final dt = cur.timeMs - prev.timeMs;
    final dist = haversineMeters(prev.lat, prev.lng, cur.lat, cur.lng);
    if (dt.abs() < 1000) {
      // 同一秒：位移超过 1 km 只能是瞬移。
      return dist > sameStampJumpMeters
          ? PointVerdict.anomaly
          : PointVerdict.keep;
    }
    if (dt.abs() <= speedWindowMs) {
      final v = dist / (dt.abs() / 1000.0);
      if (v > maxSpeedMps) return PointVerdict.anomaly;
    }
    return PointVerdict.keep;
  }

  static double haversineMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}

/// `track_points.flags` 位定义。
abstract final class PointFlags {
  static const int anomaly = 1;
}
