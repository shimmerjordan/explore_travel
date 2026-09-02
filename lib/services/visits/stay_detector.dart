import 'dart:math' as math;

import '../location/point_filter.dart';

/// Stay-point detection — a Dart port of Dawarich's v3 visit pipeline
/// (`Visits::Detection::{DwellSweep, GapBridger, StayAssembler}`), minus the
/// transport-mode reconciler we have no data for.
///
/// Three passes over one layer's clean, time-ordered fixes:
///  1. **dwellSweep** — single pass; a run stays open while each new fix is
///     within [radiusM] of the run's running mean AND within
///     `radiusM × driftCapFactor` of its first fix (so a slow stroll doesn't
///     smear one "stay" across a neighbourhood). Silence > [sweepGapS] closes it.
///  2. **bridgeGaps** — two consecutive runs at the same spot (centres within
///     [radiusM]) separated by silence ≤ [bridgeCapS] become one stay; the
///     silence is remembered as `bridgedS`. Silence that ended somewhere ELSE
///     is never bridged — the timeline shows a hole, not an invented visit.
///  3. **assemble** — chain-merge runs closer than [mergeGapS], then keep only
///     runs with ≥ [minPoints] fixes and ≥ [minDurationS]; centre = mean
///     weighted by 1/accuracy, radius = max distance (floor [minRadiusM]).
///
/// Pure functions, no IO — run them in `compute()` for a whole month.
class StayPoint {
  final double lat;
  final double lng;
  final int tMs;
  final double? accuracy;
  const StayPoint(this.lat, this.lng, this.tMs, {this.accuracy});
}

class StayParams {
  final double radiusM;
  final int minPoints;
  final int minDurationS;
  final int mergeGapS;
  final int sweepGapS;
  final int bridgeCapS;
  final double driftCapFactor;
  final double minRadiusM;
  const StayParams({
    this.radiusM = 100,
    this.minPoints = 3,
    this.minDurationS = 5 * 60,
    this.mergeGapS = 15 * 60,
    this.sweepGapS = 3600,
    this.bridgeCapS = 7 * 86400,
    this.driftCapFactor = 1.5,
    this.minRadiusM = 15,
  });

  static const defaults = StayParams();
}

class Stay {
  final int startMs;
  final int endMs;
  final double lat;
  final double lng;
  final double radiusM;
  final int count;
  final int bridgedS;
  final double medianAccM;
  const Stay({
    required this.startMs,
    required this.endMs,
    required this.lat,
    required this.lng,
    required this.radiusM,
    required this.count,
    required this.bridgedS,
    required this.medianAccM,
  });

  int get durationS => (endMs - startMs) ~/ 1000;
  double get bridgedFraction =>
      durationS <= 0 ? 0 : (bridgedS / durationS).clamp(0.0, 1.0);

  @override
  String toString() =>
      'Stay(${DateTime.fromMillisecondsSinceEpoch(startMs)} → '
      '${DateTime.fromMillisecondsSinceEpoch(endMs)}, $count pts, r=${radiusM.toStringAsFixed(0)}m'
      '${bridgedS > 0 ? ', bridged ${bridgedS}s' : ''})';
}

/// One contiguous (or bridged) group of fixes — the pipeline's working unit.
class _Run {
  final List<StayPoint> pts = [];
  double sumLat = 0, sumLng = 0;
  int bridgedS = 0;

  bool get isEmpty => pts.isEmpty;
  int get startMs => pts.first.tMs;
  int get endMs => pts.last.tMs;
  double get meanLat => sumLat / pts.length;
  double get meanLng => sumLng / pts.length;

  void add(StayPoint p) {
    pts.add(p);
    sumLat += p.lat;
    sumLng += p.lng;
  }

  void absorb(_Run o) {
    pts.addAll(o.pts);
    sumLat += o.sumLat;
    sumLng += o.sumLng;
    bridgedS += o.bridgedS;
  }
}

double _dist(double lat1, double lng1, double lat2, double lng2) =>
    PointFilter.haversineMeters(lat1, lng1, lat2, lng2);

List<_Run> _dwellSweep(List<StayPoint> pts, StayParams p) {
  final runs = <_Run>[];
  var cur = _Run();
  final driftCap = p.radiusM * p.driftCapFactor;
  for (final pt in pts) {
    if (cur.isEmpty) {
      cur.add(pt);
      continue;
    }
    final silent = (pt.tMs - cur.endMs) > p.sweepGapS * 1000;
    final co = !silent &&
        _dist(pt.lat, pt.lng, cur.meanLat, cur.meanLng) <= p.radiusM &&
        _dist(pt.lat, pt.lng, cur.pts.first.lat, cur.pts.first.lng) <= driftCap;
    if (co) {
      cur.add(pt);
    } else {
      runs.add(cur);
      cur = _Run()..add(pt);
    }
  }
  if (!cur.isEmpty) runs.add(cur);
  return runs;
}

