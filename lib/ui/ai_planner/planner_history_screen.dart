import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'planner_history.dart';

/// Browse / resume / delete previous planner sessions.
/// Sessions older than 30 days are auto-purged by [PlannerHistory.load].
class PlannerHistoryScreen extends ConsumerStatefulWidget {
  const PlannerHistoryScreen({super.key});
  @override
  ConsumerState<PlannerHistoryScreen> createState() =>
      _PlannerHistoryScreenState();
}

class _PlannerHistoryScreenState
    extends ConsumerState<PlannerHistoryScreen> {
  List<PlannerSession>? _sessions;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final hist = ref.read(plannerHistoryProvider);
    final s = await hist.load();
    if (mounted) setState(() => _sessions = s);
  }

  @override
  Widget build(BuildContext context) {
    final list = _sessions;
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史规划',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
          ),
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? Center(
                  child: Text('暂无历史 — 30 天内的规划会出现在这里',
                      style: TextStyle(
                          color: Theme.of(context).hintColor)))
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final s = list[i];
                    return Dismissible(
                      key: ValueKey(s.id),
                      background: Container(
                        color: Colors.redAccent,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: const Icon(Icons.delete,
                            color: Colors.white),
                      ),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) async {
                        await ref
                            .read(plannerHistoryProvider)
                            .delete(s.id);
                        setState(() => _sessions!.removeAt(i));
                      },
                      child: ListTile(
                        leading: const Icon(Icons.history_rounded),
                        title: Text(
                          s.title.isEmpty ? '(无标题)' : s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${DateFormat('MM-dd HH:mm').format(s.updatedAt)}'
                          ' · ${s.messages.where((m) => m["role"] != "system").length} 条消息',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onTap: () => Navigator.of(context).pop(s),
                      ),
                    );
                  },
                ),
    );
  }
}
