import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'dart:io';

import '../../app/providers.dart';
import '../../services/ai/ai_service.dart';
import '../common/empty_state.dart';
import '../common/failure.dart';
import '../common/status_palette.dart';

/// AI 服务设置 —— 从原设置页的三字段小抽屉升级成完整页面：
/// 对话模型 / 图片理解 / 人设、语音识别（STT）、语音合成（TTS，三引擎多音色）、
/// 通话数据管理。地图页 AI 旅伴卡片的 ⚙ 直达这里。
class AiSettingsScreen extends ConsumerStatefulWidget {
  const AiSettingsScreen({super.key});
  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  // 对话连通性测试
  bool _pinging = false;
  AiPingResult? _pingResult;

  // TTS 试听
  bool _speaking = false;
  String? _speakStatus;
  final AudioPlayer _player = AudioPlayer();

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _ping() async {
    setState(() {
      _pinging = true;
      _pingResult = null;
    });
    final r =
        await ref.read(aiServiceProvider).ping(ref.read(settingsProvider));
    if (mounted) {
      setState(() {
        _pinging = false;
        _pingResult = r;
      });
    }
  }

  Future<void> _preview() async {
    setState(() {
      _speaking = true;
      _speakStatus = '合成中…';
    });
    const line = '你好呀，我是小岚，你的旅行搭子！接下来的路，一起走。';
    final tts = ref.read(ttsServiceProvider);
    final s = ref.read(settingsProvider);
    try {
      if (tts.playsItself(s)) {
        if (mounted) setState(() => _speakStatus = '播放中…');
        await tts
            .speakDirect(settings: s, text: line)
            .timeout(const Duration(seconds: 30));
      } else {
        final bytes = await tts
            .synthesize(settings: s, text: line)
            .timeout(const Duration(seconds: 30));
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/tts_preview.mp3');
        await f.writeAsBytes(bytes, flush: true);
        await _player.setFilePath(f.path);
        if (mounted) setState(() => _speakStatus = '播放中…');
        await _player.play();
        await _player.stop();
      }
      if (mounted) setState(() => _speakStatus = '✅ 正常');
    } catch (e) {
      debugPrint('[UI] TTS 试听 失败: $e');
      // '❌' 前缀是这条状态的上色依据（见下面的 subtitle），保留。
      if (mounted) {
        setState(() => _speakStatus = '❌ ${failureMessage('试听', e)}');
      }
    } finally {
      if (mounted) setState(() => _speaking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 服务',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: '保存（输入时已自动保存，按此再次确认）',
            icon: const Icon(Icons.check_rounded),
            onPressed: () {
              FocusScope.of(context).unfocus();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('已保存'), duration: Duration(seconds: 1)));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.smart_toy_outlined, size: 18, color: cs.primary),
                  const SizedBox(width: 6),
                  const Text('这里配置什么',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 8),
                const Text(
                  '地图页的 AI 旅伴（文字聊天 + 语音通话）、AI 旅行规划和旅行歌单共用这套配置。\n'
                  '· 对话/识别走任何 OpenAI 兼容接口，默认硅基流动（识别用 SenseVoice，免费）。\n'
                  '· 语音合成三选一：系统引擎免费离线；火山引擎付费但音色最好（湾湾小何）；'
                  'OpenAI 兼容可接硅基流动 CosyVoice 等。',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),

          // 一个字段都没填时，下面每一栏都是空的，而「测试连接」只会失败；
          // 先说清缺的是哪两格。
          if ((s.aiBaseUrl ?? '').trim().isEmpty &&
              (s.aiApiKey ?? '').trim().isEmpty)
            const EmptyState(
              title: '还没有接上 AI 服务',
              hint: '把下面的「Base URL」和「API Key」填好，旅伴、语音通话和 AI 规划'
                  '就都能用了。',
              expand: false,
            ),

          // ── 对话模型 ────────────────────────────────────────────────────
          const _SectionHeader('对话模型（OpenAI 兼容）'),
          _Text('Base URL', s.aiBaseUrl ?? '',
              (v) => n.update((p) => p.copyWith(aiBaseUrl: v)),
              hint: 'https://api.siliconflow.cn/v1'),
          _Text('API Key', s.aiApiKey ?? '',
              (v) => n.update((p) => p.copyWith(aiApiKey: v)),
              obscure: true),
          _Text('对话模型', s.aiModel,
              (v) => n.update((p) => p.copyWith(aiModel: v)),
              hint: 'Qwen/Qwen2.5-7B-Instruct'),
          _Text('图片理解模型（选填）', s.aiVisionModel,
              (v) => n.update((p) => p.copyWith(aiVisionModel: v)),
              hint: '留空则发图片时也用上面的对话模型，如 Qwen/Qwen2.5-VL-32B-Instruct'),
          _Text('旅伴人设（选填）', s.aiPersona,
              (v) => n.update((p) => p.copyWith(aiPersona: v)),
              hint: '留空用内置的「小岚」——想换个性格/名字就写在这',
              maxLines: 3),
          ListTile(
            leading: Icon(
                _pingResult == null
                    ? Icons.bolt_rounded
                    : _pingResult!.success
                        ? Icons.check_circle_rounded
                        : Icons.error_rounded,
                color: _pingResult == null
                    ? cs.onSurfaceVariant
                    : _pingResult!.success
                        ? Theme.of(context).status.success
                        : cs.error),
            title: const Text('测试连接'),
            subtitle: Text(
              _pingResult == null
                  ? '发一条 "ok" 验证当前配置'
                  : _pingResult!.success
                      ? '✅ ${_pingResult!.latencyMs}ms — ${_pingResult!.message}'
                      : '❌ ${_pingResult!.message}',
              maxLines: 3,
            ),
            trailing: _pinging
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _pinging ? null : _ping,
          ),

          // ── 语音识别 ────────────────────────────────────────────────────
          const _SectionHeader('语音识别（通话时听你说）'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Wrap(spacing: 8, children: [
              _preset('硅基流动 · 免费', () {
                n.update((p) => p.copyWith(
                    sttBaseUrl: 'https://api.siliconflow.cn/v1',
                    sttModel: 'FunAudioLLM/SenseVoiceSmall'));
              }),
              _preset('Groq Whisper', () {
                n.update((p) => p.copyWith(
                    sttBaseUrl: 'https://api.groq.com/openai/v1',
                    sttModel: 'whisper-large-v3-turbo'));
              }),
              _preset('OpenAI', () {
                n.update((p) => p.copyWith(
                    sttBaseUrl: 'https://api.openai.com/v1',
                    sttModel: 'gpt-4o-mini-transcribe'));
              }),
            ]),
          ),
          _Text('识别 Base URL', s.sttBaseUrl,
              (v) => n.update((p) => p.copyWith(sttBaseUrl: v))),
          _Text('识别 API Key（选填）', s.sttApiKey ?? '',
              (v) => n.update((p) => p.copyWith(sttApiKey: v)),
              hint: '留空复用上面对话的 API Key', obscure: true),
          _Text('识别模型', s.sttModel,
              (v) => n.update((p) => p.copyWith(sttModel: v))),

          // ── 语音合成 ────────────────────────────────────────────────────
          const _SectionHeader('语音合成（通话时它说话）'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('系统 · 免费')),
                ButtonSegment(value: 'volcano', label: Text('火山引擎')),
                ButtonSegment(value: 'openai', label: Text('OpenAI 兼容')),
              ],
              selected: {s.ttsEngine},
              onSelectionChanged: (v) =>
                  n.update((p) => p.copyWith(ttsEngine: v.first)),
            ),
          ),
          if (s.ttsEngine == 'system') ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                  '用手机自带的语音引擎朗读：免费、离线、零流量。想换音色/引擎去'
                  '系统设置 → 无障碍（或「更多设置」）→ 文字转语音 里调。',
                  style: TextStyle(fontSize: 11, height: 1.4)),
            ),
          ] else if (s.ttsEngine == 'volcano') ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Wrap(spacing: 8, children: [
                for (final v in const [
                  ('湾湾小何', 'zh_female_wanwanxiaohe_moon_bigtts'),
                  ('爽快思思', 'zh_female_shuangkuaisisi_moon_bigtts'),
                  ('温暖阿虎', 'zh_male_wennuanahu_moon_bigtts'),
                  ('灿灿', 'zh_female_cancan_mars_bigtts'),
                ])
                  _preset(v.$1,
                      () => n.update((p) => p.copyWith(volcTtsVoice: v.$2))),
              ]),
            ),
            _Text('AppID', s.volcTtsAppId ?? '',
                (v) => n.update((p) => p.copyWith(volcTtsAppId: v))),
            _Text('Access Token', s.volcTtsToken ?? '',
                (v) => n.update((p) => p.copyWith(volcTtsToken: v)),
                obscure: true),
            _Text('音色 voice_type', s.volcTtsVoice,
                (v) => n.update((p) => p.copyWith(volcTtsVoice: v))),
            _Text('Cluster', s.volcTtsCluster,
                (v) => n.update((p) => p.copyWith(volcTtsCluster: v)),
                hint: '默认 volcano_tts'),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                  '在火山引擎控制台开通「语音合成大模型」并订购音色后，把 AppID / Token 填进来。'
                  '湾湾小何等大模型音色需单独开通。',
                  style: TextStyle(fontSize: 11, height: 1.4)),
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Wrap(spacing: 8, children: [
                _preset('硅基流动 CosyVoice2', () {
                  n.update((p) => p.copyWith(
                      ttsBaseUrl: 'https://api.siliconflow.cn/v1',
                      ttsModel: 'FunAudioLLM/CosyVoice2-0.5B',
                      ttsVoice: 'FunAudioLLM/CosyVoice2-0.5B:anna'));
                }),
                _preset('OpenAI tts-1', () {
                  n.update((p) => p.copyWith(
                      ttsBaseUrl: 'https://api.openai.com/v1',
                      ttsModel: 'tts-1',
                      ttsVoice: 'alloy'));
                }),
                _preset('自建 EdgeTTS 中转', () {
                  n.update((p) => p.copyWith(
                      ttsModel: 'edge-tts',
                      ttsVoice: 'zh-CN-XiaoxiaoNeural'));
                }),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                  '想白嫖微软 EdgeTTS 音色：在 NAS 上跑仓库里的 '
                  'tools/edge_tts_proxy.py（pip install edge-tts 即可），'
                  'Base URL 填 http://NAS地址:8123/v1，voice 填 Edge 音色名。',
                  style: TextStyle(fontSize: 11, height: 1.4)),
            ),
            _Text('合成 Base URL', s.ttsBaseUrl,
                (v) => n.update((p) => p.copyWith(ttsBaseUrl: v))),
            _Text('合成 API Key（选填）', s.ttsApiKey ?? '',
                (v) => n.update((p) => p.copyWith(ttsApiKey: v)),
                hint: '留空复用对话的 API Key', obscure: true),
            _Text('合成模型', s.ttsModel,
                (v) => n.update((p) => p.copyWith(ttsModel: v))),
            _Text('音色 voice', s.ttsVoice,
                (v) => n.update((p) => p.copyWith(ttsVoice: v)),
                hint: 'CosyVoice 写成 模型:音色，如 …CosyVoice2-0.5B:anna'),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Row(children: [
              const Text('语速', style: TextStyle(fontSize: 13)),
              Expanded(
                child: Slider(
                  value: s.ttsSpeed.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  label: '×${s.ttsSpeed.toStringAsFixed(1)}',
                  onChanged: (v) => n.update((p) => p.copyWith(ttsSpeed: v)),
                ),
              ),
              SizedBox(
                  width: 38,
                  child: Text('×${s.ttsSpeed.toStringAsFixed(1)}',
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace'))),
            ]),
          ),
          ListTile(
            leading: Icon(Icons.volume_up_rounded, color: cs.primary),
            title: const Text('试听当前音色'),
            subtitle: Text(_speakStatus ?? '合成一句欢迎语立即播放',
                maxLines: 2,
                style: TextStyle(
                    color: (_speakStatus ?? '').startsWith('❌')
                        ? cs.error
                        : null)),
            trailing: _speaking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _speaking ? null : _preview,
          ),

          // ── 数据 ────────────────────────────────────────────────────────
          const _SectionHeader('对话数据'),
          ListTile(
            leading: Icon(Icons.delete_sweep_outlined, color: cs.error),
            title: const Text('清空旅伴聊天记录'),
            subtitle: const Text('删除旅伴的全部历史会话（卡片的「历史」Tab 里也能按段管理），'
                'AI 规划的会话不受影响'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (dctx) => AlertDialog(
                  title: const Text('清空聊天记录？'),
                  content: const Text('与旅伴的全部对话将被删除，无法恢复。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dctx, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dctx, true),
                        child: const Text('清空')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(companionProvider).clearHistory();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已清空')));
                }
              }
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _preset(String label, VoidCallback onTap) => ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      );
}

// ── 与图床设置页同款的小组件（保持全 app 设置页语言一致）────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
      ),
      child: child,
    );
  }
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

class _Text extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool obscure;
  final int maxLines;
  const _Text(this.label, this.value, this.onChanged,
      {this.hint, this.obscure = false, this.maxLines = 1});
  @override
  State<_Text> createState() => _TextState();
}

class _TextState extends State<_Text> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _Text old) {
    super.didUpdateWidget(old);
    // 预设 chip 等外部改动要同步进输入框；用户正在敲字时不去打架。
    if (widget.value != old.value && widget.value != _ctrl.text) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: TextField(
        controller: _ctrl,
        obscureText: widget.obscure,
        maxLines: widget.obscure ? 1 : widget.maxLines,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          hintStyle: const TextStyle(fontSize: 12),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}
