import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../app/providers.dart';
import '../../services/group/group_service.dart';
import '../../services/group/ptt_controller.dart';

/// 1:1 conversation with another peer. Backed by the same GroupService
/// transport — messages flow over the direct socket / data channel and are
/// routed by the `to` field, so other peers never see them.
class PrivateChatScreen extends ConsumerStatefulWidget {
  final GroupPeer peer;

  /// When true, jump straight into the walkie-talkie view (used from the
  /// "对讲" button on the members list).
  final bool startInCall;

  const PrivateChatScreen(
      {super.key, required this.peer, this.startInCall = false});

  @override
  ConsumerState<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends ConsumerState<PrivateChatScreen> {
  final _msgCtrl = TextEditingController();
  bool _showCall = false;

  @override
  void initState() {
    super.initState();
    _showCall = widget.startInCall;
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.peer;
    final selfId = ref.watch(settingsProvider).selfPeerId;
    final me = ref.watch(settingsProvider).displayName;
    final running = ref.watch(groupRunningProvider);
    // Messages from the other peer to me.
    final incoming = ref.watch(privateChatLogProvider)[p.id] ?? const [];
    // Plus my own outgoing messages we echo locally (also stored under p.id).
    final messages = incoming;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: Color(p.colorValue),
              radius: 14,
              child: Text(
                p.name.isEmpty ? '?' : p.name[0],
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 10),
            Text(p.name),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_showCall ? Icons.chat_outlined : Icons.mic_none_rounded),
            tooltip: _showCall ? '回到聊天' : '对讲',
            onPressed: () => setState(() => _showCall = !_showCall),
          ),
        ],
      ),
      body: _showCall
          ? _CallView(peer: p)
          : Column(
              children: [
                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: Text(
                            running
                                ? '还没有消息\n说一句私聊吧'
                                : '尚未连接到群组',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Theme.of(context).hintColor),
                          ),
                        )
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
                            controller: _msgCtrl,
                            decoration: const InputDecoration(
                              hintText: '私聊…',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _send(me),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: running ? () => _send(me) : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _send(String me) async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    final p = widget.peer;
    final svc = ref.read(groupServiceProvider);
    try {
      await svc.sendChatTo(p.id, text);
    } catch (_) {}
    // Echo locally so the sender sees their own bubble.
    final logs = {...ref.read(privateChatLogProvider)};
    final list = <GroupMessage>[...(logs[p.id] ?? const [])];
    list.add(GroupMessage(
      type: 'chat',
      fromId: ref.read(settingsProvider).selfPeerId ?? 'self',
      fromName: me,
      groupId: ref.read(settingsProvider).groupId ?? '',
      data: {'text': text, 'to': p.id},
      time: DateTime.now(),
    ));
    logs[p.id] = list;
    ref.read(privateChatLogProvider.notifier).state = logs;
    _msgCtrl.clear();
  }
}

class _CallView extends ConsumerStatefulWidget {
  final GroupPeer peer;
  const _CallView({required this.peer});
  @override
  ConsumerState<_CallView> createState() => _CallViewState();
}

class _CallViewState extends ConsumerState<_CallView> {
  bool _talking = false;

  Future<void> _press() async {
    if (_talking) return;
    setState(() => _talking = true);
    final ok = await ref
        .read(pttControllerProvider)
        .start(targetPeerId: widget.peer.id);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有麦克风权限')));
      setState(() => _talking = false);
    }
  }

  Future<void> _release() async {
    if (!_talking) return;
    await ref.read(pttControllerProvider).stop();
    if (mounted) setState(() => _talking = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.peer;
    final running = ref.watch(groupRunningProvider);
    final stale = DateTime.now().difference(p.lastSeen) >
        const Duration(seconds: 30);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              backgroundColor: Color(p.colorValue),
              radius: 56,
              child: Text(
                p.name.isEmpty ? '?' : p.name[0],
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 40),
              ),
            ),
            const SizedBox(height: 16),
            Text(p.name,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w600)),
            Text(stale
                ? '离线 / 信号丢失'
                : (running ? '已连接' : '群组未连接')),
            const SizedBox(height: 48),
            GestureDetector(
              onTapDown: (_) => _press(),
              onTapUp: (_) => _release(),
              onTapCancel: _release,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _talking
                      ? Colors.redAccent
                      : Theme.of(context).colorScheme.primary,
                  boxShadow: [
                    BoxShadow(
                      color: (_talking
                              ? Colors.redAccent
                              : Theme.of(context).colorScheme.primary)
                          .withValues(alpha: 0.45),
                      blurRadius: _talking ? 36 : 12,
                      spreadRadius: _talking ? 6 : 0,
                    ),
                  ],
                ),
                child: const Icon(Icons.mic, color: Colors.white, size: 56),
              ),
            ),
            const SizedBox(height: 16),
            Text(_talking ? '正在讲话…' : '按住说话',
                style: TextStyle(color: Theme.of(context).hintColor)),
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
            Text(text),
            Text(DateFormat('HH:mm:ss').format(m.time),
                style: const TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}
