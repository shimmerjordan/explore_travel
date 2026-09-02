import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/heat/heat3d_camera.dart';

void main() {
  Heat3DCamera cam({
    double zoom = 16,
    double pitch = 50,
    double yaw = 0,
  }) =>
      Heat3DCamera(
        centerX01: 0.789, // ~成都 longitude band
        centerY01: 0.416,
        zoom: zoom,
        pitchDeg: pitch,
        yawDeg: yaw,
        viewport: const Size(400, 800),
      );

  test('pitch 0 is the identity map around the centre', () {
    final c = cam(pitch: 0);
    expect(c.project(0, 0, 0), const Offset(200, 400));
    expect(c.project(50, -30, 0), const Offset(250, 370));
    final g = c.unproject(const Offset(250, 370))!;
    expect(g.mx, closeTo(50, 1e-6));
    expect(g.my, closeTo(-30, 1e-6));
  });

  test('groundMatrix matches project() for h = 0 across pitch/yaw', () {
    for (final (p, y) in [(0.0, 0.0), (35.0, 0.0), (52.0, 30.0), (65.0, -120.0)]) {
      final c = cam(pitch: p, yaw: y);
      final m = c.groundMatrix();
      for (final (mx, my) in [(0.0, 0.0), (120.0, -300.0), (-80.0, 250.0)]) {
        // Column-major storage: X_h = m00·x + m01·y + m03, etc.
        final xh = m[0] * mx + m[4] * my + m[12];
        final yh = m[1] * mx + m[5] * my + m[13];
        final wh = m[3] * mx + m[7] * my + m[15];
        final viaMatrix = Offset(xh / wh, yh / wh);
        final direct = c.project(mx, my, 0);
        expect(viaMatrix.dx, closeTo(direct.dx, 1e-6), reason: 'p=$p y=$y');
        expect(viaMatrix.dy, closeTo(direct.dy, 1e-6), reason: 'p=$p y=$y');
      }
    }
  });

  test('unproject(project(g)) round-trips on the ground plane', () {
    final c = cam(pitch: 55, yaw: 40);
    for (final (mx, my) in [(0.0, 0.0), (140.0, 90.0), (-200.0, 300.0), (10.0, -220.0)]) {
      final s = c.project(mx, my, 0);
      final g = c.unproject(s)!;
      expect(g.mx, closeTo(mx, 1e-6));
      expect(g.my, closeTo(my, 1e-6));
    }
  });

  test('unproject returns null at and above the horizon', () {
    final c = cam(pitch: 65);
    expect(c.unproject(const Offset(200, 799)), isNotNull);
    expect(c.unproject(const Offset(200, -100000)), isNull);
    // Just below the horizon line (denom → 0⁺) the ground is beyond the fog
    // cap → still null; a bit further down it resolves.
    final f = c.focal;
    final horizonDy = -f * math.cos(65 * math.pi / 180) /
        math.sin(65 * math.pi / 180);
    expect(c.unproject(Offset(200, 400 + horizonDy * 0.995)), isNull);
    expect(c.unproject(Offset(200, 400 + horizonDy + 300)), isNotNull);
    // With f = 1.6 × height and pitch ≤ 65°, the fog line sits above the
    // screen top on a portrait viewport — nothing on screen needs the fade.
    expect(c.fogLineY(), 0);
  });

  test('perspective: far ground is smaller (w grows up-screen)', () {
    final c = cam(pitch: 50);
    final near = c.unproject(const Offset(200, 700))!;
    final far = c.unproject(const Offset(200, 200))!;
    expect(c.wAt(near.mx, near.my), lessThan(1));
    expect(c.wAt(far.mx, far.my), greaterThan(1));
    // Same screen step covers more ground when far.
    final near2 = c.unproject(const Offset(200, 690))!;
    final far2 = c.unproject(const Offset(200, 190))!;
    expect((far2.my - far.my).abs(), greaterThan((near2.my - near.my).abs()));
  });

  test('anchorWorldToScreen keeps the grabbed point under the finger', () {
    final c = cam(pitch: 48, yaw: 25);
    const finger = Offset(260, 550);
    final g = c.unproject(finger)!;
    final world = c.modelToWorld(g.mx, g.my);
    // Simulate a drag: the camera moves, then re-anchor.
    c.centerX01 += 0.0004;
    c.centerY01 -= 0.0002;
    c.anchorWorldToScreen(world.x01, world.y01, finger);
    final back = c.unproject(finger)!;
    final worldBack = c.modelToWorld(back.mx, back.my);
    expect(worldBack.x01, closeTo(world.x01, 1e-12));
    expect(worldBack.y01, closeTo(world.y01, 1e-12));
  });

  test('pitch allowance shrinks when zoomed out', () {
    expect(Heat3DCamera.maxPitchForZoom(16), 65);
    expect(Heat3DCamera.maxPitchForZoom(10), lessThan(65));
    expect(Heat3DCamera.maxPitchForZoom(4), 20);
  });

  group('selectVisibleTiles', () {
    test('top-down: native-zoom tiles cover the viewport, correct dst rects',
        () {
      final c = cam(zoom: 16, pitch: 0);
      final tiles = selectVisibleTiles(c);
      expect(tiles, isNotEmpty);
      expect(tiles.every((t) => t.z == 16), isTrue);
      // The tile under the camera centre must be present, its rect must
      // contain the model origin.
      final centreTile = tiles.firstWhere((t) =>
          t.dstModel.contains(const Offset(0, 0)));
      final n = 1 << 16;
      expect(centreTile.x, (0.789 * n).floor());
      expect(centreTile.y, (0.416 * n).floor());
      // Rects tile the plane: each is 256 model px at native zoom.
      expect(centreTile.dstModel.width, closeTo(256, 1e-6));
    });

    test('tilted: far bands use coarser tiles, sorted coarse-first', () {
      final c = cam(zoom: 16, pitch: 60);
      final tiles = selectVisibleTiles(c);
      final zooms = tiles.map((t) => t.z).toSet();
      expect(zooms, contains(16));
      expect(zooms.any((z) => z < 16), isTrue,
          reason: 'far ground must load coarser tiles');
      // Sorted coarse-first so fine levels overdraw at seams.
      for (var i = 1; i < tiles.length; i++) {
        expect(tiles[i].z, greaterThanOrEqualTo(tiles[i - 1].z));
      }
      // Bounded working set even at full tilt.
      expect(tiles.length, lessThan(220));
    });

    test('every selected tile projects to a sane on-screen size', () {
      final c = cam(zoom: 16.4, pitch: 55, yaw: 33);
      for (final t in selectVisibleTiles(c)) {
        // Project the tile's near edge midpoint and measure the screen size
        // of one tile-width step.
        final mid = t.dstModel.center;
        final w = cam(zoom: 16.4, pitch: 55, yaw: 33).wAt(mid.dx, mid.dy);
        if (w > Heat3DCamera.farW || w <= 0) continue;
        final screenPerTile = t.dstModel.width / w;
        expect(screenPerTile, greaterThan(150), reason: 'z=${t.z} too coarse');
        expect(screenPerTile, lessThan(560), reason: 'z=${t.z} too fine');
      }
    });

    test('zoomed-out top-down never selects below minZoom and stays bounded',
        () {
      final c = cam(zoom: 3.2, pitch: 0);
      final tiles = selectVisibleTiles(c);
      expect(tiles.every((t) => t.z >= 3), isTrue);
      expect(tiles.length, lessThan(120));
      final ideal = math.log(1) / math.ln2; // silence unused-import lint
      expect(ideal, 0);
    });
  });
}
