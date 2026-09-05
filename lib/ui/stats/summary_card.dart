/// 旅程 / 年度总结卡：把一段时间的足迹渲成一张可分享的竖图。
///
/// 卡片本身是普通 widget，按固定的 9:16 逻辑尺寸布局，再由 [SummaryCardScreen]
/// 用屏上的 `RepaintBoundary` 抓成 1080 宽的 PNG——与回放页导出视频完全同一套
/// 机制（那条路已经真机验证过）。**不离屏挂载**：预览页让用户先看到要发的图，
/// 也顺带避开了离屏渲染那些"没有 layout 就 toImage"的坑。
///
/// 形状来自**这段范围内的轨迹点**，不是迷雾位图：`fog_tiles` 只有块级
/// `updatedAt`，取不出"某年点亮的那部分"。轨迹点带精确时间，与卡片上的里程、
/// 天数同源。整段历史都是 FOW 位图导入的用户没有轨迹点，那时不画形状。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/stats/footprint_stats.dart' show formatKm;
import '../../services/stats/summary_card_data.dart';
import '../common/pixel.dart';

/// 卡片的逻辑尺寸。9:16，抓图时按 1080 宽换算 pixelRatio。
const Size kSummaryCardSize = Size(360, 640);

class SummaryCard extends StatelessWidget {
  final SummaryCardData data;
  const SummaryCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    // 卡片是要发出去的图，不跟随用户当前主题——发出去的东西应当长得一样。
    // 用品牌的夜色，与应用的暗色面同族。
    const bg = Color(0xFF14212C);
    const ink = Color(0xFFDDE4E2);
    const muted = Color(0xFF8FA3AD);
    const brand = Color(0xFF26A69A);

    return SizedBox.fromSize(
      size: kSummaryCardSize,
      child: ColoredBox(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(data.range.title,
                  style: PixelText.headline.copyWith(color: ink)),
              const SizedBox(height: 4),
              Text('走过的路', style: TextStyle(fontSize: 11, color: muted)),
              const SizedBox(height: 10),
              if (data.isEmpty)
                _Empty(muted: muted)
              else ...[
                Text(formatKm(data.totalMeters),
                    style: PixelText.display.copyWith(color: brand)),
                const SizedBox(height: 18),
                _Stats(data: data, ink: ink, muted: muted),
                const SizedBox(height: 18),
                // 形状吃掉全部剩余空间。注意下面**不能**再有第二个 flex：
                // 之前页脚前还留着一个 Spacer，两个 flex 平分剩余，结果形状只
                // 拿到一半、页脚上方空出一大片（真机第一版就是这个毛病）。
                Expanded(
                  child: data.hasShape
                      ? _Shape(shape: data.shape, color: brand)
                      : _NoShape(muted: muted),
                ),
                const SizedBox(height: 14),
                _HourStrip(hourly: data.hourly, color: brand, muted: muted),
                if (data.places.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _Places(places: data.places, ink: ink, muted: muted),
                ],
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  const PixelSprite(rows: PixelSprites.map, color: brand, cell: 2),
                  const SizedBox(width: 8),
                  Text('Explore Journal',
                      style: TextStyle(fontSize: 10, color: muted)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final Color muted;
  const _Empty({required this.muted});
  @override
  Widget build(BuildContext context) => Expanded(
        child: Center(
          child: Text('这段时间还没有记录',
              style: TextStyle(fontSize: 13, color: muted)),
        ),
      );
}

class _NoShape extends StatelessWidget {
  final Color muted;
  const _NoShape({required this.muted});
  @override
  Widget build(BuildContext context) => Center(
        // FOW 位图导入的历史没有轨迹点。说清楚，别摆一张空画布。
        child: Text('这段时间的迷雾来自导入，没有轨迹可画',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: muted)),
      );
}

class _Stats extends StatelessWidget {
  final SummaryCardData data;
  final Color ink;
  final Color muted;
  const _Stats({required this.data, required this.ink, required this.muted});

  @override
  Widget build(BuildContext context) {
    Widget cell(String value, String label) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700, color: ink)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 10, color: muted)),
            ],
          ),
        );
    return Row(children: [
      cell('${data.recordedDays}', '有记录的天'),
      cell('${data.longestStreakDays}', '最长连续'),
      cell('${data.countries.length}', '国家 / 地区'),
    ]);
  }
}

