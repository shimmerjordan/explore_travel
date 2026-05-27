import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../app/providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);
    // 地图与群组已集成在首页底部导航栏，这里不重复列出。
    final tiles = <_HomeTile>[
      _HomeTile('图层与标签', Icons.layers_rounded, '/layers',
          gradient: const [Color(0xFF42A5F5), Color(0xFF1E88E5)]),
      _HomeTile('旅行手账', Icons.auto_stories_rounded, '/journal',
          gradient: const [Color(0xFFAB47BC), Color(0xFF8E24AA)]),
      _HomeTile('回放 / 总结', Icons.route_rounded, '/playback',
          gradient: const [Color(0xFFFF7043), Color(0xFFF4511E)]),
      _HomeTile('探索进度', Icons.explore_rounded, '/explore',
          gradient: const [Color(0xFF66BB6A), Color(0xFF43A047)]),
      _HomeTile('AI 旅游规划', Icons.auto_awesome_rounded, '/ai',
          gradient: const [Color(0xFFFFCA28), Color(0xFFFFA000)]),
      _HomeTile('旅行歌单', Icons.headphones_rounded, '/music',
          gradient: const [Color(0xFFEC407A), Color(0xFFD81B60)]),
      _HomeTile('排行榜', Icons.leaderboard_rounded, '/leaderboard',
          gradient: const [Color(0xFF5C6BC0), Color(0xFF3949AB)]),
      _HomeTile('备份与导出', Icons.cloud_sync_rounded, '/backup',
          gradient: const [Color(0xFF26C6DA), Color(0xFF00ACC1)]),
      _HomeTile('手账图床', Icons.image_outlined, '/imghost',
          gradient: const [Color(0xFF9CCC65), Color(0xFF7CB342)]),
      _HomeTile('组队配置', Icons.groups_rounded, '/group/setup',
          gradient: const [Color(0xFF7E57C2), Color(0xFF5E35B1)]),
      _HomeTile('设置', Icons.tune_rounded, '/settings',
          gradient: const [Color(0xFF78909C), Color(0xFF546E7A)]),
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(
              'Explore Journal',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            expandedHeight: 120,
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => _showProfileSheet(context, ref),
                  child: _ProfileAvatar(
                    b64: settings.avatarBase64,
                    seed: settings.selfPeerId ?? settings.displayName,
                  ),
                ),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SwitchListTile.adaptive(
                title: const Text('后台地理预热'),
                subtitle: const Text('地图平移时偷偷预查行政区，写入本地缓存'),
                secondary: const Icon(Icons.travel_explore_rounded),
                value: settings.geocodingPrewarm,
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update((p) => p.copyWith(geocodingPrewarm: v)),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.95,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final t = tiles[i];
                  return _TileCard(tile: t);
                },
                childCount: tiles.length,
              ),
            ),
          ),
          if (settings.debugMode)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _TileCard(
                  tile: _HomeTile('调试面板', Icons.bug_report_outlined,
                      '/debug',
                      gradient: const [Color(0xFFEF5350), Color(0xFFC62828)]),
                ),
              ),
            ),
          SliverToBoxAdapter(child: _VersionTap()),
        ],
      ),
    );
  }
}

/// Tap the version label 10 times to flip [AppSettings.debugMode]. No
/// visible counter — by design — but each tap nudges a SnackBar past 7
/// taps so the user knows something's happening.
class _VersionTap extends ConsumerStatefulWidget {
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      child: Center(
        child: GestureDetector(
          onTap: _onTap,
          behavior: HitTestBehavior.opaque,
          child: Text(
            'Explore Journal · v0.1.0${debug ? ' · debug' : ''}',
            style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).hintColor,
                letterSpacing: 0.5),
          ),
        ),
      ),
    );
  }
}

/// Press-scale animation on every home tile — taps feel responsive
/// even before the route transition starts. 96 % scale + 80 ms ease
/// matches the M3 motion guidance for "container response". The card
/// also gains a soft glow border via the gradient end-colour, picked up
/// in the BoxDecoration boxShadow.
class _TileCard extends StatefulWidget {
  final _HomeTile tile;
  const _TileCard({required this.tile});
  @override
  State<_TileCard> createState() => _TileCardState();
}

class _TileCardState extends State<_TileCard> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final tile = widget.tile;
    return AnimatedScale(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      scale: _pressed ? 0.96 : 1.0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: tile.gradient.last.withValues(alpha: _pressed ? 0.45 : 0.25),
              blurRadius: _pressed ? 18 : 12,
              offset: const Offset(0, 6),
              spreadRadius: -2,
            ),
          ],
        ),
        child: Material(
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push(tile.route),
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: Ink(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: tile.gradient,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(tile.icon, size: 34, color: Colors.white),
                    const SizedBox(height: 10),
                    Text(
                      tile.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
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

class _HomeTile {
  final String label;
  final IconData icon;
  final String route;
  final List<Color> gradient;
  _HomeTile(this.label, this.icon, this.route, {required this.gradient});
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
              Text('个人资料',
                  style: Theme.of(sheetCtx).textTheme.titleLarge),
              const SizedBox(height: 16),
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  _ProfileAvatarBig(
                    b64: s.avatarBase64,
                    seed: s.selfPeerId ?? s.displayName,
                  ),
                  Material(
                    color: Theme.of(sheetCtx).colorScheme.primary,
                    shape: const CircleBorder(),
                    elevation: 2,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _pickAvatar(sheetCtx, ref),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.photo_camera_outlined,
                            color: Colors.white, size: 18),
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
                onChanged: (v) =>
                    n.update((p) => p.copyWith(displayName: v)),
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('图片过大，请选择更小或更低质量的照片')));
      }
      return;
    }
    await ref
        .read(settingsProvider.notifier)
        .update((p) => p.copyWith(avatarBase64: b64));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('选择图片失败：$e')));
    }
  }
}
