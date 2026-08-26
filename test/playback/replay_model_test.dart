import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/playback/replay_model.dart';

/// The replay model must (a) never fuse trails of different layers into one
/// session, (b) give a TIME-based cursor with an interpolated head, and (c)
/// merge N selected sessions into one virtual clock with idle gaps removed
/// while keeping simultaneous sessions simultaneous.
void main() {
  final t0 = DateTime(2026, 8, 1, 8, 0);
  var nextId = 1;
  TrackPoint pt(int layer, Duration dt, double lat, double lng) => TrackPoint(
        id: nextId++,
        uuid: 'u$nextId',
        lat: lat,
        lng: lng,
        time: t0.add(dt),
        layerId: layer,
      );

  /// [n] points, one per second, walking north 0.001° per step.
  List<TrackPoint> walk(int layer, Duration from, int n,
          {double lat = 30.0, double lng = 104.0}) =>
      [
        for (var i = 0; i < n; i++)
          pt(layer, from + Duration(seconds: i), lat + i * 0.001, lng),
      ];

  group('splitIntoSessions', () {
    test('splits on the silence gap and drops short runs', () {
      final pts = [
        ...walk(1, Duration.zero, 12),
        ...walk(1, const Duration(hours: 1), 12), // 1 h later → new session
        ...walk(1, const Duration(hours: 2), 3), // too short → dropped
      ];
      final s = splitIntoSessions(pts, minPoints: 10);
      expect(s, hasLength(2));
      // newest first
      expect(s.first.start, t0.add(const Duration(hours: 1)));
      expect(s.last.pointCount, 12);
    });

    test('never merges two layers recorded at the same time', () {
      final pts = [
        ...walk(1, Duration.zero, 12, lat: 30.0),
        ...walk(2, Duration.zero, 12, lat: 31.0), // 111 km away, same times
      ];
      final s = splitIntoSessions(pts, minPoints: 10);
      expect(s, hasLength(2));
      expect(s.map((x) => x.layerId).toSet(), {1, 2});
      // Each trail is ~1.2 km of northward walking, not a 111 km zig-zag.
      for (final x in s) {
        expect(x.distanceKm, closeTo(1.22, 0.05));
      }
    });

    test('input order does not matter', () {
      final pts = walk(1, Duration.zero, 12)..shuffle();
      final s = splitIntoSessions(pts, minPoints: 10);
      expect(s.single.points.map((p) => p.time).toList(),
          List.generate(12, (i) => t0.add(Duration(seconds: i))));
    });
  });

  group('ReplaySession time cursor', () {
    final s = ReplaySession(1, walk(1, Duration.zero, 11)); // 0..10 s

    test('before start: nothing; after end: parked at the last point', () {
      expect(s.positionAt(t0.subtract(const Duration(seconds: 1))), isNull);
      expect(s.pathUntil(t0.subtract(const Duration(seconds: 1))), isEmpty);
      final late = s.positionAt(t0.add(const Duration(minutes: 5)))!;
      expect(late.latitude, closeTo(30.010, 1e-9));
    });

    test('interpolates the head between samples', () {
      final t = t0.add(const Duration(milliseconds: 2500)); // between 2 & 3
      final head = s.positionAt(t)!;
      expect(head.latitude, closeTo(30.0025, 1e-9));
      final path = s.pathUntil(t);
      expect(path, hasLength(4)); // points 0,1,2 + interpolated head
      expect(path.last, LatLng(head.latitude, head.longitude));
    });

    test('exactly on a sample adds no duplicate head', () {
      final path = s.pathUntil(t0.add(const Duration(seconds: 3)));
      expect(path, hasLength(4));
    });
  });

  group('MergedTimeline', () {
    test('removes idle gaps, keeps overlaps simultaneous', () {
      final a = ReplaySession(1, walk(1, Duration.zero, 61)); // 08:00:00–08:01:00
      final b = ReplaySession(
          2, walk(2, const Duration(seconds: 30), 61)); // 08:00:30–08:01:30
      final c = ReplaySession(
          1, walk(1, const Duration(days: 2), 31)); // two days later, 30 s
      final tl = MergedTimeline([c, a, b]);
      expect(tl.segments, hasLength(2));
      expect(tl.total, const Duration(seconds: 90 + 30));
      // Virtual 45 s is inside the first segment: a and b both active.
      final r = tl.realAt(const Duration(seconds: 45));
      expect(a.isActiveAt(r), isTrue);
      expect(b.isActiveAt(r), isTrue);
      // Virtual 100 s jumps straight into the third session, 2 days on.
      final r2 = tl.realAt(const Duration(seconds: 100));
      expect(r2, t0.add(const Duration(days: 2, seconds: 10)));
      expect(c.isActiveAt(r2), isTrue);
    });

    test('realAt / virtualOf round-trip and clamp', () {
      final a = ReplaySession(1, walk(1, Duration.zero, 61));
      final c = ReplaySession(1, walk(1, const Duration(hours: 5), 61));
      final tl = MergedTimeline([a, c]);
      for (final v in [0, 10, 60, 61, 119, 120]) {
        final d = Duration(seconds: v);
        expect(tl.virtualOf(tl.realAt(d)), d, reason: 'v=$v');
      }
      // Inside the gap → end of the preceding segment.
      expect(tl.virtualOf(t0.add(const Duration(hours: 2))),
          const Duration(seconds: 60));
      expect(tl.realAt(const Duration(hours: 9)), tl.realEnd);
      expect(tl.realAt(const Duration(seconds: -5)), tl.realStart);
    });

    test('empty selection is empty', () {
      final tl = MergedTimeline(const []);
      expect(tl.isEmpty, isTrue);
      expect(tl.total, Duration.zero);
    });
  });
}
