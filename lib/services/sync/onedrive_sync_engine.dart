import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../backup/backup_service.dart';
import 'sync_storage.dart';

class SyncUpResult {
  final int uploaded;
  final int deleted;
  final int unchanged;
  const SyncUpResult(this.uploaded, this.deleted, this.unchanged);
}

/// (done, total, label) progress callback for the sync engine.
typedef SyncProgress = void Function(int done, int total, String label);

/// FOW-style incremental sync — **sharded**, transport-agnostic.
///
/// Drives a [SyncStorage] (OneDrive / WebDAV / GitHub / NAS proxy) through a
/// 3-method byte interface, so the shard / diff / merge pipeline below is
/// identical regardless of where the bytes actually land. (Historically this
/// only spoke to OneDrive — hence the file name; the body no longer knows.)
///
/// The backup archive explodes into tens of thousands of tiny files (one
/// 512-byte `.bin` per fog block). Uploading each as its own HTTP request is
/// brutally slow and makes per-file progress read as "0%". So instead of
/// syncing archive entries 1:1, we group them into a MODEST number of
/// medium-sized shard zips under the transport's Sync root:
///
///   * fog blocks → one shard per ~16 FOW tiles (`fog/<layer>/<bx>_<by>.zip`),
///     just like Fog of World keeps per-tile files — spatially local, so only
///     shards near recently-explored areas change;
///   * track points / chat → one shard per month / per peer;
///   * journal → a single `journal.zip` (text, rarely huge);
///   * everything small & rarely-changed (settings, layers, leaderboard,
///     geocode, …) → one `meta.zip`.
///
/// A `.ej_index.json` maps shard → MD5. We upload only shards whose MD5 changed
/// (git-like: unchanged history is never re-sent), delete vanished ones, and
/// reassemble everything on restore. Shard zips are packed deterministically
/// (sorted entries, zeroed mtime) so an unchanged shard keeps the same MD5.
class SyncEngine {
  final Ref ref;
  SyncEngine(this.ref);

  static const _indexName = '.ej_index.json';

  /// Test seam for [_shardFor] — the shard-routing logic is pure and worth
  /// pinning without standing up a transport.
  @visibleForTesting
  static String shardFor(String path) => _shardFor(path);

  /// Which shard an archive entry belongs to. Pure function of the path so the
  /// grouping is stable across runs.
  static String _shardFor(String path) {
    if (path == 'fog/index.json') return 'fogindex.zip';
    if (path.startsWith('fog/')) {
      final parts = path.split('/'); // fog / <layer> / <tx>_<ty>_<z>.bin
      if (parts.length >= 3) {
        final layer = parts[1];
        final coords = parts[2].split('_');
        final tx = int.tryParse(coords.isNotEmpty ? coords[0] : '0') ?? 0;
        final ty = int.tryParse(coords.length > 1 ? coords[1] : '0') ?? 0;
        // tileX/tileY are block-global coords (fowTile*128 + block). >>9 groups
        // a 4×4 patch of FOW tiles into one medium shard.
        return 'fog/$layer/${tx >> 9}_${ty >> 9}.zip';
      }
      return 'fog/misc.zip';
    }
    if (path.startsWith('track_points/')) {
      return 'tracks/${path.split('/').last.replaceAll('.jsonl', '')}.zip';
    }
    if (path.startsWith('chat_messages/')) {
      return 'chat/${path.split('/').last.replaceAll('.jsonl', '')}.zip';
    }
    if (path.startsWith('journal/')) return 'journal.zip';
    return 'meta.zip';
  }

  static String _fmtSize(int b) => b < 1024
      ? '${b}B'
      : b < 1024 * 1024
          ? '${(b / 1024).toStringAsFixed(0)}KB'
          : '${(b / 1024 / 1024).toStringAsFixed(1)}MB';

  static void _throwIfCancelled(CancelToken? t) {
    if (t != null && t.isCancelled) throw StateError('已取消');
  }

