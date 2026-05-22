import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../app/providers.dart' show settingsProvider, SettingsNotifier;
import '../../core/prefs.dart';
import '../../services/imghost/imghost_service.dart';

/// 图床配置页：在"手账设置 → 图床"里出现。三种模式：none / github / custom。
/// 保存时本地优先，后台异步上传，失败可在手账详情里手动重试。
class ImgHostSettingsScreen extends ConsumerStatefulWidget {
  const ImgHostSettingsScreen({super.key});
  @override
  ConsumerState<ImgHostSettingsScreen> createState() =>
      _ImgHostSettingsScreenState();
}

class _ImgHostSettingsScreenState
    extends ConsumerState<ImgHostSettingsScreen> {
  String? _testStatus;
  bool _testing = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('手账图床',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: '保存（输入时已自动保存，按此再次确认）',
            icon: const Icon(Icons.check_rounded),
            onPressed: () {
              // Auto-save already runs on every keystroke; this just dismisses
              // any focused field (so a pending IME composition flushes) and
              // shows a visible confirmation.
              FocusScope.of(context).unfocus();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已保存'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _Card(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.cloud_outlined, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                const Text('图床做什么',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 8),
              const Text(
                '保存手账时本地优先，后台异步上传到你选的图床。上传完成后正文与媒体里的本地路径'
                '会自动替换成远程 URL，备份与跨机访问就稳定了。删除手账时会顺手把远程文件也删掉。\n\n'
                '⚠️ 公开 GitHub repo = 全网可见，别放敏感照片。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ],
          )),
          const _SectionHeader('图床来源'),
          RadioListTile<String>(
            value: 'none',
            groupValue: s.imgHostKind,
            title: const Text('不使用图床（仅存本地路径）'),
            onChanged: (v) =>
                n.update((p) => p.copyWith(imgHostKind: v ?? 'none')),
          ),
          RadioListTile<String>(
            value: 'github',
            groupValue: s.imgHostKind,
            title: const Text('GitHub + CDN'),
            subtitle: const Text(
                '直推 Contents API，jsDelivr/Statically 加速展示'),
            onChanged: (v) =>
                n.update((p) => p.copyWith(imgHostKind: v ?? 'none')),
          ),
          RadioListTile<String>(
            value: 'custom',
            groupValue: s.imgHostKind,
            title: const Text('自定义（兼容 Chevereto / 兰空 / EasyImage 等）'),
            onChanged: (v) =>
                n.update((p) => p.copyWith(imgHostKind: v ?? 'none')),
          ),
          if (s.imgHostKind == 'github') ..._buildGithubFields(s, n),
          if (s.imgHostKind == 'custom') ..._buildCustomFields(s, n),
          const _SectionHeader('连通性测试'),
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: const Text('上传一张测试图'),
            subtitle: Text(_testStatus ?? '尚未测试',
                style: TextStyle(
                    color: _testStatus == null
                        ? Theme.of(context).hintColor
                        : (_testStatus!.startsWith('ok')
                            ? Colors.green
                            : Colors.redAccent))),
            trailing: _testing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _testing ? null : _runTest,
          ),
        ],
      ),
    );
  }

  Future<void> _runTest() async {
    setState(() {
      _testing = true;
      _testStatus = null;
    });
    try {
      final backend = backendFromSettings(ref.read(settingsProvider));
      // Public test path is fine — private repos get tested via the same
      // test image but you'd need to pass level='private' to switch repos.
      // 1x1 transparent PNG.
      const bytes = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
      ];
      final tmp = await getTemporaryDirectory();
      final f = File('${tmp.path}/imghost_test.png');
      await f.writeAsBytes(bytes);
      final res = await backend.upload(f,
          ctx: const UploadContext(
              journalId: 0, level: 'public', titleSlug: 'test'));
      if (mounted) {
        setState(() => _testStatus = 'ok · ${res.displayUrl}');
      }
    } catch (e) {
      if (mounted) setState(() => _testStatus = 'error: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  // ── GitHub fields ──────────────────────────────────────────────────────

  List<Widget> _buildGithubFields(AppSettings s, SettingsNotifier n) {
    return [
      const _SectionHeader('GitHub 仓库'),
      _Text('Owner（用户名 / 组织）', s.githubOwner ?? '',
          (v) => n.update((p) => p.copyWith(githubOwner: v.isEmpty ? null : v))),
      _Text('Repo', s.githubRepo ?? '',
          (v) => n.update((p) => p.copyWith(githubRepo: v.isEmpty ? null : v))),
      _Text('Branch', s.githubBranch,
          (v) => n.update((p) => p.copyWith(githubBranch: v))),
      _Text(
          'Personal Access Token（contents:write）', s.githubPat ?? '',
          (v) => n.update((p) => p.copyWith(githubPat: v.isEmpty ? null : v)),
          obscure: true),
      _Text('仓库内路径前缀', s.githubPathPrefix,
          (v) => n.update((p) => p.copyWith(githubPathPrefix: v)),
          hint: '例如 media — 最终路径会变成 media/yyyy/mm/<手账id>/<uuid>.jpg'),
      _Text('CDN URL 模板', s.githubCdnTemplate,
          (v) => n.update((p) => p.copyWith(githubCdnTemplate: v)),
          hint:
              '默认走 jsDelivr。国内访问受限可换 https://cdn.statically.io/gh/{user}/{repo}/{branch}/{path}'),
      const _SectionHeader('Private 手账（独立私有仓）'),
      _Text('Private Owner', s.githubPrivateOwner ?? '',
          (v) => n.update(
              (p) => p.copyWith(githubPrivateOwner: v.isEmpty ? null : v))),
      _Text('Private Repo', s.githubPrivateRepo ?? '',
          (v) => n.update(
              (p) => p.copyWith(githubPrivateRepo: v.isEmpty ? null : v))),
      _Text('Private Branch', s.githubPrivateBranch,
          (v) => n.update((p) => p.copyWith(githubPrivateBranch: v))),
      _Text('Private PAT（contents:write, repo 权限）',
          s.githubPrivatePat ?? '',
          (v) =>
              n.update((p) => p.copyWith(githubPrivatePat: v.isEmpty ? null : v)),
          obscure: true,
          hint: '私有仓加载图片时也会用这个 token；和上面那个公开 token 分开'),
      _Text('Private 路径前缀', s.githubPrivatePathPrefix,
          (v) => n.update((p) => p.copyWith(githubPrivatePathPrefix: v))),
    ];
  }

  // ── Custom fields ──────────────────────────────────────────────────────

  List<Widget> _buildCustomFields(AppSettings s, SettingsNotifier n) {
    return [
      const _SectionHeader('自定义图床'),
      _Text('上传 URL', s.customUploadUrl ?? '',
          (v) =>
              n.update((p) => p.copyWith(customUploadUrl: v.isEmpty ? null : v)),
          hint: 'POST multipart/form-data'),
      _Text('文件字段名', s.customFileField,
          (v) => n.update((p) => p.copyWith(customFileField: v)),
          hint: '常见值：file / image / smfile'),
      _Text('返回 URL 字段路径（点号分隔）', s.customResponseUrlPath,
          (v) => n.update((p) => p.copyWith(customResponseUrlPath: v)),
          hint: '例如 data.url / data.links.url'),
      _Text('展示 URL 模板', s.customDisplayUrlTemplate,
          (v) => n.update((p) => p.copyWith(customDisplayUrlTemplate: v)),
          hint: '默认 {url}。如果上传只给路径，可以拼前缀'),
      _Text('删除 URL 模板（可选）', s.customDeleteUrlTemplate,
          (v) => n.update((p) => p.copyWith(customDeleteUrlTemplate: v)),
          hint: '留空则删除时只清本地引用'),
      _Text('Authorization 头（可选）', s.customAuthHeader,
          (v) => n.update((p) => p.copyWith(customAuthHeader: v)),
          hint: '例如 Bearer xxx 或 Basic yyy',
          obscure: true),
    ];
  }
}

// ── tiny shared widgets — kept inline to avoid yet another helper file. ──

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
        borderRadius: BorderRadius.circular(14),
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

/// Stateful so the controller survives parent rebuilds — otherwise typing
/// would jitter the cursor and lose draft input every keystroke that
/// triggered an outer setState.
class _Text extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool obscure;
  const _Text(this.label, this.value, this.onChanged,
      {this.hint, this.obscure = false});
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
    // Only push external value changes in when they differ from the live
    // text — avoids fighting the user mid-typing.
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
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        // Live auto-save: every keystroke writes to SharedPreferences via
        // the settings notifier. Plenty fast for text-field volume.
        onChanged: widget.onChanged,
      ),
    );
  }
}
