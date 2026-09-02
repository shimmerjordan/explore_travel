import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/heat/heat3d_camera.dart';
import 'package:explore_journal/services/heat/heat_source.dart';
import 'package:explore_journal/services/geo/region_stats.dart';
import 'package:explore_journal/ui/heat/region_cloud_layer.dart';

RegionStat region(String city, double lat, double lng, int days,
        {String country = '中国'}) =>
    RegionStat(
      country: country,
      province: '',
      city: city,
      days: {for (var i = 0; i < days; i++) 20000 + i},
      points: days * 50,
      cellCount: 1,
      lat: lat,
      lng: lng,
      minLat: lat - 0.1,
      maxLat: lat + 0.1,
      minLng: lng - 0.1,
      maxLng: lng + 0.1,
    );

Heat3DCamera camAt(double lat, double lng, {double zoom = 6}) => Heat3DCamera(
      centerX01: HeatIndex.lngToWorldX(lng),
      centerY01: HeatIndex.latToWorldY(lat),
      zoom: zoom,
      pitchDeg: 45,
      viewport: const Size(400, 800),
    );

void main() {
  test('estimateLabelWidth: CJK is an em, ASCII narrower, flags widest', () {
    const fs = 20.0;
    final cjk = estimateLabelWidth('上海市', fs);
    final ascii = estimateLabelWidth('abc', fs);
    expect(cjk, closeTo(3 * fs, 1e-9));
    expect(ascii, lessThan(cjk));
    // A flag is a surrogate pair of regional indicators counted as one glyph.
    expect(estimateLabelWidth('🇨🇳', fs), closeTo(1.35 * fs, 1e-6));
    expect(estimateLabelWidth('上海市', 10), lessThan(cjk));
  });

  group('declutterIndices', () {
    test('keeps non-overlapping rects, drops the ones that collide', () {
      final rects = [
        const Rect.fromLTWH(0, 0, 50, 20),
        const Rect.fromLTWH(200, 0, 50, 20), // clear
        const Rect.fromLTWH(10, 5, 50, 20), // collides with #0
        const Rect.fromLTWH(0, 100, 50, 20), // clear
      ];
      expect(declutterIndices(rects), [0, 1, 3]);
    });

    test('input order is the priority order — first wins the space', () {
      const a = Rect.fromLTWH(0, 0, 80, 24);
      const b = Rect.fromLTWH(20, 4, 80, 24);
      expect(declutterIndices([a, b]), [0]);
      expect(declutterIndices([b, a]), [0]);
    });

    test('the pad separates rects that merely touch', () {
      final rects = [
        const Rect.fromLTWH(0, 0, 50, 20),
        const Rect.fromLTWH(51, 0, 50, 20),
      ];
      expect(declutterIndices(rects, pad: 0).length, 2);
      expect(declutterIndices(rects, pad: 4).length, 1);
    });
  });

  test('pinBand spreads days across the bands, hottest last', () {
    expect(pinBand(1, 100), inInclusiveRange(0, 1));
    expect(pinBand(100, 100), kPinBands - 1);
    expect(pinBand(10, 100), inInclusiveRange(1, kPinBands - 2));
    // Degenerate input must not divide by zero or go out of range.
    expect(pinBand(0, 0), kPinBands - 1);
    for (final d in [0, 1, 7, 365]) {
      expect(pinBand(d, 365), inInclusiveRange(0, kPinBands - 1));
    }
  });

  group('layoutRegionLabels', () {
    test('places visible regions, busiest first, and skips collisions', () {
      // Two cities ~1000 km apart at z6 → far enough not to collide.
      final regions = [
        region('上海市', 31.23, 121.47, 300),
        region('北京市', 39.90, 116.40, 40),
      ];
      final placed = layoutRegionLabels(
        regions: regions,
        cam: camAt(35.5, 119.0, zoom: 5),
        maxDayCount: 300,
      );
      expect(placed.length, 2);
      expect(placed.first.region.displayName, '上海市');
      // The busier city gets the bigger label.
      expect(placed[0].fontSize, greaterThan(placed[1].fontSize));
      // Labels sit above their pin.
      for (final p in placed) {
        expect(p.rect.bottom, lessThanOrEqualTo(p.anchor.dy));
      }
    });

    test('two cities in the same spot: only the busier one is labelled', () {
      // Comparable day counts → same pin height, so the labels really do
      // land on top of each other (very different counts stack vertically,
      // which is fine and stays readable).
      final placed = layoutRegionLabels(
        regions: [
          region('大城', 31.23, 121.47, 300),
          region('小城', 31.24, 121.48, 295),
        ],
        cam: camAt(31.23, 121.47, zoom: 6),
        maxDayCount: 300,
      );
      expect(placed.length, 1);
      expect(placed.single.region.displayName, '大城');
    });

    test('regions off-screen or past the fog line are dropped', () {
      final placed = layoutRegionLabels(
        regions: [region('远方', -33.87, 151.21, 10)], // Sydney
        cam: camAt(31.23, 121.47, zoom: 12), // camera over Shanghai
        maxDayCount: 10,
      );
      expect(placed, isEmpty);
    });

    test('the limit caps how many labels are even considered', () {
      final many = [
        for (var i = 0; i < 40; i++) region('城$i', 31.0 + i * 0.5, 121.0, 40 - i)
      ];
      final placed = layoutRegionLabels(
        regions: many,
        cam: camAt(35.0, 121.0, zoom: 4),
        maxDayCount: 40,
        limit: 5,
      );
      expect(placed.length, lessThanOrEqualTo(5));
    });
  });
}
