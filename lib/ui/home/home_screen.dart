import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../app/providers.dart';
import '../common/atmosphere.dart';
import '../common/failure.dart';
import '../common/pixel.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);

    // 地图与群组已在底部导航；这里不重复。功能不再平铺成等大彩色卡片，而是
    //  · 一个「探索进度」主入口(收集乐趣的落点，做成 hero)
    //  · 按意图分组的紧凑入口，层级由使用频率决定(见 PRODUCT.md 原则 4)
    // 颜色走 Material 3 role(容器色自动适配明暗/对比)，而非硬编码彩虹。
    const hero = _HomeItem('探索进度', Icons.explore_rounded, '/explore',
        subtitle: '看看你点亮了多少世界');
    final sections = <_HomeSection>[
      const _HomeSection('记录与回顾', _Tint.primary, [
        _HomeItem('旅行手账', Icons.auto_stories_rounded, '/journal'),
        _HomeItem('足迹时间轴', Icons.timeline_rounded, '/timeline'),
        _HomeItem('回放 / 总结', Icons.route_rounded, '/playback'),
        _HomeItem('图层与标签', Icons.layers_rounded, '/layers'),
        _HomeItem('手账图床', Icons.image_outlined, '/imghost'),
      ]),
      const _HomeSection('发现与同行', _Tint.tertiary, [
        _HomeItem('AI 旅游规划', Icons.auto_awesome_rounded, '/ai'),
        _HomeItem('旅行歌单', Icons.headphones_rounded, '/music'),
        _HomeItem('排行榜', Icons.leaderboard_rounded, '/leaderboard'),
        _HomeItem('组队配置', Icons.groups_rounded, '/group/setup'),
      ]),
      _HomeSection('数据与设置', _Tint.secondary, [
        const _HomeItem('导出与导入', Icons.cloud_sync_rounded, '/backup'),
        const _HomeItem('设置', Icons.tune_rounded, '/settings'),
        if (settings.debugMode)
          const _HomeItem('调试面板', Icons.bug_report_outlined, '/debug'),
      ]),
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            // 品牌时刻：App 名用像素展示字（display 层允许，正文/标签不用）。
            title: Text(
              'Explore Journal',
              style: PixelText.headline.copyWith(color: cs.onSurface),
            ),
            expandedHeight: 120,
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Semantics(
                  button: true,
                  // 一张头像（没设照片时是首字母），原来读屏只念得出那个孤立
                  // 的字母，也听不出它是个按钮。
                  label: '${settings.displayName}，个人资料',
                  child: GestureDetector(
                    onTap: () => _showProfileSheet(context, ref),
                    behavior: HitTestBehavior.opaque,
                    // 头像本身只有 36dp；外面套一个 48dp 的透明框把触控目标补
                    // 到 Material 下限，视觉不变。ExcludeSemantics 只包画面：
                    // 包住 GestureDetector 会把 tap 动作一起排除掉。
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: ExcludeSemantics(
                          child: _ProfileAvatar(
                            b64: settings.avatarBase64,
                            seed: settings.selfPeerId ?? settings.displayName,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Hero：核心探索入口，收集乐趣的落点。
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            sliver: SliverToBoxAdapter(child: _FeaturedTile(item: hero)),
          ),

          // 分组入口。
          for (final section in sections) ...[
            SliverToBoxAdapter(
                child: _SectionHeader(
                    section.title, _chipColors(cs, section.tint).$1)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 62,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) =>
                      _CompactTile(item: section.items[i], tint: section.tint),
                  childCount: section.items.length,
                ),
              ),
            ),
          ],

          // 快捷设置：后台地理预热(高频开关，就近可达)。
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Material(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(6),
                clipBehavior: Clip.antiAlias,
                child: SwitchListTile.adaptive(
                  title: const Text('后台地理预热'),
                  subtitle: const Text('地图平移时偷偷预查行政区，写入本地缓存'),
                  secondary: Icon(Icons.travel_explore_rounded,
                      color: cs.onSurfaceVariant),
                  value: settings.geocodingPrewarm,
                  onChanged: (v) => ref
                      .read(settingsProvider.notifier)
                      .update((p) => p.copyWith(geocodingPrewarm: v)),
                ),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: _VersionTap()),
        ],
      ),
    );
  }
}

/// 分组小标题：像素方块色标 + Material `titleSmall`。方块是该组图标片的
/// 色相钥匙——像素签名，也是分组的颜色图例。
class _SectionHeader extends StatelessWidget {
  final String title;
  final Color swatch;
  const _SectionHeader(this.title, this.swatch);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
      child: Row(children: [
        Container(width: 7, height: 7, color: swatch),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
        ),
      ]),
    );
  }
}

