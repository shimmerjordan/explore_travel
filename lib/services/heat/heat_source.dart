import 'dart:math' as math;
import 'dart:typed_data';

import '../fog/fog_engine.dart';
import '../geo/coord_converter.dart';
import '../location/point_filter.dart';

/// Track-point history turned into drawable line segments in Web-Mercator
/// **world coordinates** (x, y ∈ [0,1)), bucketed by z12 tile so a tile bake
/// only touches the segments near it. Pure data: no Flutter, no DB — built
/// from packed arrays so it can run in `compute()`.
///
/// Segment rule (Dawarich `minutes_between_routes` = 30 plus a distance cap):
/// consecutive fixes of the SAME layer within 30 min and 2 km are connected;
/// anything else is an isolated dot. Fog blocks (imported Fog of World data
/// that never had track points) join as faint dots so those areas aren't
/// blank on the heat map — the "迷雾块做底噪" the user asked for.
class HeatIndex {
  /// n × 4: x0, y0, x1, y1 in world coords. Degenerate (x0==x1, y0==y1) = dot.
  final Float32List segs;

  /// n: 1.0 for track segments; (0,1] popcount fraction for fog blocks.
  final Float32List weights;

  /// n: 0 = track, 1 = fog block.
  final Uint8List kinds;

  /// z12 bucket key → segment indices. Key = (tx << 12) | ty.
  final Map<int, Int32List> buckets;

  final int trackCount;
  final int fogCount;

  const HeatIndex._(this.segs, this.weights, this.kinds, this.buckets,
      this.trackCount, this.fogCount);

  static final HeatIndex empty = HeatIndex._(
      Float32List(0), Float32List(0), Uint8List(0), const <int, Int32List>{}, 0, 0);

  int get count => kinds.length;
  bool get isEmpty => count == 0;

  static const int bucketZoom = 12;
  static const int _bucketsPerAxis = 1 << bucketZoom;

  /// Visit every segment whose bbox intersects the world rect.
  void forEachIn(double x0, double y0, double x1, double y1,
      void Function(int i) fn) {
    if (isEmpty) return;
    final bx0 = (x0 * _bucketsPerAxis).floor().clamp(0, _bucketsPerAxis - 1);
    final bx1 = (x1 * _bucketsPerAxis).floor().clamp(0, _bucketsPerAxis - 1);
    final by0 = (y0 * _bucketsPerAxis).floor().clamp(0, _bucketsPerAxis - 1);
    final by1 = (y1 * _bucketsPerAxis).floor().clamp(0, _bucketsPerAxis - 1);
    // A segment spanning two buckets is listed in both; dedup only when the
    // query touches more than one bucket.
    final multi = bx0 != bx1 || by0 != by1;
    final seen = multi ? <int>{} : null;
    for (var bx = bx0; bx <= bx1; bx++) {
      for (var by = by0; by <= by1; by++) {
        final list = buckets[(bx << bucketZoom) | by];
        if (list == null) continue;
        for (final i in list) {
          if (seen != null && !seen.add(i)) continue;
          final o = i << 2;
          final sx0 = segs[o], sy0 = segs[o + 1], sx1 = segs[o + 2], sy1 = segs[o + 3];
          final minX = sx0 < sx1 ? sx0 : sx1, maxX = sx0 < sx1 ? sx1 : sx0;
          final minY = sy0 < sy1 ? sy0 : sy1, maxY = sy0 < sy1 ? sy1 : sy0;
          if (maxX < x0 || minX > x1 || maxY < y0 || minY > y1) continue;
          fn(i);
        }
      }
    }
  }

  // ─── Projection helpers ───

  static double lngToWorldX(double lng) => (lng + 180.0) / 360.0;

  static double latToWorldY(double lat) {
    final l = lat.clamp(-85.05112878, 85.05112878) * math.pi / 180.0;
    return (1.0 - math.log(math.tan(l) + 1.0 / math.cos(l)) / math.pi) / 2.0;
  }

  static double worldXToLng(double x) => x * 360.0 - 180.0;

