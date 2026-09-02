import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/visits/confidence_scorer.dart';

void main() {
  ConfidenceResult s({
    int durationS = 3600,
    int count = 20,
    double radiusM = 20,
    double stayRadiusM = 100,
    double medianAccM = 10,
    double bridgedFraction = 0,
    PlaceMatch placeMatch = PlaceMatch.manual,
  }) =>
      ConfidenceScorer.score(
        durationS: durationS,
        count: count,
        radiusM: radiusM,
        stayRadiusM: stayRadiusM,
        medianAccM: medianAccM,
        bridgedFraction: bridgedFraction,
        placeMatch: placeMatch,
      );

  test('an ideal long, tight, precise stay at a known place is high', () {
    final r = s();
    expect(r.score, greaterThanOrEqualTo(90));
    expect(r.band, 'high');
  });

  test('a short, sloppy stay nowhere known is low', () {
    final r = s(
        durationS: 300,
        count: 3,
        radiusM: 95,
        medianAccM: 90,
        bridgedFraction: 0.9,
        placeMatch: PlaceMatch.none);
    expect(r.score, lessThan(40));
    expect(r.band, 'low');
  });

  test('bands sit at 40 / 70', () {
    expect(const ConfidenceResult(70, {}).band, 'high');
    expect(const ConfidenceResult(69, {}).band, 'medium');
    expect(const ConfidenceResult(40, {}).band, 'medium');
    expect(const ConfidenceResult(39, {}).band, 'low');
  });

  test('each term moves the score in the expected direction', () {
    expect(s(durationS: 600).score, lessThan(s(durationS: 3600).score));
    expect(s(radiusM: 90).score, lessThan(s(radiusM: 10).score));
    expect(s(count: 3).score, lessThan(s(count: 30).score));
    expect(s(medianAccM: 80).score, lessThan(s(medianAccM: 10).score));
    expect(s(bridgedFraction: 0.8).score, lessThan(s().score));
    expect(s(placeMatch: PlaceMatch.none).score,
        lessThan(s(placeMatch: PlaceMatch.auto).score));
    expect(s(placeMatch: PlaceMatch.auto).score,
        lessThan(s(placeMatch: PlaceMatch.manual).score));
  });

  test('all terms perfect tops out at 97 (manual place match is 0.85)', () {
    final r = s(durationS: 100000, count: 1000, radiusM: 0, medianAccM: 1);
    expect(r.score, 97);
  });

  test('toJson is a flat map of rounded parts', () {
    final j = jsonDecode(s().toJson()) as Map<String, dynamic>;
    expect(j.keys, containsAll(ConfidenceScorer.weights.keys));
    for (final v in j.values) {
      expect(v, isA<num>());
      expect((v as num).toDouble(), inInclusiveRange(0, 1));
    }
  });
}
