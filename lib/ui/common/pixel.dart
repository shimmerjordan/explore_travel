import 'package:flutter/material.dart';

/// Pixel design language for Explore Journal.
///
/// The app's Fog-of-World metaphor *is* a game mechanic — lighting up map
/// tiles, collecting journeys. The pixel layer leans into that: chunky
/// stepped-corner panels, a CJK pixel face for display moments, block
/// progress bars and dithered fades. It is an accent language, not a
/// replacement for Material: body text, labels and controls stay system
/// (product register: no display fonts in labels), while heroes, big
/// numbers and celebratory moments speak pixel.
///
/// Font: 缝合像素字体 fusion-pixel-font 12px (OFL), registered as `PixelZh`.
/// Render display sizes as multiples of 12 (24/36/48) so glyphs sit on the
/// pixel grid and stay crisp.

// ─── Typography ──────────────────────────────────────────────────────────────

/// Display styles in the pixel face. Use ONLY for hero/display moments:
/// big numbers, page heroes, celebration copy. Never for body/labels.
abstract final class PixelText {
  static const String family = 'PixelZh';

  /// Big hero number / page hero. 36px = 3× the 12px pixel grid.
  static const TextStyle display = TextStyle(
    fontFamily: family,
    fontSize: 36,
    height: 1.15,
    letterSpacing: 0,
  );

  /// Section hero / medium stat. 24px = 2× grid.
  static const TextStyle headline = TextStyle(
    fontFamily: family,
    fontSize: 24,
    height: 1.2,
    letterSpacing: 0,
  );

  /// Small accent (badge text, tile values). 12px native grid — the
  /// smallest size that stays crisp; do not go below.
  static const TextStyle label = TextStyle(
    fontFamily: family,
    fontSize: 12,
    height: 1.3,
    letterSpacing: 0,
  );
}

// ─── Stepped-corner panel ────────────────────────────────────────────────────

/// A path with pixel "stepped" corners — the classic 8-bit panel silhouette.
/// [step] is the size of one stair; [steps] how many stairs per corner
/// (2 steps ≈ a chamfered pixel round).
Path pixelPanelPath(Size size, {double step = 3, int steps = 2}) {
  final w = size.width, h = size.height;
  final s = step;
  final n = steps;
  final path = Path();
  // Start at top-left after the corner, going clockwise.
  path.moveTo(s * n, 0);
  path.lineTo(w - s * n, 0);
  for (var i = 1; i <= n; i++) {
    path.lineTo(w - s * (n - i), s * (i - 1));
    path.lineTo(w - s * (n - i), s * i);
  }
  path.lineTo(w, h - s * n);
  for (var i = 1; i <= n; i++) {
    path.lineTo(w - s * (i - 1), h - s * (n - i));
    path.lineTo(w - s * i, h - s * (n - i));
  }
  path.lineTo(s * n, h);
  for (var i = 1; i <= n; i++) {
    path.lineTo(s * (n - i), h - s * (i - 1));
    path.lineTo(s * (n - i), h - s * i);
  }
  path.lineTo(0, s * n);
  for (var i = 1; i <= n; i++) {
    path.lineTo(s * (i - 1), s * (n - i));
    path.lineTo(s * i, s * (n - i));
  }
  path.close();
  return path;
}

class _PixelPanelPainter extends CustomPainter {
  final Color fill;
  final Color? border;
  final double borderWidth;
  final double step;
  final int steps;
  const _PixelPanelPainter({
    required this.fill,
    this.border,
    this.borderWidth = 2,
    this.step = 3,
    this.steps = 2,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = pixelPanelPath(size, step: step, steps: steps);
    canvas.drawPath(path, Paint()..color = fill);
    if (border != null) {
      canvas.drawPath(
        path,
        Paint()
          ..color = border!
          ..style = PaintingStyle.stroke
          ..strokeWidth = borderWidth
          ..strokeJoin = StrokeJoin.miter,
      );
    }
  }

  @override
  bool shouldRepaint(_PixelPanelPainter old) =>
      old.fill != fill ||
      old.border != border ||
      old.borderWidth != borderWidth ||
      old.step != step ||
      old.steps != steps;
}

class _PixelPanelClipper extends CustomClipper<Path> {
  final double step;
  final int steps;
  const _PixelPanelClipper({required this.step, required this.steps});
  @override
  Path getClip(Size size) => pixelPanelPath(size, step: step, steps: steps);
  @override
  bool shouldReclip(_PixelPanelClipper old) =>
      old.step != step || old.steps != steps;
}

/// A panel with stepped pixel corners. The pixel replacement for a
/// rounded-corner Material surface: same tonal role colors, 8-bit silhouette.
class PixelPanel extends StatelessWidget {
  final Widget child;
  final Color color;
  final Color? borderColor;
  final double borderWidth;
  final EdgeInsetsGeometry padding;
  final double step;
  final int steps;

