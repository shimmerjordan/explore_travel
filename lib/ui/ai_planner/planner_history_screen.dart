import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../common/empty_state.dart';
import '../common/pixel.dart';
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
              ? const EmptyState(
                  title: '还没有历史规划',
                  hint: '回「AI 旅游规划」聊出一份行程，它会自动存到这里，'
                      '30 天内都能翻回来接着聊。',
                  sprite: PixelSprites.book,
                )
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final s = list[i];
                    return Dismissible(
                      key: ValueKey(s.id),
                      // 左滑删除露出的底：白色垃圾桶图标压在 redAccent 上只有
                      // 3.19:1，勉强够图标；error/onError 这对是 6.5:1 以上。
                      background: Container(
                        color: Theme.of(context).colorScheme.error,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: Icon(Icons.delete,
                            color: Theme.of(context).colorScheme.onError),
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
