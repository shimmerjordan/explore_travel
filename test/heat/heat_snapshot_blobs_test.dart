import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/heat/heat_source.dart';
import 'package:explore_journal/services/heat/heat_tile_provider.dart';

/// popcount 搬进 isolate 之后的对等性守卫：原始位图走 [buildHeatIndexFromBlobs]
/// 得到的索引，必须和「主线程先数好 fogPop 再 buildHeatIndex」的旧路一模一样。
void main() {
  Uint8List block(int setBytes, {int fill = 0xFF}) =>
      Uint8List.fromList(List.generate(512, (i) => i < setBytes ? fill : 0));

  Map<String, Object> payload(List<Uint8List> bitmaps,
      {List<(double, double, int, int)> pts = const []}) {
    return <String, Object>{
      'lat': Float64List.fromList([for (final p in pts) p.$1]),
      'lng': Float64List.fromList([for (final p in pts) p.$2]),
      'timeMs': Int64List.fromList([for (final p in pts) p.$3 * 1000]),
      'layer': Int32List.fromList([for (final p in pts) p.$4]),
      'gcj02': false,
      'fogBx': Int32List.fromList(List.generate(bitmaps.length, (i) => 100 + i)),
      'fogBy': Int32List.fromList(List.filled(bitmaps.length, 200)),
      'fogBitmaps': bitmaps,
    };
  }

  test('fog weights come from the popcount of each raw bitmap', () {
    final idx = buildHeatIndexFromBlobs(payload([
      block(512), // all 4096 bits set → weight 1
      block(128), // 1024 bits → 0.25
      block(64, fill: 0x0F), // 64 × 4 bits = 256 → 1/16
      block(0), // empty → 0
    ]));
    expect(idx.fogCount, 4);
    expect(idx.kinds, everyElement(1));
    expect(idx.weights[0], closeTo(1.0, 1e-6));
    expect(idx.weights[1], closeTo(0.25, 1e-6));
    expect(idx.weights[2], closeTo(1 / 16, 1e-6));
    expect(idx.weights[3], closeTo(0.0, 1e-6));
  });

  test('matches the pre-counted HeatBuildInput path exactly', () async {
    final bitmaps = [block(512), block(37, fill: 0x81), block(300, fill: 0x55)];
    const pts = [
      (30.000, 104.000, 0, 1),
      (30.001, 104.000, 10, 1),
      (30.5, 104.5, 20 + 31 * 60, 1),
    ];
    final p = payload(bitmaps, pts: pts);
    // Old path: popcount on the caller, then the pure builder.
    final pop = Int32List.fromList([
      for (final b in bitmaps)
        b.fold<int>(0, (s, v) {
          var c = 0;
          for (var x = v; x != 0; x >>= 1) {
            c += x & 1;
          }
          return s + c;
        }),
    ]);
    final old = buildHeatIndex(HeatBuildInput(
      lat: p['lat'] as Float64List,
      lng: p['lng'] as Float64List,
      timeMs: p['timeMs'] as Int64List,
      layer: p['layer'] as Int32List,
      gcj02: false,
      fogBx: p['fogBx'] as Int32List,
      fogBy: p['fogBy'] as Int32List,
      fogPop: pop,
    ));
    // New path, through a real isolate like loadHeatSnapshot does.
    final fresh = await compute(buildHeatIndexFromBlobs, p);
    expect(fresh.count, old.count);
    expect(fresh.trackCount, old.trackCount);
    expect(fresh.fogCount, old.fogCount);
    expect(fresh.segs, old.segs);
    expect(fresh.weights, old.weights);
    expect(fresh.kinds, old.kinds);
    expect(fresh.buckets.keys.toSet(), old.buckets.keys.toSet());
    for (final k in old.buckets.keys) {
      expect(fresh.buckets[k], old.buckets[k]);
    }
  });

  test('no points and no fog → the empty index', () {
    expect(buildHeatIndexFromBlobs(payload(const [])).isEmpty, isTrue);
  });
}
