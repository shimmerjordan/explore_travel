import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../services/leaderboard/leaderboard_contributors.dart';
import '../../services/leaderboard/leaderboard_model.dart';
import '../../services/leaderboard/leaderboard_service.dart';
import '../about/about_screen.dart' show openServerGuide;
import '../common/empty_state.dart';
import '../common/failure.dart';
import '../common/pixel.dart';

/// Decentralised leaderboard screen — two tabs:
///   * 全球榜  — sorted by `globalKm2` desc
///   * 本月榜  — sorted by `monthKm2[current yyyy-MM]` desc
///   * 关于    — explain the trust model + signing + community-PR flow
class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});
  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  String _selectedMonth = _ymOf(DateTime.now());
  bool _autoRefreshed = false;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    // Snapshot the user's current stats when the screen opens so the
    // self row is live — BUT delay it past the route transition. The
    // refresh walks every track point + every fog tile, easily 50–200 ms
    // on a real device; running it inside the first frame blocks the
    // 'press the tile → page slides in' animation and the user reads
    // that as "卡一下". 500 ms is well past the standard 300 ms route
    // animation, and the user can't see leaderboard data in that window
    // anyway.
    //
    // Skip entirely if a fresh-enough self snapshot already exists
    // (within 60 s) — repeated entries to the screen during one
    // session should be instant.
    Future.delayed(const Duration(milliseconds: 500), () async {
      if (!mounted || _autoRefreshed) return;
      _autoRefreshed = true;
      final s = ref.read(settingsProvider);
      if (s.leaderboardPrivateKey.isEmpty) return;
      final svc = ref.read(leaderboardServiceProvider);
      final mine =
          svc.current.where((e) => e.peerId == s.selfPeerId).firstOrNull;
      if (mine != null &&
          DateTime.now().toUtc().difference(mine.statsAt) <
              const Duration(seconds: 60)) {
        return;
      }
      await _refreshSelf(silent: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(leaderboardEntriesProvider);
    final settings = ref.watch(settingsProvider);
    final entries = entriesAsync.maybeWhen(
      data: (l) => l,
      orElse: () => ref.read(leaderboardServiceProvider).current,
    );

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('排行榜',
              style: PixelText.headline
                  .copyWith(color: Theme.of(context).colorScheme.onSurface)),
          bottom: const TabBar(tabs: [
            Tab(text: '全球'),
            Tab(text: '本月'),
          ]),
          actions: [
            IconButton(
              tooltip: '刷新自己的数据',
              icon: const Icon(Icons.refresh),
              onPressed: () => _refreshSelf(),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'pr':
                    await _contributeToCommunity();
                    break;
                  case 'pull':
                    await _syncWithServer();
                    break;
                  case 'cfg_repo':
                    await _editRepo();
                    break;
                  case 'cfg_server':
                    await _editServer();
                    break;
                  case 'share_id':
                    await _shareSelfId();
                    break;
                  case 'guide':
                    if (mounted) await openServerGuide(context, client: true);
                    break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'share_id',
                    child: ListTile(
                        leading: Icon(Icons.copy_outlined),
                        title: Text('复制我的 peerId'),
                        contentPadding: EdgeInsets.zero,
                        dense: true)),
                PopupMenuDivider(),
                PopupMenuItem(
                    value: 'pr',
                    child: ListTile(
                        leading: Icon(Icons.upload_outlined),
                        title: Text('贡献到社区榜单 (GitHub PR)'),
                        contentPadding: EdgeInsets.zero,
                        dense: true)),
                PopupMenuItem(
                    value: 'pull',
                    child: ListTile(
                        leading: Icon(Icons.cloud_sync_outlined),
                        title: Text('同步社区服务器'),
                        contentPadding: EdgeInsets.zero,
                        dense: true)),
                PopupMenuDivider(),
                PopupMenuItem(
                    value: 'cfg_repo',
                    child: ListTile(
                        leading: Icon(Icons.merge_type),
                        title: Text('配置社区仓库'),
                        contentPadding: EdgeInsets.zero,
                        dense: true)),
                PopupMenuItem(
                    value: 'cfg_server',
                    child: ListTile(
                        leading: Icon(Icons.cloud_outlined),
                        title: Text('配置社区服务器'),
                        contentPadding: EdgeInsets.zero,
                        dense: true)),
                PopupMenuDivider(),
                PopupMenuItem(
                    value: 'guide',
                    child: ListTile(
                        leading: Icon(Icons.menu_book_outlined),
                        title: Text('自建服务器指南'),
                        contentPadding: EdgeInsets.zero,
                        dense: true)),
              ],
            ),
          ],
        ),
        // 拉榜单要走网络，慢的时候整屏空白十几秒；不说清在等什么，空状态的
        // 「还没有数据」就会把「正在拉」误报成「没有」。
        body: entries.isEmpty && (_syncing || entriesAsync.isLoading)
            ? LoadingState(
                label: _syncing ? '正在同步社区服务器…' : '正在读取榜单…')
            : TabBarView(children: [
                _GlobalTab(
                  entries: entries,
                  selfId: settings.selfPeerId,
                  onPublish: () => _refreshSelf(),
                ),
                _MonthlyTab(
                  entries: entries,
                  selfId: settings.selfPeerId,
                  selectedMonth: _selectedMonth,
                  onMonthChange: (m) => setState(() => _selectedMonth = m),
                  onPublish: () => _refreshSelf(),
                ),
              ]),
      ),
    );
  }

  Future<void> _refreshSelf({bool silent = false}) async {
    final s = ref.read(settingsProvider);
    final svc = ref.read(leaderboardServiceProvider);
    final fog = ref.read(fogEngineProvider);
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    final layerIds =
        layers.where((l) => l.visible).map((l) => l.id).toList();
    if (layerIds.isEmpty) return;

    // Global km² ≈ percent × Earth surface.
    final pct = await fog.globalExplorationPercent(layerIds);
    const earth = 510072000.0;
    final globalKm2 = pct * earth;

    // Per-month weights — use track-point counts as a proxy.
    final pts = await (db.select(db.trackPoints)
          ..where((p) => p.layerId.isIn(layerIds)))
        .get();
    final weights = <String, int>{};
    for (final p in pts) {
      final k = _ymOf(p.time);
      weights[k] = (weights[k] ?? 0) + 1;
    }
    final monthly = LeaderboardService.distributeMonthly(weights, globalKm2);

    if (s.leaderboardPrivateKey.isEmpty) return;
    await svc.publishSelf(
      peerId: s.selfPeerId ?? 'unknown',
      publicKeyB64: s.leaderboardPublicKey,
      privateKeyB64: s.leaderboardPrivateKey,
      displayName: s.displayName,
      avatarBase64: s.avatarBase64,
      globalKm2: globalKm2,
      globalPercent: pct,
      monthKm2: monthly,
    );
    if (!mounted || silent) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已发布最新成绩')),
    );
  }

  Future<void> _shareSelfId() async {
    final id = ref.read(settingsProvider).selfPeerId ?? '';
    if (id.isEmpty) {
      _toast('peerId 还未生成');
      return;
    }
    await Clipboard.setData(ClipboardData(text: id));
    _toast('peerId 已复制：${id.substring(0, id.length.clamp(0, 8))}…');
  }

  Future<void> _editRepo() async {
    final s = ref.read(settingsProvider);
    final ownerCtrl =
        TextEditingController(text: s.leaderboardRepoOwner ?? '');
    final repoCtrl =
        TextEditingController(text: s.leaderboardRepoName ?? '');
    final branchCtrl =
        TextEditingController(text: s.leaderboardRepoBranch);
    final patCtrl =
        TextEditingController(text: s.leaderboardRepoPat ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('社区榜单 GitHub 仓库'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: ownerCtrl,
                decoration: const InputDecoration(labelText: 'Owner')),
            TextField(
                controller: repoCtrl,
                decoration: const InputDecoration(labelText: 'Repo')),
            TextField(
                controller: branchCtrl,
                decoration: const InputDecoration(labelText: 'Branch')),
            TextField(
                controller: patCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'PAT (contents:write + pull_requests:write)')),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(settingsProvider.notifier).update((p) => p.copyWith(
          leaderboardRepoOwner: ownerCtrl.text.trim(),
          leaderboardRepoName: repoCtrl.text.trim(),
          leaderboardRepoBranch: branchCtrl.text.trim().isEmpty
              ? 'main'
              : branchCtrl.text.trim(),
          leaderboardRepoPat: patCtrl.text.trim(),
        ));
  }

  Future<void> _editServer() async {
    final s = ref.read(settingsProvider);
    final urlCtrl =
        TextEditingController(text: s.leaderboardServerUrl ?? '');
    final tokenCtrl =
        TextEditingController(text: s.leaderboardServerToken ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('社区榜单服务器'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                  labelText: 'Base URL', hintText: 'https://...')),
          TextField(
              controller: tokenCtrl,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'Token (可选)')),
          const SizedBox(height: 8),
          const Text('接口规范见 docs/leaderboard-server-api.md',
              style: TextStyle(fontSize: 11)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(settingsProvider.notifier).update((p) => p.copyWith(
          leaderboardServerUrl: urlCtrl.text.trim(),
          leaderboardServerToken: tokenCtrl.text.trim(),
        ));
  }

  Future<void> _contributeToCommunity() async {
    final s = ref.read(settingsProvider);
    if (s.leaderboardRepoOwner == null ||
        s.leaderboardRepoName == null ||
        (s.leaderboardRepoPat ?? '').isEmpty) {
      _toast('请先在设置里配置社区榜单仓库 + PAT');
      return;
    }
    final svc = ref.read(leaderboardServiceProvider);
    // 原先这里是 `orElse: () => throw StateError('请先刷新自己的成绩')`，而它在
    // try 之外——抛出后没人捕获，那句提示从来没到过屏幕上，用户只看到操作
    // 无声无息地什么都没发生。改成先查再提示。
    final self = svc.current
        .where((e) => e.peerId == s.selfPeerId)
        .firstOrNull;
    if (self == null) {
      _toast('请先刷新自己的成绩，再贡献到社区榜单');
      return;
    }
    try {
      final pr = GithubLeaderboardPR(
        owner: s.leaderboardRepoOwner!,
        repo: s.leaderboardRepoName!,
        branch: s.leaderboardRepoBranch,
        pat: s.leaderboardRepoPat!,
      );
      await pr.fetchAndMerge(svc.current, svc);
      final url = await pr.contribute(self);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('PR 已创建'),
          content: SelectableText(url),
        ),
      );
    } catch (e, st) {
      // 不给「重试」：开 PR 不是幂等操作，第一次可能已经推上分支了，
      // 再来一遍容易多出一个 PR。
      if (mounted) {
        showFailure(context, action: '贡献到社区榜单', error: e, stack: st);
      }
    }
  }

  Future<void> _syncWithServer() async {
    final s = ref.read(settingsProvider);
    if ((s.leaderboardServerUrl ?? '').isEmpty) {
      _toast('请先在设置里配置 leaderboardServerUrl');
      return;
    }
    final svc = ref.read(leaderboardServiceProvider);
    setState(() => _syncing = true);
    try {
      final client = HttpLeaderboardClient(
        baseUrl: s.leaderboardServerUrl!,
        token: s.leaderboardServerToken,
      );
      final remote = await client.fetchAll();
      final n = await svc.mergeBatch(remote);
      final self = svc.current
          .where((e) => e.peerId == s.selfPeerId)
          .firstOrNull;
      if (self != null) await client.push(self);
      _toast('合并 $n 条远端数据');
    } catch (e, st) {
      // 合并是行级 LWW、push 是 upsert，重跑一次没有副作用。
      if (mounted) {
        showFailure(context,
            action: '同步社区服务器',
            error: e,
            stack: st,
            onRetry: _syncWithServer);
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s)));
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

