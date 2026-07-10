import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A restrained atmospheric layer: slow-drifting soft "fog" blooms plus a
/// sparse field of light motes. Built for this app's Fog-of-World metaphor —
/// the drifting haze reinforces "clearing the fog", it isn't decoration for
/// its own sake.
///
/// Design intent (premium, not cheap):
/// - **Slow.** Cheap particle effects are fast and jittery; everything here
///   loops over ~2 minutes on integer cycles so it never visibly repeats.
/// - **Low contrast.** Blooms/motes sit at low alpha behind content, so text
///   contrast is never harmed (a11y).
/// - **Interactive.** Drag/hover parts the motes away from the pointer, then
///   they ease back — "wave your hand through the fog".
/// - **Reduced-motion aware.** With the system "remove animations" setting on,
///   it renders one still (still-pretty) frame and disables interaction.
///
/// Place it inside a clipped, bounded box (e.g. `Positioned.fill`) behind
/// content.
///
/// Two render styles:
/// - [AtmosphereStyle.soft]: the original soft blooms + round motes.
/// - [AtmosphereStyle.pixel]: 8-bit weather — drifting pixel clouds and
///   square motes snapped to a coarse grid with stepped, game-like motion.
///   Same restraint rules apply (slow, low alpha, reduced-motion aware).
enum AtmosphereStyle { soft, pixel }

class Atmosphere extends StatefulWidget {
  /// Overall opacity multiplier (0..1). Lower it on busy/bright surfaces.
  final double intensity;

  /// Pointer parts the motes when true.
  final bool interactive;

  /// Base color of fog + motes (usually white on a colored surface).
  final Color color;

  /// Faint secondary tint mixed into some elements for depth.
  final Color accent;

  /// Render style. Pixel is the app's signature look.
  final AtmosphereStyle style;

  const Atmosphere({
    super.key,
    this.intensity = 1,
    this.interactive = true,
    this.color = Colors.white,
    this.accent = const Color(0xFF4DD0E1),
    this.style = AtmosphereStyle.pixel,
  });

  @override
  State<Atmosphere> createState() => _AtmosphereState();
}

class _AtmosphereState extends State<Atmosphere> with TickerProviderStateMixin {
  // One full loop of the drift. All motion is expressed in integer cycles of
  // this loop so value wrapping 1→0 is seamless (no visible jump).
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 120),
  );
  // Eases pointer influence in on touch, out on release.
  late final AnimationController _influence = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  final List<_Mote> _motes = [];
  Offset? _pointer; // normalized 0..1

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(7);
    const pick = _pick;
    for (var i = 0; i < 34; i++) {
      final depth = 0.3 + rnd.nextDouble() * 0.7; // 0.3..1 (parallax + size)
      _motes.add(_Mote(
        base: Offset(rnd.nextDouble(), rnd.nextDouble()),
        // integer laps across the loop → seamless wrap. Gentle upward bias.
        kx: pick(rnd, const [-2, -1, 1, 1, 2]).toDouble(),
        ky: pick(rnd, const [-2, -1, -1, 1]).toDouble(),
        depth: depth,
        size: 0.6 + depth * 1.9,
        baseAlpha: 0.12 + depth * 0.30,
        twinkleCycles: pick(rnd, const [1, 2, 3]).toDouble(),
        phase: rnd.nextDouble() * math.pi * 2,
        tintMix: rnd.nextDouble() < 0.35 ? rnd.nextDouble() * 0.6 : 0.0,
      ));
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    _influence.dispose();
    super.dispose();
  }

  void _setPointer(Offset local) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final s = box.size;
    if (s.width <= 0 || s.height <= 0) return;
    // No setState: the drift controller already repaints every frame, so the
    // painter picks this up next tick without an extra rebuild.
    _pointer = Offset(local.dx / s.width, local.dy / s.height);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    // Drive (or freeze) the drift based on the reduced-motion setting.
    if (reduceMotion) {
      if (_drift.isAnimating) _drift.stop();
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }

    final paint = RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([_drift, _influence]),
        builder: (_, __) => CustomPaint(
          isComplex: true,
          willChange: !reduceMotion,
          painter: _AtmospherePainter(
            p: reduceMotion ? 0.16 : _drift.value,
            motes: _motes,
            pointer: reduceMotion ? null : _pointer,
            influence: reduceMotion ? 0 : _influence.value,
            intensity: widget.intensity,
            color: widget.color,
            accent: widget.accent,
            pixel: widget.style == AtmosphereStyle.pixel,
          ),
        ),
      ),
    );

    if (!widget.interactive || reduceMotion) return paint;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (e) {
        _setPointer(e.localPosition);
        if (_influence.value < 1) _influence.forward();
      },
      onPointerDown: (e) {
        _setPointer(e.localPosition);
        _influence.forward();
      },
      onPointerMove: (e) => _setPointer(e.localPosition),
      onPointerUp: (_) => _influence.reverse(),
      onPointerCancel: (_) => _influence.reverse(),
      child: paint,
    );
  }
}

