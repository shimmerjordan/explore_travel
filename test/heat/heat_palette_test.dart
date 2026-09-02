import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/heat/heat_palette.dart';

void main() {
  test('every palette ends white and starts dark-ish', () {
    for (final p in HeatPalette.all) {
      expect(p.stops.last, const Color(0xFFFFFFFF), reason: p.name);
      final first = p.stops.first;
      expect(first.computeLuminance(), lessThan(0.3), reason: p.name);
    }
  });

  test('at() clamps and interpolates', () {
    final p = HeatPalette.all[0];
    expect(p.at(-1), p.stops.first);
    expect(p.at(2), p.stops.last);
    final mid = p.at(0.5);
    expect(mid, isNot(p.stops.first));
    expect(mid, isNot(p.stops.last));
  });

  test('lut: entry 0 transparent, alpha ramps in, values premultiplied', () {
    final lut = HeatPalette.all[1].lut();
    expect(lut.length, 256);
    expect(lut[0], 0);
    int a(int v) => (v >> 24) & 0xFF;
    int r(int v) => v & 0xFF;
    // Alpha is monotonic non-decreasing.
    for (var i = 1; i < 256; i++) {
      expect(a(lut[i]), greaterThanOrEqualTo(a(lut[i - 1])), reason: '$i');
    }
    // Ramp-in region is translucent, tail is opaque white.
    expect(a(lut[4]), lessThan(255));
    expect(a(lut[255]), 255);
    expect(lut[255] & 0x00FFFFFF, 0x00FFFFFF);
    // Premultiplied: no channel exceeds alpha.
    for (var i = 0; i < 256; i++) {
      expect(r(lut[i]), lessThanOrEqualTo(a(lut[i])), reason: '$i');
    }
  });

  test('byIndex falls back to the first palette for unknown indices', () {
    expect(HeatPalette.byIndex(99), HeatPalette.all[0]);
    expect(HeatPalette.byIndex(-1), HeatPalette.all[0]);
    expect(HeatPalette.byIndex(2), HeatPalette.all[2]);
  });
}
