import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../common/empty_state.dart';
import '../common/failure.dart';
import '../common/status_palette.dart';
import 'cookie_webview_screen.dart';

/// "音乐平台配置" — five sources presented as peers, with credential entry
/// per platform.
///
/// Honest truth: today every search still resolves through GD 音乐台's
/// aggregator. The credential fields here are stored for the upcoming
/// direct-backend integration — they don't change current behaviour. This
/// is called out at the top of the page so users aren't surprised.
class MusicSourcesScreen extends ConsumerStatefulWidget {
  const MusicSourcesScreen({super.key});
  @override
  ConsumerState<MusicSourcesScreen> createState() =>
      _MusicSourcesScreenState();
}

class _MusicSourcesScreenState
    extends ConsumerState<MusicSourcesScreen> {
  final Map<String, String?> _status = {};
  final Set<String> _testing = {};

  static const _sources = ['gd', 'netease', 'kuwo', 'joox'];
  static const _meta = <String, _Meta>{
    'gd': _Meta(
      label: 'GD 音乐台',
      note: '聚合接口，无需登录。失败回退用。',
      stable: true,
      direct: false,
      authKind: _Auth.none,
    ),
    'netease': _Meta(
      label: '网易云音乐',
      note: '✅ 直连 music.163.com linuxapi。免费曲目无需登录；VIP 需 MUSIC_U Cookie。'
          '注意：MUSIC_U 是 HttpOnly，WebView 取不到——若需要 VIP 请按指引手填。',
      stable: true,
      direct: true,
      authKind: _Auth.cookie,
      loginUrl: 'https://music.163.com/#/login',
      loginKeepKeys: ['MUSIC_U', '__csrf', 'NMTID'],
    ),
    'kuwo': _Meta(
      label: '酷我音乐',
      note: '✅ 直连 kuwo.cn 公开 JSON 接口。免费曲目无需登录；VIP 需 Cookie。',
      stable: true,
      direct: true,
      authKind: _Auth.cookie,
      loginUrl: 'https://www.kuwo.cn/',
      loginKeepKeys: ['kw_token', 't', 'userid'],
    ),
    'joox': _Meta(
      label: 'JOOX',
      note: '✅ 直连 api-jooxtt.sanook.com 公开接口。港台为主。',
      stable: true,
      direct: true,
      authKind: _Auth.cookie,
      loginUrl: 'https://www.joox.com/',
      loginKeepKeys: ['wmid'],
    ),
  };

  Future<void> _test(String source) async {
    setState(() {
      _testing.add(source);
      _status[source] = null;
    });
    final svc = ref.read(musicServiceProvider);
    try {
      final r = await svc.search('hello', source: source, count: 3);
      if (mounted) {
        setState(() => _status[source] =
            r.isEmpty ? '空 — gdstudio 后端可能未登录或被限流' : 'ok · ${r.length} 首');
      }
    } catch (e) {
      debugPrint('[UI] 音乐平台 $source 测试 失败: $e');
      if (mounted) setState(() => _status[source] = failureMessage('测试', e));
    } finally {
      if (mounted) setState(() => _testing.remove(source));
    }
  }

  Future<void> _loginViaWebview(String source, _Meta m) async {
    if (m.loginUrl == null) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CookieWebViewScreen(
          source: source,
          platformLabel: m.label,
          startUrl: m.loginUrl!,
          keepKeys: m.loginKeepKeys,
        ),
      ),
    );
    if (mounted) setState(() {}); // refresh credential indicator
  }

  Future<void> _editCredential(String source, _Meta m) async {
    final s = ref.read(settingsProvider);
    final ctrl = TextEditingController(text: s.musicCredentials[source] ?? '');
    final saved = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${m.label} · ${m.authKind.label}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.authKind.hint,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).hintColor)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              maxLines: 3,
              minLines: 1,
              autofocus: true,
              decoration: InputDecoration(
                hintText: m.authKind.placeholder,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                // 只是给这段说明染一层警示底色；正文仍用 onSurface（亮 13.65:1 /
                // 暗 8.62:1），所以这里跟随主题的警告色比固定的 orangeAccent 稳。
                color: Theme.of(context)
                    .status
                    .warning
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                '⚠️ 当前版本搜索仍走 GD 音乐台代理。此处填的凭证会保存，'
                '等下一版直连后端上线后自动启用。',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('清空')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (saved == null) return;
    final updated = {...s.musicCredentials};
    if (saved.isEmpty) {
      updated.remove(source);
    } else {
      updated[source] = saved;
    }
    await ref
        .read(settingsProvider.notifier)
        .update((p) => p.copyWith(musicCredentials: updated));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('音乐平台配置',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    const Text('诚实说明',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '✅ 网易云 / 酷我 / JOOX：已实现直连，搜索和播放走各自官方接口。\n'
                  'GD 音乐台：聚合接口，作为兜底。\n'
                  '海外平台（Spotify / Apple Music 等）暂未支持——它们都需要付费 SDK '
                  '或服务端 JWT 签名，纯 HTTP 拿不到完整流。\n\n'
                  '免费曲目无需登录。VIP 曲目需要在下方填该平台的 Cookie。'
                  '点"测试"看当前是否能搜出歌。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
              ],
            ),
          ),
          ..._sources.map((src) {
            final m = _meta[src]!;
            final status = _status[src];
            final busy = _testing.contains(src);
            final isOk = status != null && status.startsWith('ok');
            // 失败文案已统一成「测试失败 · …」，不再有 'error' 前缀可认；
            // 除了明确 ok 的，其余有状态的都按失败上色。
            final isError = status != null && !isOk;
            final hasCred = (s.musicCredentials[src] ?? '').isNotEmpty;
            return Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 4),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(m.label,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600)),
                          ),
                          if (m.direct)
                            const Padding(
                              padding: EdgeInsets.only(right: 6),
                              child: _Tag(
                                  text: '直连',
                                  color: Colors.lightBlueAccent),
                            ),
                          _Tag(
                            // _Tag 把同一枚色当文字色、又当 0.18 的底色，等于
                            // 自己降自己的对比度；语义色板在这种自染底上仍有
                            // 亮 4.7:1 / 暗 5.3:1，Material 直出的两枚不行。
                            text: m.stable ? '稳定' : '实验性',
                            color: m.stable
                                ? Theme.of(context).status.success
                                : Theme.of(context).status.warning,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(m.note,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).hintColor)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          if (busy)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          else
                            Icon(
                              status == null
                                  ? Icons.help_outline
                                  : (isOk
                                      ? Icons.check_circle
                                      : Icons.error_outline),
                              size: 16,
                              color: status == null
                                  ? Theme.of(context).hintColor
                                  : (isOk
                                      ? Theme.of(context).status.success
                                      : Theme.of(context).status.danger),
                            ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              status ?? '尚未测试',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: status == null
                                      ? Theme.of(context).hintColor
                                      : (isOk
                                          ? Theme.of(context).status.success
                                          : (isError
                                              ? Theme.of(context).status.danger
                                              : null))),
                            ),
                          ),
                          TextButton(
                            onPressed: busy ? null : () => _test(src),
                            child: const Text('测试'),
                          ),
                        ],
                      ),
                      if (m.authKind != _Auth.none)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Icon(
                                hasCred
                                    ? Icons.lock_outlined
                                    : Icons.lock_open_outlined,
                                size: 16,
                                color: hasCred ? cs.primary : null,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  hasCred
                                      ? '已保存 ${m.authKind.label}（${(s.musicCredentials[src]!.length)} 字符）'
                                      : '未配置 ${m.authKind.label}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              if (m.loginUrl != null)
                                TextButton.icon(
                                  icon:
                                      const Icon(Icons.login, size: 16),
                                  onPressed: () =>
                                      _loginViaWebview(src, m),
                                  label: const Text('登录'),
                                ),
                              TextButton(
                                onPressed: () =>
                                    _editCredential(src, m),
                                child: Text(hasCred ? '改' : '手填'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
          // 一份凭证都没存时，这页只是四张「未配置」的卡片；说清这不算没配好，
          // 并指到真正要用的那两个按钮上。
          if (!_sources.any(
              (src) => (s.musicCredentials[src] ?? '').isNotEmpty))
            const EmptyState(
              title: '还没有保存任何平台凭证',
              hint: '免费曲目不登录也能搜、能放。想听 VIP 曲目，在对应平台上点「登录」'
                  '或「手填」存一份 Cookie。',
              expand: false,
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

enum _Auth {
  none(label: '无需登录', hint: '', placeholder: ''),
  cookie(
    label: 'Cookie',
    hint: '浏览器登录后，从开发者工具复制完整的 Cookie 字符串',
    placeholder: 'MUSIC_U=xxx; __csrf=xxx; ...',
  );

  final String label;
  final String hint;
  final String placeholder;
  const _Auth({
    required this.label,
    required this.hint,
    required this.placeholder,
  });
}

class _Meta {
  final String label;
  final String note;
  final bool stable;
  final bool direct;
  final _Auth authKind;
  /// If set, "登录" button is shown and opens this URL in an in-app
  /// WebView. After login, [loginKeepKeys] cookies are saved.
  final String? loginUrl;
  final List<String> loginKeepKeys;
  const _Meta({
    required this.label,
    required this.note,
    required this.stable,
    required this.direct,
    required this.authKind,
    this.loginUrl,
    this.loginKeepKeys = const [],
  });
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag({required this.text, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600)),
    );
  }
}