int _pick(math.Random r, List<int> xs) => xs[r.nextInt(xs.length)];

class _Mote {
  final Offset base;
  final double kx, ky; // integer laps over the loop
  final double depth; // 0.3..1 → parallax + size
  final double size;
  final double baseAlpha;
  final double twinkleCycles; // integer
  final double phase;
  final double tintMix; // 0 = base color, →1 = accent
  const _Mote({
    required this.base,
    required this.kx,
    required this.ky,
    required this.depth,
    required this.size,
    required this.baseAlpha,
    required this.twinkleCycles,
    required this.phase,
    required this.tintMix,
  });
}

class _Bloom {
  final double ampX, ampY, cX, cY, phX, phY, rFactor, alpha, tintMix;
  const _Bloom(this.ampX, this.ampY, this.cX, this.cY, this.phX, this.phY,
      this.rFactor, this.alpha, this.tintMix);
}

const _blooms = <_Bloom>[
  _Bloom(0.22, 0.16, 1, 2, 0.0, 1.1, 0.72, 0.11, 0.0),
  _Bloom(0.18, 0.22, 2, 1, 2.3, 0.4, 0.56, 0.09, 0.5),
  _Bloom(0.26, 0.13, 1, 1, 4.0, 3.2, 0.62, 0.08, 0.0),
];

/// Pixel cloud masks — '#' = cell, 'o' = cell at half alpha. Hand-drawn
/// 8-bit cumulus in three sizes so the sky doesn't repeat.
const _pixelClouds = <List<String>>[
  [
    '....oo####oo....',
    '..o##########o..',
    '.o############o.',
    'o##############o',
    '.oo##########oo.',
  ],
  [
    '...o####o...',
    '.o########o.',
    'o##########o',
    '.oo######oo.',
  ],
  [
    '..o##o..',
    'o######o',
    '.oo##oo.',
  ],
];

class _AtmospherePainter extends CustomPainter {
  final double p; // loop position 0..1
  final List<_Mote> motes;
  final Offset? pointer; // normalized
  final double influence; // 0..1
  final double intensity;
  final Color color;
  final Color accent;
  final bool pixel;

  _AtmospherePainter({
    required this.p,
    required this.motes,
    required this.pointer,
    required this.influence,
    required this.intensity,
    required this.color,
    required this.accent,
    this.pixel = false,
  });

  static const _tau = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    if (pixel) {
      _paintPixel(canvas, size);
      return;
    }

