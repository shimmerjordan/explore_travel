import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/models/models.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:explore_journal/services/fog/fow_compat.dart';
import 'package:explore_journal/services/map/fog_tile_provider.dart';

/// Rasterises the fog tile baker and pins the corridor look:
///   * 缩小时路径按比例变细：at-and-below native zoom corridor width scales
///     WITH the map (ground-proportional), bottoming out at ~1 px — no
///     constant-screen-width inflation ("缩小后线条特别粗").
///   * 无光晕：edges are crisp anti-aliased transitions, not a gaussian
///     feather ("路径边缘发糊").
///   * the bit-exact integer skeleton is preserved — every explored cell is
///     inside the corridor, far fog keeps the exact veil alpha.
///   * a coloured layer renders the IDENTICAL corridor geometry, only tinted
///     (透明色 vs 自定义颜色 — 同一路径样式).
///   * rendering depends ONLY on bitmap bytes → FOW imports, local recording
///     and export→import roundtrips all look the same by construction.
/// Dumps PNGs under build/fog_bake_preview/ for eyeball verification.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const veil = Color(0xC7101820); // alpha 199 — mid-strength fog
  final veilA = (veil.a * 255.0).round(); // 199
  const dim = 256;

  // One 64×64 block: a 3-px-wide diagonal corridor plus an isolated dot.
  // Block (100,100) == the full extent of Web-Mercator tile z16 (100,100),
  // so the geometry below fills the baked tile edge-to-edge.
  FogTile makeBlock({int layerId = 1}) {
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
      layerId: layerId,
      bitmap: bmp,
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  // A 1-cell-wide vertical line through the whole block at x=32 — the
  // worst-case thin trail used for the constant-screen-width checks.
  FogTile makeThinLine({int layerId = 1}) {
    final bmp = Uint8List(FogEngine.bitmapBytes);
    for (var y = 0; y < 64; y++) {
      FogEngine.setBit(bmp, 32, y);
    }
    return FogTile(
      tileX: 100,
      tileY: 100,
      zoom: FogEngine.tileZoom,
      layerId: layerId,
      bitmap: bmp,
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  FogSnapshot snapshotWith(List<FogTile> rows,
          {Map<int, Color> tints = const {}}) =>
      FogSnapshot(
        rows: rows,
        veil: veil,
        mapProvider: MapProvider.osm,
        generation: 1,
        tints: tints,
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

  /// Count of "revealed" px (alpha < veil/2) across a horizontal scan row.
  int clearWidth(ByteData d, int y, int x0, int x1, int width) {
    var n = 0;
    for (var x = x0; x < x1; x++) {
      if (alphaAt(d, x, y, width) < veilA ~/ 2) n++;
    }
    return n;
  }

  group('overzoom (z>14) disc bake — crisp AA edges, no glow', () {
    test('z16: revealed core, exact veil outside, crisp edge', () async {
      final img = await bakeFogTileForTest(
          snapshotWith([makeBlock()]), 100, 100, 16, dim);
      expect(img.width, dim);
      final d = await rgbaOf(img);

      expect(alphaAt(d, 122, 122, dim), lessThan(30),
          reason: 'corridor interior must be punched (nearly) clear');
      expect(alphaAt(d, 250, 6, dim), inInclusiveRange(veilA - 2, veilA + 2),
          reason: 'unexplored fog must keep the configured veil opacity');

      // 无光晕: the corridor edge must be a narrow AA transition. The old
      // gaussian feather spread intermediate alphas over many px ("发糊");
      // a crisp edge leaves only a few AA px along a 60-px scan.
      var feathered = 0;
      for (var x = 100; x < 160; x++) {
        final a = alphaAt(d, x, 120, dim);
        if (a > 40 && a < veilA - 40) feathered++;
      }
      expect(feathered, lessThanOrEqualTo(6),
          reason: 'edge must be crisp AA, not a multi-px gaussian glow');
      await dumpPng(img, 'z16_smooth.png');
    });

    test('isolated dot renders as a round disk, not a hard square', () async {
      final img = await bakeFogTileForTest(
          snapshotWith([makeBlock()]), 100, 100, 16, dim);
      final d = await rgbaOf(img);
      expect(alphaAt(d, 50, 202, dim), lessThan(veilA ~/ 2));
      final corner = alphaAt(d, 50 + 5, 202 + 5, dim);
      expect(corner, greaterThan(20),
          reason: 'disk corners must be soft (square corners were clear)');
    });
  });

  group('native-and-below (z≤14) — ground-proportional width, ~1px floor', () {
    test('z14: skeleton exact, corridor stays near its true cell width',
        () async {
      // Block (100,100) sits in the z14 tile (25,25) at offset (0,0); each
      // fog px == 1 dest px there.
      final img = await bakeFogTileForTest(
          snapshotWith([makeThinLine()]), 25, 25, 14, dim);
      final d = await rgbaOf(img);

      // Skeleton: the data cell itself is fully revealed.
      expect(alphaAt(d, 32, 30, dim), lessThan(30),
          reason: 'explored cell must be inside the corridor');
      // Proportional width: a 1-cell trail renders ~1-2px at z14 — no
      // constant-screen-width inflation.
      final w = clearWidth(d, 30, 20, 45, dim);
      expect(w, inInclusiveRange(1, 3),
          reason: '1-cell trail must stay near 1-2px at z14, not inflate');
      // Far fog untouched.
      expect(alphaAt(d, 200, 200, dim), inInclusiveRange(veilA - 2, veilA + 2),
          reason: 'dilation must not lift the veil away from the trail');
      await dumpPng(img, 'z14_thin_line.png');
    });

    test('z12 + z10: a thin trail bottoms out at ~1px, never inflates',
        () async {
      // z12 tile (6,6): block cells map at scale 1/4 → line at dest x≈72.
      final img12 = await bakeFogTileForTest(
          snapshotWith([makeThinLine()]), 6, 6, 12, dim);
      final d12 = await rgbaOf(img12);
      final w12 = clearWidth(d12, 70, 60, 90, dim);
      expect(w12, inInclusiveRange(1, 2),
          reason: 'z12: a 1-cell trail must render at the ~1px floor');

      // z10 tile (1,1): scale 1/16 → line at dest x≈146, rows 144..148.
      final img10 = await bakeFogTileForTest(
          snapshotWith([makeThinLine()]), 1, 1, 10, dim);
      final d10 = await rgbaOf(img10);
      final w10 = clearWidth(d10, 146, 135, 160, dim);
      expect(w10, inInclusiveRange(1, 2),
          reason: 'z10: a 1-cell trail must render at the ~1px floor');

      await dumpPng(img12, 'z12_thin_line.png');
      await dumpPng(img10, 'z10_thin_line.png');
    });

    test('zooming out shrinks a wide area proportionally', () async {
      // A fully-explored 64×64 block: 64px wide at z14, so it must measure
      // ~16px at z12 (scale 1/4) and ~4px at z10 (scale 1/16) — the exact
      // "地图缩小路径也按比例缩小" behaviour.
      final bmp = Uint8List(FogEngine.bitmapBytes);
      for (var i = 0; i < bmp.length; i++) {
        bmp[i] = 0xFF;
      }
      final fullBlock = FogTile(
        tileX: 100,
        tileY: 100,
        zoom: FogEngine.tileZoom,
        layerId: 1,
        bitmap: bmp,
        updatedAt: DateTime(2026, 1, 1),
      );

      // z12: block spans dest x 64..80 (16px) on row 70.
      final img12 = await bakeFogTileForTest(
          snapshotWith([fullBlock]), 6, 6, 12, dim);
      final w12 = clearWidth(await rgbaOf(img12), 70, 50, 95, dim);
      expect(w12, inInclusiveRange(14, 18),
          reason: 'z12: a 64-cell-wide area must render ~16px wide');

      // z10: block spans dest x 144..148 (4px) on row 146.
      final img10 = await bakeFogTileForTest(
          snapshotWith([fullBlock]), 1, 1, 10, dim);
      final w10 = clearWidth(await rgbaOf(img10), 146, 130, 165, dim);
      expect(w10, inInclusiveRange(3, 6),
          reason: 'z10: the same area must shrink to ~4px, not stay wide');

      await dumpPng(img12, 'z12_wide_area.png');
      await dumpPng(img10, 'z10_wide_area.png');
    });

    test('z14 diagonal corridor is continuous (no beads/scallops)', () async {
      final img = await bakeFogTileForTest(
          snapshotWith([makeBlock()]), 25, 25, 14, dim);
      final d = await rgbaOf(img);
      // Walk the diagonal y=x from 8..55: every step must be revealed —
      // the constant-width dilation must never leave gaps between cells.
      for (var i = 8; i < 55; i++) {
        expect(alphaAt(d, i, i, dim), lessThan(veilA ~/ 2),
            reason: 'diagonal corridor must be gap-free at ($i,$i)');
      }
      await dumpPng(img, 'z14_diagonal.png');
    });
  });

  group('coloured layers — same geometry, only the colour differs', () {
    const tint = Color(0xB3FF7043); // deep orange @ 0.7

    test('z14: tinted corridor matches the transparent corridor shape',
        () async {
      final plain = await bakeFogTileForTest(
          snapshotWith([makeThinLine()]), 25, 25, 14, dim);
      final tinted = await bakeFogTileForTest(
          snapshotWith([makeThinLine()], tints: const {1: tint}),
          25,
          25,
          14,
          dim);
      final dp = await rgbaOf(plain);
      final dt = await rgbaOf(tinted);

      // Where the plain bake reveals, the tinted bake must paint colour —
      // and the veil region must be identical in both.
      var corridorPx = 0, tintedPx = 0, veilMismatch = 0;
      for (var y = 4; y < 60; y++) {
        for (var x = 4; x < 252; x++) {
          final ap = alphaAt(dp, x, y, dim);
          if (ap < 40) {
            corridorPx++;
            final o = (y * dim + x) * 4;
            final r = dt.getUint8(o), g = dt.getUint8(o + 1);
            // Tinted corridor: orange-ish (r >> g), not veil-dark.
            if (r > 60 && r > g) tintedPx++;
          } else if (ap > veilA - 10) {
            if ((alphaAt(dt, x, y, dim) - ap).abs() > 6) veilMismatch++;
          }
        }
      }
      expect(corridorPx, greaterThan(50));
      expect(tintedPx / corridorPx, greaterThan(0.85),
          reason: 'the tinted bake must colour the SAME corridor pixels');
      expect(veilMismatch, 0,
          reason: 'fog away from the corridor must be unaffected by tinting');
      await dumpPng(tinted, 'z14_tinted.png');
    });

    test('z16: tint pass exists at overzoom too', () async {
      final tinted = await bakeFogTileForTest(
          snapshotWith([makeBlock()], tints: const {1: tint}),
          100,
          100,
          16,
          dim);
      final d = await rgbaOf(tinted);
      // Corridor centre must be orange-ish, not fully transparent.
      final o = (122 * dim + 122) * 4;
      expect(d.getUint8(o), greaterThan(80), reason: 'corridor must be tinted');
      expect(d.getUint8(o) > d.getUint8(o + 2), isTrue,
          reason: 'tint hue must be the layer colour (r > b for orange)');
      await dumpPng(tinted, 'z16_tinted.png');
    });

    test('two layers: transparent + coloured both punch, colour only on its own',
        () async {
      // Layer 1: thin line at x=32 (transparent). Layer 2: shifted line at
      // x=48 (tinted). Both in block (100,100).
      final l2 = Uint8List(FogEngine.bitmapBytes);
      for (var y = 0; y < 64; y++) {
        FogEngine.setBit(l2, 48, y);
      }
      final rows = [
        makeThinLine(layerId: 1),
        FogTile(
          tileX: 100,
          tileY: 100,
          zoom: FogEngine.tileZoom,
          layerId: 2,
          bitmap: l2,
          updatedAt: DateTime(2026, 1, 1),
        ),
      ];
      final img = await bakeFogTileForTest(
          snapshotWith(rows, tints: const {2: tint}), 25, 25, 14, dim);
      final d = await rgbaOf(img);
      // x=32 (layer1): revealed, NOT tinted.
      expect(alphaAt(d, 32, 30, dim), lessThan(40));
      final o1 = (30 * dim + 32) * 4;
      expect(d.getUint8(o1), lessThan(60),
          reason: 'transparent layer must not pick up another layer\'s tint');
      // x=48 (layer2): revealed AND tinted.
      final o2 = (30 * dim + 48) * 4;
      expect(d.getUint8(o2), greaterThan(80),
          reason: 'coloured layer corridor must be tinted');
      await dumpPng(img, 'z14_two_layers.png');
    });
  });

  group('render depends only on bitmap bytes (import == record == roundtrip)',
      () {
    test('identical bitmaps bake byte-identical tiles', () async {
      // "FOW import" row and "locally recorded" row with the same bits —
      // different layer ids and timestamps must not change the pixels.
      final a = makeBlock(layerId: 1);
      final b = FogTile(
        tileX: 100,
        tileY: 100,
        zoom: FogEngine.tileZoom,
        layerId: 7, // different layer (still untinted)
        bitmap: Uint8List.fromList(a.bitmap),
        updatedAt: DateTime(2020, 5, 5), // different mtime
      );
      for (final z in [10, 12, 14, 16]) {
        final (tx, ty) = switch (z) {
          16 => (100, 100),
          14 => (25, 25),
          12 => (6, 6),
          _ => (1, 1),
        };
        final ia = await bakeFogTileForTest(snapshotWith([a]), tx, ty, z, dim);
        final ib = await bakeFogTileForTest(snapshotWith([b]), tx, ty, z, dim);
        final da = (await rgbaOf(ia)).buffer.asUint8List();
        final db = (await rgbaOf(ib)).buffer.asUint8List();
        expect(da, db,
            reason: 'z$z: same bitmap must render identically regardless of '
                'layer id / origin / timestamp');
      }
    });
  });

  group('real FOW data (Sync.zip copy)', () {
    // A real Fog-of-World Sync.zip is machine-local (not committed) — point
    // FOW_SYNC_ZIP at a copy to exercise this case; otherwise it skips.
    final zipFile = File(Platform.environment['FOW_SYNC_ZIP'] ??
        '/tmp/claude-1000/-home-xyz-Projects-priv/'
            '173af09c-41fe-4c28-b5dd-85f5957d2af9/scratchpad/fow/Sync.zip');

    test('bakes a real user region cleanly at z8..z14', () async {
      if (!zipFile.existsSync()) {
        markTestSkipped('Sync.zip copy not present — skipping real-data case');
        return;
      }
      final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
      // Largest tile file = densest region.
      ArchiveFile? best;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        if (best == null || f.size > best.size) best = f;
      }
      expect(best, isNotNull);
      final name = best!.name.split('/').last;
      final fow = parseFowTile(name, best.content as Uint8List);

      final rows = <FogTile>[
        for (final b in fow.blocks)
          FogTile(
            tileX: fow.tileX * 128 + b.bx,
            tileY: fow.tileY * 128 + b.by,
            zoom: FogEngine.tileZoom,
            layerId: 1,
            bitmap: b.bitmap,
            updatedAt: DateTime(2026, 1, 1),
          ),
      ];
      expect(rows, isNotEmpty);

      // Centre of the data, in global fog px.
      var sx = 0, sy = 0;
      for (final r in rows) {
        sx += r.tileX;
        sy += r.tileY;
      }
      final cgx = (sx / rows.length * 64).round();
      final cgy = (sy / rows.length * 64).round();

      final snap = snapshotWith(rows);
      for (final z in [8, 10, 12, 14]) {
        final ppt = FogEngine.full >> z;
        final tx = cgx ~/ ppt, ty = cgy ~/ ppt;
        final img = await bakeFogTileForTest(snap, tx, ty, z, dim);
        final d = await rgbaOf(img);
        // The region must show SOME revealed px and SOME fog px — i.e. real
        // corridors render, and dilation didn't wash the whole tile clear.
        var clear = 0, fog = 0;
        for (var y = 0; y < dim; y += 2) {
          for (var x = 0; x < dim; x += 2) {
            final a = alphaAt(d, x, y, dim);
            if (a < veilA ~/ 2) {
              clear++;
            } else {
              fog++;
            }
          }
        }
        expect(clear, greaterThan(20),
            reason: 'z$z: real corridors must be visible');
        expect(fog, greaterThan(500),
            reason: 'z$z: fog must survive around the corridors');
        await dumpPng(img, 'real_fow_z$z.png');
      }
    });
  });
}
