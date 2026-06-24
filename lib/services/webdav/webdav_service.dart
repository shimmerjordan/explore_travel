import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webdav_client/webdav_client.dart' as wd;
import '../../core/prefs.dart';

/// WebDAV-backed backup/sync of the SQLite database and media files.
/// All data is packaged as a single .zip uploaded to a remote folder. We also
/// support a "mailbox" pattern for P2P offline messaging.
class WebDavService {
  wd.Client? _client;

  void configure(AppSettings s) {
    if (s.webdavUrl == null || s.webdavUser == null || s.webdavPass == null) {
      _client = null;
      return;
    }
    _resolvedUrl = _normalizeUrl(s.webdavUrl!);
    _client = wd.newClient(
      _resolvedUrl!,
      user: s.webdavUser!,
      password: s.webdavPass!,
      debug: false,
    );
    _client!.setHeaders({'Accept': '*/*'});
    // Fail fast on an unreachable server instead of hanging the UI: a dead
    // network should surface a connect error in ~3s, not spin indefinitely.
    _client!.setConnectTimeout(3000);
    _client!.setSendTimeout(60000);
    _client!.setReceiveTimeout(60000);
  }

  /// Tolerate the common "I typed dav.jianguoyun.com/dav/" mistake by
  /// inserting an `https://` prefix. Carefully preserves any port the user
  /// did type (e.g. `192.168.1.10:5005/webdav` becomes
  /// `https://192.168.1.10:5005/webdav`, port intact).
  ///
  /// Also handles the IP+port case where Dart's `Uri.parse` would otherwise
  /// interpret `192.168.1.10:5005` as scheme=`192.168.1.10`, port=5005
  /// (and throw because the scheme must start with a letter).
  static String _normalizeUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    final lower = s.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      // Already has a scheme — pass through, but lowercase the scheme so a
      // typo like `HTTP://...` doesn't trip downstream parsers.
      final idx = s.indexOf('://');
      s = s.substring(0, idx).toLowerCase() + s.substring(idx);
      return s;
    }
    // No scheme. Default to https for public hosts, but http for raw IPs
    // and `localhost` since those are almost always plaintext WebDAV
    // (AList, dav.sh, debug servers).
    final hostPart = s.split('/').first.split(':').first;
    final isIp = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(hostPart);
    final isLocal = hostPart == 'localhost' || hostPart.startsWith('127.');
    final scheme = (isIp || isLocal) ? 'http' : 'https';
    return '$scheme://$s';
  }

  bool get isReady => _client != null;

  /// Last URL we built a client for, including any scheme we had to inject.
  /// Exposed so the test button can show users what's actually being hit —
  /// the #1 source of confusion is "I typed a port but it isn't being used".
  String? _resolvedUrl;
  String? get resolvedUrl => _resolvedUrl;

  /// Round-trip sanity check: ensures the backup folder exists and we can
  /// list it. Returns null on success, or a human-readable error string.
  /// Used by the backup screen's "测试" button.
  ///
  /// Always returns the full parsed URI breakdown so users can spot port-
  /// vs-path confusion (the #1 footgun — `/4918/` as path vs `:4918/` as
  /// port — both look fine in the input box).
  Future<String?> testConnection() async {
    if (_client == null) return 'WebDAV 未配置';
    final detail = _describeParsedUrl();
    try {
      await _ensureDir('/explore_journal');
      final files = await _client!.readDir('/explore_journal');
      return 'ok · 目录可读，已有 ${files.length} 个文件\n$detail';
    } catch (e) {
      return 'error: $e\n$detail';
    }
  }

  /// Break the resolved URL into scheme / host / port / path so users see
  /// exactly which port is in play — especially important when they typed
  /// `http://host/1234/` thinking 1234 is the port (it's the path).
  String _describeParsedUrl() {
    final url = _resolvedUrl ?? '';
    Uri? u;
    try {
      u = Uri.parse(url);
    } catch (_) {}
    if (u == null) return '解析后的 URL: $url (无法解析)';
    final defaultPort = (u.scheme == 'https') ? 443 : 80;
    final port = u.hasPort ? u.port : defaultPort;
    final note = !u.hasPort
        ? '  ⚠ 没填端口，回退到默认 $port — 如果 4918 之类的数字是端口，'
            '应该写成 ${u.scheme}://${u.host}:<port>${u.path}'
        : '';
    return '解析后的 URL: $url\n'
        '  scheme: ${u.scheme}\n'
        '  host:   ${u.host}\n'
        '  port:   $port\n'
        '  path:   ${u.path}\n'
        '$note';
  }

  Future<void> _ensureDir(String dir) async {
    try {
      await _client!.mkdirAll(dir);
    } catch (_) {}
  }

  Future<File> _buildArchive() async {
    final supportDir = await getApplicationSupportDirectory();
    final docsDir = await getApplicationDocumentsDirectory();
    final tmp = await getTemporaryDirectory();
    final out = File(p.join(tmp.path, 'explore_journal_backup.zip'));
    if (out.existsSync()) out.deleteSync();
    final encoder = ZipFileEncoder()..create(out.path);
    final dbFile = File(p.join(supportDir.path, 'explore_journal.sqlite'));
    if (dbFile.existsSync()) {
      encoder.addFile(dbFile, 'explore_journal.sqlite');
    }
    final mediaDir = Directory(p.join(docsDir.path, 'media'));
    if (mediaDir.existsSync()) {
      encoder.addDirectory(mediaDir, includeDirName: true);
    }
    encoder.close();
    return out;
  }

  Future<void> backup() async {
    if (_client == null) throw StateError('WebDAV not configured');
    await _ensureDir('/explore_journal');
    final zip = await _buildArchive();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final remote = '/explore_journal/backup_$ts.zip';
    await _client!.writeFromFile(zip.path, remote);
    await _client!.writeFromFile(zip.path, '/explore_journal/latest.zip');
  }

  /// Downloads the latest backup zip from WebDAV and extracts it into the app
  /// storage (overwriting the SQLite db and `media/` directory). Caller should
  /// restart the app afterwards so Drift reopens the new database file.
  Future<void> restoreLatest() async {
    if (_client == null) throw StateError('WebDAV not configured');
    final tmp = await getTemporaryDirectory();
    final localZip = File(p.join(tmp.path, 'restore.zip'));
    if (localZip.existsSync()) localZip.deleteSync();
    await _client!.read2File('/explore_journal/latest.zip', localZip.path);

    final supportDir = await getApplicationSupportDirectory();
    final docsDir = await getApplicationDocumentsDirectory();
    final bytes = await localZip.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive) {
      if (entry.isFile) {
        String target;
        if (entry.name == 'explore_journal.sqlite') {
          target = p.join(supportDir.path, entry.name);
        } else if (entry.name.startsWith('media/')) {
          target = p.join(docsDir.path, entry.name);
        } else {
          continue;
        }
        final f = File(target);
        await f.create(recursive: true);
        await f.writeAsBytes(entry.content as List<int>);
      }
    }
  }

  Future<List<String>> listBackups() async {
    if (_client == null) return [];
    try {
      final files = await _client!.readDir('/explore_journal');
      return files
          .where((f) =>
              f.name != null &&
              f.name!.startsWith('backup_') &&
              f.name!.endsWith('.zip'))
          .map((f) => f.name!)
          .toList()
        ..sort((a, b) => b.compareTo(a));
    } catch (_) {
      return [];
    }
  }

  /// Restores a specific backup file by name. Path is the file name within
  /// `/explore_journal/` (e.g. `backup_2026-05-20T...zip`).
  Future<void> restoreFromName(String filename) async {
    if (_client == null) throw StateError('WebDAV not configured');
    final tmp = await getTemporaryDirectory();
    final localZip = File(p.join(tmp.path, 'restore.zip'));
    if (localZip.existsSync()) localZip.deleteSync();
    await _client!
        .read2File('/explore_journal/$filename', localZip.path);
    final supportDir = await getApplicationSupportDirectory();
    final docsDir = await getApplicationDocumentsDirectory();
    final archive = ZipDecoder().decodeBytes(await localZip.readAsBytes());
    for (final entry in archive) {
      if (!entry.isFile) continue;
      String target;
      if (entry.name == 'explore_journal.sqlite') {
        target = p.join(supportDir.path, entry.name);
      } else if (entry.name.startsWith('media/')) {
        target = p.join(docsDir.path, entry.name);
      } else {
        continue;
      }
      final f = File(target);
      await f.create(recursive: true);
      await f.writeAsBytes(entry.content as List<int>);
    }
  }

  /// Mailbox-style messaging: write a message JSON to recipient's WebDAV inbox.
  Future<void> sendMail(String recipient, Map<String, dynamic> message) async {
    if (_client == null) throw StateError('WebDAV not configured');
    final dir = '/explore_journal/mailbox/$recipient';
    await _ensureDir(dir);
    final id = DateTime.now().microsecondsSinceEpoch;
    final remote = '$dir/$id.json';
    final tmp = await getTemporaryDirectory();
    final f = File(p.join(tmp.path, 'mail_$id.json'));
    await f.writeAsString(jsonEncode(message));
    await _client!.writeFromFile(f.path, remote);
  }

  // ─── Modular JSON backup (used by the merged backup screen) ─────────
  //
  // These coexist with the older zip-based backup above. The merged UI
  // writes one timestamped JSON file per "立即备份" and tracks a
  // `latest.json` pointer for quick restore-most-recent. The body is
  // produced by [BackupService.exportToJson], which already handles
  // per-module selection.

  /// Upload a chunked-zip backup archive built by [BackupService]. Also
  /// refreshes a `latest.zip` pointer for one-tap restore.
  Future<void> uploadArchive(String filename, List<int> bytes) async {
    if (_client == null) throw StateError('WebDAV 未配置');
    await _ensureDir('/explore_journal');
    final tmp = await getTemporaryDirectory();
    final f = File(p.join(tmp.path, 'out_$filename'));
    await f.writeAsBytes(bytes);
    await _client!.writeFromFile(f.path, '/explore_journal/$filename');
    await _client!.writeFromFile(f.path, '/explore_journal/latest.zip');
  }

  Future<List<int>> downloadArchive(String filename) async {
    if (_client == null) throw StateError('WebDAV 未配置');
    final tmp = await getTemporaryDirectory();
    final local = File(p.join(
        tmp.path, 'in_${DateTime.now().microsecondsSinceEpoch}.zip'));
    await _client!.read2File('/explore_journal/$filename', local.path);
    return local.readAsBytes();
  }

  Future<List<String>> listArchives() async {
    if (_client == null) return [];
    try {
      final files = await _client!.readDir('/explore_journal');
      return files
          .where((f) =>
              f.name != null &&
              f.name!.startsWith('explore_journal_backup_') &&
              f.name!.endsWith('.zip'))
          .map((f) => f.name!)
          .toList()
        ..sort((a, b) => b.compareTo(a));
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> readMail(String self) async {
    if (_client == null) return [];
    final dir = '/explore_journal/mailbox/$self';
    try {
      final files = await _client!.readDir(dir);
      final tmp = await getTemporaryDirectory();
      final out = <Map<String, dynamic>>[];
      for (final f in files) {
        if (f.name == null || !f.name!.endsWith('.json')) continue;
        final local = File(p.join(tmp.path, 'in_${f.name}'));
        await _client!.read2File('$dir/${f.name}', local.path);
        out.add(jsonDecode(await local.readAsString()));
        await _client!.remove('$dir/${f.name}');
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}
