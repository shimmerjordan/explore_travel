import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import 'planner_history.dart';
import 'planner_history_screen.dart';
import 'trip_plan.dart';

class AiPlannerScreen extends ConsumerStatefulWidget {
  const AiPlannerScreen({super.key});
  @override
  ConsumerState<AiPlannerScreen> createState() => _AiPlannerScreenState();
}

class _AiPlannerScreenState extends ConsumerState<AiPlannerScreen> {
  // Trip parameters (form).
  final _budgetCtrl = TextEditingController(text: '3000');
  final _daysCtrl = TextEditingController(text: '3');
  final _peopleCtrl = TextEditingController(text: '2');
  final _prefCtrl = TextEditingController(text: '自然风景，少人，能拍照');
  final _originCtrl = TextEditingController(text: '');
  final _notesCtrl = TextEditingController(text: '');

  static const _physicalOptions = ['很好', '一般', '体力差/有伤病'];
  static const _financialOptions = ['宽裕，舒适为主', '中等，性价比为主', '紧张，省钱为主'];
  static const _companyOptions = ['独行', '情侣', '家庭带娃', '父母同行', '朋友/驴友'];
  String _physical = '一般';
  String _financial = '中等，性价比为主';
  String _company = '朋友/驴友';

  // Conversation. Each entry: { role: 'user'|'assistant'|'system', content }
  final List<Map<String, String>> _history = [];
  final _followCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  bool _running = false;
  // Live cancel token for the currently-streaming AI call. Calling
  // `cancel()` aborts the underlying dio request and the chatStream returns
  // cleanly, so the user can stop a long-running plan without leaving the
  // screen.
  CancelToken? _cancelToken;
  bool _formExpanded = true;
  String? _autoOriginLabel;
  bool _resolvingLocation = false;
  // Sticky session id so save/upsert across turns updates the same entry
  // instead of appending a new one on every reply. Reset by [_newSession].
  String? _sessionId;

  @override
  void initState() {
    super.initState();
    _resolveOrigin();
    // Restore the most-recent session on entry so coming back from another
    // screen doesn't lose work.
    _restoreLatestSession();
  }

  Future<void> _restoreLatestSession() async {
    final list = await ref.read(plannerHistoryProvider).load();
    if (!mounted || list.isEmpty) return;
    final latest = list.first;
    setState(() {
      _sessionId = latest.id;
      _history
        ..clear()
        ..addAll(latest.messages);
      _formExpanded = false; // collapse so the user sees the chat
    });
    _scrollToBottom();
  }

  /// First non-empty user message becomes the session title.
  String _deriveTitle() {
    for (final m in _history) {
      if (m['role'] == 'user') {
        final c = (m['content'] ?? '').trim();
        if (c.isNotEmpty) {
          // Use the first line, truncate.
          final firstLine = c.split('\n').first;
          return firstLine.length > 40
              ? '${firstLine.substring(0, 40)}…'
              : firstLine;
        }
      }
    }
    return '未命名规划';
  }

  Future<void> _persist() async {
    if (_history.length < 2) return;
    final id = _sessionId ??= PlannerHistory.newId();
    final s = PlannerSession(
      id: id,
      updatedAt: DateTime.now(),
      title: _deriveTitle(),
      messages: List<Map<String, String>>.from(_history),
    );
    await ref.read(plannerHistoryProvider).upsert(s);
  }

  void _newSession() {
    setState(() {
      _sessionId = null;
      _history.clear();
      _formExpanded = true;
    });
  }

