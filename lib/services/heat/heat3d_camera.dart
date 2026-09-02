import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';


/// The 3D heat mode's map camera — Google-Maps-style tilt over a live tile
/// plane, in pure math (no Flutter widgets) so every projection identity is
/// unit-testable.
///
/// Spaces:
///  * **world01** — Web-Mercator [0,1)² (same as `HeatIndex.lngToWorldX/Y`),
///    in the DISPLAY datum (GCJ-02 on Amap, like the 2D map).
///  * **model px** — world01 offset from [centerX/Y] × [scale] (= world pixels
///    at the current fractional [zoom]). The ground plane lives here, z up.
///  * **screen px** — after yaw → pitch → perspective divide.
///
/// The ground (z = 0) maps to the screen by a homography, exposed as a
/// [groundMatrix] so tiles can be drawn with plain `canvas.drawImageRect`
/// under `canvas.transform` (GPU does the perspective-correct sampling);
/// ridges (z > 0) use [project] directly with the same constants.
class Heat3DCamera {
  double centerX01;
  double centerY01;

  /// Fractional tile zoom, like the 2D map's.
  double zoom;
  double pitchDeg;
  double yawDeg;
  Size viewport;

  Heat3DCamera({
    required this.centerX01,
    required this.centerY01,
    required this.zoom,
    this.pitchDeg = 0,
    this.yawDeg = 0,
    required this.viewport,
  });

  static const double minZoom = 3, maxZoom = 19;
  static const double maxPitch = 65;

  /// Beyond this homogeneous w the ground is "past the fog line": tiles are
  /// not selected and a dark fade covers it (Google fades to horizon too).
  static const double farW = 3.2;

  /// Focal length — matches the previous painter (1.6 × viewport height).
  double get focal => 1.6 * viewport.height;

  /// world01 → model px at the current zoom.
  double get scale => 256.0 * math.pow(2.0, zoom).toDouble();

  double get _pitchRad => pitchDeg * math.pi / 180;
  double get _yawRad => yawDeg * math.pi / 180;

  /// Tilt allowance shrinks as you zoom out (Google caps tilt at low zoom —
  /// a tilted world view is all horizon and no map).
  static double maxPitchForZoom(double zoom) =>
      zoom >= 14 ? maxPitch : math.max(20, maxPitch - (14 - zoom) * 6);

  void clampAll() {
    zoom = zoom.clamp(minZoom, maxZoom);
    pitchDeg = pitchDeg.clamp(0.0, maxPitchForZoom(zoom));
    centerX01 = centerX01.clamp(0.0, 1.0);
    centerY01 = centerY01.clamp(0.0, 1.0);
  }

  ({double mx, double my}) worldToModel(double x01, double y01) =>
      (mx: (x01 - centerX01) * scale, my: (y01 - centerY01) * scale);

  ({double x01, double y01}) modelToWorld(double mx, double my) =>
      (x01: centerX01 + mx / scale, y01: centerY01 + my / scale);

  /// Homogeneous w of a ground point: < 1 near (below centre), > 1 far,
  /// → ∞ at the horizon. Screen scale of the ground there is 1/w.
  double wAt(double mx, double my) {
    final a = math.sin(_pitchRad) / focal;
    final ry = mx * math.sin(_yawRad) + my * math.cos(_yawRad);
    return 1 - ry * a;
  }

  /// Model (mx, my, height h in model px, z-up) → screen px.
  Offset project(double mx, double my, double h) {
    final cosP = math.cos(_pitchRad), sinP = math.sin(_pitchRad);
    final cosY = math.cos(_yawRad), sinY = math.sin(_yawRad);
    final rx = mx * cosY - my * sinY;
    final ry = mx * sinY + my * cosY;
    final camY = ry * cosP - h * sinP;
    final camZ = ry * sinP + h * cosP; // toward the viewer
    final s = focal / (focal - camZ);
    return Offset(viewport.width / 2 + rx * s, viewport.height / 2 + camY * s);
  }

  /// Screen px → ground model px (h = 0), or null past the horizon / beyond
  /// the [farW] fog line (an anchor there would fling the camera to infinity).
  ({double mx, double my})? unproject(Offset screen) {
    final cosP = math.cos(_pitchRad), sinP = math.sin(_pitchRad);
    final cosY = math.cos(_yawRad), sinY = math.sin(_yawRad);
    final dx = screen.dx - viewport.width / 2;
    final dy = screen.dy - viewport.height / 2;
    final denom = cosP + dy * sinP / focal;
    if (denom <= 1e-6) return null; // at/above the horizon
    final ry = dy / denom;
    final w = 1 - ry * sinP / focal;
    if (w <= 0.05 || w > farW) return null;
    final rx = dx * w;
    return (
      mx: rx * cosY + ry * sinY,
      my: -rx * sinY + ry * cosY,
    );
  }

