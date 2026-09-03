
import 'package:latlong2/latlong.dart';

import '../../core/geo_math.dart' show haversineMeters;
import '../../data/db/database.dart' show TrackPoint;

/// Pure-Dart playback model, shared by the replay screen and the video
/// exporter (and unit-tested without a map):
///
///   * [splitIntoSessions] — one "session" is a contiguous run of GPS samples
///     of ONE layer, separated from its neighbours by [kSessionGap] of
///     silence. Splitting is per layer: two layers recorded at overlapping
///     times used to be shuffled into one session whose distance zig-zagged
///     between two unrelated trails.
///   * [ReplaySession.pathUntil] — the trail drawn up to a moment in time,
///     with the head interpolated between samples, so the cursor is TIME (a
///     real ×N speed) rather than a point index (uneven sampling made the
///     old index-stepping playback lurch).
///   * [MergedTimeline] — a virtual clock over N selected sessions: the
///     union of their time spans with the idle gaps between them removed.
///     Sessions that overlap in real time play side by side; sessions days
///     apart follow each other back to back.

const Duration kSessionGap = Duration(minutes: 10);
const int kMinPointsPerSession = 10;

class ReplaySession {
  final int layerId;

  /// Time-ascending, at least one point.
  final List<TrackPoint> points;

  ReplaySession(this.layerId, this.points)
      : assert(points.isNotEmpty, 'a session needs at least one point');

  DateTime get start => points.first.time;
  DateTime get end => points.last.time;
  Duration get duration => end.difference(start);
  int get pointCount => points.length;

  double get distanceKm {
    double m = 0;
    for (int i = 1; i < points.length; i++) {
      m += haversineMeters(points[i - 1].lat, points[i - 1].lng, points[i].lat,
          points[i].lng);
    }
    return m / 1000;
  }

  /// Index of the last point with `time <= t`, or -1 if [t] is before the
  /// first point. Binary search — playback calls this per frame per session.
  int _lastIndexAtOrBefore(DateTime t) {
    var lo = 0, hi = points.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (points[mid].time.isAfter(t)) {
        hi = mid - 1;
      } else {
        ans = mid;
        lo = mid + 1;
      }
    }
    return ans;
  }

  /// Where this trail's head is at [t]: null before the session started, the
  /// last point after it ended, otherwise interpolated between the two
  /// samples bracketing [t].
  LatLng? positionAt(DateTime t) {
    final i = _lastIndexAtOrBefore(t);
    if (i < 0) return null;
    if (i >= points.length - 1) {
      return LatLng(points.last.lat, points.last.lng);
    }
    return _interpolate(points[i], points[i + 1], t);
  }

  /// The trail up to [t] (inclusive) with an interpolated head appended.
  /// Empty before the session starts.
  List<LatLng> pathUntil(DateTime t) {
    final i = _lastIndexAtOrBefore(t);
    if (i < 0) return const [];
    final out = <LatLng>[
      for (var k = 0; k <= i; k++) LatLng(points[k].lat, points[k].lng),
    ];
    if (i < points.length - 1) {
      final head = _interpolate(points[i], points[i + 1], t);
      if (head.latitude != out.last.latitude ||
          head.longitude != out.last.longitude) {
        out.add(head);
      }
    }
    return out;
  }

  /// True when [t] falls inside this session's own time span.
  bool isActiveAt(DateTime t) => !t.isBefore(start) && !t.isAfter(end);

  static LatLng _interpolate(TrackPoint a, TrackPoint b, DateTime t) {
    final span = b.time.difference(a.time).inMilliseconds;
    if (span <= 0) return LatLng(b.lat, b.lng);
    final f = (t.difference(a.time).inMilliseconds / span).clamp(0.0, 1.0);
    return LatLng(a.lat + (b.lat - a.lat) * f, a.lng + (b.lng - a.lng) * f);
  }
}

/// Split raw points into per-layer sessions. Input order is irrelevant.
/// Output is newest-first (what the list screen shows).
List<ReplaySession> splitIntoSessions(
  Iterable<TrackPoint> all, {
  Duration gap = kSessionGap,
  int minPoints = kMinPointsPerSession,
}) {
  final byLayer = <int, List<TrackPoint>>{};
  for (final p in all) {
    (byLayer[p.layerId] ??= []).add(p);
  }
  final out = <ReplaySession>[];
  for (final entry in byLayer.entries) {
    final pts = entry.value..sort((a, b) => a.time.compareTo(b.time));
    var bucket = <TrackPoint>[pts.first];
    void flush() {
      if (bucket.length >= minPoints) {
        out.add(ReplaySession(entry.key, List.of(bucket, growable: false)));
      }
    }

    for (int i = 1; i < pts.length; i++) {
      if (pts[i].time.difference(pts[i - 1].time) >= gap) {
        flush();
        bucket = <TrackPoint>[pts[i]];
      } else {
        bucket.add(pts[i]);
      }
    }
    flush();
  }
  out.sort((a, b) => b.start.compareTo(a.start));
  return out;
}

/// One contiguous stretch of real time during which at least one selected
/// session is active.
class TimelineSegment {
  final DateTime start, end;
  const TimelineSegment(this.start, this.end);
  Duration get length => end.difference(start);
}

/// Virtual playback clock over a set of sessions — see the file comment.
class MergedTimeline {
  final List<ReplaySession> sessions;
  final List<TimelineSegment> segments;

  /// Total virtual length (sum of segment lengths).
  final Duration total;

  MergedTimeline._(this.sessions, this.segments, this.total);

  factory MergedTimeline(List<ReplaySession> sessions) {
    if (sessions.isEmpty) {
      return MergedTimeline._(const [], const [], Duration.zero);
    }
    final spans = [for (final s in sessions) TimelineSegment(s.start, s.end)]
      ..sort((a, b) => a.start.compareTo(b.start));
    final merged = <TimelineSegment>[];
    var cur = spans.first;
    for (final s in spans.skip(1)) {
      if (!s.start.isAfter(cur.end)) {
        if (s.end.isAfter(cur.end)) cur = TimelineSegment(cur.start, s.end);
      } else {
        merged.add(cur);
        cur = s;
      }
    }
    merged.add(cur);
    var total = Duration.zero;
    for (final m in merged) {
      total += m.length;
    }
    return MergedTimeline._(
        List.unmodifiable(sessions), List.unmodifiable(merged), total);
  }

  bool get isEmpty => sessions.isEmpty;

  DateTime get realStart => segments.first.start;
  DateTime get realEnd => segments.last.end;

  /// Virtual position → the real instant it stands for.
  DateTime realAt(Duration virtual) {
    if (virtual <= Duration.zero) return realStart;
    var remaining = virtual;
    for (final seg in segments) {
      if (remaining <= seg.length) return seg.start.add(remaining);
      remaining -= seg.length;
    }
    return realEnd;
  }

  /// Real instant → virtual position. An instant inside an idle gap maps to
  /// the end of the segment before it.
  Duration virtualOf(DateTime real) {
    var acc = Duration.zero;
    for (final seg in segments) {
      if (real.isBefore(seg.start)) return acc;
      if (!real.isAfter(seg.end)) return acc + real.difference(seg.start);
      acc += seg.length;
    }
    return acc;
  }

  /// Every point of every session — for fitting the camera.
  Iterable<LatLng> allPoints() sync* {
    for (final s in sessions) {
      for (final p in s.points) {
        yield LatLng(p.lat, p.lng);
      }
    }
  }
}
