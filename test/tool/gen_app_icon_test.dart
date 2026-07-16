// Generates the pixel-art launcher icon into build/app_icon/.
//
// Not a behavioural test — it lives under test/ because rendering needs
// dart:ui (flutter_tester). Run:
//   flutter test test/tool/gen_app_icon_test.dart
// then copy the PNGs into android/app/src/main/res/ (see README block at
// the bottom). Design language matches lib/ui/common/pixel.dart: hard pixel
// grid, app teal palette, map + trail + pin + fog motif.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

// 24×24 pixel-art motif: folded paper map, orange走过的 trail, red pin at
// the trail head, teal fog rolling over the lower-left corner — 未探索的部分
// 还盖着雾, the app's whole premise in one glyph.
const _motif = [
  '........................',
  '........................',
  '...kkkkkkkkkkkkkkkkkk...',
  '..kwwwwwgwwwwwwgwwwwwk..',
  '..kwwwwwgwwwwwwgwwrwwk..',
  '..kwwwwwgwwwwwwgwrrrwk..',
  '..kwwwwwgwwwwwwgwrerwk..',
  '..kwwwwwgwwwwwwgwwrwwk..',
  '..kwwwwwgwwwwwwgwwowwk..',
  '..kwwwwwgwwwwwwgwowwwk..',
  '..kwwwwwgwwwwwoogwwwwk..',
  '..kwwwwwgwwwoowwgwwwwk..',
  '..kwwwwwgwoowwwwgwwwwk..',
  '..kwwwwwgoowwwwwgwwwwk..',
  '..kwwwwoowwwwwwwgwwwwk..',
  '..kwftwoowwwwwwwgwwwwk..',
  '..kftttfwwwwwwwwgwwwwk..',
  '..kttttttfwwwwwwgwwwwk..',
  '...ktttttttkkkkkkkkkk...',
  '....ftttttttf...........',
  '.....tttttt.............',
  '......fttf..............',
  '........................',
  '........................',
];

const _palette = <String, Color>{
  'k': Color(0xFF10231F), // outline
  'w': Color(0xFFF4FAF7), // paper
  'g': Color(0xFFCFE4DC), // fold shading
  'o': Color(0xFFFF8A50), // trail
  'r': Color(0xFFEF5350), // pin
  'e': Color(0xFFB23430), // pin core
  't': Color(0xFF26A69A), // fog
  'f': Color(0xFF7FD4C9), // fog highlight
};

const _night = Color(0xFF0F1E28); // icon background

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> save(ui.Image img, String name) async {
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('build/app_icon/$name');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(png!.buffer.asUint8List());
  }

  /// Paint the motif into [size]², scaled so the 24-cell grid spans
  /// [motifFrac] of the canvas, centred. Integer cell size keeps pixels hard.
  void paintMotif(ui.Canvas c, int size, double motifFrac) {
    final cell = (size * motifFrac / 24).floorToDouble();
    final span = cell * 24;
    final off = ((size - span) / 2).floorToDouble();
    final p = ui.Paint()..isAntiAlias = false;
    for (var y = 0; y < 24; y++) {
      final row = _motif[y];
      for (var x = 0; x < 24; x++) {
        final col = _palette[row[x]];
        if (col == null) continue;
        p.color = col;
        c.drawRect(
            ui.Rect.fromLTWH(off + x * cell, off + y * cell, cell, cell), p);
      }
    }
  }

  Future<ui.Image> render(int size,
      {required bool background, required double motifFrac}) async {
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    if (background) {
      final s = size.toDouble();
      c.drawRRect(
        ui.RRect.fromRectAndRadius(
            ui.Rect.fromLTWH(0, 0, s, s), ui.Radius.circular(s * 0.16)),
        ui.Paint()..color = _night,
      );
      // Subtle pixel dither in the corners — same Bayer vibe as the app.
      final d = ui.Paint()..color = const Color(0xFF16303C);
      final q = s / 24;
      for (final (x, y) in [(2, 2), (4, 3), (3, 5), (20, 19), (19, 21), (21, 20)]) {
        c.drawRect(ui.Rect.fromLTWH(x * q, y * q, q, q), d);
      }
    }
    paintMotif(c, size, motifFrac);
    return rec.endRecording().toImage(size, size);
  }

  test('generate launcher icon PNG set', () async {
    // Legacy square launcher icons (rounded-rect bg baked in).
    for (final (dir, px) in [
      ('mipmap-mdpi', 48),
      ('mipmap-hdpi', 72),
      ('mipmap-xhdpi', 96),
      ('mipmap-xxhdpi', 144),
      ('mipmap-xxxhdpi', 192),
    ]) {
      final img = await render(px, background: true, motifFrac: 0.86);
      await save(img, 'legacy/$dir/ic_launcher.png');
    }

    // Adaptive icon layers (108dp canvas, motif inside the ~66% safe zone).
    // The foreground carries the full night backdrop itself — some launchers
    // (MIUI) ignore/replace the background layer with white, which made the
    // icon look like a small sticker on a white tile.
    for (final (dir, px) in [
      ('mipmap-mdpi', 108),
      ('mipmap-hdpi', 162),
      ('mipmap-xhdpi', 216),
      ('mipmap-xxhdpi', 324),
      ('mipmap-xxxhdpi', 432),
    ]) {
      final recF = ui.PictureRecorder();
      final cF = ui.Canvas(recF);
      final sF = px.toDouble();
      cF.drawRect(ui.Rect.fromLTWH(0, 0, sF, sF), ui.Paint()..color = _night);
      paintMotif(cF, px, 0.62);
      final fg = await recF.endRecording().toImage(px, px);
      await save(fg, 'adaptive/$dir/ic_launcher_foreground.png');
      // Solid night background with the dither, full-bleed square.
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec);
      final s = px.toDouble();
      c.drawRect(ui.Rect.fromLTWH(0, 0, s, s), ui.Paint()..color = _night);
      final d = ui.Paint()..color = const Color(0xFF16303C);
      final q = s / 24;
      for (final (x, y) in [(2, 2), (4, 3), (3, 5), (20, 19), (19, 21), (21, 20), (18, 4), (5, 18)]) {
        c.drawRect(ui.Rect.fromLTWH(x * q, y * q, q, q), d);
      }
      final bg = await rec.endRecording().toImage(px, px);
      await save(bg, 'adaptive/$dir/ic_launcher_background.png');
    }

    // Big preview for eyeballing.
    final preview = await render(384, background: true, motifFrac: 0.86);
    await save(preview, 'preview_384.png');
    expect(File('build/app_icon/preview_384.png').existsSync(), isTrue);
  });
}