String _ymOf(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}';

class _GlobalTab extends StatelessWidget {
  final List<LeaderboardEntry> entries;
  final String? selfId;
  final VoidCallback onPublish;
  const _GlobalTab(
      {required this.entries, required this.selfId, required this.onPublish});

  @override
  Widget build(BuildContext context) {
    final sorted = [...entries]
      ..sort((a, b) => b.globalKm2.compareTo(a.globalKm2));
    if (sorted.isEmpty) return _EmptyHint(onPublish: onPublish);
    final selfIdx = sorted.indexWhere((e) => e.peerId == selfId);
    return CustomScrollView(
      slivers: [
        // Sticky "you are here" summary at top — always visible so the
        // user knows their rank without scrolling past 100 strangers.
        if (selfIdx >= 0)
          SliverPersistentHeader(
            pinned: true,
            delegate: _SelfHeader(
              entry: sorted[selfIdx],
              rank: selfIdx + 1,
              total: sorted.length,
              kind: _LbKind.global,
              monthKey: null,
            ),
          ),
        SliverList.builder(
          itemCount: sorted.length,
          itemBuilder: (_, i) => _Row(
            rank: i + 1,
            entry: sorted[i],
            isSelf: sorted[i].peerId == selfId,
            valueText:
                '${sorted[i].globalKm2.toStringAsFixed(2)} km²  ·  ${(sorted[i].globalPercent * 100).toStringAsFixed(6)}%',
          ),
        ),
      ],
    );
  }
}