/// Hero 入口：整宽、primary 容器色、图标 + 标题 + 副标题 + 前进指示。
/// 这是"收集乐趣"的落点——比其它入口更重，建立层级。
class _FeaturedTile extends StatelessWidget {
  final _HomeItem item;
  const _FeaturedTile({required this.item});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return _Pressable(
      color: cs.primaryContainer,
      pixel: true,
      borderColor: cs.primary.withValues(alpha: 0.55),
      onTap: () => context.push(item.route),
      child: Stack(
        children: [
          // Faint drifting pixel weather — a quiet echo of the exploration
          // surface it opens (ambient only; the tap owns interaction here).
          const Positioned.fill(
            child: Atmosphere(intensity: 0.5, interactive: false),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  color: cs.primary,
                  child: Center(
                    child: PixelSprite(
                      rows: PixelSprites.map,
                      color: cs.onPrimary,
                      accent: cs.primaryContainer,
                      cell: 3.6,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(item.label,
                          style: PixelText.headline
                              .copyWith(color: cs.onPrimaryContainer)),
                      if (item.subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(item.subtitle!,
                            style: tt.bodySmall?.copyWith(
                              color:
                                  cs.onPrimaryContainer.withValues(alpha: 0.75),
                            )),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: cs.onPrimaryContainer.withValues(alpha: 0.55)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 紧凑入口：tonal 面 + 角色色图标片 + 标签。同组共享同一色相，克制、
/// 一致，触控目标 ≥ 48dp。
class _CompactTile extends StatelessWidget {
  final _HomeItem item;
  final _Tint tint;
  const _CompactTile({required this.item, required this.tint});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (chipBg, chipFg) = _chipColors(cs, tint);
    return _Pressable(
      color: cs.surfaceContainerHigh,
      radius: 6,
      onTap: () => context.push(item.route),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              color: chipBg,
              child: Icon(item.icon, color: chipFg, size: 21),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                item.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

(Color, Color) _chipColors(ColorScheme cs, _Tint t) {
  switch (t) {
    case _Tint.primary:
      return (cs.primaryContainer, cs.onPrimaryContainer);
    case _Tint.secondary:
      return (cs.secondaryContainer, cs.onSecondaryContainer);
    case _Tint.tertiary:
      return (cs.tertiaryContainer, cs.onTertiaryContainer);
  }
}

/// 按压微反馈：97% 缩放 + 110ms ease-out，呼应 M3 容器响应，轻盈。
/// 尊重系统"移除动画"(reduced motion)：关闭时不缩放。
/// `pixel: true` 时用阶梯像素角面板（hero 专属，更重的形状语言）。
class _Pressable extends StatefulWidget {
  final Color color;
  final double radius;
  final bool pixel;
  final Color? borderColor;
  final VoidCallback onTap;
  final Widget child;
  const _Pressable({
    required this.color,
    this.radius = 6,
    this.pixel = false,
    this.borderColor,
    required this.onTap,
    required this.child,
  });
  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final Widget surface;
    if (widget.pixel) {
      surface = PixelPanel(
        color: widget.color,
        borderColor: widget.borderColor,
        step: 4,
        steps: 2,
        clipChild: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: widget.child,
          ),
        ),
      );
    } else {
      surface = Material(
        color: widget.color,
        borderRadius: BorderRadius.circular(widget.radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: widget.child,
        ),
      );
    }
    return AnimatedScale(
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      scale: (_pressed && !reduceMotion) ? 0.97 : 1.0,
      child: surface,
    );
  }
}

class _HomeItem {
  final String label;
  final IconData icon;
  final String route;
  final String? subtitle;
  const _HomeItem(this.label, this.icon, this.route, {this.subtitle});
}

enum _Tint { primary, secondary, tertiary }

class _HomeSection {
  final String title;
  final _Tint tint;
  final List<_HomeItem> items;
  const _HomeSection(this.title, this.tint, this.items);
}

/// Tap the version label 10 times to flip [AppSettings.debugMode]. No
/// visible counter — by design — but each tap nudges a SnackBar past 7
/// taps so the user knows something's happening.
class _VersionTap extends ConsumerStatefulWidget {
  const _VersionTap();
  @override
  ConsumerState<_VersionTap> createState() => _VersionTapState();
}

class _VersionTapState extends ConsumerState<_VersionTap> {
  int _taps = 0;
  DateTime? _lastTap;

  void _onTap() {
    final now = DateTime.now();
    if (_lastTap != null &&
        now.difference(_lastTap!) > const Duration(seconds: 2)) {
      _taps = 0; // reset on idle
    }
    _lastTap = now;
    _taps++;
    final remaining = 10 - _taps;
    if (_taps >= 10) {
      final s = ref.read(settingsProvider);
      final next = !s.debugMode;
      ref
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(debugMode: next));
      _taps = 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(next ? '已开启调试模式' : '已关闭调试模式'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else if (remaining <= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('再点 $remaining 次进入调试模式'),
          duration: const Duration(milliseconds: 800),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final debug = ref.watch(settingsProvider).debugMode;
    final version = 'Explore Journal · v0.1.0${debug ? ' · debug' : ''}';
    return Padding(
      // 上下 8/32 换成 0/16：下面的 48dp 触控框把高度补回来了（总高 54→64）。
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Center(
        child: Semantics(
          button: true,
          // 这行字看着是说明文字，其实是个按钮（连点十次开调试模式）。读屏
          // 原来只念到版本号，完全不知道它可点。
          label: '$version，连续点按十次可开启调试模式',
          child: GestureDetector(
            onTap: _onTap,
            behavior: HitTestBehavior.opaque,
            // 一行 11px 的字只有 ~14dp 高，够不上触控下限；48dp 的透明框把它
            // 撑够，文字仍居中。ExcludeSemantics 只包那行字——包住
            // GestureDetector 会把 tap 动作一起排除掉。
            child: SizedBox(
              height: 48,
              child: Center(
                child: ExcludeSemantics(
                  child: Text(
                    version,
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hintColor,
                        letterSpacing: 0.5),
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

/// Avatar widget — base64 JPEG when set, otherwise a hue-from-seed
/// circle with the seed's first character. Sized for the AppBar action
/// slot. Same fallback logic the leaderboard + peer markers use, so the
/// user looks identical everywhere.
class _ProfileAvatar extends StatelessWidget {
  final String b64;
  final String seed;
  const _ProfileAvatar({required this.b64, required this.seed});
  @override
  Widget build(BuildContext context) {
    if (b64.isNotEmpty) {
      try {
        return CircleAvatar(
          radius: 18,
          backgroundImage: MemoryImage(Uint8List.fromList(base64.decode(b64))),
        );
      } catch (_) {}
    }
    final hue = (seed.hashCode % 360).abs().toDouble();
    final color = HSLColor.fromAHSL(1, hue, 0.55, 0.55).toColor();
    final initial = seed.isEmpty ? '?' : seed.characters.first.toUpperCase();
    return CircleAvatar(
      radius: 18,
      backgroundColor: color,
      child: Text(initial,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600)),
    );
  }
}

/// Profile sheet — name + avatar editor, opened from the AppBar avatar.
/// Keeps profile concerns out of the general settings page; the user
/// asked for that explicitly so we put their identity front-and-centre.
Future<void> _showProfileSheet(BuildContext context, WidgetRef ref) async {
  final s = ref.read(settingsProvider);
  final nameCtrl = TextEditingController(text: s.displayName);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) {
      return Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 8,
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 24,
        ),
        child: Consumer(builder: (sheetCtx, ref, _) {
          final s = ref.watch(settingsProvider);
          final n = ref.read(settingsProvider.notifier);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('个人资料', style: Theme.of(sheetCtx).textTheme.titleLarge),
              const SizedBox(height: 16),
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  _ProfileAvatarBig(
                    b64: s.avatarBase64,
                    seed: s.selfPeerId ?? s.displayName,
                  ),
                  // 纯图标的相机徽章：语义标签是读屏唯一的信息来源。外层 48dp
                  // 透明框补足触控目标，里层 Material 保持原来 34dp 的视觉。
                  Semantics(
                    button: true,
                    label: '更换头像',
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _pickAvatar(sheetCtx, ref),
                          child: Center(
                            child: Material(
                              color: Theme.of(sheetCtx).colorScheme.primary,
                              shape: const CircleBorder(),
                              elevation: 2,
                              child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.photo_camera_outlined,
                                    color: Colors.white, size: 18),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (s.avatarBase64.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('移除头像'),
                  onPressed: () =>
                      n.update((p) => p.copyWith(avatarBase64: '')),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '昵称',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => n.update((p) => p.copyWith(displayName: v)),
              ),
              const SizedBox(height: 16),
              if ((s.selfPeerId ?? '').isNotEmpty)
                Row(
                  children: [
                    const Icon(Icons.fingerprint, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SelectableText(
                        s.selfPeerId!,
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(sheetCtx).hintColor,
                            fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(sheetCtx),
                  child: const Text('完成'),
                ),
              ),
            ],
          );
        }),
      );
    },
  );
}

class _ProfileAvatarBig extends StatelessWidget {
  final String b64;
  final String seed;
  const _ProfileAvatarBig({required this.b64, required this.seed});
  @override
  Widget build(BuildContext context) {
    if (b64.isNotEmpty) {
      try {
        return CircleAvatar(
          radius: 48,
          backgroundImage: MemoryImage(Uint8List.fromList(base64.decode(b64))),
        );
      } catch (_) {}
    }
    final hue = (seed.hashCode % 360).abs().toDouble();
    return CircleAvatar(
      radius: 48,
      backgroundColor: HSLColor.fromAHSL(1, hue, 0.55, 0.55).toColor(),
      child: Text(
        seed.isEmpty ? '?' : seed.characters.first.toUpperCase(),
        style: const TextStyle(
            color: Colors.white, fontSize: 32, fontWeight: FontWeight.w600),
      ),
    );
  }
}

Future<void> _pickAvatar(BuildContext context, WidgetRef ref) async {
  try {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 256,
      maxHeight: 256,
      imageQuality: 70,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final b64 = base64.encode(bytes);
    if (b64.length > 40000) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('图片过大，请选择更小或更低质量的照片')));
      }
      return;
    }
    await ref
        .read(settingsProvider.notifier)
        .update((p) => p.copyWith(avatarBase64: b64));
  } catch (e, st) {
    if (context.mounted) {
      showFailure(context,
          action: '选择图片',
          error: e,
          stack: st,
          onRetry: () => _pickAvatar(context, ref));
    }
  }
}
