import 'dart:typed_data';
import 'dart:ui';

/// A heat-map colour ramp: intensity 0 → 1 maps along [stops]. Every ramp
/// ends in (near-)white so the hottest streets read as "burnt in", the way
/// 人生点点 / Strava personal heat maps do; the cold end is the ramp's own
/// dark hue so a single pass is still visible on a dark map.
class HeatPalette {
  final String name;
  final List<Color> stops;
  const HeatPalette(this.name, this.stops);

  /// Persisted by INDEX (AppSettings.heatPalette) — only ever append.
  static const List<HeatPalette> all = [
    HeatPalette('青', [
      Color(0xFF0B3A44),
      Color(0xFF12B5C8),
      Color(0xFF9BF1F7),
      Color(0xFFFFFFFF),
    ]),
    HeatPalette('火', [
      Color(0xFF4A0E00),
      Color(0xFFE84A00),
      Color(0xFFFFB347),
      Color(0xFFFFF4D6),
      Color(0xFFFFFFFF),
    ]),
    HeatPalette('彩虹', [
      Color(0xFF1E1B8F),
      Color(0xFF1E88E5),
      Color(0xFF2ECC71),
      Color(0xFFF1C40F),
      Color(0xFFE74C3C),
      Color(0xFFFFFFFF),
    ]),
    HeatPalette('紫', [
      Color(0xFF2A0A3B),
      Color(0xFF8E24AA),
      Color(0xFFE040FB),
      Color(0xFFFFFFFF),
    ]),
    HeatPalette('白', [
      Color(0xFF6E7A85),
      Color(0xFFCFD8DC),
      Color(0xFFFFFFFF),
    ]),
  ];

  static HeatPalette byIndex(int i) =>
      (i >= 0 && i < all.length) ? all[i] : all[0];

  /// Colour at [t] ∈ [0,1], piecewise-linear between stops (opaque).
  Color at(double t) {
    if (t <= 0) return stops.first;
    if (t >= 1) return stops.last;
    final f = t * (stops.length - 1);
    final i = f.floor();
    final frac = f - i;
    return Color.lerp(stops[i], stops[i + 1], frac)!;
  }

  /// 256-entry lookup table, intensity byte → **premultiplied** RGBA packed as
  /// `0xAABBGGRR` little-endian (i.e. the byte order `decodeImageFromPixels`
  /// wants for rgba8888 when written through a Uint32 view). Alpha ramps in
  /// over the first ~20%: one soft halo pass (≈0.035) stays near-invisible, one core pass (≈0.135) is a clear line — a single walk reads as a line with a whisper of glow, not a dark smear.
  Uint32List lut() {
    final out = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      final t = i / 255.0;
      if (i == 0) continue; // fully transparent
      final c = at(t);
      final a = _smoothstep(0.0, 0.2, t);
      final ai = (a * 255).round();
      final r = (c.r * ai).round();
      final g = (c.g * ai).round();
      final b = (c.b * ai).round();
      out[i] = (ai << 24) | (b << 16) | (g << 8) | r;
    }
    return out;
  }

  static double _smoothstep(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }
}
