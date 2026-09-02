import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/visits/stay_detector.dart';

/// Synthetic day: home overnight → 30 min commute → office 9 h (with a GPS
/// wobble) → 2 min red light on the way back → home.
void main() {
  final t0 = DateTime(2026, 8, 20, 6, 0).millisecondsSinceEpoch;
  int min(int m) => t0 + m * 60000;
  const home = (30.0000, 104.0000);
  const office = (30.0500, 104.0500); // ~7 km away
  const light = (30.0250, 104.0250);
  final rng = math.Random(7);

  /// Fixes every [everyMin] minutes for [durMin] at [c], jittered ±[jitterM].
  List<StayPoint> dwell((double, double) c, int fromMin, int durMin,
      {int everyMin = 5, double jitterM = 20, double acc = 15}) {
    final out = <StayPoint>[];
    for (var m = 0; m <= durMin; m += everyMin) {
      final dLat = (rng.nextDouble() * 2 - 1) * jitterM / 111320;
      final dLng = (rng.nextDouble() * 2 - 1) * jitterM / 111320;
      out.add(StayPoint(c.$1 + dLat, c.$2 + dLng, min(fromMin + m),
          accuracy: acc));
    }
    return out;
  }

  /// Straight-line travel between two points, a fix per minute.
  List<StayPoint> travel(
      (double, double) a, (double, double) b, int fromMin, int durMin) {
    return [
      for (var m = 1; m < durMin; m++)
        StayPoint(
          a.$1 + (b.$1 - a.$1) * m / durMin,
          a.$2 + (b.$2 - a.$2) * m / durMin,
          min(fromMin + m),
          accuracy: 10,
        ),
    ];
  }

  test('home → commute → office → red light → home yields two stays', () {
    final pts = <StayPoint>[
      ...dwell(home, 0, 120), // 06:00–08:00 home
      ...travel(home, office, 120, 30), // 08:00–08:30
      ...dwell(office, 150, 540), // 08:30–17:30 office
      ...travel(office, light, 690, 15),
      ...dwell(light, 705, 2, everyMin: 1, jitterM: 3), // 2 min at a light
      ...travel(light, home, 707, 15),
      ...dwell(home, 722, 120), // evening
    ];
    final stays = detectStays(pts);
    // Home appears twice (morning + evening) — not bridged, we went elsewhere.
    expect(stays.length, 3, reason: stays.join('\n'));
    expect(stays[0].durationS, closeTo(120 * 60, 60));
    expect(stays[1].durationS, closeTo(540 * 60, 60));
    expect(stays[1].count, greaterThan(100));
    // The red light: 3 fixes, 2 minutes → under min duration → dropped.
    for (final s in stays) {
      expect(s.lat, isNot(closeTo(light.$1, 0.001)));
    }
    // Centres land on the true spots, radius reflects the jitter.
    expect(stays[1].lat, closeTo(office.$1, 0.0005));
    expect(stays[1].lng, closeTo(office.$2, 0.0005));
    expect(stays[1].radiusM, inInclusiveRange(15, 60));
  });

  test('overnight silence at the same spot is bridged into one stay', () {
    final pts = <StayPoint>[
      ...dwell(home, 0, 60), // 06:00–07:00
      // phone dead / recording stopped for 10 h
      ...dwell(home, 660, 60), // 17:00–18:00, still home
    ];
    final stays = detectStays(pts);
    expect(stays.length, 1, reason: stays.join('\n'));
    expect(stays.single.bridgedS, closeTo(10 * 3600, 120));
    expect(stays.single.bridgedFraction, greaterThan(0.8));
  });

  test('silence that ends somewhere else is NOT bridged', () {
    final pts = <StayPoint>[
      ...dwell(home, 0, 60),
      ...dwell(office, 660, 60),
    ];
    final stays = detectStays(pts);
    expect(stays.length, 2);
    expect(stays.every((s) => s.bridgedS == 0), isTrue);
  });

  test('drift cap: a slow stroll does not smear into one giant stay', () {
    // 200 fixes drifting 15 m each = 3 km walked over 200 min, never more than
    // 15 m from the previous fix. Without the drift cap the running mean
    // would keep "catching up" and swallow the whole walk.
    final pts = <StayPoint>[
      for (var i = 0; i < 200; i++)
        StayPoint(30.0 + i * 15 / 111320, 104.0, min(i), accuracy: 10),
    ];
    final stays = detectStays(pts);
    for (final s in stays) {
      expect(s.radiusM, lessThan(200), reason: '$s');
    }
  });

  test('fewer than minPoints never becomes a stay', () {
    final pts = [
      StayPoint(30, 104, min(0), accuracy: 10),
      StayPoint(30, 104, min(30), accuracy: 10),
    ];
    expect(detectStays(pts), isEmpty);
  });

  test('accuracy-weighted centre pulls toward precise fixes', () {
    final pts = [
      StayPoint(30.0000, 104.0, min(0), accuracy: 5),
      StayPoint(30.0000, 104.0, min(5), accuracy: 5),
      StayPoint(30.0006, 104.0, min(10), accuracy: 80), // sloppy, 67 m north
    ];
    final s = detectStays(pts).single;
    expect(s.lat, closeTo(30.0000, 0.0001));
    expect(s.medianAccM, 5);
  });

  test('packed round trip preserves stays', () {
    final pts = dwell(home, 0, 60);
    final direct = detectStays(pts);
    final packed = detectStaysPacked({
      'lat': [for (final p in pts) p.lat],
      'lng': [for (final p in pts) p.lng],
      'tMs': [for (final p in pts) p.tMs],
      'acc': [for (final p in pts) p.accuracy ?? double.nan],
    });
    final back = unpackStays(packed);
    expect(back.length, direct.length);
    expect(back.first.startMs, direct.first.startMs);
    expect(back.first.count, direct.first.count);
    expect(back.first.lat, closeTo(direct.first.lat, 1e-9));
  });
}
