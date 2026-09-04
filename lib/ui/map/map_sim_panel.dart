// 从 map_screen.dart 拆出（纯搬迁，无行为改动）。
// 模拟行走控制面板（仅调试模式可见）。
part of 'map_screen.dart';

// ─── Simulation control panel (debug only) ───

class _SimPanel extends StatelessWidget {
  final double bearing;
  final bool walking;
  final VoidCallback onStep;
  final ValueChanged<double> onBearingChanged;
  final VoidCallback onToggleWalk;
  final VoidCallback onStop;

  const _SimPanel({
    required this.bearing,
    required this.walking,
    required this.onStep,
    required this.onBearingChanged,
    required this.onToggleWalk,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: MapChrome.simulated.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('SIM',
              style: TextStyle(
                  color: MapChrome.onChromeMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2)),
          const SizedBox(height: 4),
          // Direction pad
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dirBtn(Icons.north_west, 315),
              _dirBtn(Icons.north, 0),
              _dirBtn(Icons.north_east, 45),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dirBtn(Icons.west, 270),
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: Icon(
                    walking ? Icons.pause : Icons.play_arrow,
                    color: walking ? Colors.amber : Colors.white,
                  ),
                  onPressed: onToggleWalk,
                ),
              ),
              _dirBtn(Icons.east, 90),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dirBtn(Icons.south_west, 225),
              _dirBtn(Icons.south, 180),
              _dirBtn(Icons.south_east, 135),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 24,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onStop,
              child: const Text('关闭',
                  style: TextStyle(color: MapChrome.onChromeMuted, fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dirBtn(IconData icon, double dir) {
    final active = (bearing - dir).abs() < 1 || (bearing - dir + 360).abs() < 1;
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: Icon(icon, color: active ? Colors.amber : Colors.white70),
        onPressed: () {
          onBearingChanged(dir);
          onStep();
        },
      ),
    );
  }
}