  static double worldYToLat(double y) {
    final n = math.pi - 2.0 * math.pi * y;
    return 180.0 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
  }
}

/// Packed input for [buildHeatIndex]. Points must be sorted by (layer, time)
/// and already filtered (clean, in range). Fog arrays may be empty.
class HeatBuildInput {
  final Float64List lat;
  final Float64List lng;
  final Int64List timeMs;
  final Int32List layer;
  final bool gcj02;

  /// Fog blocks: FOW global block coords (tileX/tileY of fog_tiles rows) and
  /// popcount (0..4096) of each block's bitmap.
  final Int32List fogBx;
  final Int32List fogBy;
  final Int32List fogPop;

  HeatBuildInput({
    required this.lat,
    required this.lng,
    required this.timeMs,
    required this.layer,
    required this.gcj02,
    Int32List? fogBx,
    Int32List? fogBy,
    Int32List? fogPop,
  })  : fogBx = fogBx ?? Int32List(0),
        fogBy = fogBy ?? Int32List(0),
        fogPop = fogPop ?? Int32List(0);

  int get pointCount => lat.length;

  /// Map form for `compute()` (typed lists are transferable).
  Map<String, Object> toMap() => {
        'lat': lat,
        'lng': lng,
        'timeMs': timeMs,
        'layer': layer,
        'gcj02': gcj02,
        'fogBx': fogBx,
        'fogBy': fogBy,
        'fogPop': fogPop,
      };

  static HeatBuildInput fromMap(Map<String, Object> m) => HeatBuildInput(
        lat: m['lat'] as Float64List,
        lng: m['lng'] as Float64List,
        timeMs: m['timeMs'] as Int64List,
        layer: m['layer'] as Int32List,
        gcj02: m['gcj02'] as bool,
        fogBx: m['fogBx'] as Int32List,
        fogBy: m['fogBy'] as Int32List,
        fogPop: m['fogPop'] as Int32List,
      );
}

/// Max silence between two fixes that still counts as one continuous path.
const int kHeatGapMs = 30 * 60 * 1000;

/// Max distance between two fixes that still counts as one path (a longer
/// hop is a GPS blackout — subway, flight, phone off — not a walked line).
const double kHeatGapMeters = 2000;

/// Pure builder (safe for `compute`). Accepts the map form of [HeatBuildInput].
HeatIndex buildHeatIndexFromMap(Map<String, Object> m) =>
    buildHeatIndex(HeatBuildInput.fromMap(m));

