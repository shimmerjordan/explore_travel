import 'dart:convert';

/// How sure are we this stay was a real visit? 0..100, Dawarich's
/// `Visits::ConfidenceScorer` weights, minus the corroboration term (we have
/// no transport-mode segments). Missing terms renormalise the rest.
///
/// Band: ≥ 70 high (drawn solid), ≥ 40 medium (faded), else low (folded
/// away under a "N 条低置信度" row).
enum PlaceMatch { none, auto, manual }

class ConfidenceResult {
  final int score;
  final Map<String, double> parts;
  const ConfidenceResult(this.score, this.parts);

  String get band => score >= 70 ? 'high' : (score >= 40 ? 'medium' : 'low');
  String toJson() => jsonEncode(parts.map((k, v) => MapEntry(k, _r2(v))));
  static double _r2(double v) => (v * 100).round() / 100;
}

class ConfidenceScorer {
  static const weights = <String, double>{
    'dwell': 0.30,
    'tightness': 0.25,
    'place_match': 0.20,
    'density': 0.15,
    'accuracy': 0.10,
    'bridged': 0.15,
  };

  static ConfidenceResult score({
    required int durationS,
    required int count,
    required double radiusM,
    required double stayRadiusM,
    required double medianAccM,
    required double bridgedFraction,
    required PlaceMatch placeMatch,
    int minPoints = 3,
  }) {
    final parts = <String, double>{
      'dwell': (durationS / 1800.0).clamp(0.0, 1.0),
      'tightness': (1 - radiusM / (stayRadiusM <= 0 ? 1 : stayRadiusM))
          .clamp(0.0, 1.0),
      'place_match': switch (placeMatch) {
        PlaceMatch.manual => 0.85,
        PlaceMatch.auto => 0.6,
        PlaceMatch.none => 0.35,
      },
      'density': (count / (minPoints * 3.0)).clamp(0.0, 1.0),
      'accuracy': (1 - (medianAccM - 10) / 90).clamp(0.0, 1.0),
      'bridged': (1 - bridgedFraction).clamp(0.0, 1.0),
    };
    var wSum = 0.0, acc = 0.0;
    for (final e in parts.entries) {
      final w = weights[e.key]!;
      wSum += w;
      acc += w * e.value;
    }
    final s = wSum <= 0 ? 0 : (acc / wSum * 100).round().clamp(0, 100);
    return ConfidenceResult(s, parts);
  }
}
