import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/heat/heat_field.dart';

HeatFieldInput lines(List<double> l, {List<double> dots = const []}) =>
    HeatFieldInput(
      lines: Float32List.fromList(l),
      dots: Float32List.fromList(dots),
      fogPts: Float32List(0),
      fogW: Float32List(0),
      fogBlockPx: 8,
    );

double peakH(HeatField f) {
  var m = 0.0;
  for (final v in f.h) {
    if (v > m) m = v;
  }
  return m;
}

/// The same straight road walked [passes] times, at a stroke width standing
/// in for the zoom level.
HeatField road(double strokePx, int passes, {double width = 300}) {
  final l = <double>[];
  for (var i = 0; i < passes; i++) {
    l.addAll([30, 151.5, width - 30, 151.5]);
  }
  return buildHeatField(
      width: width, height: 300, input: lines(l), strokePx: strokePx);
}

void main() {
  test('empty input → empty field of the right size', () {
    final f = buildHeatField(
        width: 300, height: 600, input: lines([]), strokePx: 3);
    expect(f.isEmpty, isTrue);
    expect(f.gw, 100);
    expect(f.gh, 200);
    expect(f.h.every((v) => v == 0), isTrue);
  });

  test('a horizontal line peaks on the line and is symmetric about it', () {
    // y = 151.5 is the centre of cell row 50 (cell = 3 px). Walked enough
    // times to reach the top of the absolute scale.
    final f = road(3, 24);
    expect(f.isEmpty, isFalse);
    final onLine = f.at(50, 50);
    expect(onLine, greaterThan(0.8));
    expect(f.at(50, 45), closeTo(f.at(50, 55), 0.05));
    expect(f.at(50, 45), lessThan(onLine));
    expect(f.at(50, 20), 0);
    expect(f.at(50, 80), 0);
  });

  test('walking twice is higher than once, but sub-linearly (log)', () {
    final once = buildHeatField(
        width: 300, height: 300, input: lines([30, 150, 270, 150]), strokePx: 3);
    final twice = buildHeatField(
        width: 300,
        height: 300,
        input: lines([30, 150, 270, 150, 30, 150, 270, 150]),
        strokePx: 3);
    // Both normalised to 1 at their own peak; compare raw peaks instead.
    expect(twice.peak, closeTo(once.peak * 2, once.peak * 0.05));
    // And in a mixed field the twice-walked road is taller than the once
    // road, but well under 2× after log normalisation.
    final mixed = buildHeatField(
        width: 300,
        height: 300,
        input: lines([30, 100, 270, 100, 30, 200, 270, 200, 30, 200, 270, 200]),
        strokePx: 3);
    final low = mixed.at(50, 33), high = mixed.at(50, 66);
    expect(high, greaterThan(low));
    expect(high / low, lessThan(1.8));
  });

  test('peak density reads back as a zoom-independent pass count', () {
    // Zooming in widens the stroke (σ), which lowers the raw peak density —
    // the pass count it stands for must not move with it. (A thin stroke
    // loses a little to grid phase, so it reads slightly low, never high.)
    for (final stroke in [3.0, 6.0, 9.0]) {
      expect(road(stroke, 1).peakPasses, closeTo(1.0, 0.25),
          reason: 'stroke=$stroke');
      expect(road(stroke, 12).peakPasses, closeTo(12, 3),
          reason: 'stroke=$stroke');
    }
    expect(road(9, 1).peak, lessThan(road(3, 1).peak * 0.75),
        reason: 'raw density really does drop as the stroke widens');
  });

  test('height is absolute: unchanged by zoom, window, or the neighbours', () {
    // Same road, same passes, three zooms → same ridge height.
    final h3 = peakH(road(3, 6)), h6 = peakH(road(6, 6)), h9 = peakH(road(9, 6));
    // (±0.1 of full scale — the residual is grid phase at thin strokes.)
    expect(h6, closeTo(h3, 0.1));
    expect(h9, closeTo(h3, 0.1));

    // Full scale is refPasses, and a single pass is a real bump, not zero.
    expect(peakH(road(3, HeatField.refPasses.toInt())), greaterThan(0.88));
    expect(peakH(road(3, 1)), inInclusiveRange(0.25, 0.4));

    // A busy road elsewhere in the view no longer squashes this one: before
    // the switch to absolute scaling, the quiet road was renormalised away.
    final together = buildHeatField(
      width: 300,
      height: 300,
      input: lines([
        30, 61.5, 270, 61.5, // walked once
        for (var i = 0; i < 24; i++) ...[30, 241.5, 270, 241.5],
      ]),
      strokePx: 3,
    );
    expect(together.at(50, 20), closeTo(peakH(road(3, 1)), 0.05));
    expect(together.at(50, 80), greaterThan(0.88));
  });

  test('an all-quiet view gets a gentle lift, a busy one does not', () {
    expect(road(3, 1).heightLift, greaterThan(1.0));
    expect(road(3, 24).heightLift, 1.0);
    expect(road(3, 1).heightLift, lessThanOrEqualTo(2.6));
  });

  test('a crossing is higher than either road', () {
    final f = buildHeatField(
        width: 300,
        height: 300,
        input: lines([30, 150, 270, 150, 150, 30, 150, 270]),
        strokePx: 3);
    final cross = f.at(50, 50);
    expect(cross, greaterThan(f.at(20, 50)));
    expect(cross, greaterThan(f.at(50, 20)));
  });

  test('heights stay within [0,1] and a well-walked road reaches ~1', () {
    final l = <double>[];
    for (var i = 0; i < 24; i++) {
      l.addAll([10, 60, 110, 60]);
    }
    final f =
        buildHeatField(width: 120, height: 120, input: lines(l), strokePx: 6);
    var mx = 0.0;
    for (final v in f.h) {
      expect(v, inInclusiveRange(0.0, 1.0));
      if (v > mx) mx = v;
    }
    expect(mx, greaterThan(0.85));
  });

  test('segments fully off-screen contribute nothing', () {
    final f = buildHeatField(
        width: 100, height: 100, input: lines([500, 500, 900, 900]), strokePx: 3);
    expect(f.isEmpty, isTrue);
  });

  test('fog blocks are faint compared to a walked line', () {
    final f = buildHeatField(
      width: 300,
      height: 300,
      input: HeatFieldInput(
        lines: Float32List.fromList([30, 100, 270, 100]),
        dots: Float32List(0),
        fogPts: Float32List.fromList([150, 220]),
        fogW: Float32List.fromList([1.0]),
        fogBlockPx: 20,
      ),
      strokePx: 3,
    );
    expect(f.at(50, 73), lessThan(f.at(50, 33) * 0.6));
    expect(f.at(50, 73), greaterThan(0));
  });

  test('cornerHeights averages the surrounding cells', () {
    final f = buildHeatField(
        width: 30, height: 30, input: lines([0, 15, 30, 15]), strokePx: 3);
    final c = f.cornerHeights();
    expect(c.length, (f.gw + 1) * (f.gh + 1));
    // Interior corner between rows 4 and 5 ≈ mean of those cells.
    final w1 = f.gw + 1;
    final corner = c[5 * w1 + 5];
    final mean = (f.at(4, 4) + f.at(5, 4) + f.at(4, 5) + f.at(5, 5)) / 4;
    expect(corner, closeTo(mean, 1e-6));
  });
}
