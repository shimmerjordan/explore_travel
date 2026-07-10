import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../app/providers.dart';

/// Hardcoded — bumped in lockstep with [pubspec.yaml]'s `version:`. We
/// could read it via `package_info_plus` at runtime, but the extra
/// plugin is the kind of dep this app doesn't otherwise need.
const String _kAppVersion = '0.1.0';
const String _kRepoUrl = 'https://github.com/shimmerjordan/explore_travel';
const String _kRepoOwner = 'shimmerjordan';
const String _kRepoName = 'explore_travel';

/// Docs shipped under `docs/` in the repo. Each entry maps the in-repo
/// path to a title + summary. The doc viewer reads the raw markdown
/// from the asset bundle (declared in `pubspec.yaml -> assets`), so
/// adding a doc means: drop the .md into `docs/` AND append a row here.
const List<({String path, String title, String summary})> _kDocs = [
  (
    path: 'docs/self-host-server-deploy.md',
    title: '自建服务器 · 部署指南',
    summary: '排行榜+组队后端：ECS 上 Docker 一键部署，frpc / Cloudflare Tunnel 暴露公网',
  ),
  (
    path: 'docs/self-host-client-config.md',
    title: '自建服务器 · 客户端配置',
    summary: '排行榜同步与组队云中继的逐步接入配置、排障与流量说明',
  ),
  (
    path: 'docs/leaderboard-server-api.md',
    title: '社区榜单服务器 API',
    summary: 'REST 4+1 端点 / Ed25519 验签 / LWW + TOFU 规范，社区维护者实现参考',
  ),
];

/// Public entry so other screens (group setup, leaderboard) can deep-link
/// straight into a bundled guide without duplicating the viewer.
Future<void> openServerGuide(BuildContext context, {bool client = false}) =>
    _openDoc(
      context,
      client
          ? 'docs/self-host-client-config.md'
          : 'docs/self-host-server-deploy.md',
      client ? '自建服务器 · 客户端配置' : '自建服务器 · 部署指南',
    );