  /// Clip [child] to the stepped silhouette (needed when the child paints
  /// to the edges, e.g. an image or map).
  final bool clipChild;

  const PixelPanel({
    super.key,
    required this.child,
    required this.color,
    this.borderColor,
    this.borderWidth = 2,
    this.padding = EdgeInsets.zero,
    this.step = 3,
    this.steps = 2,
    this.clipChild = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget inner = Padding(padding: padding, child: child);
    if (clipChild) {
      inner = ClipPath(
        clipper: _PixelPanelClipper(step: step, steps: steps),
        child: inner,
      );
    }
    return CustomPaint(
      painter: _PixelPanelPainter(
        fill: color,
        border: borderColor,
        borderWidth: borderWidth,
        step: step,
        steps: steps,
      ),
      child: inner,
    );
  }
}

// ─── Block progress bar ──────────────────────────────────────────────────────

/// Progress as discrete blocks — the 8-bit health-bar read. Filled cells in
/// [color], empty cells as faint outlines. Meaning stays: n of m collected.
class PixelBlockBar extends StatelessWidget {
  final double value; // 0..1
  final int cells;
  final double cellHeight;
  final Color color;
  final Color emptyColor;
  const PixelBlockBar({
    super.key,
    required this.value,
    required this.color,
    required this.emptyColor,
    this.cells = 20,
    this.cellHeight = 8,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: cellHeight,
      child: CustomPaint(
        painter: _BlockBarPainter(
          value: value.clamp(0.0, 1.0),
          cells: cells,
          color: color,
          emptyColor: emptyColor,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _BlockBarPainter extends CustomPainter {
  final double value;
  final int cells;
  final Color color;
  final Color emptyColor;
  const _BlockBarPainter({
    required this.value,
    required this.cells,
    required this.color,
    required this.emptyColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    const gap = 2.0;
    final cellW = (size.width - gap * (cells - 1)) / cells;
    if (cellW <= 0) return;
    final filled = (value * cells);
    final fillPaint = Paint()..color = color;
    final emptyPaint = Paint()..color = emptyColor;
    for (var i = 0; i < cells; i++) {
      final r = Rect.fromLTWH(i * (cellW + gap), 0, cellW, size.height);
      if (i + 1 <= filled) {
        canvas.drawRect(r, fillPaint);
      } else if (i < filled) {
        // Partial cell: fill the fraction, keep the rest as empty tint.
        canvas.drawRect(r, emptyPaint);
        canvas.drawRect(
          Rect.fromLTWH(r.left, 0, cellW * (filled - i), size.height),
          fillPaint,
        );
      } else {
        canvas.drawRect(r, emptyPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_BlockBarPainter old) =>
      old.value != value ||
      old.cells != cells ||
      old.color != color ||
      old.emptyColor != emptyColor;
}

// ─── Dither fade ─────────────────────────────────────────────────────────────

/// A vertical Bayer-dither fade band: solid [color] at the bottom fading to
/// transparent at the top through a 4×4 ordered-dither pattern. The pixel
/// answer to a gradient scrim (e.g. over hero imagery so text stays legible).
class PixelDitherFade extends StatelessWidget {
  final Color color;
  final double cell; // dither cell size in logical px
  const PixelDitherFade({super.key, required this.color, this.cell = 3});

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: the dither field is thousands of tiny rects — cache
    // it as a layer so scrolling translates instead of repainting.
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _DitherFadePainter(color: color, cell: cell),
          size: Size.infinite,
        ),
      ),
    );
  }
}

// 4×4 Bayer matrix, thresholds 0..15.
const _bayer4 = [
  [0, 8, 2, 10],
  [12, 4, 14, 6],
  [3, 11, 1, 9],
  [15, 7, 13, 5],
];

class _DitherFadePainter extends CustomPainter {
  final Color color;
  final double cell;
  const _DitherFadePainter({required this.color, required this.cell});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final cols = (size.width / cell).ceil();
    final rows = (size.height / cell).ceil();
    final paint = Paint()..color = color;
    for (var y = 0; y < rows; y++) {
      // 0 at top → 1 at bottom.
      final t = rows <= 1 ? 1.0 : y / (rows - 1);
      final level = t * 16;
      for (var x = 0; x < cols; x++) {
        if (_bayer4[y % 4][x % 4] < level) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell, cell),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_DitherFadePainter old) =>
      old.color != color || old.cell != cell;
}

// ─── Pixel sprite icon ───────────────────────────────────────────────────────

/// Draws a tiny pixel sprite from a string map ('.' empty, any other char =
/// a cell; '#' base color, '+' accent, 'o' base at half alpha). Crisp at any
/// scale because every cell is an integer square.
class PixelSprite extends StatelessWidget {
  final List<String> rows;
  final Color color;
  final Color? accent;
  final double cell;
  const PixelSprite({
    super.key,
    required this.rows,
    required this.color,
    this.accent,
    this.cell = 3,
  });

  @override
  Widget build(BuildContext context) {
    final w = rows.isEmpty ? 0.0 : rows[0].length * cell;
    final h = rows.length * cell;
    return SizedBox(
      width: w,
      height: h,
      child: CustomPaint(
        painter: _SpritePainter(
          rows: rows,
          color: color,
          accent: accent ?? color,
          cell: cell,
        ),
      ),
    );
  }
}

class _SpritePainter extends CustomPainter {
  final List<String> rows;
  final Color color;
  final Color accent;
  final double cell;
  const _SpritePainter({
    required this.rows,
    required this.color,
    required this.accent,
    required this.cell,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()..color = color;
    final acc = Paint()..color = accent;
    final half = Paint()..color = color.withValues(alpha: 0.5);
    for (var y = 0; y < rows.length; y++) {
      final row = rows[y];
      for (var x = 0; x < row.length; x++) {
        final ch = row[x];
        if (ch == '.') continue;
        final p = switch (ch) { '+' => acc, 'o' => half, _ => base };
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), p);
      }
    }
  }

  @override
  bool shouldRepaint(_SpritePainter old) =>
      old.rows != rows ||
      old.color != color ||
      old.accent != accent ||
      old.cell != cell;
}

/// Shared sprites — small, on-brand pictograms for empty states and heroes.
abstract final class PixelSprites {
  /// A little map with a lit tile (the core loop: light up the map).
  static const map = [
    '..........',
    '.########.',
    '.#..++..#.',
    '.#.++++.#.',
    '.#..++..#.',
    '.#......#.',
    '.########.',
    '..........',
  ];

  /// Open journal / book.
  static const book = [
    '..........',
    '.###..###.',
    '.#.#..#.#.',
    '.#.#..#.#.',
    '.#.#..#.#.',
    '.#.#..#.#.',
    '.###..###.',
    '..........',
  ];

  /// Compass diamond.
  static const compass = [
    '....#....',
    '...###...',
    '..##+##..',
    '.##+++##.',
    '..##+##..',
    '...###...',
    '....#....',
  ];

  /// Footprints trail.
  static const steps = [
    '.##......',
    '.##..##..',
    '.....##..',
    '..##.....',
    '..##..##.',
    '......##.',
  ];

  /// Music note.
  static const note = [
    '...####.',
    '...#..#.',
    '...#..#.',
    '...#....',
    '.###....',
    '.###....',
  ];

  /// Cloud (sync/backup).
  static const cloud = [
    '...####...',
    '..######..',
    '.########.',
    '##########',
    '.########.',
  ];
}
