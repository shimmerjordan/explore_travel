import 'dart:convert';
import 'package:flutter/services.dart';

/// Optional GeoJSON polygon support for exploration progress.
///
/// If `assets/boundaries/<country>.geojson` is bundled, ExploreScreen will
/// use the true polygon (ray-casting point-in-polygon) instead of the bbox
/// grid. To enable, drop GeoJSON `FeatureCollection` files into
/// `assets/boundaries/` and list them in `pubspec.yaml` assets section.
///
/// Supported geometries: `Polygon` and `MultiPolygon`.
class GeoFeature {
  final String name;
  final List<List<List<double>>> rings; // outer + holes, then more polys
  /// `rings[i]` = polygon i (ring 0 outer, rest holes). One feature can
  /// produce multiple polygons (MultiPolygon flattened: each item is
  /// a separate polygon's rings).
  /// For simplicity we store all polygons as a flat list and check each.
  final List<List<List<List<double>>>> polygons;
  final List<double> bbox;
  GeoFeature(this.name, this.polygons, this.bbox)
      : rings = polygons.expand((p) => p).toList();

  bool contains(double lat, double lng) {
    if (lng < bbox[1] || lng > bbox[3] || lat < bbox[0] || lat > bbox[2]) {
      return false;
    }
    for (final poly in polygons) {
      if (poly.isEmpty) continue;
      final outer = poly[0];
      if (!_inRing(outer, lat, lng)) continue;
      bool inHole = false;
      for (int i = 1; i < poly.length; i++) {
        if (_inRing(poly[i], lat, lng)) {
          inHole = true;
          break;
        }
      }
      if (!inHole) return true;
    }
    return false;
  }

  static bool _inRing(List<List<double>> ring, double lat, double lng) {
    bool inside = false;
    final n = ring.length;
    for (int i = 0, j = n - 1; i < n; j = i++) {
      final xi = ring[i][0]; // lng
      final yi = ring[i][1]; // lat
      final xj = ring[j][0];
      final yj = ring[j][1];
      final intersect = ((yi > lat) != (yj > lat)) &&
          (lng < (xj - xi) * (lat - yi) / (yj - yi + 1e-12) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }
}

class GeoJsonLoader {
  /// Tries to load `assets/boundaries/<name>.geojson`. Returns null if
  /// missing or unparseable.
  static Future<GeoFeature?> tryLoad(String name) async {
    try {
      final raw = await rootBundle
          .loadString('assets/boundaries/$name.geojson');
      return _parse(name, jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static GeoFeature? _parse(String name, dynamic data) {
    final polygons = <List<List<List<double>>>>[];
    void addGeom(Map<String, dynamic> geom) {
      final type = geom['type'];
      final coords = geom['coordinates'];
      if (type == 'Polygon') {
        polygons.add(_rings(coords as List));
      } else if (type == 'MultiPolygon') {
        for (final poly in coords as List) {
          polygons.add(_rings(poly as List));
        }
      }
    }

    if (data is Map && data['type'] == 'FeatureCollection') {
      for (final f in data['features']) {
        final geom = f['geometry'];
        if (geom is Map<String, dynamic>) addGeom(geom);
      }
    } else if (data is Map && data['type'] == 'Feature') {
      final geom = data['geometry'];
      if (geom is Map<String, dynamic>) addGeom(geom);
    } else if (data is Map && (data['type'] == 'Polygon' || data['type'] == 'MultiPolygon')) {
      addGeom(Map<String, dynamic>.from(data));
    } else {
      return null;
    }

    if (polygons.isEmpty) return null;
    double minLat = 90, minLng = 180, maxLat = -90, maxLng = -180;
    for (final poly in polygons) {
      for (final ring in poly) {
        for (final pt in ring) {
          final lng = pt[0];
          final lat = pt[1];
          if (lat < minLat) minLat = lat;
          if (lat > maxLat) maxLat = lat;
          if (lng < minLng) minLng = lng;
          if (lng > maxLng) maxLng = lng;
        }
      }
    }
    return GeoFeature(name, polygons, [minLat, minLng, maxLat, maxLng]);
  }

  static List<List<List<double>>> _rings(List raw) {
    return raw
        .map<List<List<double>>>((ring) => (ring as List)
            .map<List<double>>((pt) =>
                [(pt[0] as num).toDouble(), (pt[1] as num).toDouble()])
            .toList())
        .toList();
  }
}
