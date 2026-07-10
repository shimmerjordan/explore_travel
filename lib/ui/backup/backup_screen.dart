import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart' show CancelToken;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../app/providers.dart';
import '../../core/prefs.dart';
import '../../services/backup/backup_service.dart';
import '../../services/sync/local_folder_storage.dart';
import '../../services/sync/onedrive_service.dart';
import '../../services/sync/onedrive_sync_engine.dart';
import '../../services/fog/fog_engine.dart';
import '../../services/fog/fow_compat.dart';
import '../widgets/responsive_content.dart';

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
    final oneDriveHasClientId = OneDriveService.defaultClientId.isNotEmpty ||
        (s.oneDriveClientId ?? '').isNotEmpty;
    final oneDriveConnected = (s.oneDriveRefreshToken ?? '').isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('导出与导入',
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
      body: ResponsiveContent(
          child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(6),
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
              // A per-module "clear this module's LOCAL data" button (with a
              // confirm). leaderboard is community-shared → not clearable.
              secondary: k == 'leaderboard'
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      tooltip: '清除本机此模块数据',
                      color: cs.error,
                      onPressed: _busy ? null : () => _clearModule(k),
                    ),
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

          // ── OneDrive（微软账号登录）────────────────────────────────────
          const _SectionHeader('OneDrive（微软账号登录）'),
          ListTile(
            leading: Icon(oneDriveConnected
                ? Icons.cloud_done_rounded
                : Icons.login_rounded),
            title: Text(oneDriveConnected
                ? '已连接：${s.oneDriveAccount ?? 'OneDrive'}'
                : '连接 OneDrive（跳转微软登录）'),
            subtitle: Text(oneDriveConnected
                ? '点此断开连接'
                : (oneDriveHasClientId
                    ? '点击直接打开微软登录页授权'
                    : '未配置客户端 ID（见 docs/onedrive_setup.md）')),
            enabled: oneDriveHasClientId && !_busy,
            onTap: (!oneDriveHasClientId || _busy)
                ? null
                : (oneDriveConnected ? _disconnectOneDrive : _connectOneDrive),
          ),
          // The client ID is normally baked into the build (OneDriveService
          // .defaultClientId / --dart-define), so users just tap Connect. Only
          // surface the manual-override field when nothing is baked in.
          if (OneDriveService.defaultClientId.isEmpty)
            _TextSetting(Icons.vpn_key_outlined, 'Azure 客户端 ID（可选覆盖）',
                s.oneDriveClientId ?? '',
                (v) => n.update(
                    (p) => p.copyWith(oneDriveClientId: v.isEmpty ? null : v)),
                hint: '构建时已内置 client ID 则可留空；否则在此粘贴（见 docs）'),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('立即同步到 OneDrive'),
            subtitle: Text(oneDriveConnected
                ? '增量同步到 App 专属 Sync 文件夹：只传有变化的文件，按 MD5 跳过未变的'
                : '先连接 OneDrive'),
            enabled: oneDriveConnected && !_busy,
            onTap: (oneDriveConnected && !_busy) ? _oneDriveSyncUp : null,
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download_outlined),
            title: const Text('从 OneDrive 恢复'),
            subtitle: Text(oneDriveConnected
                ? '拉取 Sync 文件夹并按勾选模块合并（UUID 去重）'
                : '先连接 OneDrive'),
            enabled: oneDriveConnected && !_busy,
            onTap: (oneDriveConnected && !_busy) ? _oneDriveSyncDown : null,
          ),

          // ── 本地文件夹（与云端同构·便于排查）──────────────────────────
          const _SectionHeader('本地文件夹（与云端同构·便于排查）'),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '和「同步到 OneDrive / 从 OneDrive 恢复」走完全相同的流水线（分片打包 → '
              'MD5 增量 → 合并），区别只是文件写到本机文件夹而非云端。用它可以在无网络、'
              '无第二台设备的情况下复现同步问题：先导出，再清空数据，然后从文件夹导入。',
              style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: cs.onSurfaceVariant),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.drive_folder_upload_outlined),
            title: const Text('导出到本地文件夹'),
            subtitle: const Text(
                '写到 documents/ej_sync_mirror/（同 OneDrive 的 Sync 目录结构）'),
            enabled: !_busy,
            onTap: _busy ? null : _exportToLocalFolder,
          ),
          ListTile(
            leading: const Icon(Icons.drive_folder_upload_outlined),
            title: const Text('从本地文件夹导入'),
            subtitle: const Text('从上面那个文件夹按勾选模块合并（与「从 OneDrive 恢复」同逻辑）'),
            enabled: !_busy,
            onTap: _busy ? null : _importFromLocalFolder,
          ),

          // ── Fog of World 兼容 ─────────────────────────────────────────
          const _SectionHeader('Fog of World 兼容'),
          ListTile(
            leading: const Icon(Icons.file_download_rounded),
            title: const Text('导入 FOW 数据'),
            subtitle: const Text(
                '推荐选「Sync.zip」单个文件（最快）；也可多选 Sync 文件夹里的文件（可从 OneDrive 选，文件多时系统缓存会比较慢）'),
            enabled: !_busy,
            onTap: _busy ? null : _importFow,
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_rounded),
            title: const Text('导出为 FOW 格式'),
            subtitle: const Text('把可见图层的迷雾导出为世界迷雾 zip，可保存或分享到任意位置'),
            enabled: !_busy,
            onTap: _busy ? null : _exportFow,
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
      )),
    );
  }

  // ── Local ───────────────────────────────────────────────────────────────
  //
  // Local and WebDAV share the same archive bytes — only the destination
  // differs. The archive is built once via [BackupService.exportToArchive].

  /// Runs [op] behind a non-dismissible floating dialog with a progress bar +
  /// live phase text. The dialog blocks the back button, so the screen can't be
  /// disposed mid-operation (which previously caused setState-after-dispose
  /// crashes). Progress is driven via ValueNotifiers, not setState. Returns the
  /// op's result, or null if it threw (in which case _status shows the error).
  Future<T?> _withProgress<T>(
    String title,
    Future<T> Function(
            void Function(double? value, String phase) report, CancelToken cancel)
        op,
  ) async {
    final value = ValueNotifier<double?>(null);
    final phase = ValueNotifier<String>('准备中…');
    final cancel = CancelToken();
    if (mounted) setState(() => _busy = true);
    void requestCancel() {
      if (!cancel.isCancelled) {
        cancel.cancel('用户中断');
        phase.value = '正在中断…';
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      // canPop:false but the back press requests cancellation — the op aborts
      // and the dialog is then dismissed programmatically.
      builder: (_) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) requestCancel();
        },
        child: AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ValueListenableBuilder<double?>(
                valueListenable: value,
                builder: (_, v, __) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: v),
                    ),
                    if (v != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('${(v * 100).round()}%',
                            style: const TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: phase,
                builder: (_, v, __) => Text(v,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: requestCancel, child: const Text('中断')),
          ],
        ),
      ),
    );
    T? result;
    Object? error;
    try {
      result = await op((v, p) {
        value.value = v;
        phase.value = p;
      }, cancel);
    } catch (e) {
      error = e;
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      value.dispose();
      phase.dispose();
      if (mounted) setState(() => _busy = false);
    }
    if (cancel.isCancelled) {
      if (mounted) setState(() => _status = '$title已取消');
      return null;
    }
    if (error != null) {
      if (mounted) setState(() => _status = '$title失败：$error');
      return null;
    }
    return result;
  }

  /// Import an archive (no UI) — used inside [_withProgress]. Returns a status
  /// line and refreshes the map.
  Future<String> _runImport(Uint8List bytes) async {
    final sum = await ref.read(backupServiceProvider).importFromArchive(
          bytes,
          modules: _selectedModules(ref.read(settingsProvider)),
          clearBeforeImport: ref.read(settingsProvider).importClearBeforeImport,
          // A user-picked backup is an authoritative RESTORE: bring back rows
          // even if the user deleted them locally after this backup was made.
          restore: true,
        );
    ref.read(journalRefreshProvider.notifier).state++;
    ref.read(fogRefreshProvider.notifier).state++;
    // The archive may have carried settings — re-read prefs so they apply
    // immediately instead of after the next app start.
    await ref.read(settingsProvider.notifier).reload();
    return '导入完成：\n${sum.describe()}';
  }

  Future<void> _exportAndShare() async {
    if (_selectedModules(ref.read(settingsProvider)).isEmpty) {
      setState(() => _status = '至少选一个模块');
      return;
    }
    final path = await _withProgress<String>('导出备份', (report, _) async {
      report(null, '打包数据…');
      final f = await ref
          .read(backupServiceProvider)
          .exportToFile(_selectedModules(ref.read(settingsProvider)));
      return f.path;
    });
    if (path == null || !mounted) return;
    final size = await File(path).length();
    setState(() => _status = '已写入：$path\n大小：${_fmtBytes(size)}');
    await Share.shareXFiles([XFile(path)], subject: 'Explore Journal backup');
  }

  Future<void> _pickAndImport() async {
    if (_selectedModules(ref.read(settingsProvider)).isEmpty) {
      setState(() => _status = '至少选一个模块');
      return;
    }
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      // withData so the bytes come back in-memory: on web there is no file
      // path, and BackupService.importFromArchive is pure-bytes anyway.
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;
    final picked = res.files.single;
    if (picked.bytes == null && picked.path == null) return;
    final status = await _withProgress<String>('导入备份', (report, _) async {
      report(null, '读取文件…');
      final bytes = picked.bytes ?? await File(picked.path!).readAsBytes();
      report(null, '合并导入…');
      return _runImport(bytes);
    });
    if (status != null && mounted) setState(() => _status = status);
  }

  // ── WebDAV ──────────────────────────────────────────────────────────────

  Future<void> _testWebdav() async {
    // Force-reload the provider so any URL/credential typed seconds ago is
    // reflected even before the widget tree has settled.
    ref.invalidate(webdavServiceProvider);
    final status = await _withProgress<String>('测试 WebDAV', (report, _) async {
      report(null, '连接中…');
      return await ref.read(webdavServiceProvider).testConnection() ?? 'ok';
    });
    if (status != null && mounted) setState(() => _status = status);
  }

  Future<void> _uploadToWebdav() async {
    if (_selectedModules(ref.read(settingsProvider)).isEmpty) {
      setState(() => _status = '至少选一个模块');
      return;
    }
    final status = await _withProgress<String>('上传到 WebDAV', (report, _) async {
      report(null, '打包数据…');
      final bytes = await ref
          .read(backupServiceProvider)
          .exportToArchive(_selectedModules(ref.read(settingsProvider)));
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final filename = 'explore_journal_backup_$ts.zip';
      report(null, '上传 $filename…');
      await ref.read(webdavServiceProvider).uploadArchive(filename, bytes);
      return '已上传：$filename\n大小：${_fmtBytes(bytes.length)}';
    });
    if (status != null && mounted) setState(() => _status = status);
  }

  Future<void> _restoreFromWebdav() async {
    final dav = ref.read(webdavServiceProvider);
    final list = await _withProgress<List<String>>('读取 WebDAV', (report, _) async {
      report(null, '列出云端备份…');
      return dav.listArchives();
    });
    if (list == null || !mounted) return; // error already surfaced
    String? picked;
    if (list.isEmpty) {
      picked = 'latest.zip';
    } else {
      picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择要恢复的备份'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'latest.zip'),
              child: const Text('最新（latest.zip）'),
            ),
            const Divider(),
            for (final name in list)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, name),
                child: Text(name),
              ),
          ],
        ),
      );
      if (picked == null) return;
    }
    final chosen = picked;
    final status = await _withProgress<String>('从 WebDAV 恢复', (report, _) async {
      report(null, '下载 $chosen…');
      final bytes = await dav.downloadArchive(chosen);
      report(null, '合并导入…');
      return _runImport(Uint8List.fromList(bytes));
    });
    if (status != null && mounted) setState(() => _status = status);
  }

  // ── OneDrive (Microsoft Graph) ──────────────────────────────────────────

  Future<void> _connectOneDrive() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final label = await ref.read(oneDriveServiceProvider).connect();
      setState(() => _status = '已连接 OneDrive：$label');
    } catch (e) {
      setState(() => _status = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnectOneDrive() async {
    await ref.read(oneDriveServiceProvider).disconnect();
    if (mounted) setState(() => _status = '已断开 OneDrive 连接');
  }

  /// Show an operation's outcome in a dialog. The bottom-of-page `_status`
  /// container also gets it, but it sits BELOW the fold — users watching the
  /// OneDrive tiles never saw it and read a finished restore as "没有反应".
  Future<void> _showResult(String title, String body) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Text(body, style: const TextStyle(fontSize: 13, height: 1.6)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  /// Confirm, then wipe one module's local data. Refreshes the map/journal
  /// so a cleared module visibly disappears.
  Future<void> _clearModule(String key) async {
    final label = BackupService.moduleLabels[key] ?? key;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('清除本机「$label」？'),
        content: const Text(
            '仅删除本设备上的这部分数据（云端备份不受影响，除非你随后再同步上传）。'
            '此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final msg = await ref.read(backupServiceProvider).clearModule(key);
      // Reflect the wipe on screen immediately.
      ref.read(journalRefreshProvider.notifier).state++;
      ref.read(fogRefreshProvider.notifier).state++;
      if (key == 'settings') {
        await ref.read(settingsProvider.notifier).reload();
      }
      if (mounted) setState(() => _status = msg);
    } catch (e) {
      if (mounted) setState(() => _status = '清除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _oneDriveSyncUp() async {
    if (_selectedModules(ref.read(settingsProvider)).isEmpty) {
      setState(() => _status = '至少选一个模块');
      return;
    }
    final res =
        await _withProgress<SyncUpResult>('同步到 OneDrive', (report, cancel) {
      return ref.read(syncEngineProvider).syncUp(
            modules: _selectedModules(ref.read(settingsProvider)),
            cancelToken: cancel,
            onProgress: (done, total, label) =>
                report(total == 0 ? null : done / total, label),
          );
    });
    if (res != null && mounted) {
      final msg =
          '增量同步完成：上传 ${res.uploaded} · 删除 ${res.deleted} · 未变 ${res.unchanged}';
      setState(() => _status = msg);
      await _showResult('同步到 OneDrive', msg);
    }
  }

  Future<void> _oneDriveSyncDown() async {
    final status =
        await _withProgress<String>('从 OneDrive 恢复', (report, cancel) async {
      final summary = await ref.read(syncEngineProvider).syncDown(
            modules: _selectedModules(ref.read(settingsProvider)),
            clearBeforeImport:
                ref.read(settingsProvider).importClearBeforeImport,
            cancelToken: cancel,
            onProgress: (done, total, label) =>
                report(total == 0 ? null : done / total, label),
          );
      if (summary == null) {
        return 'OneDrive 的 Sync 文件夹还是空的（先同步一次上去）';
      }
      // A restore can replace journals, layers, fog AND settings — refresh
      // the map and re-read prefs so the imported settings apply now (and a
      // later settings edit can't write the stale in-memory copy back).
      ref.read(journalRefreshProvider.notifier).state++;
      ref.read(fogRefreshProvider.notifier).state++;
      await ref.read(settingsProvider.notifier).reload();
      return '已从 OneDrive 恢复：\n${summary.describe()}';
    });
    if (status != null && mounted) {
      setState(() => _status = status);
      await _showResult('从 OneDrive 恢复', status);
    }
  }

  // ── Local folder — a local mirror of the cloud Sync folder ────────────────
  //
  // Identical SyncEngine pipeline to OneDrive (export → shard → MD5 diff →
  // merge); only the transport differs (LocalFolderStorage writes to
  // documents/ej_sync_mirror). This is the "reproduce a sync bug with no
  // network / no second device" tool: export → clear data → import back.

  Future<String> _mirrorDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/ej_sync_mirror');
    await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> _exportToLocalFolder() async {
    if (_selectedModules(ref.read(settingsProvider)).isEmpty) {
      setState(() => _status = '至少选一个模块');
      return;
    }
    final root = await _mirrorDir();
    final res = await _withProgress<SyncUpResult>(
        '导出到本地文件夹', (report, cancel) {
      return ref.read(syncEngineProvider).syncUp(
            modules: _selectedModules(ref.read(settingsProvider)),
            storage: LocalFolderStorage(root),
            cancelToken: cancel,
            onProgress: (done, total, label) =>
                report(total == 0 ? null : done / total, label),
          );
    });
    if (res != null && mounted) {
      final msg = '已导出到：\n$root\n\n'
          '上传 ${res.uploaded} · 删除 ${res.deleted} · 未变 ${res.unchanged}\n'
          '目录结构与 OneDrive 的 Sync 文件夹一致，可用文件管理器 / adb pull 查看。';
      setState(() => _status = msg);
      await _showResult('导出到本地文件夹', msg);
    }
  }

  Future<void> _importFromLocalFolder() async {
    final root = await _mirrorDir();
    final status = await _withProgress<String>(
        '从本地文件夹导入', (report, cancel) async {
      final summary = await ref.read(syncEngineProvider).syncDown(
            modules: _selectedModules(ref.read(settingsProvider)),
            clearBeforeImport:
                ref.read(settingsProvider).importClearBeforeImport,
            // The local folder is a backup mirror: importing from it is a
            // RESTORE (export → delete → import back must bring the data back),
            // not a two-way sync. Only OneDrive keeps strict sync semantics.
            restore: true,
            storage: LocalFolderStorage(root),
            cancelToken: cancel,
            onProgress: (done, total, label) =>
                report(total == 0 ? null : done / total, label),
          );
      if (summary == null) {
        return '本地文件夹还是空的（先「导出到本地文件夹」一次）：\n$root';
      }
      ref.read(journalRefreshProvider.notifier).state++;
      ref.read(fogRefreshProvider.notifier).state++;
      await ref.read(settingsProvider.notifier).reload();
      return '已从本地文件夹导入：\n${summary.describe()}';
    });
    if (status != null && mounted) {
      setState(() => _status = status);
      await _showResult('从本地文件夹导入', status);
    }
  }

  // ── Fog of World ──────────────────────────────────────────────────────────

  Future<void> _importFow() async {
    // Capture the long-lived services BEFORE the (possibly very slow) picker:
    // picking many cloud files can take minutes, during which Android may
    // destroy/recreate this screen. Holding the engine + providers directly
    // means the import still completes even if this State is gone by the time
    // the picker returns; setState is always behind a `mounted` check.
    final fog = ref.read(fogEngineProvider);
    final db = ref.read(dbProvider);
    final layerId = ref.read(effectiveActiveLayerIdProvider);
    final fogRefresh = ref.read(fogRefreshProvider.notifier);
    final fogImportFocus = ref.read(fogImportFocusProvider.notifier);
    // Expand imported cells into the same penRadius corridors native recording
    // paints, so FOW data looks/behaves like in-app data (not FoW's thin cells).
    final penRadius = ref.read(settingsProvider).fogPenRadius;

    // Same picker as "从本地 zip 导入" (reaches OneDrive). Pick the single
    // Sync.zip for the fast path, or multi-select the loose Sync files.
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;

    final phase = ValueNotifier<String>('正在读取所选文件…');
    final showUi = mounted;
    if (mounted) {
      setState(() => _status = null);
      // Floating progress dialog. The parse runs in a background isolate and
      // DB writes happen on drift's isolate, so the spinner actually animates
      // — the UI thread is free (the old in-place parse froze it for ~10 s).
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => PopScope(
          canPop: false,
          child: Dialog(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.6)),
                  const SizedBox(width: 18),
                  Flexible(
                    child: ValueListenableBuilder<String>(
                      valueListenable: phase,
                      builder: (_, v, __) => Text(v),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    String result;
    try {
      result = await _runFowImport(
        res.files,
        fog: fog,
        layerId: layerId,
        penRadiusMeters: penRadius,
        fogRefresh: fogRefresh,
        fogImportFocus: fogImportFocus,
        onPhase: (p) => phase.value = p,
      );
    } catch (e) {
      result = 'FOW 导入失败：$e';
    } finally {
      if (showUi && mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // close the dialog
      }
      phase.dispose();
    }
    // Guarantee the imported fog is actually rendered: the map only draws
    // VISIBLE layers, and the effective-active layer can be a hidden one when
    // the user has toggled every layer's eye off — the fog then lands in the DB
    // but never appears ("导入不生效/清除后再导入就没了"). Un-hide the target and
    // force a reload.
    if (result.startsWith('已点亮')) {
      await db.setLayerVisible(layerId, true);
      fogRefresh.state++;
    }
    if (mounted) setState(() => _status = result);
  }

  /// Read → parse (in a background isolate) → batch-import the picked FOW
  /// inputs, then fly the map to the revealed region. Returns a status string.
  /// Uses only captured services + [compute], so it completes regardless of
  /// this screen's lifecycle.
  Future<String> _runFowImport(
    List<PlatformFile> files, {
    required FogEngine fog,
    required int layerId,
    required double penRadiusMeters,
    required StateController<int> fogRefresh,
    required StateController<LatLng?> fogImportFocus,
    required void Function(String) onPhase,
  }) async {
    onPhase('正在读取所选文件…');
    final inputs = <({String name, Uint8List bytes})>[];
    for (final pf in files) {
      final bytes = pf.bytes ??
          (pf.path != null ? await File(pf.path!).readAsBytes() : null);
      if (bytes != null) inputs.add((name: pf.name, bytes: bytes));
    }
    if (inputs.isEmpty) return '没有读到所选文件的内容';

    onPhase('正在解析迷雾数据并生成走廊…（${inputs.length} 个文件）');
    // Parse + expand to penRadius corridors off the UI isolate — ~45k blocks
    // (and their dilation) would otherwise freeze the app for seconds.
    final blocks = await compute(
      parseAndExpandFowInputs,
      (inputs: inputs, penRadiusMeters: penRadiusMeters),
    );
    if (blocks.isEmpty) {
      return '没有读到 FOW 数据。请选世界迷雾（Fog of World）的 Sync.zip，'
          '或多选 Sync 文件夹里的文件';
    }

    onPhase('正在写入 ${blocks.length} 个迷雾块…');
    final written = await fog.importBlocks(layerId: layerId, blocks: blocks);
    // DIAG: which layer the FOW fog landed on. If this layer isn't in the map's
    // visibleLayerIds (see [FOG] reload log), the import writes fine but nothing
    // renders — the "清除后再导入就没了" symptom.
    debugPrint('[FOW] import → activeLayer=$layerId '
        'blocks=${blocks.length} written=$written');
    fogRefresh.state++;

    // Fly the map to the centre of the imported fog (FoW has no track lines,
    // so cleared fog far from the user is otherwise easy to miss).
    var sx = 0.0, sy = 0.0;
    for (final b in blocks) {
      sx += (b.tileX * FogEngine.tileWidth + b.blockX) * FogEngine.bitmapWidth;
      sy += (b.tileY * FogEngine.tileWidth + b.blockY) * FogEngine.bitmapWidth;
    }
    fogImportFocus.state = LatLng(
      FogEngine.globalYToLat((sy / blocks.length).round()),
      FogEngine.globalXToLng((sx / blocks.length).round()),
    );

    return '已点亮 $written 块迷雾（来自 ${inputs.length} 个文件），'
        '并已按 ${penRadiusMeters.toStringAsFixed(0)}m 笔刷扩成与原生记录一致的走廊。\n'
        '注意：FOW 数据只含迷雾、不含轨迹线——已为你跳转到点亮的区域，'
        '在深色迷雾下最明显。';
  }

  Future<void> _exportFow() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final fog = ref.read(fogEngineProvider);
      final db = ref.read(dbProvider);
      final layers = (await db.allLayers())
          .where((l) => l.visible)
          .map((l) => l.id)
          .toList();
      final bytes = await exportFowArchive(engine: fog, layerIds: layers);
      if (bytes.isEmpty) {
        setState(() =>
            _status = '没有可导出的迷雾数据（请确认有可见且已探索的图层）');
        return;
      }
      // Stage the zip in a temp file and hand it to the system share sheet —
      // the user picks where to save it or which app to send it to.
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final f = File('${dir.path}/fow_export_$ts.zip');
      await f.writeAsBytes(bytes);
      if (!mounted) return;
      setState(() => _status =
          '已导出 FOW zip（${_fmtBytes(bytes.length)}）—— 选择保存位置或分享');
      await Share.shareXFiles([XFile(f.path)], subject: 'Fog of World export');
    } catch (e) {
      setState(() => _status = 'FOW 导出失败：$e');
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
