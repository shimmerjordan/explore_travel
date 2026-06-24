import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/models/models.dart';
import 'package:explore_journal/services/geo/coord_converter.dart';

/// Great-circle distance in meters between two WGS-84 points. Used to assert
/// the GCJ-02 offset magnitude and round-trip accuracy in meters (more
/// intuitive than degrees).
double _haversineM(double lat0, double lng0, double lat1, double lng1) {
  const r = 6371008.8; // mean Earth radius (m)
  final dLat = (lat1 - lat0) * math.pi / 180.0;
  final dLng = (lng1 - lng0) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat0 * math.pi / 180.0) *
          math.cos(lat1 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

void main() {
  group('CoordConverter.needsGcj02', () {
    test('amap and google use GCJ-02 tiles', () {
      expect(CoordConverter.needsGcj02(MapProvider.amap), isTrue);
      expect(CoordConverter.needsGcj02(MapProvider.google), isTrue);
    });

    test('osm uses raw WGS-84 (no shift)', () {
      expect(CoordConverter.needsGcj02(MapProvider.osm), isFalse);
    });
  });

  group('CoordConverter out-of-China passthrough', () {
    // The GCJ-02 obfuscation is only defined inside China's rough bbox.
    // Everywhere else the converter MUST be an exact identity, otherwise
    // overseas tracks would drift.
    final overseas = <(String, double, double)>[
      ('London', 51.5074, -0.1278),
      ('New York', 40.7128, -74.0060),
      ('Sydney', -33.8688, 151.2093),
      ('just south of the China bbox', 0.5, 110.0),
      ('just west of the China bbox', 30.0, 70.0),
    ];

    for (final (name, lat, lng) in overseas) {
      test('$name is returned unchanged both directions', () {
        final g = CoordConverter.wgs84ToGcj02(lat, lng);
        expect(g.lat, lat, reason: '$name lat must not shift');
        expect(g.lng, lng, reason: '$name lng must not shift');

        final w = CoordConverter.gcj02ToWgs84(lat, lng);
        expect(w.lat, lat);
        expect(w.lng, lng);
      });
    }
  });

  group('CoordConverter in-China shift', () {
    // A spread of points well inside China so _outOfChina is false.
    final inChina = <(String, double, double)>[
      ('Beijing / Tiananmen', 39.90750, 116.39124),
      ('Shanghai', 31.2304, 121.4737),
      ('Chengdu', 30.5728, 104.0668),
      ('Guangzhou', 23.1291, 113.2644),
      ('Urumqi', 43.8256, 87.6168),
    ];

    for (final (name, lat, lng) in inChina) {
      test('$name shifts by a realistic 50–800 m', () {
        final g = CoordConverter.wgs84ToGcj02(lat, lng);
        final offset = _haversineM(lat, lng, g.lat, g.lng);
        expect(offset, greaterThan(50.0),
            reason: '$name: GCJ shift suspiciously small ($offset m)');
        expect(offset, lessThan(800.0),
            reason: '$name: GCJ shift suspiciously large ($offset m)');
      });

      test('$name round-trips WGS→GCJ→WGS to < 1 m', () {
        final g = CoordConverter.wgs84ToGcj02(lat, lng);
        final back = CoordConverter.gcj02ToWgs84(g.lat, g.lng);
        final err = _haversineM(lat, lng, back.lat, back.lng);
        expect(err, lessThan(1.0),
            reason: '$name: round-trip error $err m exceeds the documented '
                '~0.5 m accuracy');
      });

      test('$name round-trips GCJ→WGS→GCJ to < 1 m', () {
        final w = CoordConverter.gcj02ToWgs84(lat, lng);
        final fwd = CoordConverter.wgs84ToGcj02(w.lat, w.lng);
        final err = _haversineM(lat, lng, fwd.lat, fwd.lng);
        expect(err, lessThan(1.0));
      });
    }

    test('conversion is deterministic (pure function)', () {
      final a = CoordConverter.wgs84ToGcj02(39.9075, 116.39124);
      final b = CoordConverter.wgs84ToGcj02(39.9075, 116.39124);
      expect(a.lat, b.lat);
      expect(a.lng, b.lng);
    });

    test('Beijing golden — pins the canonical GCJ-02 algorithm output', () {
      // Regression guard: Tiananmen WGS-84 (39.90750, 116.39124) → GCJ-02 under
      // the standard "eviltransform" algorithm is ≈(39.908901, 116.397481).
      // Pinned tightly so any change to the transform constants/formula trips
      // this test. (~1e-5° ≈ 1 m of slack absorbs only float noise.)
      final g = CoordConverter.wgs84ToGcj02(39.90750, 116.39124);
      expect(g.lat, closeTo(39.908901, 1e-5),
          reason: 'got lat ${g.lat}');
      expect(g.lng, closeTo(116.397481, 1e-5),
          reason: 'got lng ${g.lng}');
    });
  });
}
