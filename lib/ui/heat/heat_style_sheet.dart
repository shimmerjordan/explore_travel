import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/prefs.dart';
import '../../services/heat/heat_palette.dart';

/// (from, to) of the heat map's time window for the current settings, or
/// (null, null) for "everything".
(DateTime?, DateTime?) heatTimeWindow(AppSettings s) {
  final now = DateTime.now();
  switch (s.heatRange) {
    case 1:
      return (DateTime(now.year), null);
    case 2:
      return (now.subtract(const Duration(days: 30)), null);
    case 3:
      return (
        s.heatRangeFromMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(s.heatRangeFromMs)
            : null,
        s.heatRangeToMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(s.heatRangeToMs)
            : null,
      );
    default:
      return (null, null);
  }
}

/// Heat-map style sheet — the two continuous knobs 人生点点 exposes
/// (粗细 / 曝光) plus the palette row, the time window and the 3D height.
/// Edits apply live: the tiles re-bake in place behind the sheet.
Future<void> showHeatStyleSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      backgroundColor: const Color(0xFF1A2733),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (_) => const SafeArea(child: _HeatStyleBody()),
    );

class _HeatStyleBody extends ConsumerWidget {
  const _HeatStyleBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    void upd(AppSettings Function(AppSettings) f) =>
        ref.read(settingsProvider.notifier).update(f);
    const labelStyle = TextStyle(color: Colors.white70, fontSize: 12);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.local_fire_department_rounded,
                  color: Colors.white70, size: 18),
              SizedBox(width: 8),
              Text('热图样式',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              Spacer(),
              Text('点地图上的火焰进入 3D',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 14),
          const Text('颜色', style: labelStyle),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 0; i < HeatPalette.all.length; i++) ...[
                Expanded(
                  child: _PaletteSwatch(
                    palette: HeatPalette.all[i],
                    selected: s.heatPalette == i,
                    onTap: () => upd((p) => p.copyWith(heatPalette: i)),
                  ),
                ),
                if (i != HeatPalette.all.length - 1) const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 10),
          _Knob(
            label: '曝光',
            value: s.heatExposure,
            min: 0.3,
            max: 3.0,
            format: (v) => '${v.toStringAsFixed(1)}×',
            onChanged: (v) => upd((p) => p.copyWith(heatExposure: v)),
          ),
          _Knob(
            label: '粗细',
            value: s.heatWidth,
            min: 0.5,
            max: 3.0,
            format: (v) => '${v.toStringAsFixed(1)}×',
            onChanged: (v) => upd((p) => p.copyWith(heatWidth: v)),
          ),
          _Knob(
            label: '3D 高度',
            value: s.heatHeight,
            min: 0.3,
            max: 2.0,
            format: (v) => '${v.toStringAsFixed(1)}×',
            onChanged: (v) => upd((p) => p.copyWith(heatHeight: v)),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Text('时间范围', style: labelStyle),
              const Spacer(),
              SegmentedButton<int>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 8))),
                segments: const [
                  ButtonSegment(value: 0, label: Text('全部')),
                  ButtonSegment(value: 1, label: Text('今年')),
                  ButtonSegment(value: 2, label: Text('30 天')),
                  ButtonSegment(value: 3, label: Text('自定义')),
                ],
                selected: {s.heatRange},
                onSelectionChanged: (v) async {
                  final r = v.first;
                  if (r != 3) {
                    upd((p) => p.copyWith(heatRange: r));
                    return;
                  }
                  final now = DateTime.now();
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2000),
                    lastDate: now,
                    initialDateRange: s.heatRangeFromMs > 0
                        ? DateTimeRange(
                            start: DateTime.fromMillisecondsSinceEpoch(
                                s.heatRangeFromMs),
                            end: s.heatRangeToMs > 0
                                ? DateTime.fromMillisecondsSinceEpoch(
                                    s.heatRangeToMs)
                                : now,
                          )
                        : null,
                  );
                  if (picked == null) return;
                  upd((p) => p.copyWith(
                        heatRange: 3,
                        heatRangeFromMs: picked.start.millisecondsSinceEpoch,
                        // Inclusive end of day.
                        heatRangeToMs: picked.end
                            .add(const Duration(days: 1))
                            .subtract(const Duration(milliseconds: 1))
                            .millisecondsSinceEpoch,
                      ));
                },
              ),
            ],
          ),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('迷雾区域作底噪', style: labelStyle),
            subtitle: const Text('没有轨迹点的已探索区域（如导入的世界迷雾）也带一点热度',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
            value: s.heatFogBaseline,
            onChanged: (v) => upd((p) => p.copyWith(heatFogBaseline: v)),
          ),
        ],
      ),
    );
  }
}

class _PaletteSwatch extends StatelessWidget {
  final HeatPalette palette;
  final bool selected;
  final VoidCallback onTap;
  const _PaletteSwatch(
      {required this.palette, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 22,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                gradient: LinearGradient(colors: palette.stops),
                border: Border.all(
                  color: selected ? Colors.white : Colors.white24,
                  width: selected ? 2 : 1,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(palette.name,
                style: TextStyle(
                    color: selected ? Colors.white : Colors.white54,
                    fontSize: 11,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w400)),
          ],
        ),
      );
}

class _Knob extends StatelessWidget {
  final String label;
  final double value, min, max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  const _Knob({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(
              width: 56,
              child: Text(label,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12))),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
              width: 40,
              child: Text(format(value),
                  textAlign: TextAlign.right,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12))),
        ],
      );
}
