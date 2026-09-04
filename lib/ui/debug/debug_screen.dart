import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../app/providers.dart';
import '../../services/debug/log_buffer.dart';
import '../../services/fog/fog_engine.dart';
import '../common/failure.dart';

/// 调试面板（只在 debugMode 开启或 kDebugMode 下可见）。
/// 入口：首页底部版本号点 10 次 → 切换 debugMode。
class DebugScreen extends ConsumerStatefulWidget {
  const DebugScreen({super.key});
  @override
  ConsumerState<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends ConsumerState<DebugScreen> {
  late List<LogEntry> _entries;
  final _scroll = ScrollController();
  bool _autoScroll = true;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _entries = LogBuffer.snapshot();
    LogBuffer.addListener(_onChange);
  }

  @override
  void dispose() {
    LogBuffer.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() => _entries = LogBuffer.snapshot());
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final filtered = _filter.isEmpty
        ? _entries
        : _entries
            .where((e) =>
                e.message.toLowerCase().contains(_filter.toLowerCase()))
            .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('调试面板',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: '导出日志',
            onPressed: _entries.isEmpty ? null : _exportLogs,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空缓冲区',
            onPressed: _entries.isEmpty
                ? null
                : () {
                    LogBuffer.clear();
                    _onChange();
                  },
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.bug_report_outlined),
            title: const Text('调试模式'),
            subtitle: const Text(
                '开启后地图上的 sim 面板永久可见（release build 也是）'),
            value: s.debugMode,
            onChanged: (v) => n.update((p) => p.copyWith(debugMode: v)),
          ),
          _FogDiagnostics(),
          SwitchListTile(
            secondary: const Icon(Icons.vertical_align_bottom_rounded),
            title: const Text('自动滚动到底部'),
            value: _autoScroll,
            onChanged: (v) => setState(() => _autoScroll = v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.filter_alt_outlined, size: 18),
                hintText: '过滤（子串，大小写不敏感）',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('共 ${_entries.length} 条 · 显示 ${filtered.length}',
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hintColor)),
              ],
            ),
          ),
          const Divider(height: 12),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('暂无日志'))
                : ListView.builder(
                    controller: _scroll,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final e = filtered[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 2),
                        child: SelectableText(
                          '${_fmtTime(e.time)}  ${e.message}',
                          style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              height: 1.3),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    String two(int x) => x.toString().padLeft(2, '0');
    String three(int x) => x.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }

  Future<void> _exportLogs() async {
    try {
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final f = File(p.join(dir.path, 'explore_journal_log_$ts.txt'));
      await f.writeAsString(LogBuffer.exportText());
      await Share.shareXFiles([XFile(f.path)],
          subject: 'Explore Journal log');
    } catch (e, st) {
      if (!mounted) return;
      showFailure(context,
          action: '导出日志', error: e, stack: st, onRetry: _exportLogs);
    }
  }
}

/// Fog / recording snapshot + a one-shot "fire test reveal" button.
/// Lets the user prove whether (a) recording is firing samples, (b) writes
/// land in DB, (c) the renderer reads them back.
class _FogDiagnostics extends ConsumerStatefulWidget {
  @override
  ConsumerState<_FogDiagnostics> createState() => _FogDiagnosticsState();
}

class _FogDiagnosticsState extends ConsumerState<_FogDiagnostics> {
  int? _tiles;
  int? _bits;
  String? _lastAction;

  Future<void> _refresh() async {
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    final layerIds =
        layers.where((l) => l.visible).map((l) => l.id).toList();
    final rows = await db.fogTilesForLayers(layerIds, FogEngine.tileZoom);
    int bits = 0;
    for (final r in rows) {
      for (final byte in r.bitmap) {
        var v = byte;
        while (v != 0) {
          v &= v - 1;
          bits++;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _tiles = rows.length;
      _bits = bits;
    });
  }

  Future<void> _fireTestReveal() async {
    final pos = ref.read(currentDisplayPositionProvider);
    if (pos == null) {
      setState(() => _lastAction = '失败：当前没有位置 — 先在地图等定位');
      return;
    }
    final fog = ref.read(fogEngineProvider);
    final settings = ref.read(settingsProvider);
    final layerId = ref.read(effectiveActiveLayerIdProvider);
    try {
      // 100m radius — big enough to be visible at any reasonable zoom.
      await fog.revealPoint(
        lat: pos.lat,
        lng: pos.lng,
        radiusMeters: 100,
        layerId: layerId,
      );
      ref.read(fogRefreshProvider.notifier).state++;
      setState(() => _lastAction =
          '✓ 在 (${pos.lat.toStringAsFixed(5)}, ${pos.lng.toStringAsFixed(5)}) layer=$layerId 写入 100m 半径'
          '\n  → 回地图看应该立刻有一圈清除');
      await _refresh();
    } catch (e, st) {
      setState(() => _lastAction = '✗ 写入失败：$e');
      debugPrint('[Debug] revealPoint failed: $e\n$st');
    }
    // Touch settings so the analyzer doesn't whine; harmless.
    settings.toString();
  }

  Future<void> _listLayers() async {
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    final active = ref.read(activeLayerIdProvider);
    final lines = layers
        .map((l) =>
            '  id=${l.id} ${l == layers.first ? '★' : ' '} name="${l.name}" visible=${l.visible}${l.id == active ? ' (active)' : ''}')
        .join('\n');
    setState(() => _lastAction = '图层（active=$active）：\n$lines');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.cloud_outlined, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            const Text('迷雾 / 录制诊断',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: '刷新',
              onPressed: _refresh,
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            _tiles == null
                ? '未刷新'
                : 'fog_tile 行数：$_tiles · 已亮像素：$_bits',
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.list_alt, size: 16),
              label: const Text('看图层状态'),
              onPressed: _listLayers,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.flare_outlined, size: 16),
              label: const Text('在当前位置写一个 100m 测试点'),
              onPressed: _fireTestReveal,
            ),
          ]),
          if (_lastAction != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              _lastAction!,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.4),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '提示：录制时每个 GPS 采样只点亮 1 个 ~9m 像素（仿世界迷雾）。'
            '在 zoom < 15 时一个像素是亚像素的，看不到；放大到 17+ 才能看到单点。'
            '想看连续轨迹得多走几步累积。',
            style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant,
                height: 1.4),
          ),
        ],
      ),
    );
  }
}