enum _LbKind { global, monthly }

/// Pinned "我 · 第 X 名" card. Pinned via SliverPersistentHeader so the
/// row stays in view when scrolling through long leaderboards.
class _SelfHeader extends SliverPersistentHeaderDelegate {
  final LeaderboardEntry entry;
  final int rank;
  final int total;
  final _LbKind kind;
  final String? monthKey;
  _SelfHeader({
    required this.entry,
    required this.rank,
    required this.total,
    required this.kind,
    required this.monthKey,
  });

  @override
  double get minExtent => 62;
  @override
  double get maxExtent => 62;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final c = Theme.of(context).colorScheme;
    final value = switch (kind) {
      _LbKind.global =>
        '${entry.globalKm2.toStringAsFixed(2)} km² · ${(entry.globalPercent * 100).toStringAsFixed(6)}%',
      _LbKind.monthly =>
        '${(entry.monthKm2[monthKey] ?? 0).toStringAsFixed(2)} km²',
    };
    return Material(
      elevation: 1,
      color: c.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _Avatar(b64: entry.avatarBase64, peerId: entry.peerId),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('我 · 第 $rank 名 / $total',
                      style: TextStyle(
                          color: c.onPrimaryContainer,
                          fontWeight: FontWeight.w700)),
                  Text(value,
                      style: TextStyle(
                          color: c.onPrimaryContainer.withValues(alpha: 0.85),
                          fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SelfHeader old) =>
      old.entry.statsAt != entry.statsAt ||
      old.rank != rank ||
      old.total != total ||
      old.monthKey != monthKey;
}

class _MonthlyTab extends StatelessWidget {
  final List<LeaderboardEntry> entries;
  final String? selfId;
  final String selectedMonth;
  final ValueChanged<String> onMonthChange;
  final VoidCallback onPublish;
  const _MonthlyTab({
    required this.entries,
    required this.selfId,
    required this.selectedMonth,
    required this.onMonthChange,
    required this.onPublish,
  });

  @override
  Widget build(BuildContext context) {
    // Collect every month that shows up across all entries — that's the
    // dropdown menu.
    final months = <String>{};
    for (final e in entries) {
      months.addAll(e.monthKm2.keys);
    }
    months.add(selectedMonth); // always offer the picked month
    final sortedMonths = months.toList()..sort((a, b) => b.compareTo(a));

    final ranked = [...entries]
      ..sort((a, b) => (b.monthKm2[selectedMonth] ?? 0)
          .compareTo(a.monthKm2[selectedMonth] ?? 0));
    final selfIdx = ranked.indexWhere((e) => e.peerId == selfId);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Text('月份：'),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: selectedMonth,
                items: [
                  for (final m in sortedMonths)
                    DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: (v) {
                  if (v != null) onMonthChange(v);
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: ranked.isEmpty
              ? _EmptyHint(onPublish: onPublish)
              : CustomScrollView(slivers: [
                  if (selfIdx >= 0)
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _SelfHeader(
                        entry: ranked[selfIdx],
                        rank: selfIdx + 1,
                        total: ranked.length,
                        kind: _LbKind.monthly,
                        monthKey: selectedMonth,
                      ),
                    ),
                  SliverList.builder(
                    itemCount: ranked.length,
                    itemBuilder: (_, i) {
                      final e = ranked[i];
                      final km2 = e.monthKm2[selectedMonth] ?? 0;
                      return _Row(
                        rank: i + 1,
                        entry: e,
                        isSelf: e.peerId == selfId,
                        valueText: '${km2.toStringAsFixed(2)} km²',
                        dimmed: km2 == 0,
                      );
                    },
                  ),
                ]),
        ),
      ],
    );
  }
}

