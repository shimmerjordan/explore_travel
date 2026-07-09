import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/models/models.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:explore_journal/services/map/fog_tile_provider.dart';

/// Rasterises the fog tile baker and pins the Fog-of-World look:
///   * corridor interior fully revealed (alpha ≈ 0),
///   * untouched fog at exactly the veil alpha,
///   * a soft feathered transition in between (the anti-staircase guarantee).
/// Also dumps side-by-side PNGs (new smooth z16 bake vs the old "z14 pixels
/// scaled 4×" look) under build/fog_bake_preview/ for eyeball verification.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const veil = Color(0xC7101820); // alpha 199 — mid-strength fog
  final veilA = (veil.a * 255.0).round(); // 199
  const dim = 256;

  // One 64×64 block: a 3-px-wide diagonal corridor plus an isolated dot.
  // Block (100,100) == the full extent of Web-Mercator tile z16 (100,100),
  // so the geometry below fills the baked tile edge-to-edge.
  FogTile makeBlock() {
    final bmp = Uint8List(FogEngine.bitmapBytes);
    for (var i = 6; i < 58; i++) {
      for (var o = -1; o <= 1; o++) {
        final x = i + o;
        if (x >= 0 && x < 64) FogEngine.setBit(bmp, x, i);
      }
    }
    FogEngine.setBit(bmp, 12, 50); // isolated single-cell dot
    return FogTile(
      tileX: 100,
      tileY: 100,
      zoom: FogEngine.tileZoom,
      layerId: 1,
      bitmap: bmp,
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  FogSnapshot snapshotWith(FogTile t) => FogSnapshot(
        rows: [t],
        veil: veil,
        mapProvider: MapProvider.osm,
        generation: 1,
      );

  Future<ByteData> rgbaOf(ui.Image img) async =>
      (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;

  int alphaAt(ByteData d, int x, int y, int width) =>
      d.getUint8((y * width + x) * 4 + 3);

  Future<void> dumpPng(ui.Image img, String name) async {
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('build/fog_bake_preview/$name');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(png!.buffer.asUint8List());
  }

  test('z16 smooth bake: revealed core, exact veil outside, feathered edge',
      () async {
    final img = await bakeFogTileForTest(snapshotWith(makeBlock()),
        100, 100, 16, dim);
    expect(img.width, dim);
    final d = await rgbaOf(img);

    // Corridor centre (fog px (30,30) → dest px ~4×30+2): fully revealed.
    expect(alphaAt(d, 122, 122, dim), lessThan(30),
        reason: 'corridor interior must be punched (nearly) clear');

    // Far corner: untouched fog stays at the exact veil alpha.
    expect(alphaAt(d, 250, 6, dim), inInclusiveRange(veilA - 2, veilA + 2),
        reason: 'unexplored fog must keep the configured veil opacity');

    // Perpendicular walk across the corridor edge at y=120 must pass through
    // at least one genuinely intermediate alpha — that IS the feather. The
    // old hard punch jumps 0→veil in a single pixel and fails this.
    var feathered = 0;
    for (var x = 100; x < 160; x++) {
      final a = alphaAt(d, x, 120, dim);
      if (a > 40 && a < veilA - 40) feathered++;
    }
    expect(feathered, greaterThanOrEqualTo(2),
        reason: 'edge must fade over multiple px, not staircase-jump');

    await dumpPng(img, 'new_z16_smooth.png');
  });

  test('isolated dot renders as a soft disk, not a hard 4×4 square', () async {
    final img = await bakeFogTileForTest(snapshotWith(makeBlock()),
        100, 100, 16, dim);
    final d = await rgbaOf(img);
    // Dot centre fog px (12,50) → dest (~50,202): clearly revealed.
    expect(alphaAt(d, 50, 202, dim), lessThan(veilA ~/ 2));
    // A hard square's corner (2px diagonal from centre) would be fully clear;
    // a disk+feather leaves partial veil there.
    final corner = alphaAt(d, 50 + 5, 202 + 5, dim);
    expect(corner, greaterThan(20),
        reason: 'disk corners must be soft (square corners were fully clear)');
    await dumpPng(img, 'new_z16_dot_detail.png');
  });

  test('z14-and-below keeps the exact integer punch (no feather at native)',
      () async {
    // Block (100,100) sits in the z14 tile (25,25) at offset (0,0); each fog
    // px == 1 dest px there.
    final img = await bakeFogTileForTest(snapshotWith(makeBlock()),
        25, 25, 14, dim);
    final d = await rgbaOf(img);
    // Corridor centre fog px (30,30) → dest px (30,30): exactly clear.
    expect(alphaAt(d, 30, 30, dim), 0,
        reason: 'native-zoom punch must stay pixel-exact for FOW parity');
    // Neighbour outside the corridor: exact veil (no bleed).
    expect(alphaAt(d, 40, 30, dim), veilA,
        reason: 'no feather may leak into the stored-bitmap zoom levels');
    // Dump a 4× nearest-neighbour blow-up of the corridor quadrant — this is
    // what z16 USED to look like before the smooth bake (the "锯齿" look).
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    c.scale(4);
    c.drawImageRect(
      img,
      const ui.Rect.fromLTWH(0, 0, 64, 64),
      const ui.Rect.fromLTWH(0, 0, 64, 64),
      ui.Paint()..filterQuality = ui.FilterQuality.none,
    );
    final old = await rec.endRecording().toImage(dim, dim);
    await dumpPng(old, 'old_z16_equivalent_hard.png');
  });
}
