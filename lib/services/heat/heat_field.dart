import 'dart:math' as math;
import 'dart:typed_data';

/// Screen-space density field behind the 3D "heat ridge" view.
///
/// The 2D tiles accumulate coverage in 8-bit additive alpha, which saturates
/// after ~10 passes — fine for colour, useless for height (every busy street
/// would be the same plateau). This rasterises the same segments into a
/// **float** grid instead: no clipping, so the commute you walked 300 times
/// really does stand taller than the one you walked 30 times, then a log
/// curve keeps the tallest peak from flattening everything else.
///
/// Pure Dart, no Flutter — unit-testable and `compute()`-safe.
class HeatFieldInput {
  /// n × 4 screen-px line segments (x0,y0,x1,y1).
  final Float32List lines;

  /// m × 2 isolated fixes.
  final Float32List dots;

  /// k × 2 fog-block centres + k weights (popcount fraction) + block side px.
  final Float32List fogPts;
  final Float32List fogW;
  final double fogBlockPx;

  const HeatFieldInput({
    required this.lines,
    required this.dots,
    required this.fogPts,
    required this.fogW,
    required this.fogBlockPx,
  });

  bool get isEmpty => lines.isEmpty && dots.isEmpty && fogPts.isEmpty;
}

class HeatField {
  /// Grid size in cells and cell side in logical px.
  final int gw, gh;
  final double cell;

  /// gw × gh normalised heights in [0,1] (row-major, y down).
  final Float32List h;

  /// Peak raw density before normalisation (0 when empty).
  final double peak;

  /// Gaussian σ (in cells) used for walked lines in this build.
  final double sigma;

  /// Gentle rescue factor for a view where nothing was walked much: 1 almost
  /// always, up to 2.6 when even the tallest crest would otherwise be a bump.
  /// Applied to the HEIGHT only (not the colour), so a quiet neighbourhood
  /// still reads as terrain without pretending it is a highway.
  final double heightLift;

  const HeatField(this.gw, this.gh, this.cell, this.h, this.peak, this.sigma,
      this.heightLift);

  bool get isEmpty => peak <= 0;

  /// Pass count that reaches full height. Heights are ABSOLUTE against this,
  /// never renormalised per view: the same street is the same mountain at any
  /// zoom and in any window — which is the whole point, since a per-view
  /// normalisation makes the ridge collapse the moment you zoom into a single
  /// road (it becomes its own peak) and rebuild it on every gesture.
  static const double refPasses = 24;

  /// [peak] read as "how many times was the busiest spot walked".
  ///
  /// One pass lays down a Gaussian ridge whose crest is `1 / (√2π·σ)`, so
  /// dividing that out turns raw density into a pass count — necessary
  /// because σ tracks the stroke width, which grows as you zoom in.
  double get peakPasses => peak * math.sqrt(2 * math.pi) * sigma;

  /// Multiplier on the height budget. [h] already carries absolute height, so
  /// this is just [heightLift] (kept as the painter's single knob).
  double get heightScale => peak <= 0 ? 0 : heightLift;

  double at(int x, int y) {
    if (x < 0 || y < 0 || x >= gw || y >= gh) return 0;
    return h[y * gw + x];
  }

  /// Heights at cell CORNERS ((gw+1) × (gh+1)): mean of the ≤4 cells around
  /// each corner. The tilt mesh is built on corners so neighbouring cells
  /// share vertices and the ridge is a continuous surface, not a bar chart.
  Float32List cornerHeights() {
    final w1 = gw + 1, h1 = gh + 1;
    final out = Float32List(w1 * h1);
    for (var y = 0; y < h1; y++) {
      for (var x = 0; x < w1; x++) {
        var sum = 0.0;
        var n = 0;
        for (var dy = -1; dy <= 0; dy++) {
          for (var dx = -1; dx <= 0; dx++) {
            final cx = x + dx, cy = y + dy;
            if (cx < 0 || cy < 0 || cx >= gw || cy >= gh) continue;
            sum += h[cy * gw + cx];
            n++;
          }
        }
        out[y * w1 + x] = n == 0 ? 0 : sum / n;
      }
    }
    return out;
  }
}