/// 前三名的奖牌色。**不是状态色**（金牌不等于"成功"），所以不进
/// `StatusPalette`；但它被当成**文字色**用，仍要过正文的 4.5:1。
///
/// Material 直出的 `amber.shade600` / `grey.shade400` 只在暗色主题里成立：
/// 压在亮色脚手架 `#F3FAF8` 上分别只有 1.70:1 / 1.78:1，等于看不见；
/// `brown.shade300` 连暗色主题里"这是我"那一行（primaryContainer 0.45 的
/// 底）也只有 3.96:1。所以按明暗各给一套——**色相不变**，只是亮色压深、
/// 暗色提亮。`test/ui/contrast_test.dart` 对普通行与"这是我"行各断言一次。
Color medalColor(int rank, ColorScheme cs) {
  final dark = cs.brightness == Brightness.dark;
  return switch (rank) {
    1 => dark ? const Color(0xFFFFB300) : const Color(0xFF8A5A00), // 金
    2 => dark ? const Color(0xFFBDBDBD) : const Color(0xFF5C6670), // 银
    _ => dark ? const Color(0xFFD7A48A) : const Color(0xFF8A4B2A), // 铜
  };
}

class _Row extends StatelessWidget {
  final int rank;
  final LeaderboardEntry entry;
  final String valueText;
  final bool isSelf;
  final bool dimmed;
  const _Row({
    required this.rank,
    required this.entry,
    required this.valueText,
    required this.isSelf,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      color: isSelf ? c.primaryContainer.withValues(alpha: 0.45) : null,
      child: ListTile(
        leading: SizedBox(
          width: 56,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 名次是收集时刻：前三名用像素展示字 + 奖牌色。
              SizedBox(
                width: 24,
                child: Text(
                  '$rank',
                  style: rank <= 3
                      ? PixelText.label.copyWith(
                          fontSize: 14,
                          color: medalColor(rank, c),
                        )
                      : const TextStyle(),
                ),
              ),
              _Avatar(b64: entry.avatarBase64, peerId: entry.peerId),
            ],
          ),
        ),
        title: Row(
          children: [
            Flexible(child: Text(entry.displayName)),
            if (isSelf) ...const [
              SizedBox(width: 6),
              _Chip(label: '我'),
            ],
            if (entry.signature.isEmpty) ...const [
              SizedBox(width: 6),
              _Chip(label: '未签名', warn: true),
            ],
          ],
        ),
        subtitle: Text(
          valueText,
          style: dimmed
              ? TextStyle(color: c.onSurface.withValues(alpha: 0.35))
              : null,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String b64;
  final String peerId;
  const _Avatar({required this.b64, required this.peerId});

  @override
  Widget build(BuildContext context) {
    if (b64.isNotEmpty) {
      try {
        return CircleAvatar(
          radius: 16,
          backgroundImage: MemoryImage(base64Decode(b64)),
        );
      } catch (_) {}
    }
    // Hue-from-peerId fallback.
    final hue = (peerId.hashCode % 360).abs().toDouble();
    final color = HSLColor.fromAHSL(1, hue, 0.6, 0.55).toColor();
    final initial = peerId.isEmpty ? '?' : peerId[0].toUpperCase();
    return CircleAvatar(
      radius: 16,
      backgroundColor: color,
      child: Text(initial, style: const TextStyle(color: Colors.white)),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool warn;
  const _Chip({required this.label, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: warn ? c.errorContainer : c.secondaryContainer,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(label,
          style: TextStyle(
            fontSize: 10,
            color: warn ? c.onErrorContainer : c.onSecondaryContainer,
          )),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final VoidCallback onPublish;
  const _EmptyHint({required this.onPublish});
  @override
  Widget build(BuildContext context) => EmptyState(
        title: '榜单上还没有人',
        hint: '点下面的按钮把自己的成绩算出来发上去，或者和队友组个队，'
            '他们的成绩会自动合并过来。',
        sprite: PixelSprites.compass,
        actionLabel: '发布我的成绩',
        onAction: onPublish,
      );
}

