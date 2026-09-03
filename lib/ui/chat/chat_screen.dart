import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../app/providers.dart';
import '../../core/prefs.dart' show PeerOverrideX;
import '../../services/group/group_service.dart';
import '../common/format.dart' show fmtRelativeTime;
import 'private_chat_screen.dart';

/// Group screen.
/// Lifecycle (start/stop, message subscription, peer list update) is owned
/// by `groupLifecycleProvider` at app scope, NOT by this widget — that way
/// trails keep flowing on the map even when the user is on another tab.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _msgCtrl = TextEditingController();
  final _groupCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _groupCtrl.text = ref.read(settingsProvider).groupId ?? '';
  }

  @override
  void dispose() {
    _tabs.dispose();
    _msgCtrl.dispose();
    _groupCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(groupRunningProvider);
    final s = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('群组'),
        bottom: TabBar(controller: _tabs, tabs: const [
          Tab(text: '聊天'),
          Tab(text: '成员'),
        ]),
        actions: [
          IconButton(
            tooltip: '组队配置',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => context.push('/group/setup'),
          ),
          IconButton(
            tooltip: running ? '断开' : '连接',
            icon: Icon(running ? Icons.cloud_done : Icons.cloud_off,
                color: running ? Colors.greenAccent : Colors.grey),
            onPressed: () {
              final ctrl = ref.read(groupLifecycleProvider);
              running ? ctrl.stop() : ctrl.start();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _groupCtrl,
                    decoration: InputDecoration(
                      labelText: '群组 ID',
                      hintText: '比如：川西自驾2026',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: (s.groupId ?? '').isEmpty
                          ? null
                          : const Icon(Icons.check, color: Colors.greenAccent),
                    ),
                    onSubmitted: _joinGroup,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.login),
                  label: const Text('加入'),
                  onPressed: () => _joinGroup(_groupCtrl.text),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(controller: _tabs, children: [
              _ChatTab(msgCtrl: _msgCtrl),
              const _MembersTab(),
            ]),
          ),
        ],
      ),
    );
  }

  Future<void> _joinGroup(String raw) async {
    final id = raw.trim();
    await ref
        .read(settingsProvider.notifier)
        .update((p) => p.copyWith(groupId: id, groupAutoConnect: true));
    // Lifecycle controller auto-restarts on groupId change.
  }
}

class _ChatTab extends ConsumerWidget {
  final TextEditingController msgCtrl;
  const _ChatTab({required this.msgCtrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(settingsProvider).displayName;
    final selfId = ref.watch(settingsProvider).selfPeerId;
    final messages = ref.watch(groupChatLogProvider);
    final running = ref.watch(groupRunningProvider);

    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Text(
                  running
                      ? '群里还没有消息\n说一句打个招呼吧'
                      : '尚未连接到群组',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).hintColor),
                ))
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: messages.length,
                  itemBuilder: (_, i) {
                    final m = messages[i];
                    return _Bubble(m: m, mine: m.fromId == selfId);
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: msgCtrl,
                    decoration: const InputDecoration(
                      hintText: '发送消息...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(ref, me),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: running ? () => _send(ref, me) : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _send(WidgetRef ref, String me) async {
    final text = msgCtrl.text.trim();
    if (text.isEmpty) return;
    final svc = ref.read(groupServiceProvider);
    try {
      await svc.sendChat(text);
    } catch (_) {}
    // Echo locally so the sender sees their own message immediately.
    final log = [
      ...ref.read(groupChatLogProvider),
      GroupMessage(
        type: 'chat',
        fromId: ref.read(settingsProvider).selfPeerId ?? 'self',
        fromName: me,
        groupId: ref.read(settingsProvider).groupId ?? '',
        data: {'text': text},
        time: DateTime.now(),
      ),
    ];
    ref.read(groupChatLogProvider.notifier).state = log;
    msgCtrl.clear();
  }
}

class _MembersTab extends ConsumerWidget {
  const _MembersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(groupPeersProvider);
    final me = ref.watch(settingsProvider);

