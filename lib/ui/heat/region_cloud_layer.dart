import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/heat/heat3d_camera.dart';
import '../../services/heat/heat_source.dart';
import '../../services/geo/region_stats.dart';
import '../common/flag_badge.dart';

/// The 区域点云 layer: every ~5 km cell is a lit pin whose height and colour
/// follow how many DAYS it was visited, and every administrative region gets
/// one label sized the same way, with its country's flag.
///
/// Drawing splits in two on purpose: the pins are canvas work (there can be
/// thousands, batched into a handful of `drawRawPoints` calls), while the
/// labels are real widgets — crisp text, tappable, and emoji flags rendered
/// by the system font.

/// Height of the tallest pin as a fraction of the viewport.
const double _kPinTop = 0.14;

/// How many colour/height bands the pins are bucketed into. One draw call
/// each — per-point colours would mean one call per pin.
const int kPinBands = 5;

/// Band index (0 = quietest) for a cell with [days] out of [maxDays].
int pinBand(int days, int maxDays) {
  if (maxDays <= 1) return kPinBands - 1;
  final t = math.log(1 + days) / math.log(1 + maxDays);
  return (t.clamp(0.0, 1.0) * (kPinBands - 1)).round();
}

/// Cool → hot, matching the ridge palette's feel without importing it (the
/// cloud reads as a different mode, not a second heat map).
const List<Color> kPinColors = [
  Color(0xFF2C6E8F),
  Color(0xFF2E9FB5),
  Color(0xFF37C6C0),
  Color(0xFF8BE6C4),
  Color(0xFFF2FFF7),
];

/// Rough text width without laying it out — CJK ≈ 1 em, ASCII ≈ 0.55 em, a
/// flag ≈ 1.35 em. Only feeds the overlap test, so an estimate is fine and
/// keeps label layout off the text-shaping path every frame.
double estimateLabelWidth(String text, double fontSize) {
  var em = 0.0;
  for (final r in text.runes) {
    if (r >= 0x1F1E6 && r <= 0x1F1FF) {
      em += 0.675; // half a flag: they come in pairs
    } else if (r < 0x2000) {
      em += r == 0x20 ? 0.32 : 0.55;
    } else {
      em += 1.0;
    }
  }
  return em * fontSize;
}

/// Greedy label declutter: walk [rects] in the order given (callers pass
/// busiest-first) and keep one only when it clears everything kept so far.
/// Returns the kept indices, in input order.
List<int> declutterIndices(List<Rect> rects, {double pad = 3}) {
  final kept = <int>[];
  final placed = <Rect>[];
  for (var i = 0; i < rects.length; i++) {
    final r = rects[i].inflate(pad);
    var clear = true;
    for (final p in placed) {
      if (r.overlaps(p)) {
        clear = false;
        break;
      }
    }
    if (clear) {
      kept.add(i);
      placed.add(r);
    }
  }
  return kept;
}

/// One label that made it onto the screen.
class PlacedLabel {
  final RegionStat region;
  final Offset anchor; // tip of the pin, in screen px
  final Rect rect;
  final double fontSize;
  const PlacedLabel(this.region, this.anchor, this.rect, this.fontSize);
}

/// Project every region, size its label, and drop the ones that collide.
/// Regions must arrive busiest-first (as [foldRegions] returns them).
List<PlacedLabel> layoutRegionLabels({
  required List<RegionStat> regions,
  required Heat3DCamera cam,
  required int maxDayCount,
  String? homeCountry,
  double viewportPad = 40,
  int limit = 60,
}) {
  final cands = <PlacedLabel>[];
  final rects = <Rect>[];
  final h = cam.viewport.height;
  for (final r in regions) {
    if (cands.length >= limit) break;
    final x01 = HeatIndex.lngToWorldX(r.lng);
    final y01 = HeatIndex.latToWorldY(r.lat);
    final m = cam.worldToModel(x01, y01);
    final w = cam.wAt(m.mx, m.my);
    if (w <= 0.05 || w > Heat3DCamera.farW) continue;
    final size = regionLabelSize(r.dayCount, maxDayCount);
    final tip = cam.project(m.mx, m.my, _pinHeight(r.dayCount, maxDayCount, h));
    if (!tip.dx.isFinite || !tip.dy.isFinite) continue;
    if (tip.dx < -viewportPad ||
        tip.dy < -viewportPad ||
        tip.dx > cam.viewport.width + viewportPad ||
        tip.dy > h + viewportPad) {
      continue;
    }
    final text = '${r.flag} ${r.labelWith(homeCountry: homeCountry)}';
    final wpx = estimateLabelWidth(text, size) + 16;
    final hpx = size * 1.45 + 12;
    // The label sits just above its pin.
    final rect = Rect.fromLTWH(tip.dx - wpx / 2, tip.dy - hpx - 4, wpx, hpx);
    cands.add(PlacedLabel(r, tip, rect, size));
    rects.add(rect);
  }
  final keep = declutterIndices(rects);
  return [for (final i in keep) cands[i]];
}

