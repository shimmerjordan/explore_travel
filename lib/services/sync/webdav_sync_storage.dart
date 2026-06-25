import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:webdav_client/webdav_client.dart' as wd;

import '../webdav/webdav_service.dart';
import 'sync_storage.dart';

/// [SyncStorage] over a generic WebDAV server, addressing shards as files
/// under [WebDavService.syncRoot] (`/explore_journal/Sync/<rel>`).
///
/// Uses the byte-level `write` / `read` / `remove` methods of the underlying
/// `webdav_client` (all dio-based and `CancelToken`-aware), so unlike the
/// legacy zip backup there's no temp-file round-trip. Native only on the
/// direct path — most WebDAV servers send no CORS headers, so the browser
/// reaches them through the NAS proxy instead (a later phase).
class WebdavSyncStorage implements SyncStorage {
  final WebDavService _dav;
  WebdavSyncStorage(this._dav);

  String _full(String rel) => '${WebDavService.syncRoot}/$rel';

  /// Parent directory of [_full]`(rel)`, for [wd.Client.mkdirAll].
  String _parentDir(String full) {
    final i = full.lastIndexOf('/');
    return i <= 0 ? '/' : full.substring(0, i);
  }

  wd.Client get _client {
    final c = _dav.rawClient;
    if (c == null) throw StateError('WebDAV 未配置');
    return c;
  }

  @override
  Future<void> putSyncFile(String rel, List<int> bytes,
      {CancelToken? cancelToken}) async {
    final full = _full(rel);
    // Ensure the (possibly nested) parent exists. mkdirAll is idempotent;
    // swallow its errors EXCEPT a cancellation, which must propagate.
    try {
      await _client.mkdirAll(_parentDir(full), cancelToken);
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
    }
    await _client.write(full, Uint8List.fromList(bytes),
        cancelToken: cancelToken);
  }

  @override
  Future<Uint8List?> getSyncFile(String rel, {CancelToken? cancelToken}) async {
    try {
      final data = await _client.read(_full(rel), cancelToken: cancelToken);
      return Uint8List.fromList(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<void> deleteSyncFile(String rel, {CancelToken? cancelToken}) async {
    try {
      await _client.remove(_full(rel), cancelToken);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return; // idempotent
      rethrow;
    }
  }
}