    return ListView(
      children: [
        ListTile(
          leading: CircleAvatar(
            backgroundColor: Color(groupPalette[0]),
            child: Text(
              me.displayName.isEmpty ? '我' : me.displayName[0],
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          title: Text('${me.displayName}（我）'),
          subtitle: Text(me.selfPeerId ?? '',
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const Divider(height: 1),
        if (peers.isEmpty)
          Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                '没有其他成员在线\n确认对方也加入了同一群组',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ),
          )
        else
          ...peers.map((p) {
            final stale = DateTime.now().difference(p.lastSeen) >
                const Duration(seconds: 30);
            final color = Color(me.peerColor(p.id) ?? p.colorValue);
            final shownName = me.peerName(p.id) ?? p.name;
            final visible = me.peerVisible(p.id);
            return ListTile(
              leading: Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    backgroundColor: color,
                    child: Text(
                      shownName.isEmpty ? '?' : shownName[0],
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: stale ? Colors.grey : Colors.greenAccent,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              title: Row(
                children: [
                  Expanded(child: Text(shownName)),
                  if (!visible)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(Icons.visibility_off_outlined,
                          size: 16,
                          color: Theme.of(context).hintColor),
                    ),
                ],
              ),
              subtitle: Text(
                p.lat != null
                    ? '${p.lat!.toStringAsFixed(3)}, ${p.lng!.toStringAsFixed(3)} · '
                        '${fmtRelativeTime(p.lastSeen)}'
                    : '位置未知 · ${fmtRelativeTime(p.lastSeen)}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '编辑显示',
                    icon: const Icon(Icons.palette_outlined),
                    onPressed: () => _editPeer(context, ref, p),
                  ),
                  IconButton(
                    tooltip: '私聊',
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => PrivateChatScreen(peer: p)),
                    ),
                  ),
                  IconButton(
                    tooltip: '对讲',
                    icon: const Icon(Icons.mic_none_rounded),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) =>
                              PrivateChatScreen(peer: p, startInCall: true)),
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Future<void> _editPeer(
      BuildContext context, WidgetRef ref, GroupPeer p) async {
    final s = ref.read(settingsProvider);
    final current = Map<String, dynamic>.from(s.peerOverrides[p.id] ?? {});
    final nameCtrl = TextEditingController(
        text: (current['name'] as String?) ?? p.name);
    int color = (current['color'] as int?) ?? p.colorValue;
    bool visible = (current['visible'] as bool?) ?? true;
    final palette = const [
      0xFFEF5350, 0xFFEC407A, 0xFFAB47BC, 0xFF7E57C2, 0xFF5C6BC0,
      0xFF42A5F5, 0xFF26C6DA, 0xFF26A69A, 0xFF66BB6A, 0xFF9CCC65,
      0xFFFFCA28, 0xFFFFA726, 0xFFFF7043, 0xFF8D6E63, 0xFF78909C,
    ];

    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (_, setSt) => AlertDialog(
          title: const Text('显示设置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: '显示名',
                    hintText: p.name,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                const Text('颜色',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: palette
                      .map((c) => GestureDetector(
                            onTap: () => setSt(() => color = c),
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: Color(c),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: color == c
                                      ? Colors.white
                                      : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('在地图上显示轨迹'),
                  contentPadding: EdgeInsets.zero,
                  value: visible,
                  onChanged: (v) => setSt(() => visible = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                // Reset → remove override entry entirely.
                final updated = {...s.peerOverrides}..remove(p.id);
                await ref
                    .read(settingsProvider.notifier)
                    .update((p) => p.copyWith(peerOverrides: updated));
                if (dctx.mounted) Navigator.pop(dctx);
              },
              child: const Text('重置'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final entry = <String, dynamic>{
                  'color': color,
                  'visible': visible,
                  'name': nameCtrl.text.trim(),
                };
                final updated = {...s.peerOverrides, p.id: entry};
                await ref
                    .read(settingsProvider.notifier)
                    .update((p) => p.copyWith(peerOverrides: updated));
                if (dctx.mounted) Navigator.pop(dctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final GroupMessage m;
  final bool mine;
  const _Bubble({required this.m, required this.mine});

  @override
  Widget build(BuildContext context) {
    final text = m.type == 'chat'
        ? m.data['text']?.toString() ?? ''
        : m.type == 'voice'
            ? '🎤 语音消息'
            : m.type == 'music_play'
                ? '🎵 ${m.data['title']} - ${m.data['artist']}'
                : '[${m.type}]';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: mine
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.fromName,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold)),
            Text(text),
            Text(DateFormat('HH:mm:ss').format(m.time),
                style: const TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}
