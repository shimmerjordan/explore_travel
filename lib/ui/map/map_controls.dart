// 从 map_screen.dart 拆出（纯搬迁，无行为改动）。
// 地图浮层控件：胶囊、圆形按钮、图层选择、信号与指北。
part of 'map_screen.dart';

class _MapChip extends StatelessWidget {
  final IconData icon;
  final String? label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _MapChip(
      {required this.icon, this.label, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: label != null ? 10 : 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: Colors.white),
                if (label != null) ...[
                  const SizedBox(width: 4),
                  Text(label!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapFab extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color? activeColor;
  final VoidCallback onTap;
  const _MapFab({
    required this.icon,
    this.active = false,
    this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Hard-cornered square stack — the pixel take on map controls (the round
    // dots on the map itself keep their physical meaning; chrome goes 8-bit).
    return Material(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      color: active ? (activeColor ?? Colors.blue) : const Color(0xFF1A2733),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

/// Rebuild-limiter for camera-scaled layers: subscribes to the camera (so its
/// own build runs per frame) but only re-runs [builder] — and thus rebuilds
/// the child subtree — when the zoom crosses a 1/[buckets] step. Pan and
/// sub-bucket zoom return the cached child untouched.
class _ZoomBucketed extends StatefulWidget {
  final int buckets;
  final Widget Function(BuildContext, double zoomBucket) builder;
  const _ZoomBucketed({required this.buckets, required this.builder});

  @override
  State<_ZoomBucketed> createState() => _ZoomBucketedState();
}

class _ZoomBucketedState extends State<_ZoomBucketed> {
  double? _bucket;
  Widget? _cached;

  @override
  Widget build(BuildContext context) {
    final z = MapCamera.of(context).zoom;
    final b = (z * widget.buckets).round() / widget.buckets;
    if (b != _bucket || _cached == null) {
      _bucket = b;
      _cached = widget.builder(context, b);
    }
    return _cached!;
  }
}

/// Small chip on the top-left of the map. Shows the active layer's name
/// and color, and pops a menu of all layers — tap to set active, eye icon
/// to toggle visibility, "管理…" to jump to the layers screen.
class _LayerChip extends StatelessWidget {
  final int activeId;
  final List<db_t.TrackLayer> layers;
  final ValueChanged<int> onSelectActive;
  final ValueChanged<db_t.TrackLayer> onToggleVisible;
  final VoidCallback onManage;
  const _LayerChip({
    required this.activeId,
    required this.layers,
    required this.onSelectActive,
    required this.onToggleVisible,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    // Bail with a neutral placeholder if layers haven't loaded yet.
    if (layers.isEmpty) {
      return const SizedBox.shrink();
    }
    final active = layers.firstWhere(
      (l) => l.id == activeId,
      orElse: () => layers.first,
    );
    return Material(
      elevation: 3,
      color: const Color(0xFF1A2733),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => _showMenu(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 像素方块色标（图层颜色钥匙），与首页分组色标同语言。
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Color(active.colorValue),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                active.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              const Icon(Icons.expand_more_rounded,
                  color: Colors.white, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      // The sheet is a separate route built ONCE; a plain snapshot of `layers`
      // never repaints when the eye toggles the DB. Watch the providers here so
      // the visibility icon (and the ★ active marker) flip live on tap.
      builder: (sheetCtx) => Consumer(
        builder: (ctx, ref, _) {
          final liveLayers = ref.watch(layersProvider).value ?? layers;
          final liveActive = ref.watch(activeLayerIdProvider);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(children: [
                    const Text('图层',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.tune_rounded, size: 16),
                      label: const Text('管理…'),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        onManage();
                      },
                    ),
                  ]),
                ),
                const Divider(height: 1),
                // Scrollable + height-capped: with many layers (e.g. after a
                // multi-layer import / recovery) a plain Column overflowed the
                // sheet ("RenderFlex overflowed by 463 pixels").
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final l in liveLayers)
                        ListTile(
                          leading: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: Color(l.colorValue),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.black12),
                            ),
                          ),
                          title: Text(l.name,
                              style: TextStyle(
                                  fontWeight: l.id == liveActive
                                      ? FontWeight.w700
                                      : FontWeight.w500)),
                          subtitle: Text(l.id == liveActive ? '★ 当前活动图层' : ''),
                          trailing: IconButton(
                            icon: Icon(l.visible
                                ? Icons.visibility
                                : Icons.visibility_off_outlined),
                            onPressed: () {
                              onToggleVisible(l);
                            },
                          ),
                          onTap: () {
                            onSelectActive(l.id);
                            Navigator.pop(sheetCtx);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
/// cached FutureBuilder so panning the map doesn't re-hit the DB.

/// Live GPS signal indicator. Shows fix quality + accuracy distance,
/// or a clear "no fix" state when the OS hasn't reported anything
/// recently. Users would otherwise have no idea why the trail isn't
/// moving — especially indoors where the OS silently stops reporting.
class _SignalChip extends StatefulWidget {
  final double? accuracyMeters;
  final DateTime? reportedAt;
  const _SignalChip({required this.accuracyMeters, required this.reportedAt});
  @override
  State<_SignalChip> createState() => _SignalChipState();
}

class _SignalChipState extends State<_SignalChip> {
  /// Map the LAST KNOWN fix accuracy to "bars" (1-4) + colour.
  ///
  /// Signal strength depends ONLY on whether the GPS can produce a fix and
  /// how accurate that fix is — NOT on how recently the position changed.
  /// A stationary user (or one whose distanceFilter suppresses identical
  /// updates) still has a perfectly good fix, so we no longer downgrade to
  /// "信号弱" just because no fresh sample arrived. "No fix at all" is the
  /// only no-signal state, and that's keyed off [reportedAt] being null.
  ({int bars, Color color, String label}) _classify() {
    if (widget.reportedAt == null) {
      return (bars: 0, color: Colors.grey, label: '无定位');
    }
    final acc = widget.accuracyMeters ?? 9999;
    if (acc <= 10) {
      return (
        bars: 4,
        color: const Color(0xFF66BB6A),
        label: '强 · ±${acc.toStringAsFixed(0)} m'
      );
    }
    if (acc <= 30) {
      return (
        bars: 3,
        color: const Color(0xFFAED581),
        label: '良好 · ±${acc.toStringAsFixed(0)} m'
      );
    }
    if (acc <= 80) {
      return (
        bars: 2,
        color: const Color(0xFFFFB74D),
        label: '一般 · ±${acc.toStringAsFixed(0)} m'
      );
    }
    return (
      bars: 1,
      color: const Color(0xFFE57373),
      label: '弱 · ±${acc.toStringAsFixed(0)} m'
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _classify();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: s.color.withValues(alpha: 0.6), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Four ascending bars; lit ones use the level colour.
          for (int i = 1; i <= 4; i++)
            Container(
              width: 3,
              height: 4.0 + i * 2.5,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: i <= s.bars
                    ? s.color
                    : Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          const SizedBox(width: 8),
          Text(
            s.label,
            style: TextStyle(
                color: s.color, fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Tiny circular compass — only shown when the map's been rotated
/// off-north. Tapping snaps the camera back to north-up.
class _CompassChip extends StatelessWidget {
  final double bearingDeg;
  final VoidCallback onTap;
  const _CompassChip({required this.bearingDeg, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: '回正北',
        child: Material(
          color: Colors.black.withValues(alpha: 0.55),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 32,
              height: 32,
              child: Transform.rotate(
                // flutter_map's `rotation` is degrees CCW; the compass
                // needle should point to true north, which is opposite
                // the camera rotation.
                angle: -bearingDeg * math.pi / 180.0,
                child: const Icon(
                  Icons.navigation_rounded,
                  color: Color(0xFFFF5252),
                  size: 18,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