  Future<void> _openHistory() async {
    // Save the in-flight session before navigating so it shows up in the
    // history list immediately.
    await _persist();
    if (!mounted) return;
    final picked = await Navigator.of(context).push<PlannerSession>(
      MaterialPageRoute(builder: (_) => const PlannerHistoryScreen()),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _sessionId = picked.id;
      _history
        ..clear()
        ..addAll(picked.messages);
      _formExpanded = false;
    });
    _scrollToBottom();
  }

  Future<void> _resolveOrigin() async {
    setState(() => _resolvingLocation = true);
    try {
      final pos = await ref.read(locationServiceProvider).currentOnce();
      if (pos != null && _originCtrl.text.isEmpty) {
        final txt =
            '当前位置 ${pos.latitude.toStringAsFixed(3)}, ${pos.longitude.toStringAsFixed(3)}';
        _originCtrl.text = txt;
        _autoOriginLabel = txt;
      }
    } catch (_) {}
    if (mounted) setState(() => _resolvingLocation = false);
  }

  @override
  void dispose() {
    for (final c in [
      _budgetCtrl,
      _daysCtrl,
      _peopleCtrl,
      _prefCtrl,
      _originCtrl,
      _notesCtrl,
      _followCtrl,
    ]) {
      c.dispose();
    }
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 旅游规划',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded),
            tooltip: '历史规划',
            onPressed: _openHistory,
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '新建规划',
            onPressed: _newSession,
          ),
        ],
      ),
      body: Column(
        children: [
          if (settings.aiApiKey == null || settings.aiApiKey!.isEmpty)
            _missingKeyBanner(context),
          // Collapsible parameter form.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: _formExpanded
                ? _buildForm()
                : _buildFormSummary(),
          ),
          const Divider(height: 1),
          Expanded(
            child: _history.isEmpty
                ? Center(
                    child: Text(
                      '填好上面的参数，点"生成方案"开始',
                      style: TextStyle(
                          color: Theme.of(context).hintColor),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: _history.length,
                    itemBuilder: (_, i) {
                      final m = _history[i];
                      if (m['role'] == 'system') return const SizedBox.shrink();
                      return _MessageBubble(
                          role: m['role']!, content: m['content']!);
                    },
                  ),
          ),
          if (_history.isNotEmpty)
            _buildFollowUpBar()
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }

  Widget _missingKeyBanner(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.shade900.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              color: Colors.amber, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text('请先到「设置」配置 AI API Key',
                style: TextStyle(
                    color: Colors.amber.shade200, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// Compact one-line summary shown when the form is collapsed (after the
  /// first message). Tap to expand again.
  Widget _buildFormSummary() {
    final summary =
        '${_originCtrl.text.isEmpty ? "不限出发" : _originCtrl.text} → '
        '${_daysCtrl.text}天 / ${_peopleCtrl.text}人 / ¥${_budgetCtrl.text} '
        '· $_physical / $_financial / $_company';
    return InkWell(
      onTap: () => setState(() => _formExpanded = true),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            const Icon(Icons.tune_rounded, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor)),
            ),
            const Icon(Icons.expand_more_rounded, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _formExpanded = false),
              icon: const Icon(Icons.expand_less_rounded, size: 18),
              label: const Text('收起'),
            ),
          ),
          Row(children: [
            Expanded(child: _num(_budgetCtrl, '预算 (元)')),
            const SizedBox(width: 8),
            Expanded(child: _num(_daysCtrl, '天数')),
            const SizedBox(width: 8),
            Expanded(child: _num(_peopleCtrl, '人数')),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _originCtrl,
            decoration: InputDecoration(
              labelText: '出发地',
              hintText: _resolvingLocation ? '正在获取当前位置…' : null,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4)),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: '用当前位置',
                icon: const Icon(Icons.my_location_rounded, size: 20),
                onPressed: _resolveOrigin,
              ),
            ),
          ),
          if (_autoOriginLabel != null &&
              _originCtrl.text == _autoOriginLabel)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '已自动填入 GPS — 想从别处出发可直接改',
                  style: TextStyle(
                      fontSize: 11, color: Theme.of(context).hintColor),
                ),
              ),
            ),
          const SizedBox(height: 8),
          _dropdown('身体状况', _physical, _physicalOptions,
              (v) => setState(() => _physical = v)),
          const SizedBox(height: 8),
          _dropdown('经济状况', _financial, _financialOptions,
              (v) => setState(() => _financial = v)),
          const SizedBox(height: 8),
          _dropdown('随行人员', _company, _companyOptions,
              (v) => setState(() => _company = v)),
          const SizedBox(height: 8),
          TextField(
            controller: _prefCtrl,
            decoration: InputDecoration(
              labelText: '偏好 / 期待',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4)),
              isDense: true,
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _notesCtrl,
            decoration: InputDecoration(
              labelText: '备注（行程禁忌、特殊要求等）',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4)),
              isDense: true,
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: _running
                ? FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent),
                    icon: const Icon(Icons.stop_rounded),
                    onPressed: _stop,
                    label: const Text('停止生成'),
                  )
                : FilledButton.icon(
                    icon: const Icon(Icons.auto_awesome_rounded),
                    onPressed: _generate,
                    label: Text(_history.isEmpty ? '生成方案' : '重新生成'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFollowUpBar() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border(
              top: BorderSide(
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: 0.2))),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _followCtrl,
                enabled: !_running,
                decoration: const InputDecoration(
                  hintText: '追问 — 比如"再便宜一点"、"详细写第二天行程"…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _sendFollowUp(),
              ),
            ),
            const SizedBox(width: 8),
            if (_running)
              IconButton.filled(
                style: IconButton.styleFrom(
                    backgroundColor: Colors.redAccent),
                icon: const Icon(Icons.stop_rounded),
                onPressed: _stop,
              )
            else
              IconButton.filled(
                icon: const Icon(Icons.send),
                onPressed: _sendFollowUp,
              ),
          ],
        ),
      ),
    );
  }

  Widget _num(TextEditingController c, String label) => TextField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
          isDense: true,
        ),
        keyboardType: TextInputType.number,
      );

  Widget _dropdown(String label, String value, List<String> options,
          ValueChanged<String> onChanged) =>
      InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
          isDense: true,
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            isDense: true,
            isExpanded: true,
            items: options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      );

  String _systemPrompt() => '''
你是旅行规划助手。根据用户输入给出一份具体可行的中文 Markdown 旅行方案。

格式要求：
- 用 ## 二级标题区分"目的地"、"行程概览"、"逐日安排"、"预算拆解"四个部分
- 整体控制在 600 字左右，简洁、可执行
- 不要寒暄、不要重复用户输入、不要插入图片链接

**在 Markdown 结尾必须追加一段 fenced JSON code block**（标记为 ```json），结构如下：
```json
{
  "destination": "目的地中文名",
  "origin": {"name": "出发地名", "lat": 30.65, "lng": 104.07},
  "days": [
    {
      "day": 1,
      "pois": [
        {"name": "景点A", "lat": 30.66, "lng": 104.06, "type": "景点"},
        {"name": "餐馆B", "lat": 30.67, "lng": 104.08, "type": "餐饮"}
      ]
    }
  ],
  "totalKm": 35.2,
  "walkingKm": 8.5
}
```
- 每个 POI 必须给出真实经纬度（你可以参考已知地理知识，给近似值即可，精度到小数点后 3 位）
- type 限定：景点 / 餐饮 / 住宿 / 交通
- totalKm 是全程距离，walkingKm 是其中步行段
- JSON 必须能严格 parse；不要在 JSON 内加注释

如果用户后续追问，针对其追问调整方案，不重列已说过的部分；但**只要方案有任何 POI 变化，整段 JSON 必须重新输出最新完整版**。
''';

  String _initialUserBlob() {
    final lines = <String>[
      '预算：${_budgetCtrl.text} 元',
      '出发地：${_originCtrl.text.isEmpty ? "不限" : _originCtrl.text}',
      '天数：${_daysCtrl.text} 天',
      '人数：${_peopleCtrl.text} 人',
      '偏好：${_prefCtrl.text}',
      '身体状况：$_physical',
      '经济状况：$_financial',
      '随行：$_company',
    ];
    if (_notesCtrl.text.trim().isNotEmpty) {
      lines.add('备注：${_notesCtrl.text.trim()}');
    }
    lines.add('请推荐一个国内或周边的旅行目的地并给出详细方案。');
    return lines.join('\n');
  }

  void _stop() {
    final t = _cancelToken;
    if (t != null && !t.isCancelled) t.cancel('用户手动终止');
  }

  Future<void> _generate() async {
    setState(() {
      _running = true;
      _formExpanded = false; // collapse immediately so chat is visible
      _history
        ..clear()
        ..add({'role': 'system', 'content': _systemPrompt()})
        ..add({'role': 'user', 'content': _initialUserBlob()})
        ..add({'role': 'assistant', 'content': ''}); // placeholder for stream
    });
    _scrollToBottom();
    await _streamInto(_history.length - 1,
        temperature: 0.9, maxTokens: 1200);
  }

  Future<void> _sendFollowUp() async {
    final q = _followCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _running = true;
      _history.add({'role': 'user', 'content': q});
      _history.add({'role': 'assistant', 'content': ''});
      _followCtrl.clear();
    });
    _scrollToBottom();
    await _streamInto(_history.length - 1,
        temperature: 0.7, maxTokens: 800);
  }

  /// Stream the assistant reply into [_history[idx]] character-by-character.
  /// Updates UI ~once per 80ms so we don't rebuild on every token.
  Future<void> _streamInto(int idx,
      {required double temperature, required int maxTokens}) async {
    final settings = ref.read(settingsProvider);
    final ai = ref.read(aiServiceProvider);
    final buf = StringBuffer();
    DateTime lastFlush = DateTime.now();
    _cancelToken = CancelToken();
    try {
      // Drop the placeholder before sending to the model.
      final outgoing = _history.sublist(0, idx);
      await for (final chunk in ai.chatStream(
        settings: settings,
        messages: outgoing,
        temperature: temperature,
        maxTokens: maxTokens,
        cancelToken: _cancelToken,
      )) {
        buf.write(chunk);
        final now = DateTime.now();
        if (now.difference(lastFlush) >
            const Duration(milliseconds: 80)) {
          lastFlush = now;
          if (!mounted) return;
          setState(() => _history[idx] = {
                'role': 'assistant',
                'content': buf.toString(),
              });
          _scrollToBottom();
        }
      }
    } catch (e) {
      buf.write('\n\n**出错：**$e');
    }
    _cancelToken = null;
    if (!mounted) return;
    setState(() {
      final cur = buf.toString();
      _history[idx] = {
        'role': 'assistant',
        'content': cur.isEmpty ? '_(已手动终止)_' : cur,
      };
      _running = false;
    });
    _scrollToBottom();
    // Persist after each completed turn so leaving the screen doesn't lose
    // the conversation.
    await _persist();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }
}

class _MessageBubble extends StatelessWidget {
  final String role;
  final String content;
  const _MessageBubble({required this.role, required this.content});

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    final cs = Theme.of(context).colorScheme;

    // For assistant messages: split out the trailing ```json``` block so
    // the user sees a nice mini-map + stats card instead of raw JSON.
    final plan = isUser ? null : TripPlan.tryParse(content);
    final prose = plan == null
        ? content
        : content
            .replaceAll(
              RegExp(r'```(?:json)?\s*\n[\s\S]*?\n```'),
              '',
            )
            .trim();

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.92),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: isUser
                    ? cs.primaryContainer
                    : cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(4),
              ),
              child: isUser
                  ? SelectableText(content,
                      style: const TextStyle(fontSize: 13))
                  : MarkdownBody(
                      data: prose,
                      selectable: true,
                      imageBuilder: (uri, _, __) {
                        final u = uri.toString();
                        if (!u.startsWith('http')) {
                          return const SizedBox.shrink();
                        }
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            u,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                            loadingBuilder: (_, child, p) =>
                                p == null ? child : const SizedBox.shrink(),
                          ),
                        );
                      },
                    ),
            ),
            if (plan != null) TripMiniMapCard(plan: plan),
          ],
        ),
      ),
    );
  }
}