double _pinHeight(int days, int maxDays, double viewportH) {
  if (maxDays <= 0) return 0;
  final t = math.log(1 + days) / math.log(1 + maxDays);
  return (0.22 + 0.78 * t.clamp(0.0, 1.0)) * _kPinTop * viewportH;
}

/// Paint the pins. Cheap: two batched calls per band (stems, then heads).
void paintRegionCloud(
  Canvas canvas,
  Heat3DCamera cam,
  List<CellAgg> cells,
  int maxDayCount,
) {
  if (cells.isEmpty) return;
  final h = cam.viewport.height;
  final stems = List.generate(kPinBands, (_) => <double>[]);
  final heads = List.generate(kPinBands, (_) => <double>[]);
  for (final c in cells) {
    final x01 = HeatIndex.lngToWorldX(c.lng);
    final y01 = HeatIndex.latToWorldY(c.lat);
    final m = cam.worldToModel(x01, y01);
    final w = cam.wAt(m.mx, m.my);
    if (w <= 0.05 || w > Heat3DCamera.farW) continue;
    final ground = cam.project(m.mx, m.my, 0);
    if (!ground.dx.isFinite || !ground.dy.isFinite) continue;
    if (ground.dx < -80 ||
        ground.dy < -80 ||
        ground.dx > cam.viewport.width + 80 ||
        ground.dy > h + 80) {
      continue;
    }
    final days = c.days.length;
    final tip = cam.project(m.mx, m.my, _pinHeight(days, maxDayCount, h));
    final b = pinBand(days, maxDayCount);
    stems[b]
      ..add(ground.dx)
      ..add(ground.dy)
      ..add(tip.dx)
      ..add(tip.dy);
    heads[b]
      ..add(tip.dx)
      ..add(tip.dy);
  }
  for (var b = 0; b < kPinBands; b++) {
    if (heads[b].isEmpty) continue;
    final color = kPinColors[b];
    canvas.drawRawPoints(
      ui.PointMode.lines,
      Float32List.fromList(stems[b]),
      Paint()
        ..color = color.withValues(alpha: 0.55)
        ..strokeWidth = 1.6
        ..isAntiAlias = true,
    );
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(heads[b]),
      Paint()
        ..color = color
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3.0 + b * 1.4
        ..isAntiAlias = true,
    );
  }
}

/// The label chip drawn over the canvas.
class RegionLabelChip extends StatelessWidget {
  final PlacedLabel placed;
  final VoidCallback? onTap;
  const RegionLabelChip({super.key, required this.placed, this.onTap});

  @override
  Widget build(BuildContext context) {
    final r = placed.region;
    final fs = placed.fontSize;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: fs * 0.18),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(fs * 0.5),
          border: Border.all(color: Colors.white24, width: 0.6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (r.country.isNotEmpty) ...[
              FlagBadge(country: r.country, size: fs * 0.9),
              SizedBox(width: fs * 0.24),
            ],
            Text(
              r.displayName,
              style: TextStyle(
                color: Colors.white,
                fontSize: fs,
                height: 1.1,
                fontWeight: fs > 20 ? FontWeight.w600 : FontWeight.w500,
                shadows: const [
                  Shadow(color: Colors.black87, blurRadius: 4),
                ],
              ),
            ),
            SizedBox(width: fs * 0.45),
            Text(
              '${r.dayCount}天',
              style: TextStyle(
                color: Colors.white70,
                fontSize: math.max(9, fs * 0.52),
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