/// 走出来的形状。断开的段之间不连线（见 [SummaryShapePoint.connected]）。
class _Shape extends StatelessWidget {
  final List<SummaryShapePoint> shape;
  final Color color;
  const _Shape({required this.shape, required this.color});

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _ShapePainter(shape, color),
        ),
      );
}

class _ShapePainter extends CustomPainter {
  final List<SummaryShapePoint> shape;
  final Color color;
  _ShapePainter(this.shape, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    // 归一化坐标是个正方形，等比放进给定的框里并居中。
    final side = math.min(size.width, size.height);
    final dx = (size.width - side) / 2;
    final dy = (size.height - side) / 2;
    Offset at(SummaryShapePoint p) =>
        Offset(dx + p.x * side, dy + p.y * side);

    // 年度卡里常常是几座城市各一小团：只画线的话，每团都是几像素的发丝，
    // 缩成分享图后基本看不见。所以先在每个顶点点一颗小圆，让稀疏的团也有
    // 视觉重量，再画线把同一段连起来。
    final dot = Paint()..color = color.withValues(alpha: 0.55);
    for (final p in shape) {
      canvas.drawCircle(at(p), 1.1, dot);
    }

    // 先画一层粗而透明的光晕，再画细实线——同一条几何画两遍，是应用里
    // 热图与轨迹一直用的"发光"做法，不用 blur（省一次 saveLayer）。
    for (final pass in [
      (width: 5.0, alpha: 0.22),
      (width: 1.6, alpha: 1.0),
    ]) {
      final paint = Paint()
        ..color = color.withValues(alpha: pass.alpha)
        ..strokeWidth = pass.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      var pen = false;
      for (final p in shape) {
        final o = at(p);
        if (p.connected && pen) {
          path.lineTo(o.dx, o.dy);
        } else {
          path.moveTo(o.dx, o.dy);
          pen = true;
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_ShapePainter old) =>
      old.shape != shape || old.color != color;
}

/// 24 格的作息带：什么时辰在路上。
class _HourStrip extends StatelessWidget {
  final List<double> hourly;
  final Color color;
  final Color muted;
  const _HourStrip(
      {required this.hourly, required this.color, required this.muted});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 26,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final v in hourly)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 0.6),
                      child: FractionallySizedBox(
                        // 有数据的时辰至少留一丝高度，读得出"有 vs 无"。
                        heightFactor: v <= 0 ? 0.06 : (0.14 + v * 0.86),
                        child: ColoredBox(
                          color: color.withValues(alpha: v <= 0 ? 0.14 : 0.85),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final h in ['0', '6', '12', '18', '24'])
                Text(h, style: TextStyle(fontSize: 8, color: muted)),
            ],
          ),
        ],
      );
}

class _Places extends StatelessWidget {
  final List<SummaryPlace> places;
  final Color ink;
  final Color muted;
  const _Places(
      {required this.places, required this.ink, required this.muted});

  String _dwell(int seconds) {
    if (seconds >= 3600) return '${(seconds / 3600).toStringAsFixed(1)} 小时';
    return '${(seconds / 60).round()} 分钟';
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('待得最久', style: TextStyle(fontSize: 10, color: muted)),
          const SizedBox(height: 5),
          for (final pl in places)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: ink)),
                  ),
                  const SizedBox(width: 8),
                  Text(_dwell(pl.dwellSeconds),
                      style: TextStyle(fontSize: 10, color: muted)),
                ],
              ),
            ),
        ],
      );
}
