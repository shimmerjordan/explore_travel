import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/heat/heat_source.dart';

HeatBuildInput input(List<(double lat, double lng, int tSec, int layer)> pts,
    {bool gcj = false,
    List<(int bx, int by, int pop)> fog = const []}) {
  return HeatBuildInput(
    lat: Float64List.fromList([for (final p in pts) p.$1]),
    lng: Float64List.fromList([for (final p in pts) p.$2]),
    timeMs: Int64List.fromList([for (final p in pts) p.$3 * 1000]),
    layer: Int32List.fromList([for (final p in pts) p.$4]),
    gcj02: gcj,
    fogBx: Int32List.fromList([for (final f in fog) f.$1]),
    fogBy: Int32List.fromList([for (final f in fog) f.$2]),
    fogPop: Int32List.fromList([for (final f in fog) f.$3]),
  );
}

void main() {
  test('consecutive close fixes become segments; big gaps break them', () {
    final idx = buildHeatIndex(input([
      (30.000, 104.000, 0, 1),
      (30.001, 104.000, 10, 1), // linked
      (30.002, 104.000, 20, 1), // linked
      (30.002, 104.000, 20 + 31 * 60, 1), // 31 min later → new run (dot)
      (31.000, 104.000, 20 + 31 * 60 + 10, 1), // 111 km hop → dot
    ]));
    // 2 segments + 2 dots.
    expect(idx.trackCount, 4);
    expect(idx.fogCount, 0);
    var dots = 0, lines = 0;
    for (var i = 0; i < idx.count; i++) {
      final o = i << 2;
      if (idx.segs[o] == idx.segs[o + 2] && idx.segs[o + 1] == idx.segs[o + 3]) {
        dots++;
      } else {
        lines++;
      }
    }
    expect(lines, 2);
    expect(dots, 2);
  });

  test('different layers never connect', () {
    final idx = buildHeatIndex(input([
      (30.000, 104.000, 0, 1),
      (30.001, 104.000, 10, 2),
    ]));
    expect(idx.trackCount, 2); // two dots
  });

  test('fog blocks join as weighted dots', () {
    final idx = buildHeatIndex(input(const [], fog: [(100, 200, 4096), (101, 200, 1024)]));
    expect(idx.fogCount, 2);
    expect(idx.kinds, everyElement(1));
    expect(idx.weights[0], closeTo(1.0, 1e-6));
    expect(idx.weights[1], closeTo(0.25, 1e-6));
  });

  test('forEachIn returns only segments intersecting the window', () {
    final idx = buildHeatIndex(input([
      (30.000, 104.000, 0, 1),
      (30.001, 104.000, 10, 1),
      (40.000, 116.000, 1000, 1), // Beijing-ish, isolated
    ]));
    final x = HeatIndex.lngToWorldX(104.0005);
    final y = HeatIndex.latToWorldY(30.0005);
    final hit = <int>[];
    idx.forEachIn(x - 1e-5, y - 1e-5, x + 1e-5, y + 1e-5, hit.add);
    expect(hit.length, 1);
    final far = <int>[];
    final bx = HeatIndex.lngToWorldX(116.0), by = HeatIndex.latToWorldY(40.0);
    idx.forEachIn(bx - 1e-5, by - 1e-5, bx + 1e-5, by + 1e-5, far.add);
    expect(far.length, 1);
    expect(far.single, isNot(hit.single));
  });

  test('a segment crossing a z12 bucket edge is found from either side, once',
      () {
    // Bucket edge in world x at k/4096. Pick lng so that x straddles one.
    const per = 4096;
    final edgeX = 2500 / per;
    final lngA = HeatIndex.worldXToLng(edgeX - 4e-6);
    final lngB = HeatIndex.worldXToLng(edgeX + 4e-6);
    final idx = buildHeatIndex(input([
      (30.0, lngA, 0, 1),
      (30.0, lngB, 5, 1),
    ]));
    expect(idx.trackCount, 1);
    final y = HeatIndex.latToWorldY(30.0);
    final hits = <int>[];
    idx.forEachIn(edgeX - 1e-4, y - 1e-4, edgeX + 1e-4, y + 1e-4, hits.add);
    expect(hits, [0]); // once, not twice
    final left = <int>[];
    // Window entirely left of the bucket edge but overlapping the segment.
    idx.forEachIn(edgeX - 1e-4, y - 1e-4, edgeX - 1e-6, y + 1e-4, left.add);
    expect(left, [0]);
  });

  test('projection round-trips', () {
    for (final (lat, lng) in [(0.0, 0.0), (30.5, 104.1), (-45.0, -170.0), (80.0, 179.0)]) {
      expect(HeatIndex.worldXToLng(HeatIndex.lngToWorldX(lng)), closeTo(lng, 1e-9));
      expect(HeatIndex.worldYToLat(HeatIndex.latToWorldY(lat)), closeTo(lat, 1e-7));
    }
  });

  test('gcj02 shifts mainland coordinates, leaves the index otherwise equal', () {
    final a = buildHeatIndex(input([(30.0, 104.0, 0, 1)]));
    final b = buildHeatIndex(input([(30.0, 104.0, 0, 1)], gcj: true));
    expect(a.count, b.count);
    expect(a.segs[0], isNot(closeTo(b.segs[0], 1e-9)));
  });

  test('empty input yields the empty index', () {
    expect(buildHeatIndex(input(const [])).isEmpty, isTrue);
  });
}
