import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart' show CancelToken;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:archive/archive.dart';
import '../../services/backup/backup_credentials.dart';
import '../../app/providers.dart';
import '../../core/prefs.dart';
import '../../services/backup/backup_service.dart';
import '../../services/sync/local_folder_storage.dart';
import '../../services/sync/onedrive_service.dart';
import '../common/failure.dart';
import '../common/format.dart' show fmtBytes;
import '../../services/sync/onedrive_sync_engine.dart';
import '../../services/fog/fog_engine.dart';
import '../../services/fog/fow_compat.dart';
import '../../services/vault/admin_config_client.dart' show AdminAuthException;
import '../../services/vault/auth_controller.dart'
    show defaultPasswordWarningProvider, kConsoleLogoutNotNotifiedNotice;
import '../../services/vault/config_payload.dart' show ConfigPayload;
import '../../services/vault/config_sync_controller.dart'
    show ConfigSyncController;
import '../auth/login_screen.dart' show humanizeLoginError, validateLoginInput;
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

          // ── 凭据如何随备份与同步旅行 ──────────────────────────────────
          const _SectionHeader('凭据的旅行方式'),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '导出的备份与云同步都会把设置里的凭据（各家口令、令牌、API 密钥）'
              '剔除，所以泄露的文件不会泄露凭据。代价是换设备后要手工重填——'
              '除非给它们一把钥匙。\n\n'
              '备份用的是导出时现场输入的口令。云同步是后台跑的、没人能输口令，'
              '所以它用下面这个：两台设备填同一个值，凭据就会加密后随同步旅行。'
              '留空则同步不带凭据（和没有这个功能时一样）。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _TextSetting(
            Icons.key_rounded,
            '同步凭据口令',
            s.syncCredentialsPassphrase ?? '',
            (v) => n.update((p) =>
                p.copyWith(syncCredentialsPassphrase: v.isEmpty ? null : v)),
            hint: '留空 = 同步不带凭据；两台设备要填同一个',
            obscure: true,
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '它本身也算凭据：不会随明文设置外传，但**会**被封进带口令的备份里——'
              '所以在新设备上恢复一次带口令的备份，就等于把这把钥匙也带过去了，'
              '不用两边各输一遍。忘了它只影响凭据能否随同步旅行，数据不受影响。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),

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

          // ── Web 前端 · 配置推送 ────────────────────────────────────────
          //
          // Native only. In the browser this config is what the app was HANDED
          // (the console serves the bundle and the config together), so a push
          // button there would suggest the read-only viewer can republish it.
          if (!kIsWeb) const ConsolePushSection(),

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
            title: const Text('导出 FOW Sync.zip'),
            subtitle: const Text(
                '把可见图层的迷雾按世界迷雾原生 Sync.zip 结构导出到本地（默认下载目录），可直接导回 FOW'),
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
      debugPrint('[UI] $title 失败: $error');
      if (mounted) setState(() => _status = failureMessage(title, error));
      return null;
    }
    return result;
  }

  /// Import an archive (no UI) — used inside [_withProgress]. Returns a status
  /// line and refreshes the map.
  /// Peek into the archive for sealed credentials, and only then ask for a
  /// password. Prompting unconditionally would train people to dismiss a dialog
  /// that usually means nothing — and most archives (anything the sync engine
  /// produced) carry no credentials at all.
  ///
  /// Returns `(proceed, password)`. `proceed == false` means the user cancelled
  /// the prompt and the import should not run.
  bool _archiveHasSealedCredentials(Uint8List bytes) {
    try {
      // Only the central directory is walked here; `ArchiveFile.content`
      // decompresses lazily, so this reads one small member rather than
      // inflating the whole archive.
      for (final f in ZipDecoder().decodeBytes(bytes).files) {
        if (f.isFile && f.name == BackupCredentials.fileName) {
          return BackupCredentials.isSealed(
              utf8.decode(f.content as List<int>, allowMalformed: true));
        }
      }
    } catch (_) {
      // Not a readable zip — let the import itself produce the real error
      // rather than failing here with a confusing one about credentials.
    }
    return false;
  }

  Future<String> _runImport(Uint8List bytes, {String? credentialsPassword}) async {
    final sum = await ref.read(backupServiceProvider).importFromArchive(
          bytes,
          modules: _selectedModules(ref.read(settingsProvider)),
          clearBeforeImport: ref.read(settingsProvider).importClearBeforeImport,
          // A user-picked backup is an authoritative RESTORE: bring back rows
          // even if the user deleted them locally after this backup was made.
          restore: true,
          credentialsPassword: credentialsPassword,
        );
    ref.read(journalRefreshProvider.notifier).state++;
    ref.read(fogRefreshProvider.notifier).state++;
    // The archive may have carried settings — re-read prefs so they apply
    // immediately instead of after the next app start.
    await ref.read(settingsProvider.notifier).reload();
    return '导入完成：\n${sum.describe()}';
  }

  /// Is there anything for an export password to protect?
  ///
  /// Two reasons it can be "no": the `settings` module is not selected (the
  /// archive will carry no settings at all, so the password would be silently
  /// ignored — the dialog would be promising something that cannot happen), or
  /// the user simply has no credentials configured yet. Prompting in either case
  /// is the same mistake `_passwordForArchive` avoids on the import side:
  /// training people to dismiss a dialog that usually means nothing.
  /// The passphrase credentials ride along with sync under, or null when the
  /// user has not set one (sync then carries none, as before).
  String? _syncPassphrase() {
    final v = ref.read(settingsProvider).syncCredentialsPassphrase;
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<bool> _exportWouldCarryCredentials() => ref
      .read(backupServiceProvider)
      .hasCredentialsToSeal(_selectedModules(ref.read(settingsProvider)));

  /// Ask for the password that seals (or unseals) the credentials in an archive.
  ///
  /// Returns `null` when the user cancels, `''` when they deliberately continue
  /// without one. Those are different answers and the callers treat them
  /// differently: cancel aborts the whole operation, empty means "export a
  /// shareable backup with no credentials in it".
  Future<String?> _askArchivePassword({required bool forExport}) async {
    final ctrl = TextEditingController();
    var obscure = true;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(forExport ? '给备份里的凭据加个口令' : '这份备份带着加密的凭据'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                forExport
                    ? '备份里的凭据（WebDAV 口令、各家令牌与 API 密钥）会用这个口令'
                        '加密后单独存放。不填就不带凭据——那样这份 zip 可以放心分享，'
                        '但在新设备上恢复后要手动重填。\n\n'
                        '口令不会被记住，也无法找回：忘了它，这份备份里的凭据就再也'
                        '取不出来（数据本身不受影响）。'
                    : '输入导出时设的口令来恢复凭据。不填或填错都不会影响其它数据的'
                        '导入，只是凭据保持原样、需要手动重填。',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                obscureText: obscure,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '口令',
                  hintText: forExport ? '留空 = 不带凭据' : '',
                  suffixIcon: IconButton(
                    icon: Icon(obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setLocal(() => obscure = !obscure),
                  ),
                ),
                onSubmitted: (v) => Navigator.of(ctx).pop(v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              child: Text(forExport ? '继续' : '恢复凭据'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<void> _exportAndShare() async {
    if (_selectedModules(ref.read(settingsProvider)).isEmpty) {
      setState(() => _status = '至少选一个模块');
      return;
    }
    var pw = '';
    if (await _exportWouldCarryCredentials()) {
      final typed = await _askArchivePassword(forExport: true);
      if (typed == null || !mounted) return; // 取消 → 整个操作中止
      pw = typed; // '' 表示「继续，但不带凭据」
    }
    final path = await _withProgress<String>('导出备份', (report, _) async {
      report(null, pw.isEmpty ? '打包数据…' : '打包并加密凭据…');
      final f = await ref.read(backupServiceProvider).exportToFile(
            _selectedModules(ref.read(settingsProvider)),
            credentialsPassword: pw.isEmpty ? null : pw,
          );
      return f.path;
    });
    if (path == null || !mounted) return;
    final size = await File(path).length();
    setState(() => _status = '已写入：$path\n大小：${fmtBytes(size)}');
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
    // Reading (and probing) happens inside a progress pass of its own: a
    // several-hundred-MB archive takes real time, and the password dialog can
    // only open once the progress dialog has closed — so this is two passes
    // rather than one, same shape as the WebDAV restore path below.
    final probed = await _withProgress<(Uint8List, bool)>('读取备份', (report, _) async {
      report(null, '读取文件…');
      final b = picked.bytes ?? await File(picked.path!).readAsBytes();
      report(null, '检查内容…');
      return (b, _archiveHasSealedCredentials(b));
    });
    if (probed == null || !mounted) return;
    final (bytes, hasSealed) = probed;
    String? pw;
    if (hasSealed) {
      final typed = await _askArchivePassword(forExport: false);
      if (typed == null || !mounted) return; // 取消
      pw = typed.isEmpty ? null : typed;
    }
    final status = await _withProgress<String>('导入备份', (report, _) async {
      report(null, '合并导入…');
      return _runImport(bytes, credentialsPassword: pw);
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
    var pw = '';
    if (await _exportWouldCarryCredentials()) {
      final typed = await _askArchivePassword(forExport: true);
      if (typed == null || !mounted) return; // 取消 → 整个操作中止
      pw = typed; // '' 表示「继续，但不带凭据」
    }
    final status = await _withProgress<String>('上传到 WebDAV', (report, _) async {
      report(null, pw.isEmpty ? '打包数据…' : '打包并加密凭据…');
      final bytes = await ref.read(backupServiceProvider).exportToArchive(
            _selectedModules(ref.read(settingsProvider)),
            credentialsPassword: pw.isEmpty ? null : pw,
          );
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final filename = 'explore_journal_backup_$ts.zip';
      report(null, '上传 $filename…');
      await ref.read(webdavServiceProvider).uploadArchive(filename, bytes);
      return '已上传：$filename\n大小：${fmtBytes(bytes.length)}';
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
    // Download and import are two progress passes rather than one, because the
    // password prompt has to sit between them: it can only be asked once the
    // archive is in hand (that is how we know whether it even HAS sealed
    // credentials), and a dialog cannot open on top of the progress dialog.
    final bytes = await _withProgress<List<int>>('从 WebDAV 下载', (report, _) async {
      report(null, '下载 $chosen…');
      return dav.downloadArchive(chosen);
    });
    if (bytes == null || !mounted) return;
    final archive = Uint8List.fromList(bytes);
    String? pw;
    if (_archiveHasSealedCredentials(archive)) {
      final typed = await _askArchivePassword(forExport: false);
      if (typed == null || !mounted) return; // 取消
      pw = typed.isEmpty ? null : typed;
    }
    final status = await _withProgress<String>('从 WebDAV 恢复', (report, _) async {
      report(null, '合并导入…');
      return _runImport(archive, credentialsPassword: pw);
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
      debugPrint('[UI] 连接 OneDrive 失败: $e');
      setState(() => _status = failureMessage('连接', e));
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
            // 不可逆的清除：用 M3 成对的 error/onError，白字压 Colors.red
            // 只有 3.68:1。
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
              foregroundColor: Theme.of(dialogCtx).colorScheme.onError,
            ),
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
      debugPrint('[UI] 清除模块 $key 失败: $e');
      if (mounted) setState(() => _status = failureMessage('清除', e));
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
          credentialsPassphrase: _syncPassphrase(),
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
          credentialsPassphrase: _syncPassphrase(),
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
          credentialsPassphrase: _syncPassphrase(),
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
          credentialsPassphrase: _syncPassphrase(),
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
      debugPrint('[UI] FOW 导入 失败: $e');
      result = failureMessage('FOW 导入', e);
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
      // Save as a FoW-native Sync.zip wherever the user picks (Android's SAF
      // dialog defaults to Download). saveFile writes [bytes] itself on
      // mobile/web; desktop pickers only return a path, so write explicitly.
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存 FOW Sync.zip',
        fileName: 'Sync.zip',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: bytes,
      );
      if (path == null) {
        if (mounted) setState(() => _status = '已取消 FOW 导出');
        return;
      }
      if (!kIsWeb &&
          (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
        await File(path).writeAsBytes(bytes);
      }
      if (!mounted) return;
      setState(() => _status =
          '已导出 FOW Sync.zip（${fmtBytes(bytes.length)}）：\n$path\n'
          '内部结构与世界迷雾原生 Sync.zip 一致（Sync/ 目录 + 混淆名瓦片），'
          '可直接用于 FOW 云同步，也可再导回本应用。');
    } catch (e) {
      debugPrint('[UI] FOW 导出 失败: $e');
      setState(() => _status = failureMessage('FOW 导出', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The address in the form the controller would store it, so a trailing slash
/// never counts as a different server. Falls back to the raw text for anything
/// unparseable — `validateLoginInput` is what rejects those, not this.
String _normalizedOrRaw(String raw) {
  try {
    return ConfigSyncController.normalizeServerUrl(raw);
  } catch (_) {
    return raw.trim();
  }
}

/// Whether two console addresses name the SAME server.
///
/// Not `==`: per RFC 3986 the scheme and host are case-insensitive, so
/// `HTTP://HOST-A:48080` and `http://host-a:48080` are one server — and reading
/// them as two would force a pointless re-login out of the console's 10-per-
/// minute bucket. `Uri` also resolves the default port, so `http://h` and
/// `http://h:80` agree. Everything below the authority (path) still has to
/// match: a console mounted under a sub-path is a different endpoint.
///
/// Unparseable input falls back to a trimmed string compare rather than
/// pretending two nonsense strings are the same host.
bool _sameConsole(String a, String b) {
  final ua = Uri.tryParse(a.trim());
  final ub = Uri.tryParse(b.trim());
  if (ua == null || ub == null) return a.trim() == b.trim();
  String path(Uri u) =>
      u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
  return ua.scheme.toLowerCase() == ub.scheme.toLowerCase() &&
      ua.host.toLowerCase() == ub.host.toLowerCase() &&
      ua.port == ub.port &&
      path(ua) == path(ub);
}

/// How many roaming-config fields the login's pull rewrote on this device.
///
/// Reported to the user because the merge is invisible otherwise: the value they
/// last typed on the phone can be replaced by the server's older one and then
/// re-published as if it were theirs. A count is enough to make them look; the
/// field names would be a wall of text on a phone, and some of them are secrets.
///
/// `_schema` is not a config field. Values are compared as JSON so a Map-typed
/// key (none today — see `ConfigPayload.mapKeys`) compares by content, not
/// identity.
int _countOverwrittenFields(
    Map<String, dynamic> before, Map<String, dynamic> after) {
  var n = 0;
  for (final k in {...before.keys, ...after.keys}) {
    if (k == '_schema') continue;
    if (jsonEncode(before[k]) != jsonEncode(after[k])) n++;
  }
  return n;
}

String _hhmmss(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

/// 「Web 前端 · 配置推送」— the phone's only way to publish its settings config
/// to the self-hosted console, and the only place its session can be ended.
///
/// Before this existed, [ConfigSyncController.pushNow]'s only caller was the
/// debounced auto-push, which requires `isLoggedIn` — and the login route only
/// exists on web. So the phone could never log in and the config never left the
/// device: the whole "phone publishes → browser displays" chain was unreachable
/// on real hardware.
///
/// Public (and a widget of its own) so a test can pump the section alone: the
/// page around it is a long [ListView] whose bottom half is never laid out on a
/// test surface, so nothing here would be findable through [BackupScreen].
class ConsolePushSection extends ConsumerStatefulWidget {
  const ConsolePushSection({super.key});

  @override
  ConsumerState<ConsolePushSection> createState() => _ConsolePushSectionState();
}

class _ConsolePushSectionState extends ConsumerState<ConsolePushSection> {
  /// Prefilled from (and written back to) [AppSettings.nasServerUrl].
  final _server = TextEditingController();

  /// Page-local on purpose: the server is single-admin, so `admin` is already
  /// the right answer and a new persisted settings field would be one more
  /// thing to migrate, export, and roam for no gain.
  final _username = TextEditingController(text: 'admin');

  /// NEVER persisted, never logged. The console derives the config's encryption
  /// key from this password, so a copy on disk beside the ciphertext defeats the
  /// envelope entirely. It lives in this controller and nowhere else, and is
  /// released in [dispose]. The session token — not the password — is what gets
  /// stored, and only by `AdminSessionStore` on web.
  final _password = TextEditingController();

  bool _busy = false;
  String? _message;
  bool _isError = false;

  /// Set only by a 401 from the PUSH (not from the login). `pushNow` has already
  /// dropped the session by then, so this is the mount point that turns the
  /// primary action into 「重新登录并推送」.
  bool _needsRelogin = false;

  DateTime? _lastPushAt;

  @override
  void initState() {
    super.initState();
    _server.text = ref.read(settingsProvider).nasServerUrl ?? '';
    // The primary action's label depends on what is CURRENTLY typed (a retyped
    // address means the held session is for the wrong host), and typing a
    // controller's text does not rebuild the widget that reads it.
    _server.addListener(_onServerEdited);
    // Settings load from disk asynchronously; opening this page during a cold
    // start would otherwise leave the address blank forever. Fill it in when it
    // arrives, but never over something the user has already typed.
    ref.listenManual<AppSettings>(settingsProvider, (_, next) {
      final url = next.nasServerUrl ?? '';
      if (url.isNotEmpty && _server.text.isEmpty) _server.text = url;
    });
  }

  void _onServerEdited() {
    if (!mounted) return;
    setState(() {
      // 「已推送配置到服务器」was about the address that was in the box at the
      // time. Once the user retypes it, that line is a claim about a server
      // they may no longer be talking to, so it goes. Error lines stay: they
      // are usually the reason the address is being edited.
      if (_message != null && !_isError) _message = null;
    });
  }

  @override
  void dispose() {
    _server.removeListener(_onServerEdited);
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Log in (when we don't hold a session) and publish the current config.
  ///
  /// [withLogin] false is the "already logged in, just push again" path — it
  /// must not spend one of the console's 10 logins per minute.
  Future<void> _run({required bool withLogin}) async {
    // The re-entrancy guard belongs HERE, not only on the tile. `onTap` is a
    // closure captured when the tile was built, and `setState(_busy = true)`
    // merely marks this element dirty — any second pointer-up that lands before
    // the rebuild (a dropped frame, a request still in flight, TalkBack's
    // double-tap-to-activate) runs that same live closure. `enabled: false` on
    // the tile is only the visual half. Without this line the phone spends two
    // of the console's ten logins per minute and uploads the config twice.
    if (_busy) return;
    if (withLogin) {
      // Same pre-flight the login screen uses. A blank password or a typo'd
      // address must not cost a slot in that 10/min bucket.
      final bad = validateLoginInput(
        needsServer: true, // a phone has no same-origin to fall back on
        server: _server.text,
        username: _username.text,
        password: _password.text,
      );
      if (bad != null) {
        setState(() {
          _message = bad;
          _isError = true;
        });
        return;
      }
    }
    setState(() {
      _busy = true;
      _message = null;
      _isError = false;
      _needsRelogin = false;
    });
    final ctrl = ref.read(configSyncControllerProvider);
    // Grabbed BEFORE the first await, on purpose. This flag is the only thing
    // that tells the user their console still answers to admin/admin, and this
    // section is its only native renderer. If the user leaves the page while the
    // login is in flight, the login still SUCCEEDS server-side — so the flag has
    // to be set even though `ref` is by then unusable. The notifier object lives
    // in the ProviderContainer rather than in this widget, so holding it across
    // the gap is safe; calling `ref.read` after dispose is not.
    final warn = ref.read(defaultPasswordWarningProvider.notifier);
    // Which half of the operation a 401 came from. A 401 while logging in is a
    // wrong credential; a 401 while pushing is a dead session with a perfectly
    // good credential — telling the user "用户名或密码错误" there sends them
    // hunting for a typo that isn't in the form.
    var authenticated = !withLogin;
    // Snapshot of the roaming config as it stands BEFORE the login's pull, so
    // the merge can be reported rather than merely disclosed in the subtitle.
    final before = withLogin
        ? ConfigPayload.extract(ref.read(settingsProvider)).toJson()
        : null;
    var overwritten = 0;
    try {
      if (withLogin) {
        final url = ConfigSyncController.normalizeServerUrl(_server.text);
        final isDefaultPassword = await ctrl.login(
          serverUrl: url,
          username: _username.text.trim(),
          password: _password.text,
        );
        authenticated = true;
        // NOT behind a `mounted` check — see `warn` above. Losing this line is
        // losing the sentence 「你的服务端还是默认口令」forever: nothing else sets
        // it, and re-entering the page does not recompute it.
        warn.state = isDefaultPassword;
        if (!mounted) return;
        // Read before the `nasServerUrl` write below, which is not a config
        // field but would still be one more diff to reason about.
        overwritten = _countOverwrittenFields(
            before!, ConfigPayload.extract(ref.read(settingsProvider)).toJson());
        // Remember WHERE the console is — never the credential — so the next
        // launch prefills. Normalized, so it matches what the controller stored.
        await ref
            .read(settingsProvider.notifier)
            .update((p) => p.copyWith(nasServerUrl: url));
        if (!mounted) return;
      }
      // force: a manual tap means "publish now, unconditionally". Without it the
      // digest dedupe inside pushNow makes "nothing changed since the last
      // push" indistinguishable from a completed upload — the user taps, sees a
      // success line, and the config never leaves the phone.
      final pushed = await ctrl.pushNow(force: true);
      if (!mounted) return;
      setState(() {
        if (pushed) {
          // The credential has done its whole job; keeping it in a live
          // controller only leaves a plaintext password in memory for as long as
          // the page stays open. Cleared only on FULL success: after a push 401
          // the retry needs it, and clearing there would make the re-login
          // entry point demand a retype for nothing.
          _password.clear();
          _lastPushAt = DateTime.now();
          _message = '已推送配置到服务器（${_hhmmss(_lastPushAt!)}）'
              '${overwritten > 0 ? '。注意：其中 $overwritten 项先被服务器上已有的值覆盖，'
                  '上传的是覆盖后的结果' : ''}';
          _isError = false;
        } else {
          _message = '没有可用会话，配置未推送 —— 请先登录';
          _isError = true;
        }
      });
    } on AdminAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        if (authenticated) {
          _needsRelogin = true;
          // Not "retype your password": after a push 401 the password is still
          // in the form (it is only cleared on a completed push), so a plain
          // second tap usually works. It IS empty when the session was resumed
          // without one, hence the conditional phrasing.
          _message = '会话已过期，配置未推送。密码若已清空请重新填写，然后「重新登录并推送」。';
        } else {
          _message = humanizeLoginError(e);
        }
        _isError = true;
      });
    } catch (e) {
      if (!mounted) return;
      // humanizeLoginError already turns 429 / 413 / transport failures into
      // sentences a user can act on — a second mapping here would only drift.
      setState(() {
        _message = humanizeLoginError(e);
        _isError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    if (_busy) return; // same re-entrancy as _run, same reason
    setState(() {
      _busy = true;
      _message = null;
      _isError = false;
    });
    // Before the await, and cleared in BOTH exits below: `logout()` forgets the
    // token before it does anything else, so however the rest of it ends, this
    // device is locally logged out and a warning about the console's password is
    // no longer ours to display.
    final warn = ref.read(defaultPasswordWarningProvider.notifier);
    try {
      final outcome = await ref.read(configSyncControllerProvider).logout();
      warn.state = false;
      if (!mounted) return;
      _password.clear();
      setState(() {
        _needsRelogin = false;
        _lastPushAt = null;
        _message = outcome.serverNotified
            ? '已退出登录，服务端会话也已注销'
            : kConsoleLogoutNotNotifiedNotice;
        _isError = !outcome.serverNotified;
      });
      // The native shell has no notice bar (that `builder:` is on the web
      // branch only), so an unconfirmed logout is surfaced here — a status line
      // below the fold plus a snackbar the user can't miss.
      if (!outcome.serverNotified) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(kConsoleLogoutNotNotifiedNotice),
            duration: Duration(seconds: 8),
          ),
        );
      }
    } catch (e) {
      // `logout()` documents that it never throws, and its own network half is
      // wrapped — but the local half reaches the platform keychain through
      // `AdminSessionStore.clear()`, which can throw a PlatformException. Without
      // this branch that surfaced as the tile flickering once and saying nothing
      // at all, which reads exactly like a successful logout.
      warn.state = false;
      if (!mounted) return;
      setState(() {
        _needsRelogin = false;
        _lastPushAt = null;
        // 这里只要「原因」那半句：humanizeLoginError 的兜底现在是「登录失败 ·
        // …」，接在「清理会话记录时出错：」后面就成了病句。
        _message = '已在本机退出（会话令牌已丢弃），但清理会话记录时出错：'
            '${describeFailure(e) ?? '未知原因'}';
        _isError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(settingsProvider);
    final usingDefaultPassword = ref.watch(defaultPasswordWarningProvider);
    // A plain Provider, so watching it never rebuilds this on its own. That is
    // fine but NOT because "only this page can change the login state" — the
    // native auto-push drops the session on a 401 entirely outside this widget,
    // and until something rebuilds, the line below still says 「已登录」. It
    // self-heals: the next tap finds no session, `pushNow` returns false, and the
    // 「没有可用会话」branch both says so and rebuilds with the truth. What would
    // NOT be acceptable is a stale 「已登录」that also let the user believe a push
    // happened, and that cannot occur — the push result is read, not assumed.
    final sync = ref.watch(configSyncControllerProvider);
    final loggedIn = sync.isLoggedIn;
    final consoleUrl = (s.nasServerUrl ?? '').isNotEmpty
        ? s.nasServerUrl!
        : (_server.text.trim().isEmpty ? '服务器地址' : _server.text.trim());
    // A session belongs to ONE console: the controller keeps the client it was
    // built with. So a session held from an earlier address would publish to
    // THAT host while the form on screen names another one — and report success.
    // Retyping the address therefore demands a fresh login.
    //
    // Compared against the SESSION's own base URL, never against
    // `s.nasServerUrl`. That field is persisted settings, and all four restore
    // actions on this very screen overwrite the settings map wholesale and
    // reload — a backup made on another device carries ITS `nasServerUrl`. Using
    // it as the yardstick therefore failed in both directions: after such a
    // restore, typing the restored address made the check answer 「没换服务器」and
    // ship every credential to the host the session actually belongs to, while
    // touching nothing at all made it accuse the user of changing the address and
    // burn a login.
    final typed = _normalizedOrRaw(_server.text);
    final sessionUrl = sync.sessionBaseUrl;
    final addressChanged = loggedIn &&
        typed.isNotEmpty &&
        sessionUrl != null &&
        !_sameConsole(typed, sessionUrl);
    final needsLogin = !loggedIn || addressChanged;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Web 前端 · 配置推送'),
        // Same one-paragraph-then-tiles shape (and the same margins, size, and
        // colour) as the 本地文件夹 section immediately above — not a second
        // typographic system. Trimmed to the one thing the tiles below can't
        // say for themselves: which direction this sync runs in. The password's
        // "never stored" promise lives in that field's own hint.
        Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            '把本机的同步配置（WebDAV / OneDrive 凭据、图床、AI 定位等）推到你自建的 '
            'web-front，浏览器打开它就能只读浏览这些足迹。手机是发布方，网页是消费方。',
            style: TextStyle(
                fontSize: 11, height: 1.5, color: cs.onSurfaceVariant),
          ),
        ),
        _TextSetting.controlled(Icons.dns_rounded, '服务器地址', _server,
            hint: '需带 http(s)://，例如 http://192.168.1.9:48080',
            // A URL keyboard and no autocorrect, matching the login screen: a
            // helpfully capitalised host or an "corrected" IP costs a login out
            // of the 10-per-minute bucket to discover.
            keyboardType: TextInputType.url,
            autocorrect: false,
            enabled: !_busy),
        _TextSetting.controlled(Icons.person_rounded, '用户名', _username,
            hint: '服务端只有一个管理员账号，默认 admin',
            autocorrect: false,
            enabled: !_busy),
        _TextSetting.controlled(Icons.lock_rounded, '密码', _password,
            hint: '不会保存在本机；换设备或重装需要重新输入',
            obscure: true,
            autocorrect: false,
            // Enter submits, like the login screen. `_run` re-checks `_busy`
            // itself, so a keyboard submit can't race the tile.
            onSubmitted: (_) => _run(withLogin: needsLogin),
            enabled: !_busy),
        ListTile(
          leading: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.4))
              : Icon(_needsRelogin
                  ? Icons.refresh_rounded
                  : (needsLogin
                      ? Icons.login_rounded
                      : Icons.cloud_upload_rounded)),
          title: Text(_needsRelogin
              ? '重新登录并推送'
              : (needsLogin ? '登录并推送当前配置' : '推送当前配置')),
          // Every login-flavoured branch says the merge out loud, because
          // `ConfigSyncController.login` pulls the stored config and applies it
          // BEFORE this screen pushes — and `ConfigPayload.applyTo` lets any
          // non-empty remote value win. So the upload that follows carries the
          // MERGED result: a WebDAV token changed on the phone but not yet
          // published can be replaced by the server's older one and then frozen
          // back into it. The pull is not removable (the web build's login is the
          // same call), so the button has to stop describing itself as a one-way
          // publish. The no-login branch really is one-way, and says so.
          subtitle: Text(_needsRelogin
              ? '上次推送时服务端说会话已失效，需要重新登录一次；'
                  '登录会先合并服务器上已有的配置（服务器已有的值优先），再整份上传'
              : (addressChanged
                  ? '服务器地址改过了，现有会话属于旧地址 —— 会重新登录到新地址；'
                      '登录会先合并该服务器已有的配置（它已有的值优先），再整份上传'
                  : (needsLogin
                      ? '先登录换取会话令牌 —— 登录会把服务器上已有的配置合并进本机'
                          '（服务器已有的值优先），然后把合并结果整份上传'
                      : '已持有会话，直接无条件上传本机当前配置'
                          '（不再拉取合并，也不做「没改过就跳过」判断）'))),
          enabled: !_busy,
          onTap: _busy ? null : () => _run(withLogin: needsLogin),
        ),
        if (loggedIn)
          ListTile(
            leading: const Icon(Icons.logout_rounded),
            title: const Text('退出登录'),
            subtitle: const Text('只丢弃会话令牌，本机数据与配置一律不动'),
            enabled: !_busy,
            onTap: _busy ? null : _logout,
          ),
        ListTile(
          dense: true,
          leading: Icon(
            loggedIn ? Icons.verified_user_rounded : Icons.lock_open_rounded,
            color: loggedIn ? cs.primary : cs.onSurfaceVariant,
          ),
          title: Text(loggedIn ? '当前状态：已登录' : '当前状态：未登录'),
          subtitle: Text(_lastPushAt == null
              ? '本次进入此页后还没有成功推送过'
              : '上次成功推送：${_hhmmss(_lastPushAt!)}'),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _message!,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: _isError ? cs.error : cs.onSurfaceVariant,
              ),
            ),
          ),
        if (usingDefaultPassword)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.errorContainer,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: cs.error.withValues(alpha: 0.4)),
            ),
            child: Text(
              '服务端仍在使用默认密码 admin / admin —— 任何能连到它的人都能读走刚推上去的'
              '全部凭据。手机端没有改密入口，请在浏览器打开 $consoleUrl 登录后修改。',
              style: TextStyle(
                  fontSize: 12, height: 1.6, color: cs.onErrorContainer),
            ),
          ),
      ],
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

/// Live-saving text field. Mirrors the pattern in the imghost screen so
/// every keystroke writes through to settings — no save button needed.
///
/// [_TextSetting.controlled] is the second mode: the CALLER owns the controller
/// and there is no write-through. The console section needs it because its
/// password must exist in exactly one place, be released with the page, and
/// never be handed to a persisting `onChanged`.
class _TextSetting extends StatefulWidget {
  final IconData icon;
  final String label;
  final String value;
  final ValueChanged<String>? onChanged;
  final String? hint;
  final bool obscure;

  /// Non-null → caller-owned; this widget must not dispose it.
  final TextEditingController? controller;
  final bool enabled;

  /// Keyboard affordances, matching the login screen's fields. Defaulted so the
  /// existing live-saving call sites are unchanged.
  final TextInputType? keyboardType;
  final bool autocorrect;
  final ValueChanged<String>? onSubmitted;

  const _TextSetting(this.icon, this.label, this.value, this.onChanged,
      {this.hint, this.obscure = false})
      : controller = null,
        enabled = true,
        keyboardType = null,
        autocorrect = true,
        onSubmitted = null;

  const _TextSetting.controlled(this.icon, this.label, this.controller,
      {this.hint,
      this.obscure = false,
      this.enabled = true,
      this.keyboardType,
      this.autocorrect = true,
      this.onSubmitted})
      : value = '',
        onChanged = null;

  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  /// Only set in the live-saving mode; null when the caller supplied one.
  TextEditingController? _owned;

  TextEditingController get _ctrl => widget.controller ?? _owned!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _owned = TextEditingController(text: widget.value);
    }
  }

  @override
  void didUpdateWidget(covariant _TextSetting old) {
    super.didUpdateWidget(old);
    final owned = _owned;
    if (owned != null && widget.value != old.value && widget.value != owned.text) {
      owned.text = widget.value;
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: TextField(
        controller: _ctrl,
        obscureText: widget.obscure,
        enabled: widget.enabled,
        keyboardType: widget.keyboardType,
        autocorrect: widget.autocorrect,
        onSubmitted: widget.onSubmitted,
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
