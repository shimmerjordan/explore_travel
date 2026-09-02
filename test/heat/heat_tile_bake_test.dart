import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/heat/heat_palette.dart';
import 'package:explore_journal/services/heat/heat_source.dart';
import 'package:explore_journal/services/heat/heat_tile_provider.dart';

/// Rasterises real heat tiles (needs the engine, hence `tester.runAsync`).
void main() {
  HeatSnapshot snap(List<(double lat, double lng, int tSec)> pts,
      {double exposure = 1.0, double width = 1.0, int palette = 1}) {
    final input = HeatBuildInput(
      lat: Float64List.fromList([for (final p in pts) p.$1]),
      lng: Float64List.fromList([for (final p in pts) p.$2]),
      timeMs: Int64List.fromList([for (final p in pts) p.$3 * 1000]),
      layer: Int32List.fromList(List.filled(pts.length, 1)),
      gcj02: false,
    );
    return HeatSnapshot(
      index: buildHeatIndex(input),
      lut: HeatPalette.byIndex(palette).lut(),
      exposure: exposure,
      width: width,
      generation: 1,
    );
  }

  /// Tile containing a lat/lng at zoom z.
  (int, int) tileOf(double lat, double lng, int z) {
    final n = 1 << z;
    return ((HeatIndex.lngToWorldX(lng) * n).floor(),
        (HeatIndex.latToWorldY(lat) * n).floor());
  }

  Future<Uint8List> pixels(ui.Image img) async {
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    return bd!.buffer.asUint8List();
  }

  int alphaAt(Uint8List px, int dim, int x, int y) => px[(y * dim + x) * 4 + 3];

  testWidgets('a horizontal walk paints a band through the tile, edges stay clear',
      (tester) async {
    await tester.runAsync(() async {
      const z = 15;
      const dim = 256;
      // A 300 m eastward walk at lat 30 — long enough to span most of a z15
      // tile (≈1.2 km wide) if we start near its left edge.
      final (tx, ty) = tileOf(30.0, 104.0, z);
      final n = 1 << z;
      final lngLeft = HeatIndex.worldXToLng((tx + 0.1) / n);
      final lngRight = HeatIndex.worldXToLng((tx + 0.9) / n);
      final latMid = HeatIndex.worldYToLat((ty + 0.5) / n);
      final s = snap([
        for (var i = 0; i <= 10; i++)
          (latMid, lngLeft + (lngRight - lngLeft) * i / 10, i * 20),
      ]);
      final img = await bakeHeatTileForTest(s, tx, ty, z, dim);
      final px = await pixels(img);
      // Middle row, middle column: painted.
      expect(alphaAt(px, dim, 128, 128), greaterThan(0));
      // Far above / below the line: clear.
      expect(alphaAt(px, dim, 128, 20), 0);
      expect(alphaAt(px, dim, 128, 236), 0);
      // Colour comes from the palette (火 → reddish/orange, never blue-ish).
      final i = (128 * dim + 128) * 4;
      expect(px[i], greaterThan(px[i + 2])); // R > B
    });
  });

  testWidgets('walking the same street twice is brighter than once',
      (tester) async {
    await tester.runAsync(() async {
      const z = 15;
      const dim = 256;
      final (tx, ty) = tileOf(30.0, 104.0, z);
      final n = 1 << z;
      final lngLeft = HeatIndex.worldXToLng((tx + 0.1) / n);
      final lngRight = HeatIndex.worldXToLng((tx + 0.9) / n);
      final latMid = HeatIndex.worldYToLat((ty + 0.5) / n);
      List<(double, double, int)> walk(int t0) => [
            for (var i = 0; i <= 10; i++)
              (latMid, lngLeft + (lngRight - lngLeft) * i / 10, t0 + i * 20),
          ];
      final once = await pixels(await bakeHeatTileForTest(
          snap(walk(0)), tx, ty, z, dim));
      final twice = await pixels(await bakeHeatTileForTest(
          snap([...walk(0), ...walk(10000)]), tx, ty, z, dim));
      // Intensity byte drives the LUT; more passes → later LUT entry →
      // brighter (higher luminance) at the line centre.
      double lum(Uint8List p) {
        final i = (128 * dim + 128) * 4;
        return 0.2126 * p[i] + 0.7152 * p[i + 1] + 0.0722 * p[i + 2];
      }
      expect(lum(twice), greaterThan(lum(once)));
    });
  });

  testWidgets('a tile with nothing nearby is fully transparent',
      (tester) async {
    await tester.runAsync(() async {
      final s = snap([(30.0, 104.0, 0)]);
      final (tx, ty) = tileOf(40.0, 116.0, 12);
      final img = await bakeHeatTileForTest(s, tx, ty, 12, 256);
      final px = await pixels(img);
      expect(px.every((b) => b == 0), isTrue);
    });
  });

  test('stroke width grows with zoom and is clamped', () {
    expect(heatStrokePx(14, 1.0), 3.0);
    expect(heatStrokePx(16, 1.0), 12.0);
    expect(heatStrokePx(10, 1.0), 1.0); // floor
    expect(heatStrokePx(20, 1.0), 14.0); // cap
    expect(heatStrokePx(14, 2.0), 6.0);
  });
}
