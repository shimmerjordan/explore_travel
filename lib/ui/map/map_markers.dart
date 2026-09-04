// 从 map_screen.dart 拆出（纯搬迁，无行为改动）。
// 地图上的自身位置标记：定位点、精度圈与朝向箭头。
part of 'map_screen.dart';
// ─── UI components ───

class _LocationDot extends StatelessWidget {
  final bool simulated;

  /// Degrees clockwise from north. Null → plain dot, no arrow.
  final double? heading;
  const _LocationDot({this.simulated = false, this.heading});

  @override
  Widget build(BuildContext context) {
    final color = simulated ? Colors.deepPurple : const Color(0xFF26A69A);
    return Stack(
      alignment: Alignment.center,
      children: [
        // Translucent precision halo.
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
        ),
        // Heading arrow — small triangle pointing in motion direction.
        // Sits outside the dot so it's visible against any background.
        if (heading != null)
          Transform.rotate(
            angle: heading! * math.pi / 180,
            // Translate the arrow above center BEFORE rotation so it
            // orbits the dot in the heading direction.
            child: Transform.translate(
              offset: const Offset(0, -16),
              child: CustomPaint(
                size: const Size(14, 10),
                painter: _ArrowPainter(color: color),
              ),
            ),
          ),
        // Solid inner dot.
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 4,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  _ArrowPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = ui.Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width / 2, size.height * 0.7)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
    final outline = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(path, outline);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) => old.color != color;
}