HeatIndex buildHeatIndex(HeatBuildInput input) {
  final n = input.pointCount;
  final nf = input.fogBx.length;
  if (n == 0 && nf == 0) return HeatIndex.empty;

  // Project every point once (with the base-map's datum shift baked in).
  final wx = Float64List(n);
  final wy = Float64List(n);
  for (var i = 0; i < n; i++) {
    var lat = input.lat[i], lng = input.lng[i];
    if (input.gcj02) {
      final g = CoordConverter.wgs84ToGcj02(lat, lng);
      lat = g.lat;
      lng = g.lng;
    }
    wx[i] = HeatIndex.lngToWorldX(lng);
    wy[i] = HeatIndex.latToWorldY(lat);
  }

  // Pass 1: decide connections. connected[i] = point i links to i+1.
  final connected = Uint8List(n);
  var segCount = 0;
  for (var i = 0; i + 1 < n; i++) {
    if (input.layer[i] != input.layer[i + 1]) continue;
    final dt = input.timeMs[i + 1] - input.timeMs[i];
    if (dt < 0 || dt > kHeatGapMs) continue;
    final d = PointFilter.haversineMeters(
        input.lat[i], input.lng[i], input.lat[i + 1], input.lng[i + 1]);
    if (d > kHeatGapMeters) continue;
    connected[i] = 1;
    segCount++;
  }
  // Isolated points (no link either side) become dots.
  var dotCount = 0;
  for (var i = 0; i < n; i++) {
    final prevLinked = i > 0 && connected[i - 1] == 1;
    final nextLinked = connected[i] == 1;
    if (!prevLinked && !nextLinked) dotCount++;
  }
  final total = segCount + dotCount + nf;
  final segs = Float32List(total * 4);
  final weights = Float32List(total);
  final kinds = Uint8List(total);

  var k = 0;
  for (var i = 0; i < n; i++) {
    final prevLinked = i > 0 && connected[i - 1] == 1;
    final nextLinked = connected[i] == 1;
    if (nextLinked) {
      final o = k << 2;
      segs[o] = wx[i];
      segs[o + 1] = wy[i];
      segs[o + 2] = wx[i + 1];
      segs[o + 3] = wy[i + 1];
      weights[k] = 1;
      kinds[k] = 0;
      k++;
    } else if (!prevLinked) {
      final o = k << 2;
      segs[o] = wx[i];
      segs[o + 1] = wy[i];
      segs[o + 2] = wx[i];
      segs[o + 3] = wy[i];
      weights[k] = 1;
      kinds[k] = 0;
      k++;
    }
  }
  final trackCount = k;
  // Fog blocks: centre of each 64×64 block in world coords.
  const bw = FogEngine.bitmapWidth;
  const full = FogEngine.full;
  for (var i = 0; i < nf; i++) {
    final o = k << 2;
    final x = (input.fogBx[i] * bw + bw / 2) / full;
    final y = (input.fogBy[i] * bw + bw / 2) / full;
    segs[o] = x;
    segs[o + 1] = y;
    segs[o + 2] = x;
    segs[o + 3] = y;
    weights[k] = (input.fogPop[i] / (bw * bw)).clamp(0.0, 1.0);
    kinds[k] = 1;
    k++;
  }

  // Bucket by z12 tile (a segment spanning a bucket edge goes in both).
  const per = 1 << HeatIndex.bucketZoom;
  final counts = <int, int>{};
  void visitBuckets(int i, void Function(int key) fn) {
    final o = i << 2;
    final x0 = segs[o], y0 = segs[o + 1], x1 = segs[o + 2], y1 = segs[o + 3];
    final bx0 = (math.min(x0, x1) * per).floor().clamp(0, per - 1);
    final bx1 = (math.max(x0, x1) * per).floor().clamp(0, per - 1);
    final by0 = (math.min(y0, y1) * per).floor().clamp(0, per - 1);
    final by1 = (math.max(y0, y1) * per).floor().clamp(0, per - 1);
    for (var bx = bx0; bx <= bx1; bx++) {
      for (var by = by0; by <= by1; by++) {
        fn((bx << HeatIndex.bucketZoom) | by);
      }
    }
  }

  for (var i = 0; i < total; i++) {
    visitBuckets(i, (key) => counts[key] = (counts[key] ?? 0) + 1);
  }
  final buckets = <int, Int32List>{
    for (final e in counts.entries) e.key: Int32List(e.value),
  };
  final fill = <int, int>{};
  for (var i = 0; i < total; i++) {
    visitBuckets(i, (key) {
      final at = fill[key] ?? 0;
      buckets[key]![at] = i;
      fill[key] = at + 1;
    });
  }
  return HeatIndex._(segs, weights, kinds, buckets, trackCount, nf);
}

/// Everything a heat tile bake needs. Immutable; a new instance (with a new
/// [generation]) is published whenever the data or style changes, exactly
/// like `FogSnapshot`.
class HeatSnapshot {
  final HeatIndex index;

  /// Intensity byte → premultiplied RGBA (see HeatPalette.lut).
  final Uint32List lut;

  /// Per-pass alpha multiplier (人生点点's 「曝光」). 1.0 = default.
  final double exposure;

  /// Stroke width multiplier (「粗细」). 1.0 = default.
  final double width;
  final int generation;
  const HeatSnapshot({
    required this.index,
    required this.lut,
    required this.exposure,
    required this.width,
    required this.generation,
  });

  bool get isEmpty => index.isEmpty;
}
