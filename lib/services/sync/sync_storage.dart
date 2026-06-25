import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;

/// Byte-oriented transport for FOW-style incremental sync **shards**.
///
/// [SyncEngine] depends only on this 3-method contract, so the actual remote
/// (OneDrive / WebDAV / GitHub / a NAS proxy) is swappable without touching
/// the shard / diff / merge / zip pipeline. Files are addressed by a
/// forward-slash relative path under each implementation's own sync root —
/// e.g. `meta.zip`, `fog/<layer>/<bx>_<by>.zip`, `.ej_index.json`.
///
/// The method names match what [OneDriveService] already exposed, so the
/// historical OneDrive transport implements this interface with no behavioural
/// change (the whole point of P0: decouple transport, keep native byte-for-byte
/// identical).
abstract class SyncStorage {
  /// Upload [bytes] to [rel], overwriting any existing file at that path.
  Future<void> putSyncFile(String rel, List<int> bytes,
      {CancelToken? cancelToken});

  /// Download [rel], or `null` when it does not exist. Implementations MUST
  /// map a missing file to `null` rather than throwing — [SyncEngine] treats a
  /// `null` index read as "empty remote" and a `null` shard read as "skip".
  Future<Uint8List?> getSyncFile(String rel, {CancelToken? cancelToken});

  /// Delete [rel]. A missing file is a no-op (idempotent) — the engine deletes
  /// vanished shards without first checking they exist.
  Future<void> deleteSyncFile(String rel, {CancelToken? cancelToken});
}

/// String values for [AppSettings.syncBackend]. Kept as plain constants (not an
/// enum) so the persisted prefs JSON stays human-readable and forward-tolerant
/// — an unknown value falls back to [onedrive] at the provider.
class SyncBackend {
  const SyncBackend._();

  /// Microsoft Graph app-folder sync. The historical default; mobile keeps it.
  static const onedrive = 'onedrive';

  /// GitHub Contents API (shards stored as repo files). Native only — never
  /// usable from the browser (the PAT must not enter web JS).
  static const github = 'github';

  /// Generic WebDAV server. Native only on the direct path (most WebDAV
  /// servers send no CORS headers, so the browser reaches them via the NAS
  /// proxy instead).
  static const webdav = 'webdav';

  /// The NAS-vault-backed transport: credentials come from the decrypted
  /// zero-knowledge vault and, on web, reads route through the NAS proxy.
  /// Lands fully in a later phase.
  static const nas = 'nas';

  static const all = <String>[onedrive, github, webdav, nas];
}