List<_Run> _bridgeGaps(List<_Run> runs, StayParams p) {
  if (runs.length < 2) return runs;
  final out = <_Run>[runs.first];
  for (var i = 1; i < runs.length; i++) {
    final prev = out.last;
    final next = runs[i];
    final gapS = (next.startMs - prev.endMs) ~/ 1000;
    if (gapS >= 0 &&
        gapS <= p.bridgeCapS &&
        _dist(prev.meanLat, prev.meanLng, next.meanLat, next.meanLng) <=
            p.radiusM) {
      if (gapS > p.sweepGapS) prev.bridgedS += gapS;
      prev.absorb(next);
    } else {
      out.add(next);
    }
  }
  return out;
}

List<Stay> _assemble(List<_Run> runs, StayParams p) {
  // Chain merge: near in time AND space.
  final merged = <_Run>[];
  for (final r in runs) {
    if (merged.isEmpty) {
      merged.add(r);
      continue;
    }
    final prev = merged.last;
    final gapS = (r.startMs - prev.endMs) ~/ 1000;
    if (gapS >= 0 &&
        gapS <= p.mergeGapS &&
        _dist(prev.meanLat, prev.meanLng, r.meanLat, r.meanLng) <= p.radiusM) {
      prev.absorb(r);
    } else {
      merged.add(r);
    }
  }
  final out = <Stay>[];
  for (final r in merged) {
    final durS = (r.endMs - r.startMs) ~/ 1000;
    if (r.pts.length < p.minPoints || durS < p.minDurationS) continue;
    // Accuracy-weighted centre (unknown accuracy counts as 50 m).
    var wSum = 0.0, lat = 0.0, lng = 0.0;
    final accs = <double>[];
    for (final pt in r.pts) {
      final acc = (pt.accuracy ?? 50).clamp(1.0, double.infinity);
      accs.add(acc);
      final w = 1 / acc;
      wSum += w;
      lat += pt.lat * w;
      lng += pt.lng * w;
    }
    lat /= wSum;
    lng /= wSum;
    var radius = 0.0;
    for (final pt in r.pts) {
      final d = _dist(pt.lat, pt.lng, lat, lng);
      if (d > radius) radius = d;
    }
    accs.sort();
    final median = accs[accs.length ~/ 2];
    out.add(Stay(
      startMs: r.startMs,
      endMs: r.endMs,
      lat: lat,
      lng: lng,
      radiusM: math.max(radius, p.minRadiusM),
      count: r.pts.length,
      bridgedS: r.bridgedS,
      medianAccM: median,
    ));
  }
  return out;
}

/// Detect stays in [points] (ONE layer, ascending by time, noise filtered).
List<Stay> detectStays(List<StayPoint> points,
    {StayParams params = StayParams.defaults}) {
  if (points.isEmpty) return const [];
  final runs = _dwellSweep(points, params);
  final bridged = _bridgeGaps(runs, params);
  return _assemble(bridged, params);
}

/// `compute()` entry: flat arrays in, flat stays out (8 doubles per stay:
/// startMs, endMs, lat, lng, radius, count, bridgedS, medianAcc).
List<double> detectStaysPacked(Map<String, Object> m) {
  final lat = m['lat'] as List<double>;
  final lng = m['lng'] as List<double>;
  final t = m['tMs'] as List<int>;
  final acc = m['acc'] as List<double>; // NaN = unknown
  final pts = <StayPoint>[
    for (var i = 0; i < lat.length; i++)
      StayPoint(lat[i], lng[i], t[i], accuracy: acc[i].isNaN ? null : acc[i]),
  ];
  final stays = detectStays(pts);
  final out = <double>[];
  for (final s in stays) {
    out.addAll([
      s.startMs.toDouble(),
      s.endMs.toDouble(),
      s.lat,
      s.lng,
      s.radiusM,
      s.count.toDouble(),
      s.bridgedS.toDouble(),
      s.medianAccM,
    ]);
  }
  return out;
}

List<Stay> unpackStays(List<double> packed) => [
      for (var i = 0; i + 7 < packed.length; i += 8)
        Stay(
          startMs: packed[i].toInt(),
          endMs: packed[i + 1].toInt(),
          lat: packed[i + 2],
          lng: packed[i + 3],
          radiusM: packed[i + 4],
          count: packed[i + 5].toInt(),
          bridgedS: packed[i + 6].toInt(),
          medianAccM: packed[i + 7],
        ),
    ];
