import 'dart:math' as math;

import 'package:explore_journal/core/geo_math.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:explore_journal/services/heat/heat_source.dart';
import 'package:explore_journal/services/location/point_filter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 合并前散落在 5 处的 haversine 原文（recording_controller / replay_model /
/// track_import / map_screen 各一份），保留在这里当参照：新实现必须与它们
/// 逐位一致或只差浮点尾数。
double _legacyAtan2(double lat1, double lng1, double lat2, double lng2) {
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

/// map_screen 旧版：asin 形式。
double _legacyAsin(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// track_import 旧版：半角 (1-cos)/2 形式。
double _legacyHalfAngle(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p = math.pi / 180;
  final a = 0.5 -
      math.cos((lat2 - lat1) * p) / 2 +
      math.cos(lat1 * p) * math.cos(lat2 * p) * (1 - math.cos((lng2 - lng1) * p)) / 2;
  return 2 * r * math.asin(math.sqrt(a));
}

/// FogEngine 合并前的原文。
int _legacyLatToGlobalY(double lat) {
  final latRad = lat * math.pi / 180.0;
  final y =
      (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
          2.0 *
          FogEngine.full;
  return y.floor().clamp(0, FogEngine.full - 1);
}

void main() {
  group('haversineMeters', () {
    const cases = <List<double>>[
      [0, 0, 0, 0],
      [31.2304, 121.4737, 39.9042, 116.4074], // 上海 → 北京
      [31.2304, 121.4737, 31.2305, 121.4738], // 相邻两点
      [-33.8688, 151.2093, 51.5074, -0.1278], // 悉尼 → 伦敦
      [89.9, 0, -89.9, 180], // 近对极
      [10, 179.9, 10, -179.9], // 跨日界线
    ];

    test('与旧的 atan2 实现逐位一致', () {
      for (final c in cases) {
        expect(haversineMeters(c[0], c[1], c[2], c[3]),
            _legacyAtan2(c[0], c[1], c[2], c[3]));
      }
    });

    test('与旧的 asin / 半角实现只差浮点尾数', () {
      for (final c in cases) {
        final d = haversineMeters(c[0], c[1], c[2], c[3]);
        expect(d, closeTo(_legacyAsin(c[0], c[1], c[2], c[3]), 1e-6));
        // 半角形式 (1-cos x)/2 在 x→0 时有抵消误差（相邻两点差 0.1 mm 量级），
        // 是旧实现更粗，不是新实现有问题——按相对误差比。
        final half = _legacyHalfAngle(c[0], c[1], c[2], c[3]);
        expect(d, closeTo(half, 1e-6 + half * 1e-4));
      }
    });

    test('已知距离：上海到北京约 1068 km', () {
      expect(haversineMeters(31.2304, 121.4737, 39.9042, 116.4074) / 1000,
          closeTo(1068, 2));
    });

    test('PointFilter.haversineMeters 是同一实现', () {
      for (final c in cases) {
        expect(PointFilter.haversineMeters(c[0], c[1], c[2], c[3]),
            haversineMeters(c[0], c[1], c[2], c[3]));
      }
    });
  });

  group('Web Mercator', () {
    final lats = <double>[
      -85.05112878, -85, -60, -45.5, -1e-9, 0, 1e-9, 23.4567, 45.5, 60,
      80, 85, 85.05112878, //
    ];
    final lngs = <double>[-180, -179.9, -90, -0.001, 0, 0.001, 90, 179.9, 180];

    test('正反投影互逆', () {
      for (final lat in lats) {
        expect(worldYToLat(latToWorldY(lat)), closeTo(lat, 1e-9));
      }
      for (final lng in lngs) {
        expect(worldXToLng(lngToWorldX(lng)), closeTo(lng, 1e-9));
      }
    });

    test('赤道与本初子午线落在世界坐标中点', () {
      expect(latToWorldY(0), closeTo(0.5, 1e-15));
      expect(lngToWorldX(0), closeTo(0.5, 1e-15));
      expect(worldYToLat(0.5), closeTo(0, 1e-12));
    });

    test('纬度超出 ±85.05° 被钳到边界', () {
      expect(latToWorldY(89.9), latToWorldY(kMercatorMaxLat));
      expect(latToWorldY(-89.9), latToWorldY(-kMercatorMaxLat));
      expect(latToWorldY(kMercatorMaxLat), closeTo(0, 1e-9));
      expect(latToWorldY(-kMercatorMaxLat), closeTo(1, 1e-9));
    });

    test('FogEngine 像素投影与合并前原文逐位一致（含极区钳制）', () {
      final probe = <double>[...lats, -89.9, -88, 88, 89.9, 89.999];
      for (final lat in probe) {
        expect(FogEngine.latToGlobalY(lat), _legacyLatToGlobalY(lat),
            reason: 'lat=$lat');
      }
      // 细密采样一遍，防止只有边界对上。
      for (var lat = -85.0; lat <= 85.0; lat += 0.37) {
        expect(FogEngine.latToGlobalY(lat), _legacyLatToGlobalY(lat),
            reason: 'lat=$lat');
      }
      for (var gy = 0; gy < FogEngine.full; gy += 4099) {
        final n = math.pi - 2.0 * math.pi * gy / FogEngine.full;
        final legacy =
            180.0 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
        expect(FogEngine.globalYToLat(gy), closeTo(legacy, 1e-12));
      }
    });

    test('HeatIndex 的投影静态方法是同一实现', () {
      for (final lat in lats) {
        expect(HeatIndex.latToWorldY(lat), latToWorldY(lat));
        expect(HeatIndex.worldYToLat(latToWorldY(lat)),
            worldYToLat(latToWorldY(lat)));
      }
      for (final lng in lngs) {
        expect(HeatIndex.lngToWorldX(lng), lngToWorldX(lng));
        expect(HeatIndex.worldXToLng(lngToWorldX(lng)),
            worldXToLng(lngToWorldX(lng)));
      }
    });
  });
}