/// Project contributors. The app has no live GitHub API integration —
/// keeping this hardcoded means the credits page works offline. Add
/// yourself here in a PR if you contribute.
const List<({String name, String role})> _kContributors = [
  (name: 'shimmerjordan', role: '原作者 / 主要维护者'),
];

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // App identity card. Version label is a separate widget so it
          // can hold its own tap-counter state without rebuilding the
          // whole screen on every tap.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            c.primary,
                            c.primary.withValues(alpha: 0.6),
                          ]),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.explore_outlined,
                            color: Colors.white, size: 32),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Explore Journal',
                                style:
                                    Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 4),
                            const _VersionTapBadge(version: _kAppVersion),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // GitHub repo card — owner / repo on its own line, big buttons.
          _RepoCard(),
          const SizedBox(height: 12),

          // Docs.
          Card(
            color: c.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text('文档',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final d in _kDocs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.article_outlined),
                      title: Text(d.title),
                      subtitle: Text(d.summary,
                          style: const TextStyle(fontSize: 11)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openDoc(context, d.path, d.title),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Contributors.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('贡献者',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 10),
                  for (final p in _kContributors)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 14,
                            backgroundColor: HSLColor.fromAHSL(
                                    1,
                                    p.name.hashCode.abs() % 360.0,
                                    0.55,
                                    0.55)
                                .toColor(),
                            child: Text(
                                p.name.characters.first.toUpperCase(),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 10),
                          Text(p.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(p.role,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context).hintColor)),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('在 GitHub 提 PR 加入名单'),
                      onPressed: () => _launchExternal(_kRepoUrl),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // License.
          Card(
            color: c.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('许可证',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  const Text('CC BY-NC-SA 4.0',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text(
                      '非商业使用，衍生作品需以相同协议开源 (share-alike)。商业使用需联系作者获得授权。',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    onPressed: () => _launchExternal(
                        'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
                    child: const Text('阅读完整协议 →'),
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

/// Version chip with **visible tap feedback** + 10-tap → debugMode toggle.
///
/// Why a separate widget: previous version sat inline in the screen and
/// suffered from two problems user reported — (a) no visible response per
/// tap so the user couldn't tell taps were counting; (b) the 10-tap path
/// was buried inside a GestureDetector that gave no Material splash.
///
/// New behaviour: each tap pulses the badge (scale + ripple) and updates
/// a small "n / 10" counter that appears after the 1st tap and fades on
/// idle. Reaches 10 → debugMode flips, counter clears.
class _VersionTapBadge extends ConsumerStatefulWidget {
  final String version;
  const _VersionTapBadge({required this.version});
  @override
  ConsumerState<_VersionTapBadge> createState() => _VersionTapBadgeState();
}

class _VersionTapBadgeState extends ConsumerState<_VersionTapBadge>
    with SingleTickerProviderStateMixin {
  int _taps = 0;
  DateTime? _last;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    lowerBound: 0.92,
    upperBound: 1.0,
    value: 1.0,
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _onTap() {
    final now = DateTime.now();
    if (_last != null && now.difference(_last!) > const Duration(seconds: 2)) {
      _taps = 0;
    }
    _last = now;
    _taps++;
    _pulse.value = 0.92;
    _pulse.animateTo(1.0, curve: Curves.easeOut);
    final remaining = 10 - _taps;
    if (_taps >= 10) {
      final s = ref.read(settingsProvider);
      final next = !s.debugMode;
      ref
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(debugMode: next));
      _taps = 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(next ? '已开启调试模式' : '已关闭调试模式'),
          duration: const Duration(seconds: 2)));
    } else if (remaining <= 3) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('再点 $remaining 次进入调试模式'),
          duration: const Duration(milliseconds: 700)));
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final debug = ref.watch(settingsProvider).debugMode;
    final c = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScaleTransition(
          scale: _pulse,
          child: Material(
            color: c.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('v${widget.version}',
                        style: TextStyle(
                            color: c.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                    if (debug) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.error,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('debug',
                            style: TextStyle(
                                color: c.onError,
                                fontSize: 10,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        // Per-tap counter chip — only visible while a tap streak is in
        // progress. Without this the user has no idea whether the taps
        // were registering.
        if (_taps > 0)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: TweenAnimationBuilder<double>(
              key: ValueKey(_taps),
              tween: Tween(begin: 0.6, end: 1.0),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              builder: (_, v, child) =>
                  Opacity(opacity: v, child: child),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: c.tertiaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('$_taps / 10',
                    style: TextStyle(
                        color: c.onTertiaryContainer,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ),
      ],
    );
  }
}

class _RepoCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _launchExternal(_kRepoUrl),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c.onSurface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.code,
                        color: c.surface, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('GitHub',
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                                letterSpacing: 0.8)),
                        Row(
                          children: [
                            Text(_kRepoOwner,
                                style: TextStyle(
                                    fontSize: 14,
                                    color: c.onSurface
                                        .withValues(alpha: 0.65))),
                            const Text(' / ',
                                style: TextStyle(color: Colors.grey)),
                            Text(_kRepoName,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('打开'),
                      onPressed: () => _launchExternal(_kRepoUrl),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('复制 URL'),
                      onPressed: () async {
                        await Clipboard.setData(
                            const ClipboardData(text: _kRepoUrl));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('仓库地址已复制')));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _launchExternal(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Loads the markdown from the asset bundle and pushes a viewer route.
/// On bundle miss falls back to opening the GitHub blob URL.
Future<void> _openDoc(BuildContext context, String path, String title) async {
  try {
    final raw = await DefaultAssetBundle.of(context).loadString(path);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _DocViewerScreen(title: title, body: raw, path: path),
    ));
  } catch (_) {
    await _launchExternal('$_kRepoUrl/blob/main/$path');
  }
}

/// Markdown viewer using `flutter_markdown`. Wraps `MarkdownBody` in a
/// CustomScrollView so flutter_map-style overscroll + scrollbar + page-
/// up/down all work. Previously we shipped a `SelectableText` and the
/// user couldn't scroll past a screenful — that's why this screen
/// exists in its own right rather than reusing the AI plan renderer.
class _DocViewerScreen extends StatelessWidget {
  final String title;
  final String body;
  final String path;
  const _DocViewerScreen(
      {required this.title, required this.body, required this.path});

  Future<void> _share(BuildContext context) async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File(p.join(dir.path, p.basename(path)));
      await f.writeAsString(body);
      await Share.shareXFiles([XFile(f.path)], text: title);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('分享失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = ScrollController();
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: body));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('文档已复制到剪贴板')));
              }
            },
          ),
          IconButton(
            tooltip: '分享',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _share(context),
          ),
        ],
      ),
      // Scrollbar makes long-doc navigation usable on tablets. The
      // `Markdown` widget here is the *full-screen* variant (not the
      // `MarkdownBody`), which owns its own scrollable so paging
      // behaves exactly like a browser doc.
      body: Scrollbar(
        controller: ctrl,
        thumbVisibility: true,
        child: Markdown(
          controller: ctrl,
          data: body,
          selectable: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          onTapLink: (text, href, _) {
            if (href != null) _launchExternal(href);
          },
          // Tighter styles so the doc reads like API reference, not a
          // blog post. Code blocks get a subtle surface tint and
          // monospace stays at a sensible size.
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
              .copyWith(
            p: const TextStyle(fontSize: 14, height: 1.55),
            code: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest,
            ),
            codeblockDecoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            codeblockPadding: const EdgeInsets.all(10),
            blockquoteDecoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest,
              border: Border(
                left: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 3),
              ),
            ),
            h1: Theme.of(context).textTheme.titleLarge,
            h2: Theme.of(context).textTheme.titleMedium,
            h3: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      ),
    );
  }
}
