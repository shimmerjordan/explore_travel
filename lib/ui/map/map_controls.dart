// 从 map_screen.dart 拆出（纯搬迁，无行为改动）。
// 地图浮层控件：胶囊、圆形按钮、图层选择、信号与指北。
part of 'map_screen.dart';

class _MapChip extends StatelessWidget {
  final IconData icon;
  final String? label;

  /// 读屏标签。这排胶囊大多只有一个图标，有 label 的那颗也只写着「高德」这类
  /// 缩写——两种都听不出按下去会发生什么，所以标签必填，且要说清当前状态 +
  /// 点按后的动作。
  final String semanticLabel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 长按动作的读屏提示（只有热图胶囊有长按）。
  final String? longPressHint;
  const _MapChip({
    required this.icon,
    this.label,
    required this.semanticLabel,
    required this.onTap,
    this.onLongPress,
    this.longPressHint,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Semantics(
        button: true,
        label: semanticLabel,
        onLongPressHint: longPressHint,
        child: Material(
          color: MapChrome.glass,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onTap,
            onLongPress: onLongPress,
            // 图标与缩写是画面；语义已由外层给全，别让「高德」再被读一遍。
            child: ExcludeSemantics(
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: label != null ? 10 : 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: MapChrome.onChrome),
                    if (label != null) ...[
                      const SizedBox(width: 4),
                      Text(label!,
                          style: const TextStyle(
                              color: MapChrome.onChrome,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MapFab extends StatelessWidget {
  final IconData icon;

  /// 读屏标签。右侧这一列全是纯图标按钮，标签是 TalkBack 唯一的信息来源，
  /// 所以必填；同一颗按钮在不同状态下该给不同的话（如擦除的开/关）。
  final String semanticLabel;
  final bool active;
  final Color? activeColor;
  final VoidCallback onTap;
  const _MapFab({
    required this.icon,
    required this.semanticLabel,
    this.active = false,
    this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Hard-cornered square stack — the pixel take on map controls (the round
    // dots on the map itself keep their physical meaning; chrome goes 8-bit).
    //
    // Tooltip 只留视觉提示（悬停 / 长按），语义交给 Semantics：两边同一句话，
    // 若都进语义树 TalkBack 会把它念两遍（label 一次、tooltip 一次）。
    return Tooltip(
      message: semanticLabel,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: Material(
          elevation: 3,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          color: active ? (activeColor ?? MapChrome.brand) : MapChrome.panel,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: SizedBox(
              // 48×48：Material 无障碍下限，也是 PRODUCT.md 写明的目标（原先
              // 44 差 4dp）。图标仍是 20，视觉重量几乎没变。
              width: 48,
              height: 48,
              child: Icon(icon, color: MapChrome.onChrome, size: 20),
            ),
          ),
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
    return Semantics(
      button: true,
      // 色块 + 名字 + 下拉箭头，读屏只看得到名字；说清这是「活动图层」以及点
      // 按会打开图层菜单，否则一个孤零零的图层名毫无意义。
      label: '活动图层：${active.name}，点按打开图层菜单',
      child: Material(
        elevation: 3,
        color: MapChrome.panel,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _showMenu(context),
          child: ExcludeSemantics(
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
                      border:
                          Border.all(color: MapChrome.chromeBorder, width: 1),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    active.name,
                    style: const TextStyle(
                        color: MapChrome.onChrome,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                  const Icon(Icons.expand_more_rounded,
                      color: MapChrome.onChrome, size: 16),
                ],
              ),
            ),
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
                              border: Border.all(color: MapChrome.shadow),
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

/// 精度（米）→ 信号档位：0 = 完全没有定位，1..4 = 弱 → 强。
///
/// Signal strength depends ONLY on whether the GPS can produce a fix and how
/// accurate that fix is — NOT on how recently the position changed (见
/// [_SignalChipState] 的长注释）。抽成公开函数是因为 [_SignalChip] 与
/// [gpsSignalSemanticLabel] 都要用它，同一套阈值不能有两份；同时也让
/// widget test 直接测得到（部件本身是库私有的）。
int gpsSignalBars({double? accuracyMeters, DateTime? reportedAt}) {
  if (reportedAt == null) return 0;
  final acc = accuracyMeters ?? 9999;
  if (acc <= 10) return 4;
  if (acc <= 30) return 3;
  if (acc <= 80) return 2;
  return 1;
}

/// GPS 读数的语义标签：把「四根格子 + ±24 m」翻成一句人话。读屏用户数不了
/// 格子，所以说的是信号质量与精度，而不是「4 格」。
String gpsSignalSemanticLabel({double? accuracyMeters, DateTime? reportedAt}) {
  final bars =
      gpsSignalBars(accuracyMeters: accuracyMeters, reportedAt: reportedAt);
  if (bars == 0) return 'GPS 无定位';
  const words = ['', '信号弱', '信号一般', '信号良好', '信号强'];
  final acc = accuracyMeters ?? 9999;
  return 'GPS ${words[bars]}，精度正负 ${acc.toStringAsFixed(0)} 米';
}

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
    // 阈值只有 gpsSignalBars 一份（语义标签走的也是它），这里只负责把档位映射
    // 成颜色与短标签。
    final bars = gpsSignalBars(
        accuracyMeters: widget.accuracyMeters, reportedAt: widget.reportedAt);
    if (bars == 0) {
      return (bars: 0, color: MapChrome.onChromeMuted, label: '无定位');
    }
    const short = ['', '弱', '一般', '良好', '强'];
    final acc = widget.accuracyMeters ?? 9999;
    return (
      bars: bars,
      color: MapChrome.signalRamp[bars - 1],
      label: '${short[bars]} · ±${acc.toStringAsFixed(0)} m'
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _classify();
    // 这是个读数，不是按钮：给一句完整的话，格子与「良好 · ±24 m」这种缩写
    // 全部排除在语义外。
    return Semantics(
      label: gpsSignalSemanticLabel(
          accuracyMeters: widget.accuracyMeters,
          reportedAt: widget.reportedAt),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: MapChrome.readout,
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
                      : MapChrome.onChrome.withValues(alpha: 0.18),
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
        // 同一句话已由下面的 Semantics 给出（还多带了当前角度），tooltip 再进
        // 语义树只会被念第二遍。
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          label: '回正北，当前地图已旋转 ${bearingDeg.abs().round()} 度',
          child: Material(
            color: MapChrome.readout,
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
                    color: MapChrome.compassNeedle,
                    size: 18,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
