import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import '../../app/providers.dart';
import '../../core/prefs.dart';
import '../../services/backup/backup_service.dart';

/// 统一备份页：模块选择 + 本地导出/导入 + WebDAV 上传/恢复。
/// 所有路径都走 [BackupService] 的模块化 JSON 格式 —— 本地文件和 WebDAV
/// 备份是可互换的：本地导出能丢到 WebDAV，WebDAV 拉下来也能本地导入。
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});
  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  /// Live module selection — backed by AppSettings so the choice survives
  /// app restarts. Empty list (the default) means "all modules".
  Set<String> _selectedModules(AppSettings s) {
    if (s.backupSelectedModules.isEmpty) {
      return {...BackupService.allModules};
    }
    return s.backupSelectedModules.toSet();
  }
  bool _busy = false;
  String? _status;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final cs = Theme.of(context).colorScheme;

    final webdavReady = (s.webdavUrl ?? '').isNotEmpty &&
        (s.webdavUser ?? '').isNotEmpty &&
        (s.webdavPass ?? '').isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('备份与导出',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: '保存（输入时已自动保存，按此再次确认）',
            icon: const Icon(Icons.check_rounded),
            onPressed: () {
              // Live-save runs on every keystroke; this just dismisses
              // any focused field (so a pending IME composition flushes)
              // and shows a visible confirmation.
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
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
            ),
            child: const Text(
              '所有备份打包成同一种 zip 存档：每个模块独立目录，迷雾按瓦片分块（参考世界迷雾），'
              '轨迹按月分文件、聊天按对端分文件。本地导出 / WebDAV 上传共用同一份字节，互通。',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
          ),

          // ── 模块选择 ──────────────────────────────────────────────────
          const _SectionHeader('选择模块'),
          ...BackupService.allModules.map((k) {
            final selected = _selectedModules(s);
            return CheckboxListTile(
              value: selected.contains(k),
              title: Text(BackupService.moduleLabels[k] ?? k),
              onChanged: (v) {
                final next = {...selected};
                if (v == true) {
                  next.add(k);
                } else {
                  next.remove(k);
                }
                n.update((p) =>
                    p.copyWith(backupSelectedModules: next.toList()..sort()));
              },
            );
          }),

          // ── 本地导出 / 导入 ────────────────────────────────────────────
          const _SectionHeader('本地文件'),
          ListTile(
            leading: const Icon(Icons.ios_share_rounded),
            title: const Text('导出 zip 并分享'),
            subtitle: const Text('写到 documents/ 下，调起系统分享面板'),
            enabled: !_busy,
            onTap: _busy ? null : _exportAndShare,
          ),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('从本地 zip 导入'),
            subtitle: const Text('只导入勾选的模块'),
            enabled: !_busy,
            onTap: _busy ? null : _pickAndImport,
          ),

          // ── WebDAV ────────────────────────────────────────────────────
          const _SectionHeader('WebDAV 云端'),
          _TextSetting(Icons.link_rounded, '服务器地址', s.webdavUrl ?? '',
              (v) => n.update((p) => p.copyWith(webdavUrl: v.isEmpty ? null : v)),
              hint: '需带 https://，例如 https://dav.jianguoyun.com/dav/'),
          _TextSetting(Icons.person_rounded, '用户名', s.webdavUser ?? '',
              (v) => n.update((p) => p.copyWith(webdavUser: v.isEmpty ? null : v))),
          _TextSetting(Icons.lock_rounded, '密码 / 应用授权码', s.webdavPass ?? '',
              (v) => n.update((p) => p.copyWith(webdavPass: v.isEmpty ? null : v)),
              obscure: true),
          ListTile(
            leading: const Icon(Icons.network_check_rounded),
            title: const Text('测试 WebDAV 连接'),
            subtitle: Text(webdavReady
                ? '会创建 /explore_journal/ 并尝试列目录'
                : '先填上面的 WebDAV 配置'),
            enabled: webdavReady && !_busy,
            onTap: (webdavReady && !_busy) ? _testWebdav : null,
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload_rounded),
            title: const Text('立即上传到 WebDAV'),
            subtitle: Text(webdavReady
                ? '会上传一份带时间戳的 zip 并刷新 latest.zip'
                : '先填上面的服务器地址 / 账号 / 密码'),
            enabled: webdavReady && !_busy,
            onTap: (webdavReady && !_busy) ? _uploadToWebdav : null,
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download_rounded),
            title: const Text('从 WebDAV 恢复'),
            subtitle: Text(webdavReady
                ? '列出云端备份，选一份还原（按勾选模块）'
                : '先填上面的 WebDAV 配置'),
            enabled: webdavReady && !_busy,
            onTap: (webdavReady && !_busy) ? _restoreFromWebdav : null,
          ),

          // ── 高级 ──────────────────────────────────────────────────────
          const _SectionHeader('高级'),
          SwitchListTile(
            secondary: const Icon(Icons.delete_sweep_outlined),
            title: const Text('导入前清空对应模块'),
            subtitle: const Text(
                '关：增量合并（按 UUID 去重）；开：先 DELETE 再写入'),
            value: s.importClearBeforeImport,
            onChanged: (v) =>
                n.update((p) => p.copyWith(importClearBeforeImport: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.update_rounded),
            title: const Text('启用自动备份'),
            subtitle: const Text(
                'App 进入后台时自动 WebDAV 上传（占位，待实现）'),
            value: s.autoBackup,
            onChanged: (v) => n.update((p) => p.copyWith(autoBackup: v)),
          ),

          if (_status != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_status!,
                    style: const TextStyle(fontSize: 12, height: 1.5)),
              ),
            ),
        ],
      ),
    );
  }

  // ── Local ───────────────────────────────────────────────────────────────
  //
  // Local and WebDAV share the same archive bytes — only the destination
  // differs. The archive is built once via [BackupService.exportToArchive].

  Future<void> _exportAndShare() async {
    if (_selectedModules(ref.read(settingsProvider)).isEmpty) {
      setState(() => _status = '至少选一个模块');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final f =
          await ref.read(backupServiceProvider).exportToFile(_selectedModules(ref.read(settingsProvider)));
      final size = await f.length();
      setState(() => _status = '已写入：${f.path}\n大小：${_fmtBytes(size)}');
      await Share.shareXFiles([XFile(f.path)],
          subject: 'Explore Journal backup');
    } catch (e) {
      setState(() => _status = '导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndImport() async {
    if (_selectedModules(ref.read(settingsProvider)).isEmpty) {
      setState(() => _status = '至少选一个模块');
      return;
    }
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: false,
    );
    if (res == null || res.files.single.path == null) return;
    final bytes = await File(res.files.single.path!).readAsBytes();
    await _doImport(bytes);
  }

  // ── WebDAV ──────────────────────────────────────────────────────────────

  Future<void> _testWebdav() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      // Force-reload the provider so any URL/credential typed seconds ago
      // is reflected even before the widget tree has settled.
      ref.invalidate(webdavServiceProvider);
      final res = await ref.read(webdavServiceProvider).testConnection();
      setState(() => _status = res ?? 'ok');
    } catch (e) {
      setState(() => _status = '测试失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadToWebdav() async {
    if (_selectedModules(ref.read(settingsProvider)).isEmpty) {
      setState(() => _status = '至少选一个模块');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final dav = ref.read(webdavServiceProvider);
      final bytes = await ref
          .read(backupServiceProvider)
          .exportToArchive(_selectedModules(ref.read(settingsProvider)));
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final filename = 'explore_journal_backup_$ts.zip';
      await dav.uploadArchive(filename, bytes);
      setState(() => _status =
          '已上传：$filename\n大小：${_fmtBytes(bytes.length)}');
    } catch (e) {
      setState(() => _status = '上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromWebdav() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final dav = ref.read(webdavServiceProvider);
      final list = await dav.listArchives();
      if (list.isEmpty) {
        try {
          final bytes = await dav.downloadArchive('latest.zip');
          await _doImport(Uint8List.fromList(bytes));
          return;
        } catch (_) {
          setState(() => _status = '云端没有找到任何 zip 备份');
          return;
        }
      }
      if (!mounted) return;
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择要恢复的备份'),
          children: [
            for (final name in list)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, name),
                child: Text(name),
              ),
            const Divider(),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'latest.zip'),
              child: const Text('最新（latest.zip）'),
            ),
          ],
        ),
      );
      if (picked == null) {
        setState(() => _busy = false);
        return;
      }
      final bytes = await dav.downloadArchive(picked);
      await _doImport(Uint8List.fromList(bytes));
    } catch (e) {
      setState(() => _status = '恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Shared import path ──────────────────────────────────────────────────

  Future<void> _doImport(Uint8List bytes) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final sum =
          await ref.read(backupServiceProvider).importFromArchive(
                bytes,
                modules: _selectedModules(ref.read(settingsProvider)),
                clearBeforeImport:
                    ref.read(settingsProvider).importClearBeforeImport,
              );
      setState(() => _status = '导入完成：\n${sum.describe()}');
    } catch (e) {
      setState(() => _status = '导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(2)} MB';
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

/// Live-saving text field. Mirrors the pattern in the imghost screen so
/// every keystroke writes through to settings — no save button needed.
class _TextSetting extends StatefulWidget {
  final IconData icon;
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool obscure;
  const _TextSetting(this.icon, this.label, this.value, this.onChanged,
      {this.hint, this.obscure = false});
  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _TextSetting old) {
    super.didUpdateWidget(old);
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
          prefixIcon: Icon(widget.icon, size: 18),
          labelText: widget.label,
          hintText: widget.hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}