/// Build the field for a [width]×[height] logical-px viewport.
///
/// [strokePx] is the core stroke width the 2D tiles use at this zoom — the
/// Gaussian footprint scales with it so the ridge sits exactly on the glow.
/// [exposure] bends the log curve: higher lifts faint paths (人生点点's 曝光).
HeatField buildHeatField({
  required double width,
  required double height,
  required HeatFieldInput input,
  required double strokePx,
  double exposure = 1.0,
  double cell = 3.0,
}) {
  final gw = math.max(1, (width / cell).ceil());
  final gh = math.max(1, (height / cell).ceil());
  final acc = Float32List(gw * gh);
  // Gaussian stamp: σ tracks the stroke width, but bounded at both ends.
  // Low: never under ~1 cell — a hairline at country zoom must still land on
  // a 3×3 neighbourhood, and a narrower crest samples so unevenly (does the
  // road pass through a cell centre or between two?) that its height would
  // wobble with sub-pixel placement. High: capped at 1.6 cells — the 2D glow
  // keeps widening as you zoom in, and if the ridge widened with it the
  // height budget (a constant slice of the screen) would flatten it into a
  // plateau. Capping keeps the ridge a sharp crest running along the glow at
  // every zoom.
  final sigma = (strokePx * 0.55 / cell).clamp(0.95, 1.6);
  if (input.isEmpty) return HeatField(gw, gh, cell, acc, 0, sigma, 1);

  final kernel = _Kernel(sigma);
  final fogKernel = _Kernel(math.max(sigma, input.fogBlockPx * 0.35 / cell));

  void stamp(_Kernel k, double px, double py, double w) {
    final cx = px / cell, cy = py / cell;
    final ix = cx.round(), iy = cy.round();
    final r = k.radius;
    if (ix + r < 0 || iy + r < 0 || ix - r >= gw || iy - r >= gh) return;
    // Sub-cell offset so a line sampled every half-cell doesn't alias.
    final fx = cx - ix, fy = cy - iy;
    for (var dy = -r; dy <= r; dy++) {
      final y = iy + dy;
      if (y < 0 || y >= gh) continue;
      final row = y * gw;
      final gy = math.exp(-((dy - fy) * (dy - fy)) * k.inv2s2);
      for (var dx = -r; dx <= r; dx++) {
        final x = ix + dx;
        if (x < 0 || x >= gw) continue;
        final gx = math.exp(-((dx - fx) * (dx - fx)) * k.inv2s2);
        acc[row + x] += w * gx * gy * k.norm;
      }
    }
  }

  // Lines: walk at half-cell steps; weight per stamp = step length in cells
  // so density is per unit length (a long straight and a wiggly path of the
  // same length deposit the same total).
  final lines = input.lines;
  final step = cell * 0.5;
  for (var i = 0; i + 3 < lines.length; i += 4) {
    final x0 = lines[i], y0 = lines[i + 1], x1 = lines[i + 2], y1 = lines[i + 3];
    final dx = x1 - x0, dy = y1 - y0;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-3) {
      stamp(kernel, x0, y0, 0.5);
      continue;
    }
    // Cull segments entirely off-grid (with kernel margin).
    final m = kernel.radius * cell + 1;
    if (math.max(x0, x1) < -m ||
        math.min(x0, x1) > width + m ||
        math.max(y0, y1) < -m ||
        math.min(y0, y1) > height + m) {
      continue;
    }
    final n = math.max(1, (len / step).ceil());
    final w = (len / n) / cell;
    for (var s = 0; s <= n; s++) {
      final t = s / n;
      stamp(kernel, x0 + dx * t, y0 + dy * t, w);
    }
  }
  final dots = input.dots;
  for (var i = 0; i + 1 < dots.length; i += 2) {
    stamp(kernel, dots[i], dots[i + 1], 0.5);
  }
  // Fog baseline: faint, so imported-fog-only areas read as "been here" but
  // never compete with a real walked line.
  final fog = input.fogPts;
  for (var i = 0; i + 1 < fog.length; i += 2) {
    stamp(fogKernel, fog[i], fog[i + 1], 0.12 * input.fogW[i >> 1]);
  }

  var peak = 0.0;
  for (final v in acc) {
    if (v > peak) peak = v;
  }
  if (peak <= 0) return HeatField(gw, gh, cell, acc, 0, sigma, 1);

  // Absolute scale: log1p(k·passes) / log1p(k·refPasses). Density is turned
  // into a pass count first (÷ the crest of one pass), so the curve does not
  // move with zoom, with the time window, or with what else is on screen.
  final k = 3.0 * exposure.clamp(0.3, 3.0);
  final perPass = math.sqrt(2 * math.pi) * sigma;
  final denom = math.log(1 + k * HeatField.refPasses);
  final out = Float32List(gw * gh);
  for (var i = 0; i < acc.length; i++) {
    final v = acc[i];
    out[i] =
        v <= 0 ? 0 : (math.log(1 + k * v * perPass) / denom).clamp(0.0, 1.0);
  }
  // One 3×3 binomial smooth so the mesh has no single-cell spikes.
  final sm = Float32List(gw * gh);
  var smMax = 0.0;
  for (var y = 0; y < gh; y++) {
    for (var x = 0; x < gw; x++) {
      var sum = 0.0;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= gh) continue;
        final wy = dy == 0 ? 2.0 : 1.0;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= gw) continue;
          final wx = dx == 0 ? 2.0 : 1.0;
          sum += out[yy * gw + xx] * wx * wy;
        }
      }
      final v = sum / 16.0;
      sm[y * gw + x] = v;
      if (v > smMax) smMax = v;
    }
  }
  // No renormalisation — heights stay absolute. Only rescue a view whose
  // tallest crest is so low it would read as flat ground.
  const floor = 0.35;
  final lift =
      smMax >= floor || smMax <= 0 ? 1.0 : (floor / smMax).clamp(1.0, 2.6);
  return HeatField(gw, gh, cell, sm, peak, sigma, lift);
}

class _Kernel {
  final double sigma;
  final int radius;
  final double inv2s2;
  final double norm;
  _Kernel(this.sigma)
      : radius = math.max(1, (sigma * 2.5).ceil()),
        inv2s2 = 1 / (2 * sigma * sigma),
        norm = 1 / (2 * math.pi * sigma * sigma);
}
