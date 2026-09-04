import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/group/group_diagnostics.dart';
import '../common/status_palette.dart';

/// Live tail of group networking events. Renders newest-first, color-coded
/// by severity, with a copy-all button so the user can paste the whole log
/// into chat when something doesn't work.
class GroupDiagnosticsScreen extends ConsumerStatefulWidget {
  const GroupDiagnosticsScreen({super.key});
  @override
  ConsumerState<GroupDiagnosticsScreen> createState() =>
      _GroupDiagnosticsScreenState();
}

class _GroupDiagnosticsScreenState
    extends ConsumerState<GroupDiagnosticsScreen> {
  StreamSubscription<DiagEvent>? _sub;
  DiagLevel _minLevel = DiagLevel.trace;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _sub = groupDiagnostics.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = groupDiagnostics.events;
    final filtered =
        all.where((e) => e.level.index >= _minLevel.index).toList();
    final shown = filtered.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('组队诊断日志',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          PopupMenuButton<DiagLevel>(
            tooltip: '过滤级别',
            initialValue: _minLevel,
            onSelected: (v) => setState(() => _minLevel = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: DiagLevel.trace, child: Text('全部 (trace)')),
              PopupMenuItem(value: DiagLevel.info, child: Text('info+')),
              PopupMenuItem(value: DiagLevel.warn, child: Text('warn+')),
              PopupMenuItem(value: DiagLevel.error, child: Text('仅 error')),
            ],
            icon: const Icon(Icons.filter_alt_outlined),
          ),
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              final text = all.map((e) => e.format()).join('\n');
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: text));
              if (!mounted) return;
              messenger.showSnackBar(SnackBar(
                  content: Text('已复制 ${all.length} 行到剪贴板')));
            },
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => groupDiagnostics.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text('${all.length} 条事件，显示 ${shown.length}'),
                const Spacer(),
                Row(
                  children: [
                    const Text('滚动到顶'),
                    Switch(
                      value: _autoScroll,
                      onChanged: (v) => setState(() => _autoScroll = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text('暂无事件 — 启动组队后会显示',
                        style: TextStyle(
                            color: Theme.of(context).hintColor)),
                  )
                : ListView.separated(
                    reverse: !_autoScroll,
                    itemCount: shown.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _EventTile(e: shown[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  final DiagEvent e;
  const _EventTile({required this.e});

  @override
  Widget build(BuildContext context) {
    // 这枚颜色被画成一条 4px 的竖色条——WCAG 1.4.11 里它是"靠颜色传递信息的
    // 图形"，需要 3:1；语义色板在两套主题的列表面上都过 4.5:1。
    final status = Theme.of(context).status;
    final color = switch (e.level) {
      DiagLevel.error => status.danger,
      DiagLevel.warn => status.warning,
      DiagLevel.info => Colors.lightBlueAccent,
      DiagLevel.trace => Theme.of(context).hintColor,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              )),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${_t(e.ts)}  ${e.tag}',
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hintColor)),
                Text(e.msg,
                    style: const TextStyle(
                        fontSize: 13, fontFamily: 'monospace')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _t(DateTime ts) {
    final h = ts.hour.toString().padLeft(2, '0');
    final m = ts.minute.toString().padLeft(2, '0');
    final s = ts.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