  /// The ground-plane homography as a column-major 4×4 for
  /// `canvas.transform`: (mx, my, 0, 1) ↦ homogeneous screen. Identical math
  /// to [project] with h = 0 — pinned against it in tests.
  Float64List groundMatrix() {
    final cosP = math.cos(_pitchRad), sinP = math.sin(_pitchRad);
    final cosY = math.cos(_yawRad), sinY = math.sin(_yawRad);
    final a = sinP / focal;
    final cx = viewport.width / 2, cy = viewport.height / 2;
    final m = Float64List(16);
    // storage[col * 4 + row]
    m[0] = cosY - cx * a * sinY; // m00
    m[1] = cosP * sinY - cy * a * sinY; // m10
    m[3] = -a * sinY; // m30
    m[4] = -sinY - cx * a * cosY; // m01
    m[5] = cosP * cosY - cy * a * cosY; // m11
    m[7] = -a * cosY; // m31
    m[10] = 1; // m22
    m[12] = cx; // m03
    m[13] = cy; // m13
    m[15] = 1; // m33
    return m;
  }

  /// Screen y of the [farW] fog line along the centre column (clamped to the
  /// top edge), or 0 when the whole view is near-field. The painter fades
  /// everything above it.
  double fogLineY() {
    final sinP = math.sin(_pitchRad);
    if (sinP < 1e-4) return 0;
    final cosP = math.cos(_pitchRad);
    final ry = (1 - farW) * focal / sinP; // negative: far is up-screen
    final y = viewport.height / 2 + ry * cosP / farW;
    return y.clamp(0.0, viewport.height);
  }

  // ─── Gesture anchoring (Google-style) ───

  /// Move the camera so the world point [anchorX01, anchorY01] appears under
  /// [screen]. No-op when [screen] is past the horizon.
  void anchorWorldToScreen(double anchorX01, double anchorY01, Offset screen) {
    final g = unproject(screen);
    if (g == null) return;
    centerX01 = anchorX01 - g.mx / scale;
    centerY01 = anchorY01 - g.my / scale;
  }
}

/// One tile to draw: pyramid coords + its destination rect in model px.
class TileSpec {
  final int z, x, y;
  final Rect dstModel;
  const TileSpec(this.z, this.x, this.y, this.dstModel);

  Object get key => Object.hash(z, x, y);

  @override
  bool operator ==(Object other) =>
      other is TileSpec && other.z == z && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(z, x, y);
}

/// Google-Maps-style LOD selection: the screen is sampled on a grid, every
/// sample unprojects to the ground and asks for the tile whose resolution
/// matches its perspective scale (near → the zoom's native tiles, far →
/// coarser parents, ideal zoom ≈ `zoom − log2(w)`). Tiles come back sorted
/// coarse-first so finer levels overdraw at band seams.
///
/// Every selected tile projects to roughly 181–362 px on screen by
/// construction, so a [samplePx] grid (with one ring beyond the edges) hits
/// each of them.
List<TileSpec> selectVisibleTiles(Heat3DCamera cam,
    {double samplePx = 44, int maxNativeZoom = 19}) {
  // The near field of a tilted view is MAGNIFIED (w < 1), so it may want
  // tiles one level finer than the camera zoom itself — same as Google
  // loading sharper imagery at the bottom of a tilted view.
  final ztHigh = (cam.zoom.round() + 1)
      .clamp(Heat3DCamera.minZoom.toInt(), maxNativeZoom);
  final seen = <TileSpec>{};
  final w = cam.viewport.width, h = cam.viewport.height;
  for (var sy = -samplePx; sy <= h + samplePx; sy += samplePx) {
    for (var sx = -samplePx; sx <= w + samplePx; sx += samplePx) {
      final g = cam.unproject(Offset(sx, sy));
      if (g == null) continue;
      final pw = cam.wAt(g.mx, g.my);
      if (pw > Heat3DCamera.farW || pw <= 0) continue;
      // Ideal zoom for ~1 screen px per tile px, rounded, capped at native.
      final ideal = cam.zoom - math.log(pw) / math.ln2;
      final zt = ideal.round().clamp(Heat3DCamera.minZoom.toInt(), ztHigh);
      final n = 1 << zt;
      final world = cam.modelToWorld(g.mx, g.my);
      final tx = (world.x01 * n).floor();
      final ty = (world.y01 * n).floor();
      if (tx < 0 || ty < 0 || tx >= n || ty >= n) continue;
      final sc = cam.scale / n; // model px per tile
      final left = (tx / n - cam.centerX01) * cam.scale;
      final top = (ty / n - cam.centerY01) * cam.scale;
      seen.add(TileSpec(zt, tx, ty, Rect.fromLTWH(left, top, sc, sc)));
    }
  }
  final out = seen.toList()
    ..sort((a, b) {
      final c = a.z.compareTo(b.z);
      if (c != 0) return c;
      final d = a.y.compareTo(b.y);
      return d != 0 ? d : a.x.compareTo(b.x);
    });
  return out;
}
