import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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

class _TileCard extends StatelessWidget {
  final _HomeTile tile;
  const _TileCard({required this.tile});

  @override
  Widget build(BuildContext context) {
    return Material(
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(tile.route),
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
