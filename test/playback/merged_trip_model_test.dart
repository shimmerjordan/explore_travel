import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/data/db/database.dart' show TrackPoint;
import 'package:explore_journal/services/playback/merged_trip_model.dart';
import 'package:explore_journal/services/playback/replay_model.dart';

void main() {
  final t0 = DateTime(2026, 7, 8, 9, 0);
  var id = 0;
  ReplaySession session(int layer, DateTime from, int minutes) =>
      ReplaySession(layer, [
        for (var m = 0; m <= minutes; m++)
          TrackPoint(
            id: ++id,
            uuid: 'p$id',
            lat: 30 + m * 0.001,
            lng: 104,
            time: from.add(Duration(minutes: m)),
            accuracy: null,
            altitude: null,
            speed: null,
            width: null,
            layerId: layer,
            flags: 0,
          ),
      ]);

  const uuids = {1: 'layer-a', 2: 'layer-b', 3: ''};

  test('segments encode/decode round trip, garbage tolerated', () {
    final a = session(1, t0, 30);
    final segs = segmentsForSessions([a], uuids);
    expect(segs, hasLength(1));
    expect(segs.single.layerUuid, 'layer-a');
    final decoded = decodeTripSegments(encodeTripSegments(segs));
    expect(decoded.single.startMs, segs.single.startMs);
    expect(decodeTripSegments('not json'), isEmpty);
    expect(decodeTripSegments('[{"layer":"x"}]'), isEmpty); // missing times
    expect(decodeTripSegments('[1,2]'), isEmpty);
  });

  test('a session without a layer uuid is not saveable', () {
    expect(segmentsForSessions([session(3, t0, 5)], uuids), isEmpty);
  });

  test('resolve matches by layer uuid + start-in-window, survives growth', () {
    final a = session(1, t0, 30);
    final b = session(2, t0.add(const Duration(hours: 5)), 20);
    final other = session(1, t0.add(const Duration(days: 3)), 10);
    final segs = segmentsForSessions([a, b], uuids);

    // The "a" session later grew by 15 minutes (new points at the end).
    final aGrown = session(1, t0, 45);
    final resolved = resolveTripSessions(segs, [aGrown, b, other], uuids);
    expect(resolved, hasLength(2));
    expect(resolved.map((s) => s.layerId), containsAll([1, 2]));
    expect(resolved.any((s) => s.start == other.start), isFalse);
  });

  test('same window on a different layer does not match', () {
    final a = session(1, t0, 30);
    final segs = segmentsForSessions([a], uuids);
    final impostor = session(2, t0, 30);
    expect(resolveTripSessions(segs, [impostor], uuids), isEmpty);
  });
}
