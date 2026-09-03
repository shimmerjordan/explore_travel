/// 地理数学：大圆距离与 Web Mercator 投影。
///
/// 全 App 唯一实现。以前 haversine 在 5 个文件里各抄了一份、Mercator 反投影抄了
/// 3 份，数值一样但形式不同（atan2 / asin / 半角），改一处漏一处。
/// `FogEngine` / `HeatIndex` / `PointFilter` 上同名的静态方法只是转到这里。
library;

import 'dart:math' as math;

/// 地球平均半径（米）。与 FOW 数据格式及历史实现一致，勿改。
const double kEarthRadiusM = 6371000.0;

/// Web Mercator 能表示的纬度上限（±85.05112878°），瓦片世界坐标 Y ∈ [0,1]。
const double kMercatorMaxLat = 85.05112878;

/// 两个 WGS-84 点之间的大圆距离（米）。
double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * kEarthRadiusM * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// 经度 → 世界坐标 X ∈ [0, 1]。
double lngToWorldX(double lng) => (lng + 180.0) / 360.0;

/// 纬度 → 世界坐标 Y ∈ [0, 1]（北为 0）。超出 ±85.05° 钳到边界。
double latToWorldY(double lat) {
  final l = lat.clamp(-kMercatorMaxLat, kMercatorMaxLat) * math.pi / 180.0;
  return (1.0 - math.log(math.tan(l) + 1.0 / math.cos(l)) / math.pi) / 2.0;
}

/// 世界坐标 X → 经度。
double worldXToLng(double x) => x * 360.0 - 180.0;

/// 世界坐标 Y → 纬度。
double worldYToLat(double y) {
  final n = math.pi - 2.0 * math.pi * y;
  return 180.0 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
}
