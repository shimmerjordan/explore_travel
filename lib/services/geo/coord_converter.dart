import 'dart:math' as math;
import '../../models/models.dart';

/// WGS-84 ↔ GCJ-02 coordinate conversion.
///
/// GCJ-02 (国测局坐标/"火星坐标") is the mandatory coordinate system
/// for all maps published inside China. Amap (高德) and Google China
/// tiles both use GCJ-02, while GPS hardware outputs WGS-84.
/// Plotting raw WGS-84 points on GCJ-02 tiles produces 100-700 m offsets.
class CoordConverter {
  static const double _a = 6378245.0;
  static const double _ee = 0.00669342162296594323;

  static bool _outOfChina(double lat, double lng) {
    return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;
  }

  static double _transformLat(double x, double y) {
    double ret = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    ret += (20.0 * math.sin(y * math.pi) +
            40.0 * math.sin(y / 3.0 * math.pi)) *
        2.0 /
        3.0;
    ret += (160.0 * math.sin(y / 12.0 * math.pi) +
            320.0 * math.sin(y * math.pi / 30.0)) *
        2.0 /
        3.0;
    return ret;
  }

  static double _transformLng(double x, double y) {
    double ret = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    ret += (20.0 * math.sin(x * math.pi) +
            40.0 * math.sin(x / 3.0 * math.pi)) *
        2.0 /
        3.0;
    ret += (150.0 * math.sin(x / 12.0 * math.pi) +
            300.0 * math.sin(x / 30.0 * math.pi)) *
        2.0 /
        3.0;
    return ret;
  }

  /// Convert WGS-84 → GCJ-02.
  static ({double lat, double lng}) wgs84ToGcj02(double lat, double lng) {
    if (_outOfChina(lat, lng)) return (lat: lat, lng: lng);
    double dLat = _transformLat(lng - 105.0, lat - 35.0);
    double dLng = _transformLng(lng - 105.0, lat - 35.0);
    final radLat = lat / 180.0 * math.pi;
    double magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
    dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
    return (lat: lat + dLat, lng: lng + dLng);
  }

  /// Convert GCJ-02 → WGS-84 (iterative, accurate to ~0.5 m).
  static ({double lat, double lng}) gcj02ToWgs84(double gcjLat, double gcjLng) {
    if (_outOfChina(gcjLat, gcjLng)) return (lat: gcjLat, lng: gcjLng);
    double wLat = gcjLat, wLng = gcjLng;
    for (int i = 0; i < 5; i++) {
      final g = wgs84ToGcj02(wLat, wLng);
      wLat += gcjLat - g.lat;
      wLng += gcjLng - g.lng;
    }
    return (lat: wLat, lng: wLng);
  }

  /// Whether the user's Ovital tile service is GCJ-02 (AppSettings.ovitalGcj02).
  /// Mirrored here by SettingsNotifier so the six coordinate boundaries that
  /// call [needsGcj02] (map, journal, picker, fog tile shift…) don't each
  /// need the settings object threaded through.
  static bool ovitalUsesGcj02 = true;

  /// Returns whether a given [MapProvider] uses GCJ-02 tiles.
  static bool needsGcj02(MapProvider provider) => switch (provider) {
        MapProvider.amap || MapProvider.google => true,
        MapProvider.ovital => ovitalUsesGcj02,
        MapProvider.osm => false,
      };
}
