import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:path/path.dart' as p;

import 'sync_storage.dart';

/// A [SyncStorage] backed by a plain on-disk directory.
///
/// It honours the exact same 3-method byte contract as the OneDrive / WebDAV /
/// GitHub transports, so [SyncEngine] drives it with ZERO behavioural change —
/// the only difference is the bytes land in a local folder instead of the
/// cloud. The folder ends up byte-for-byte identical to a OneDrive Sync folder:
/// `meta.zip`, `journal.zip`, `tracks/<yyyy>.zip`, `fow/<layer>/<tile>`, and the
/// `.ej_index.json` MD5 map.
///
/// Why it exists: it makes "导出到本地文件夹 → 从本地文件夹导入" the SAME code path
/// as "同步到 OneDrive → 从 OneDrive 恢复". A sync bug can then be reproduced and
/// debugged with no network and no second device — a round-trip through this
/// folder IS the OneDrive round-trip. (The in-memory `FakeSyncStorage` in tests
/// is the same idea; this is its on-device sibling.)
class LocalFolderStorage implements SyncStorage {
  /// Absolute path to the sync-root directory. Relative shard paths hang off it.
  final String root;
  LocalFolderStorage(this.root);

  File _fileFor(String rel) => File(p.join(root, p.joinAll(rel.split('/'))));

  @override
  Future<void> putSyncFile(String rel, List<int> bytes,
      {CancelToken? cancelToken}) async {
    final f = _fileFor(rel);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> getSyncFile(String rel, {CancelToken? cancelToken}) async {
    // Contract: a missing file is null, never a throw (the engine reads that as
    // "empty remote" / "skip shard").
    final f = _fileFor(rel);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  @override
  Future<void> deleteSyncFile(String rel, {CancelToken? cancelToken}) async {
    // Idempotent — a missing file is a no-op, matching the cloud transports.
    final f = _fileFor(rel);
    if (await f.exists()) await f.delete();
  }
}
