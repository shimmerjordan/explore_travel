// 从 map_screen.dart 拆出（纯搬迁，无行为改动）。
// 底部导航栏与中央录制 FAB。
part of 'map_screen.dart';

// ════════════════════════════════════════════════════════════════════════
// FOW-style bottom nav bar with notched center cutout for the REC FAB.
// ════════════════════════════════════════════════════════════════════════

class _BottomNav extends ConsumerWidget {
  final VoidCallback onJournal;
  final VoidCallback onGroup;
  final VoidCallback onMusic;
  final VoidCallback onMenu;
  final VoidCallback onQuickNote;
  const _BottomNav({
    required this.onJournal,
    required this.onGroup,
    required this.onMusic,
    required this.onMenu,
    required this.onQuickNote,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(groupPeersProvider);
    final inGroup = (ref.watch(settingsProvider).groupId ?? '').isNotEmpty;
    return BottomAppBar(
      height: 64,
      // NO notch shape. CircularNotchedRectangle installs a _BottomAppBarClipper
      // that reads Scaffold.geometryOf() while recomputing its clip; during a
      // route transition a pointer hit-test can land between layout-invalidation
      // and the next paint, and that getter asserts "only during the paint
      // phase" → the framework exception seen on back-button transitions. With
      // no shape there is no clipper, so the race can't happen. The centre FAB
      // still docks over the bar; it just floats without the cut-out notch.
      padding: EdgeInsets.zero,
      color: MapChrome.bar,
      elevation: 12,
      child: Row(
        // stretch：让每个目标撑满整条 64dp 栏高。图标+标签那一列自己只有 39dp
        // 高（触控目标不足 48dp），列内容仍是居中的，所以视觉一点没变。
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _NavItem(
              icon: Icons.menu_book_rounded,
              label: '附近手账',
              // 长按就地新建手账是个隐藏动作，读屏只能靠这条提示知道。
              longPressHint: '快速新建手账',
              onTap: onJournal,
              onLongPress: onQuickNote,
            ),
          ),
          Expanded(
            child: _NavItem(
              icon: Icons.groups_rounded,
              label: inGroup ? '${peers.length + 1} 人' : '组队',
              // 组队时可见标签只剩一个数字（「3 人」），读屏必须听得出这颗
              // 按钮是干什么的，所以另给一句完整的话。
              semanticLabel: groupNavSemanticLabel(
                inGroup: inGroup,
                memberCount: peers.length + 1,
                peersOnline: peers.isNotEmpty,
              ),
              onTap: onGroup,
              badge: peers.isNotEmpty,
            ),
          ),
          const SizedBox(width: 72), // space for center FAB
          Expanded(
            child: _NavItem(
              icon: Icons.music_note_rounded,
              label: '歌单',
              onTap: onMusic,
            ),
          ),
          Expanded(
            child: _NavItem(
              icon: Icons.apps_rounded,
              label: '更多',
              onTap: onMenu,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「组队」入口的语义标签。组队后可见标签只剩一个人数（「3 人」），读屏用户
/// 听到的必须是这颗按钮**做什么**，而不是一个孤零零的数字。
///
/// 单独抽成公开函数是为了能在 widget test 里直接断言：这些 `map_*` 部件都是
/// `part of map_screen.dart` 的库私有类，测试拿不到；而 part 里的顶层公开函数
/// 会随库导出，可以直接测。
String groupNavSemanticLabel({
  required bool inGroup,
  required int memberCount,
  required bool peersOnline,
}) {
  final base = inGroup ? '组队，当前 $memberCount 人' : '组队';
  return peersOnline ? '$base，有队友在线' : base;
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;

  /// 读屏标签。默认就用可见标签（两者一致最不容易分叉）；只有当可见标签本身
  /// 说不清这颗按钮做什么时才另给一句，如组队的「3 人」。
  final String? semanticLabel;

  /// 长按动作的读屏提示（TalkBack 会念成「双指长按可…」）。
  final String? longPressHint;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool badge;
  const _NavItem({
    required this.icon,
    required this.label,
    this.semanticLabel,
    this.longPressHint,
    required this.onTap,
    this.onLongPress,
    this.badge = false,
  });
  @override
  Widget build(BuildContext context) {
    final core = InkResponse(
      onTap: onTap,
      onLongPress: onLongPress,
      radius: 36,
      // 图标、在线小点与标签都是这颗按钮的「画面」，语义由外层的 Semantics
      // 统一给一份，否则标签会被读两遍。
      child: ExcludeSemantics(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, color: MapChrome.onChrome, size: 22),
                if (badge)
                  Positioned(
                    right: -3,
                    top: -3,
                    child: Container(
                      width: 6,
                      height: 6,
                      color: MapChrome.online,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                  color: MapChrome.onChromeMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                )),
          ],
        ),
      ),
    );
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      onLongPressHint: longPressHint,
      // Surface the hidden long-press action via a long-press tooltip.
      // excludeFromSemantics：同一句话已经由 onLongPressHint 说过了，tooltip
      // 再进语义树就是重复播报。
      child: onLongPress == null
          ? core
          : Tooltip(
              message: '长按可快速新建手账',
              excludeFromSemantics: true,
              child: core,
            ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Center docked REC FAB with pulsing animation while recording.
// ════════════════════════════════════════════════════════════════════════

/// 录制中的红。刻意不用 `cs.error`：这枚 FAB 压在地图影像上（见 MapChrome），
/// 而 error 角色是为应用表面调的。
const Color _recRed = Color(0xFFC62828); // Material red 800

class _CenterRecFab extends StatefulWidget {
  final bool recording;
  final VoidCallback onTap;
  const _CenterRecFab({required this.recording, required this.onTap});
  @override
  State<_CenterRecFab> createState() => _CenterRecFabState();
}

class _CenterRecFabState extends State<_CenterRecFab> {
  /// 脉冲是 4 档的「精灵图式」闪动，不是平滑呼吸。以前用 AnimationController
  /// repeat(reverse) 1100 ms 再把 value 量化到 4 档：每秒 60 次 tick + 重建 +
  /// 布局，画面上却只有 ~3.6 次变化。改成 275 ms 一步的 Timer 直接走这张
  /// 三角波表——0 .25 .5 .75 .75 .5 .25 0——每一档的停留时长（两端 550 ms、
  /// 中间 275 ms）与原先量化后的结果逐帧一致，但一秒只出 ~3.6 帧。
  static const _kStep = Duration(milliseconds: 275);
  static const _kLevels = <double>[0, .25, .5, .75, .75, .5, .25, 0];
  Timer? _pulse;
  int _phase = 0;

  @override
  void dispose() {
    _pulse?.cancel();
    super.dispose();
  }

  /// The pulse only runs while recording (and never under the system's
  /// "disable animations" accessibility switch). It used to run
  /// unconditionally from construction — the home map (this widget's host)
  /// therefore never had an idle frame, and every one of those 60 frames/s
  /// re-composited the full-screen fog veil underneath.
  void _syncPulse(BuildContext context) {
    final want = widget.recording && !MediaQuery.disableAnimationsOf(context);
    if (want && _pulse == null) {
      _pulse = Timer.periodic(_kStep, (_) {
        if (!mounted) return;
        setState(() => _phase = (_phase + 1) % _kLevels.length);
      });
    } else if (!want && _pulse != null) {
      _pulse!.cancel();
      _pulse = null;
      _phase = 0; // 已在 build 里，不必再 setState
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncPulse(context);
    final color =
        widget.recording ? _recRed : MapChrome.brand;
    final t = widget.recording ? _kLevels[_phase] : 0.0;
    // RepaintBoundary：光晕每步只重绘这 64×64，不把同层的顶部芯片一起拖进来。
    // Semantics：这是全屏最主要的一颗按钮，却只有一个圆点/方块图标，读屏必须
    // 直接听到它此刻是「开始」还是「停止」。
    return Semantics(
      button: true,
      label: widget.recording ? '停止记录' : '开始记录',
      child: RepaintBoundary(
        child: SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (widget.recording)
                Container(
                  width: 64 + t * 16,
                  height: 64 + t * 16,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18 * (1 - t)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              Material(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                color: color,
                elevation: 6,
                shadowColor: color.withValues(alpha: 0.5),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: widget.onTap,
                  child: SizedBox(
                    width: 60,
                    height: 60,
                    child: Icon(
                      // Media semantics stay standard: dot = record, square = stop.
                      widget.recording
                          ? Icons.stop_rounded
                          : Icons.fiber_manual_record_rounded,
                      color: MapChrome.onChrome,
                      size: widget.recording ? 30 : 32,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