    // ── Soft fog blooms (additive so they read as diffusing light) ──────────
    for (final b in _blooms) {
      final cx = (0.5 + b.ampX * math.sin(_tau * b.cX * p + b.phX)) * w;
      final cy = (0.5 + b.ampY * math.cos(_tau * b.cY * p + b.phY)) * h;
      final center = Offset(cx, cy);
      final r = b.rFactor * w;
      final col = Color.lerp(color, accent, b.tintMix)!;
      final rect = Rect.fromCircle(center: center, radius: r);
      final paint = Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            col.withValues(alpha: b.alpha * intensity),
            col.withValues(alpha: 0),
          ],
          stops: const [0, 1],
        ).createShader(rect);
      canvas.drawCircle(center, r, paint);
    }

    // ── Sparse light motes with parallax + pointer repel ────────────────────
    const repelR = 0.26;
    final motePaint = Paint();
    final glowPaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6);
    for (final m in motes) {
      var mx = (m.base.dx + p * m.kx) % 1.0;
      if (mx < 0) mx += 1;
      var my = (m.base.dy + p * m.ky) % 1.0;
      if (my < 0) my += 1;
      var pos = Offset(mx, my);

      if (pointer != null && influence > 0) {
        final d = pos - pointer!;
        final dist = d.distance;
        if (dist < repelR && dist > 1e-4) {
          final push = (repelR - dist) / repelR * 0.13 * influence * m.depth;
          pos = pos + d / dist * push;
        }
      }

      final tw = 0.55 + 0.45 * math.sin(_tau * m.twinkleCycles * p + m.phase);
      final a = (m.baseAlpha * tw * intensity).clamp(0.0, 1.0);
      if (a <= 0.01) continue;
      final col = Color.lerp(color, accent, m.tintMix)!.withValues(alpha: a);
      final center = Offset(pos.dx * w, pos.dy * h);
      if (m.size > 1.7) {
        canvas.drawCircle(center, m.size, glowPaint..color = col);
      } else {
        canvas.drawCircle(center, m.size, motePaint..color = col);
      }
    }
  }

  /// 8-bit weather: drifting pixel clouds + square motes on a coarse grid.
  /// Motion is quantized (positions snap to the grid, twinkle steps through
  /// 4 levels) so everything moves in ticks, like a sprite sheet — but the
  /// underlying clock is the same slow 120s integer-cycle loop.
  void _paintPixel(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const grid = 3.0; // logical px per "pixel"

    // ── Clouds: each drifts horizontally on integer laps, fixed row ────────
    final cellPaintFull = Paint();
    final cellPaintHalf = Paint();
    for (var c = 0; c < _pixelClouds.length; c++) {
      final mask = _pixelClouds[c];
      // Lap counts 1/2/1 keep the wrap seamless; vertical bands spread out.
      final laps = c == 1 ? 2.0 : 1.0;
      final y0 = (0.14 + c * 0.3) * h;
      var x01 = (0.19 + c * 0.37 + p * laps) % 1.0;
      // Extend range so the cloud fully exits before wrapping.
      final cloudW = mask[0].length * grid;
      final x0 = x01 * (w + cloudW * 2) - cloudW;
      final alpha = (0.05 + c * 0.012) * intensity;
      final col = Color.lerp(color, accent, c == 1 ? 0.4 : 0.0)!;
      cellPaintFull.color = col.withValues(alpha: alpha);
      cellPaintHalf.color = col.withValues(alpha: alpha * 0.5);
      final ox = (x0 / grid).floorToDouble() * grid; // snap to grid
      final oy = (y0 / grid).floorToDouble() * grid;
      for (var yy = 0; yy < mask.length; yy++) {
        final row = mask[yy];
        for (var xx = 0; xx < row.length; xx++) {
          final ch = row[xx];
          if (ch == '.') continue;
          canvas.drawRect(
            Rect.fromLTWH(ox + xx * grid, oy + yy * grid, grid, grid),
            ch == 'o' ? cellPaintHalf : cellPaintFull,
          );
        }
      }
    }

    // ── Square motes: snapped positions, stepped twinkle, pointer repel ────
    const repelR = 0.26;
    final motePaint = Paint();
    for (final m in motes) {
      var mx = (m.base.dx + p * m.kx) % 1.0;
      if (mx < 0) mx += 1;
      var my = (m.base.dy + p * m.ky) % 1.0;
      if (my < 0) my += 1;
      var pos = Offset(mx, my);

      if (pointer != null && influence > 0) {
        final d = pos - pointer!;
        final dist = d.distance;
        if (dist < repelR && dist > 1e-4) {
          final push = (repelR - dist) / repelR * 0.13 * influence * m.depth;
          pos = pos + d / dist * push;
        }
      }

      // Twinkle stepped through 4 alpha levels — blink, not breathe.
      final twRaw = 0.55 + 0.45 * math.sin(_tau * m.twinkleCycles * p + m.phase);
      final tw = (twRaw * 4).floorToDouble() / 4 + 0.25;
      final a = (m.baseAlpha * tw * intensity).clamp(0.0, 1.0);
      if (a <= 0.01) continue;
      final col = Color.lerp(color, accent, m.tintMix)!.withValues(alpha: a);
      // Square size in whole grid cells: depth ≥ .75 → 2×2, else 1×1.
      final cells = m.depth >= 0.75 ? 2 : 1;
      final px = (pos.dx * w / grid).floorToDouble() * grid;
      final py = (pos.dy * h / grid).floorToDouble() * grid;
      motePaint.color = col;
      canvas.drawRect(
          Rect.fromLTWH(px, py, grid * cells, grid * cells), motePaint);
    }
  }

  @override
  bool shouldRepaint(_AtmospherePainter old) =>
      old.p != p ||
      old.pointer != pointer ||
      old.influence != influence ||
      old.intensity != intensity ||
      old.color != color ||
      old.pixel != pixel;
}
