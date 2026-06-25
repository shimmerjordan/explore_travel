import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sync_storage.dart';

/// [SyncStorage] whose transport is resolved from the decrypted zero-knowledge
/// vault, and which (on web) routes reads through the NAS CORS proxy so the
/// browser never holds the real PAT / WebDAV credentials.
///
/// **Stub.** The vault (Phase 1) and the NAS proxy (Phase 4) don't exist yet,
/// so the methods throw a clear `UnimplementedError`. It exists now only so the
/// `syncStorageProvider` factory has a real type for the `'nas'` case and the
/// whole tree compiles. Construction is intentionally cheap and side-effect
/// free; the error only surfaces if something actually drives a NAS sync.
class NasVaultBackedStorage implements SyncStorage {
  // ignore: unused_field
  final Ref _ref;
  NasVaultBackedStorage(this._ref);

  static const _todo =
      'NAS 同步后端尚未实现（计划 Phase 1 保险箱 + Phase 4 代理）';

  @override
  Future<void> putSyncFile(String rel, List<int> bytes,
          {CancelToken? cancelToken}) async =>
      throw UnimplementedError(_todo);

  @override
  Future<Uint8List?> getSyncFile(String rel, {CancelToken? cancelToken}) async =>
      throw UnimplementedError(_todo);

  @override
  Future<void> deleteSyncFile(String rel, {CancelToken? cancelToken}) async =>
      throw UnimplementedError(_todo);
}
