import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/location/point_filter.dart';

void main() {
  const t0 = 1700000000000;
  PointSample at(double lat, double lng, int dtSec, {double? acc}) =>
      PointSample(lat, lng, t0 + dtSec * 1000, accuracy: acc);

  group('drop', () {
    test('Null Island is dropped', () {
      expect(PointFilter.judge(at(0.001, -0.002, 0)), PointVerdict.drop);
    });
    test('out-of-range coordinates are dropped', () {
      expect(PointFilter.judge(at(91, 0, 0)), PointVerdict.drop);
      expect(PointFilter.judge(at(0, 181, 0)), PointVerdict.drop);
      expect(PointFilter.judge(at(double.nan, 10, 0)), PointVerdict.drop);
    });
    test('accuracy above 500 m is dropped, at/below is kept', () {
      expect(PointFilter.judge(at(30, 104, 0, acc: 501)), PointVerdict.drop);
      expect(PointFilter.judge(at(30, 104, 0, acc: 500)), PointVerdict.keep);
      expect(PointFilter.judge(at(30, 104, 0)), PointVerdict.keep);
    });
  });

  group('anomaly', () {
    test('first sample has nothing to compare against → keep', () {
      expect(PointFilter.judge(at(30, 104, 0)), PointVerdict.keep);
    });
    test('walking speed is kept', () {
      final prev = at(30.0, 104.0, 0);
      // ~111 m north in 60 s ≈ 1.85 m/s
      expect(PointFilter.judge(at(30.001, 104.0, 60), prev: prev),
          PointVerdict.keep);
    });
    test('a 100 km jump in 10 s is an anomaly', () {
      final prev = at(30.0, 104.0, 0);
      expect(PointFilter.judge(at(30.9, 104.0, 10), prev: prev),
          PointVerdict.anomaly);
    });
    test('a fast train (80 m/s) is NOT an anomaly', () {
      final prev = at(30.0, 104.0, 0);
      // 0.0072° ≈ 800 m in 10 s
      expect(PointFilter.judge(at(30.0072, 104.0, 10), prev: prev),
          PointVerdict.keep);
    });
    test('same timestamp: >1 km displacement is an anomaly, less is kept', () {
      final prev = at(30.0, 104.0, 0);
      expect(PointFilter.judge(at(30.02, 104.0, 0), prev: prev),
          PointVerdict.anomaly);
      expect(PointFilter.judge(at(30.005, 104.0, 0), prev: prev),
          PointVerdict.keep);
    });
    test('speed check is skipped when the previous sample is >1 h old', () {
      final prev = at(30.0, 104.0, 0);
      // 1000 km after 2 h would be 139 m/s — under the cap anyway, but a
      // 5000 km hop after 2 h (694 m/s) must still be KEPT: it's a flight
      // we simply weren't recording during.
      expect(PointFilter.judge(at(75.0, 104.0, 7200), prev: prev),
          PointVerdict.keep);
    });
  });

  test('haversine sanity: 1° of latitude ≈ 111.2 km', () {
    final d = PointFilter.haversineMeters(0, 0, 1, 0);
    expect(d, closeTo(111195, 200));
  });
}
