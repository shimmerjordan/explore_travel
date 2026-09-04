import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/debug/log_buffer.dart';
import '../../services/storage/storage_inspector.dart';
import '../common/empty_state.dart';
import '../common/failure.dart';
import '../common/format.dart' show fmtBytes;
import '../common/pixel.dart';

/// 存储空间 —— 数据库 / 照片 / 各类缓存的占用统计，以及安全的清理入口。
/// 手账照片虽然落在缓存目录（image_picker 产物），但属于用户数据：
/// 统计时单列，任何清理动作都不会碰它。
class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});
  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  StorageReport? _report;
  bool _busy = true; // 扫描或清理进行中：顶部进度条 + 禁点

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan() async {
    setState(() => _busy = true);
    try {
      final r = await StorageInspector(ref.read(dbProvider)).scan();
      if (mounted) setState(() => _report = r);
    } catch (e, s) {
      if (mounted) {
        showFailure(context,
            action: '统计', error: e, stack: s, onRetry: _scan);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 确认 → 执行 → 报告释放量 → 重扫。所有清理动作走同一条路。
  Future<void> _run({
    required String title,
    required String body,
    required String actionLabel,
    required Future<int> Function() action,
  }) async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(actionLabel)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final freed = await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('完成，释放 ${fmtBytes(freed)}')));
      }
    } catch (e, s) {
      if (mounted) {
        // 清理都是幂等的（删同一批文件），重试走同一条路——包括再确认一次。
        showFailure(context,
            action: '清理',
            error: e,
            stack: s,
            onRetry: () => _run(
                title: title,
                body: body,
                actionLabel: actionLabel,
                action: action));
      }
    }
    await _scan();
  }

  Future<void> _clearAiHistory() async {
    final c = ref.read(companionProvider);
    if (c.busy || c.inCall) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('旅伴正在通话或回复中，结束后再清空')));
      return;
    }
    final before = _report?.ai.bytes ?? 0;
    await _run(
      title: '清空旅伴聊天记录？',
      body: '删除全部历史会话（也可以在旅伴卡片的「历史」Tab 里按段删除）。'
          'AI 规划的会话不受影响。',
      actionLabel: '清空',
      action: () async {
        await c.clearHistory();
        return before;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = _report;
    final slices = r == null ? const <_Slice>[] : _slicesOf(r, cs);
    final logs = LogBuffer.snapshot();
    final logBytes = logs.fold<int>(0, (a, e) => a + e.message.length * 2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('存储空间',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: '重新统计',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _busy ? null : _scan,
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 2,
            child: _busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Expanded(
            // 首次统计时整页只有一列「—」，与其让人猜是不是坏了，不如说清在等
            // 什么；统计失败时也别把转圈留在屏幕上，给一个能重来的出口。
            // 这里刻意判 _report 而不是 r：判 r 会把下面整棵树里的 r 提升成
            // 非空，`r?.db.bytes` 之类就全成了「多余的 ?.」告警。
            child: _report == null
                ? (_busy
                    ? const LoadingState(label: '统计中…')
                    : EmptyState(
                        title: '还没统计出占用',
                        hint: '统计没跑完。点「重新统计」再来一次。',
                        sprite: PixelSprites.cloud,
                        actionLabel: '重新统计',
                        onAction: _scan,
                      ))
                : ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      _Overview(totalBytes: r?.totalBytes, slices: slices),
                      const _SectionHeader('数据'),
                      _CategoryTile(
                        dot: cs.primary,
                        title: '数据库',
                        subtitle: r == null
                            ? '轨迹 · 迷雾 · 手账 · 聊天'
                            : '${fmtWan(r.dbCounts.trackPoints)} 轨迹点 · '
                                '${fmtWan(r.dbCounts.fogTiles)} 迷雾瓦片 · '
                                '${fmtWan(r.dbCounts.journals)} 手账 · 点按整理回收空间',
                        size: r?.db.bytes,
                        onTap: r == null
                            ? null
                            : () => _run(
                                  title: '整理数据库？',
                                  body: '回收已删除数据占用的空间（VACUUM），'
                                      '不会改动任何轨迹、迷雾或手账。'
                                      '数据量大时需要几秒，期间请留在本页。',
                                  actionLabel: '整理',
                                  action: () =>
                                      StorageInspector(ref.read(dbProvider))
                                          .vacuumDb(),
                                ),
                      ),
                      _CategoryTile(
                        dot: cs.tertiary,
                        title: '手账与聊天照片',
                        subtitle: r != null && r.photosMissing > 0
                            ? '删除对应手账/消息时自动释放 · ${r.photosMissing} 张源文件已丢失'
                            : '删除对应手账/消息时自动释放，清理不会碰它们',
                        size: r?.photos.bytes,
                      ),
                      _CategoryTile(
                        dot: cs.primary.withValues(alpha: .55),
                        title: 'AI 旅伴聊天记录',
                        subtitle: r == null
                            ? '会话历史'
                            : '${r.aiSessions} 段会话 · ${r.aiMessages} 条消息 · '
                                '旅伴卡片「历史」Tab 可按段管理',
                        size: r?.ai.bytes,
                        onTap: r == null ? null : _clearAiHistory,
                      ),
                      _CategoryTile(
                        dot: cs.outlineVariant,
                        title: '其他数据',
                        subtitle: '同步镜像 / 待上传轨迹缓冲 / 排行榜记录等，不可清理',
                        size: r?.other.bytes,
                      ),
                      const _SectionHeader('缓存 · 可清理'),
                      _CategoryTile(
                        dot: cs.secondary,
                        title: '地图瓦片缓存',
                        subtitle: r == null
                            ? '离线地图'
                            : '${fmtWan(r.tiles.count)} 张瓦片 · 清理后这些区域需联网重新加载',
                        size: r?.tiles.bytes,
                        onTap: r == null
                            ? null
                            : () => _run(
                                  title: '清空地图瓦片缓存？',
                                  body: '已缓存的离线地图会被删除，再次查看这些区域时'
                                      '需要联网重新加载。迷雾、轨迹、手账不受影响。',
                                  actionLabel: '清空',
                                  action: () =>
                                      StorageInspector(ref.read(dbProvider))
                                          .cleanTiles(),
                                ),
                      ),
                      _CategoryTile(
                        dot: cs.tertiary.withValues(alpha: .55),
                        title: '行政区边界缓存',
                        subtitle: '点亮国家/省市统计用 · 清理后按需自动重新下载',
                        size: r?.regions.bytes,
                        onTap: r == null
                            ? null
                            : () => _run(
                                  title: '清空行政区边界缓存？',
                                  body: '下次查看点亮统计时会自动重新下载，'
                                      '不影响任何已点亮的数据。',
                                  actionLabel: '清空',
                                  action: () =>
                                      StorageInspector(ref.read(dbProvider))
                                          .cleanRegions(),
                                ),
                      ),
                      _CategoryTile(
                        dot: cs.secondary.withValues(alpha: .5),
                        title: '临时文件',
                        subtitle: r == null
                            ? '网络图片缓存 / 语音 / 导出过程产物'
                            : '${r.temp.count} 个 · 网络图片缓存/语音/导出产物'
                                '${r.tempSkippedRecent > 0 ? ' · ${r.tempSkippedRecent} 个新文件将保留' : ''}',
                        size: r?.temp.bytes,
                        onTap: r == null
                            ? null
                            : () => _run(
                                  title: '清理临时文件？',
                                  body: '删除歌单封面等网络图片缓存（会自动重新下载），'
                                      '以及语音合成、通话录音、打包导出产生的临时文件。'
                                      '1 小时内的新文件会保留，手账照片不会被清理。',
                                  actionLabel: '清理',
                                  action: () =>
                                      StorageInspector(ref.read(dbProvider))
                                          .cleanTemp(),
                                ),
                      ),
                      const _SectionHeader('运行日志'),
                      ListTile(
                        leading: const _Dot(color: Colors.transparent),
                        title: const Text('运行日志（内存）'),
                        subtitle: Text(
                            '最近 ${logs.length} 条 · 仅存内存，重启自动清空 · 调试页可查看'),
                        trailing: Text('~${fmtBytes(logBytes)}',
                            style: TextStyle(
                                fontSize: 13, color: cs.onSurfaceVariant)),
                        onTap: logs.isEmpty
                            ? null
                            : () {
                                LogBuffer.clear();
                                setState(() {});
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('已清空运行日志')));
                              },
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  List<_Slice> _slicesOf(StorageReport r, ColorScheme cs) => [
        _Slice(r.db.bytes, cs.primary),
        _Slice(r.photos.bytes, cs.tertiary),
        _Slice(r.ai.bytes, cs.primary.withValues(alpha: .55)),
        _Slice(r.other.bytes, cs.outlineVariant),
        _Slice(r.tiles.bytes, cs.secondary),
        _Slice(r.regions.bytes, cs.tertiary.withValues(alpha: .55)),
        _Slice(r.temp.bytes, cs.secondary.withValues(alpha: .5)),
      ];
}

class _Slice {
  final int bytes;
  final Color color;
  const _Slice(this.bytes, this.color);
}

/// 顶部总览：总占用数字 + 按占比分段的横条（颜色与下方列表的色点一一对应）。
class _Overview extends StatelessWidget {
  final int? totalBytes;
  final List<_Slice> slices;
  const _Overview({required this.totalBytes, required this.slices});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = totalBytes ?? 0;
    final visible = slices.where((s) => s.bytes > 0).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('应用数据共占用',
                  style: TextStyle(
                      fontSize: 13, color: cs.onSurfaceVariant)),
              const SizedBox(width: 8),
              Text(totalBytes == null ? '统计中…' : fmtBytes(total),
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: SizedBox(
              height: 10,
              child: total <= 0 || visible.isEmpty
                  ? ColoredBox(color: cs.surfaceContainerHighest)
                  : Row(
                      children: [
                        for (var i = 0; i < visible.length; i++)
                          Expanded(
                            // flex 上限防极端大文件溢出 int 比例失真
                            flex: (visible[i].bytes >> 10).clamp(1, 1 << 28),
                            child: Container(
                              color: visible[i].color,
                              margin: EdgeInsets.only(
                                  right: i == visible.length - 1 ? 0 : 1),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final Color dot;
  final String title;
  final String subtitle;
  final int? size;
  final VoidCallback? onTap;
  const _CategoryTile({
    required this.dot,
    required this.title,
    required this.subtitle,
    required this.size,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: _Dot(color: dot),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(size == null ? '—' : fmtBytes(size!),
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: cs.onSurfaceVariant),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 24,
        height: 24,
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(4)),
          ),
        ),
      );
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 16, 6),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 1.5)),
      );
}

String fmtWan(int n) =>
    n >= 10000 ? '${(n / 10000).toStringAsFixed(1)} 万' : '$n';