  /// Export selected modules, group into shards, push only changed/new shards.
  Future<SyncUpResult> syncUp({
    required Set<String> modules,
    SyncProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    final od = ref.read(syncStorageProvider);

    onProgress?.call(0, 1, '导出本地数据…');
    debugPrint('[Sync] export modules: ${modules.join(',')}');
    final archiveBytes =
        await ref.read(backupServiceProvider).exportToArchive(modules);
    final files = _unzip(archiveBytes);
    debugPrint('[Sync] archive entries: ${files.length}');

    onProgress?.call(0, 1, '打包分片…（${files.length} 个文件）');
    // Group entries → shards, then pack each shard deterministically.
    final grouped = <String, Map<String, List<int>>>{};
    for (final e in files.entries) {
      (grouped[_shardFor(e.key)] ??= {})[e.key] = e.value;
    }
    final packed = <String, Uint8List>{};
    final localIndex = <String, String>{};
    for (final e in grouped.entries) {
      final bytes = _packShard(e.value);
      packed[e.key] = bytes;
      localIndex[e.key] = md5.convert(bytes).toString();
    }
    debugPrint('[Sync] ${files.length} files → ${packed.length} shards');

    onProgress?.call(0, 1, '读取云端索引…');
    final remoteIndex = await _readIndex(od, cancelToken);

    final toUpload = [
      for (final s in packed.keys)
        if (remoteIndex[s] != localIndex[s]) s,
    ];
    final toDelete = [
      for (final s in remoteIndex.keys)
        if (!localIndex.containsKey(s)) s,
    ];
    debugPrint('[Sync] up: ${toUpload.length} changed, '
        '${toDelete.length} to delete, '
        '${packed.length - toUpload.length} unchanged shards');

    final total = toUpload.length + toDelete.length + 1; // +1 = index write
    if (toUpload.isEmpty && toDelete.isEmpty) {
      onProgress?.call(0, 1, '云端已是最新，无需上传');
    }
    var done = 0;

    for (final s in toUpload) {
      _throwIfCancelled(cancelToken);
      final size = packed[s]!.length;
      onProgress?.call(
          done, total, '上传分片 ${done + 1}/$total · $s（${_fmtSize(size)}）');
      debugPrint('[Sync] ↑ $s (${_fmtSize(size)})');
      await od.putSyncFile(s, packed[s]!, cancelToken: cancelToken);
      done++;
    }
    for (final s in toDelete) {
      _throwIfCancelled(cancelToken);
      onProgress?.call(done, total, '删除分片 ${done + 1}/$total · $s');
      debugPrint('[Sync] ✗ $s');
      await od.deleteSyncFile(s, cancelToken: cancelToken);
      done++;
    }
    _throwIfCancelled(cancelToken);
    onProgress?.call(done, total, '写入索引…');
    await od.putSyncFile(
        _indexName, utf8.encode(jsonEncode(localIndex)),
        cancelToken: cancelToken);
    done++;
    onProgress?.call(done, total, '完成');
    debugPrint('[Sync] up complete');

    return SyncUpResult(
      toUpload.length,
      toDelete.length,
      packed.length - toUpload.length,
    );
  }

  /// Pull the Sync shards back, reassemble the archive, and merge it in.
  Future<ImportSummary?> syncDown({
    required Set<String> modules,
    required bool clearBeforeImport,
    SyncProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    final od = ref.read(syncStorageProvider);
    onProgress?.call(0, 1, '读取云端索引…');
    final remoteIndex = await _readIndex(od, cancelToken);
    if (remoteIndex.isEmpty) {
      debugPrint('[Sync] down: remote Sync folder is empty');
      return null;
    }

    final shards = remoteIndex.keys.toList();
    final total = shards.length + 1; // +1 = import step
    var done = 0;
    final files = <String, List<int>>{};
    for (final s in shards) {
      _throwIfCancelled(cancelToken);
      onProgress?.call(done, total, '下载分片 ${done + 1}/$total · $s');
      debugPrint('[Sync] ↓ $s');
      final bytes = await od.getSyncFile(s, cancelToken: cancelToken);
      if (bytes != null) {
        // Unpack the shard's member entries back into the merged archive map.
        _unzip(Uint8List.fromList(bytes)).forEach((k, v) => files[k] = v);
      }
      done++;
    }

    _throwIfCancelled(cancelToken);
    onProgress?.call(done, total, '合并导入…（${files.length} 个文件）');
    debugPrint('[Sync] importing ${files.length} files');
    final zip = _zip(files);
    final summary = await ref.read(backupServiceProvider).importFromArchive(
          zip,
          modules: modules,
          clearBeforeImport: clearBeforeImport,
        );
    done++;
    onProgress?.call(done, total, '完成');
    debugPrint('[Sync] down complete');
    return summary;
  }

  Future<Map<String, String>> _readIndex(
      SyncStorage od, CancelToken? cancelToken) async {
    final bytes = await od.getSyncFile(_indexName, cancelToken: cancelToken);
    if (bytes == null) return {};
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  Map<String, List<int>> _unzip(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final out = <String, List<int>>{};
    for (final f in archive) {
      if (f.isFile) out[f.name] = f.content as List<int>;
    }
    return out;
  }

  /// Deterministic shard zip: entries sorted, mtime zeroed — so an unchanged
  /// shard always hashes the same (otherwise wall-clock mtime would change the
  /// MD5 every run and defeat the incremental diff).
  Uint8List _packShard(Map<String, List<int>> entries) {
    final archive = Archive();
    final keys = entries.keys.toList()..sort();
    for (final k in keys) {
      final f = ArchiveFile(k, entries[k]!.length, entries[k]!);
      f.lastModTime = 0;
      archive.addFile(f);
    }
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  Uint8List _zip(Map<String, List<int>> files) {
    final archive = Archive();
    for (final e in files.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }
}

final syncEngineProvider = Provider<SyncEngine>((ref) => SyncEngine(ref));
