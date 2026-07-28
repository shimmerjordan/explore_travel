import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show TableUpdate;
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
///
/// The engine reports done on a fixed 0..1000 permille scale spanning the
/// WHOLE pipeline (export → pack → diff → transfer → index), so the UI's
/// `done/total` bar moves through every stage instead of sitting at 0% while
/// the local export runs.
typedef SyncProgress = void Function(int done, int total, String label);

/// FOW-style incremental sync — **sharded**, transport-agnostic.
///
/// Drives a [SyncStorage] (OneDrive / WebDAV / GitHub / NAS proxy) through a
/// 3-method byte interface, so the shard / diff / merge pipeline below is
/// identical regardless of where the bytes actually land. (Historically this
/// only spoke to OneDrive — hence the file name; the body no longer knows.)
///
/// Most archive entries are grouped into a SMALL number of chunky shard
/// zips under the transport's Sync root (uploading tens of thousands of
/// tiny files 1:1 is brutally slow):
///
///   * fog → **native Fog of World tile files**, passed through RAW and
///     1:1 (`fow/<layerUuid>/<obfuscatedName>`, one per 128×128-block FoW
///     tile). NOT zipped: the cloud folder stays byte-compatible with a
///     Fog of World Sync folder — copy files either way to interop — and
///     the files are already zlib-compressed and spatially local, so only
///     tiles near recently-explored areas re-upload. Their updatedAt /
///     erase-mask side-cars ride in `fogindex.zip`;
///   * track points → one shard per **year** (`tracks/<yyyy>.zip`; entries
///     inside stay monthly);
///   * chat → one shard per peer; journal → a single `journal.zip`;
///   * everything small & rarely-changed (settings, layers, leaderboard,
///     geocode, …) → one `meta.zip`.
///
/// A zip shard whose raw entries exceed [_kShardPartRawCap] is split into
/// deterministic `.pN.zip` parts (sorted entries, greedy fill), which keeps
/// every uploaded file within the transports' simple-PUT comfort zone no
/// matter how dense one region gets. (`fow/` files are never split — they
/// must stay whole to remain FoW-readable, and never come close to the cap.)
///
/// A `.ej_index.json` maps shard → MD5. We upload only shards whose MD5
/// changed (git-like: unchanged history is never re-sent), delete vanished
/// ones, and reassemble everything on restore. Shard zips are packed
/// deterministically (sorted entries, zeroed mtime) so an unchanged shard
/// keeps the same MD5; FoW tile files are deterministic by construction
/// (blocks written in grid order, no timestamps in the format).
///
/// NOTE: shard layouts changed twice in 2026-07 (>>11 fog grouping + yearly
/// tracks, then fog → native FoW files). The first syncUp after upgrading
/// re-uploads everything and deletes old-layout shards — a one-time cost;
/// the MD5 diff then works exactly as before. syncDown still understands
/// the old layouts, so pull-before-push keeps working mid-upgrade.
class SyncEngine {
  final Ref ref;
  SyncEngine(this.ref);

  static const _indexName = '.ej_index.json';

  /// Split threshold for one shard part, measured on the RAW (pre-deflate)
  /// entry bytes. Our payloads (sparse fog bitmaps, jsonl) deflate ~3-4×, so
  /// 24 MiB raw lands around 6–9 MB zipped — the user-approved ≤10 MB per
  /// file. Files past the simple-PUT limits go through upload sessions.
  static const int _kShardPartRawCap = 24 << 20;

  /// Pack shards bigger than this off the UI isolate (deflate is CPU-bound).
  static const int _kIsolatePackThreshold = 384 << 10;

  /// Concurrent transfer width for LARGE uploads (multi-MB shard zips).
  /// Modest on purpose: enough to hide per-request latency without
  /// saturating a mobile uplink or tripping Graph / WebDAV throttling.
  static const int _kTransferConcurrency = 3;

  /// Width for small files and for downloads. The native FoW tiles are
  /// tens-of-KB each, so transfers are LATENCY-bound, not bandwidth-bound —
  /// there is no "upload a whole folder in one request" primitive in Graph /
  /// WebDAV, so the way to make many small files fast is higher parallelism
  /// (still far below Graph's throttling thresholds).
  static const int _kSmallTransferConcurrency = 8;

  /// Uploads at or below this size ride the [_kSmallTransferConcurrency]
  /// pool; bigger ones the [_kTransferConcurrency] pool.
  static const int _kSmallFileCap = 1 << 20;

  /// Test seam for [_shardFor] — the shard-routing logic is pure and worth
  /// pinning without standing up a transport.
  @visibleForTesting
  static String shardFor(String path) => _shardFor(path);

  /// Which shard an archive entry belongs to. Pure function of the path so the
  /// grouping is stable across runs.
  static String _shardFor(String path) {
    // Native FoW tile files travel 1:1 and UNzipped — the shard IS the
    // entry, so the cloud folder stays a valid Fog of World tile set.
    if (path.startsWith('fow/')) return path;
    if (path == 'fog/index.json' || path == 'fog/erases.jsonl') {
      return 'fogindex.zip';
    }
    if (path.startsWith('fog/')) {
      // Legacy v2 entries (fog/<layerId>/<x>_<y>_<z>.bin) — export no longer
      // emits them, but keep the routing stable for old archives in tests.
      final parts = path.split('/');
      if (parts.length >= 3) {
        final layer = parts[1];
        final coords = parts[2].split('_');
        final tx = int.tryParse(coords.isNotEmpty ? coords[0] : '0') ?? 0;
        final ty = int.tryParse(coords.length > 1 ? coords[1] : '0') ?? 0;
        return 'fog/$layer/${tx >> 11}_${ty >> 11}.zip';
      }
      return 'fog/misc.zip';
    }
    if (path.startsWith('track_points/')) {
      // track_points/<yyyy-mm>.jsonl → one shard per YEAR. Only the current
      // year's shard changes as new points arrive; past years stay put.
      final base = path.split('/').last.replaceAll('.jsonl', '');
      final year = base.split('-').first;
      return 'tracks/$year.zip';
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

  // ── 增量导出缓存 ────────────────────────────────────────────────────────
  // 同步的最大耗时曾是：每次 syncUp/syncDown 都全量导出所有模块（全表读 +
  // jsonEncode + FoW 瓦片重建 + 逐分片 MD5）——哪怕数据一行没变。这里把导出
  // 拆成分片组（journal / tracks / chat / fog / meta），每组用 drift 表版本
  // 计数器做指纹：自上次构建以来相关表没有任何写入 → 整组直接复用上次打包
  // 好的 (bytes, hash)。内存代价 ≈ 一份压缩后的备份，换来「上传完马上下载
  // 校验」的基线几乎瞬时完成。meta 组（settings/layers/收藏等小件）恒重建，
  // 但配合确定性导出（无 exportedAt 时间戳）其 MD5 不再每次都变。

  /// module → shard group. Absent modules land in `meta`.
  static const Map<String, String> _kModuleGroup = {
    'journal': 'journal',
    'track_points': 'tracks',
    'chat_messages': 'chat',
    'fog_tiles': 'fog',
  };

  /// Tables each cacheable group's export READS. `meta` is deliberately
  /// absent — its modules are tiny, so it rebuilds every time instead of
  /// being fingerprinted (fewer invalidation edge cases to reason about).
  static const Map<String, List<String>> _kGroupTables = {
    'journal': ['journal_entries'],
    'tracks': ['track_points'],
    'chat': ['chat_messages'],
    // fog export reads layers for the id→uuid mapping, so layer edits must
    // invalidate it too.
    'fog': ['fog_tiles', 'fog_erases', 'track_layers'],
  };

  /// Monotonic per-table write counters, bumped by drift's update stream.
  /// Every data write in the app goes through drift APIs (or customUpdate
  /// with an updateKind), so these catch ALL mutations of exported tables.
  final Map<String, int> _tableVer = {};
  StreamSubscription<Set<TableUpdate>>? _tableSub;

  final Map<String, String> _groupSig = {};
  final Map<String, Map<String, ({Uint8List bytes, String hash})>>
      _groupShards = {};

  void _ensureTableTracking() {
    _tableSub ??= ref.read(dbProvider).tableUpdates().listen((updates) {
      for (final u in updates) {
        _tableVer[u.table] = (_tableVer[u.table] ?? 0) + 1;
      }
    });
  }

  /// Fingerprint for a cacheable group, or null for `meta` (never cached).
  String? _groupFingerprint(String group, Set<String> groupModules) {
    final tables = _kGroupTables[group];
    if (tables == null) return null;
    final mods = groupModules.toList()..sort();
    return '${mods.join(',')}|'
        '${tables.map((t) => '${_tableVer[t] ?? 0}').join(':')}';
  }

  /// Export the selected modules and turn them into the shard set: entries
  /// grouped by [_shardFor], oversized zips split, every shard hashed.
  /// Unchanged groups are served from the in-memory cache; [keepBytes]
  /// controls whether packed bytes are returned (uploads need them; the
  /// syncDown baseline only needs the hashes). Progress runs [from]‰..[to]‰.
  Future<({Map<String, Uint8List> packed, Map<String, String> index})>
      _buildLocalShards(
    Set<String> modules, {
    required bool keepBytes,
    required void Function(int permille, String label) report,
    required int from,
    required int to,
    CancelToken? cancelToken,
  }) async {
    _ensureTableTracking();
    // Flush pending table-update notifications so fingerprints reflect every
    // write that completed before this build started.
    await Future<void>.delayed(Duration.zero);

    final selected = {
      for (final m in {...modules, ...BackupService.requiredModules})
        if (BackupService.allModules.contains(m)) m
    };
    final byGroup = <String, Set<String>>{};
    for (final m in selected) {
      (byGroup[_kModuleGroup[m] ?? 'meta'] ??= {}).add(m);
    }
    final manifestModules = selected.toList()..sort();
    debugPrint('[Sync] export modules: ${manifestModules.join(',')}');

    final backup = ref.read(backupServiceProvider);
    final packed = <String, Uint8List>{};
    final index = <String, String>{};
    final groups = byGroup.keys.toList()..sort();
    var gi = 0;
    var reused = 0;
    for (final group in groups) {
      _throwIfCancelled(cancelToken);
      final gFrom = from + ((to - from) * gi) ~/ groups.length;
      final gTo = from + ((to - from) * (gi + 1)) ~/ groups.length;
      gi++;

      final sig = _groupFingerprint(group, byGroup[group]!);
      final cached = _groupShards[group];
      if (sig != null && cached != null && _groupSig[group] == sig) {
        for (final e in cached.entries) {
          if (keepBytes) packed[e.key] = e.value.bytes;
          index[e.key] = e.value.hash;
        }
        reused++;
        report(gTo, '$group 未变化，复用缓存');
        continue;
      }

      final exportEnd = gFrom + ((gTo - gFrom) * 5) ~/ 9;
      final files = await backup.exportToFiles(
        byGroup[group]!,
        deterministic: true,
        includeManifest: group == 'meta',
        forceRequired: false,
        manifestModules: manifestModules,
        onProgress: (d, t, l) => report(
            gFrom + (t == 0 ? 0 : ((exportEnd - gFrom) * d / t).round()), l),
      );
      _throwIfCancelled(cancelToken);

      final grouped = <String, Map<String, List<int>>>{};
      for (final e in files.entries) {
        (grouped[_shardFor(e.key)] ??= {})[e.key] = e.value;
      }
      final parts = _splitOversized(grouped);
      final shards = <String, ({Uint8List bytes, String hash})>{};
      var pi = 0;
      for (final e in parts.entries) {
        _throwIfCancelled(cancelToken);
        report(exportEnd + ((gTo - exportEnd) * pi / parts.length).round(),
            '打包分片 ${pi + 1}/${parts.length} · ${e.key}');
        pi++;
        if (e.key.startsWith('fow/')) {
          // Raw pass-through — the shard IS its single entry (already
          // zlib-compressed native FoW bytes). Zipping it would break the
          // Fog-of-World interop of the cloud folder.
          final bytes = Uint8List.fromList(e.value.values.single);
          shards[e.key] = (bytes: bytes, hash: md5.convert(bytes).toString());
          continue;
        }
        final rawSize = e.value.values.fold<int>(0, (s, b) => s + b.length);
        final (bytes, hash) = (!kIsWeb && rawSize > _kIsolatePackThreshold)
            ? await compute(_packAndHash, e.value)
            : _packAndHash(e.value);
        shards[e.key] = (bytes: bytes, hash: hash);
        // Let the frame pump between potentially heavy packs.
        await Future<void>.delayed(Duration.zero);
      }
      if (sig != null) {
        _groupSig[group] = sig;
        _groupShards[group] = shards;
      }
      for (final e in shards.entries) {
        if (keepBytes) packed[e.key] = e.value.bytes;
        index[e.key] = e.value.hash;
      }
    }
    debugPrint('[Sync] ${index.length} shards, '
        '$reused/${groups.length} groups reused from cache');
    return (packed: packed, index: index);
  }

  /// Export selected modules, group into shards, push only changed/new shards.
  ///
  /// [storage] overrides the transport — pass a [LocalFolderStorage] to write
  /// the identical shard set to a local folder instead of the cloud (the
  /// "导出到本地文件夹" path shares this exact pipeline). Defaults to the
  /// configured cloud transport.
  Future<SyncUpResult> syncUp({
    required Set<String> modules,
    SyncStorage? storage,
    SyncProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    final SyncStorage od = storage ?? ref.read(syncStorageProvider);
    void report(int permille, String label) =>
        onProgress?.call(permille.clamp(0, 1000), 1000, label);

    // ── 0‰..450‰ · local export + shard pack/hash ────────────────────────
    report(0, '导出本地数据…');
    final local = await _buildLocalShards(modules,
        keepBytes: true,
        report: report,
        from: 0,
        to: 450,
        cancelToken: cancelToken);
    final packed = local.packed;
    final localIndex = local.index;

    // ── 450‰..480‰ · remote index + diff ─────────────────────────────────
    report(450, '读取云端索引…');
    final remoteIndex = await _readIndex(od, cancelToken);

    final toUpload = [
      for (final s in packed.keys)
        if (remoteIndex[s] != localIndex[s]) s,
    ];
    final toDelete = [
      for (final s in remoteIndex.keys)
        if (!localIndex.containsKey(s)) s,
    ];
    // Key-node log: fow/ tiles are the bulk (thousands), so report them as a
    // count but list the CONTENT shards (journal/meta/tracks/chat) by name —
    // that's what answers "did my 手账/图层 actually get uploaded?".
    final fowUp = toUpload.where((s) => s.startsWith('fow/')).length;
    final contentUp = toUpload.where((s) => !s.startsWith('fow/')).toList();
    debugPrint('[Sync] up: ${toUpload.length} changed '
        '($fowUp fow tiles + content [${contentUp.join(', ')}]), '
        '${toDelete.length} to delete, '
        '${packed.length - toUpload.length} unchanged');

    // ── 480‰..985‰ · transfers, byte-weighted ────────────────────────────
    // Small files (raw FoW tiles, most zips) ride a wide pool — they're
    // latency-bound; the few multi-MB zips ride a narrow one so they don't
    // saturate a mobile uplink.
    if (toUpload.isEmpty && toDelete.isEmpty) {
      report(985, '云端已是最新，无需上传');
    } else {
      // A delete is one cheap request — weigh it like a small file so a
      // delete-heavy diff still moves the bar sensibly.
      const deleteWeight = 64 << 10;
      final totalWeight = toUpload.fold<int>(0, (s, k) => s + packed[k]!.length) +
          toDelete.length * deleteWeight;
      var doneWeight = 0;
      var doneCount = 0;
      final opCount = toUpload.length + toDelete.length;

      Future<void> upload(String s) async {
        final size = packed[s]!.length;
        report(480 + (505 * doneWeight / totalWeight).round(),
            '上传分片 ${doneCount + 1}/$opCount · $s（${_fmtSize(size)}）');
        await od.putSyncFile(s, packed[s]!, cancelToken: cancelToken);
        doneWeight += size;
        doneCount++;
      }

      final smallUp = [
        for (final s in toUpload)
          if (packed[s]!.length <= _kSmallFileCap) s
      ];
      final largeUp = [
        for (final s in toUpload)
          if (packed[s]!.length > _kSmallFileCap) s
      ];
      await _forEachConcurrent<String>(
          smallUp, _kSmallTransferConcurrency, cancelToken, upload);
      await _forEachConcurrent<String>(
          largeUp, _kTransferConcurrency, cancelToken, upload);
      await _forEachConcurrent<String>(
        toDelete,
        _kSmallTransferConcurrency,
        cancelToken,
        (s) async {
          report(480 + (505 * doneWeight / totalWeight).round(),
              '删除旧分片 ${doneCount + 1}/$opCount · $s');
          await od.deleteSyncFile(s, cancelToken: cancelToken);
          doneWeight += deleteWeight;
          doneCount++;
        },
      );
    }

    // ── 985‰..1000‰ · index write ────────────────────────────────────────
    _throwIfCancelled(cancelToken);
    report(985, '写入索引…');
    await od.putSyncFile(_indexName, utf8.encode(jsonEncode(localIndex)),
        cancelToken: cancelToken);
    report(1000, '完成');
    debugPrint('[Sync] up complete');

    return SyncUpResult(
      toUpload.length,
      toDelete.length,
      packed.length - toUpload.length,
    );
  }

  /// Pull changed Sync shards, reassemble the entry map, and merge it in.
  ///
  /// Downloads are DIFFED, mirroring syncUp: we rebuild the local shard set
  /// (hashes only) and fetch just the shards whose cloud MD5 differs —
  /// otherwise every pull re-downloaded EVERY per-tile FoW file ("对所有碎片
  /// 文件做请求太慢"). A restore (clearBeforeImport) skips the baseline and
  /// fetches everything, since local state is about to be replaced.
  Future<ImportSummary?> syncDown({
    required Set<String> modules,
    required bool clearBeforeImport,
    bool restore = false,
    SyncStorage? storage,
    SyncProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    final SyncStorage od = storage ?? ref.read(syncStorageProvider);
    void report(int permille, String label) =>
        onProgress?.call(permille.clamp(0, 1000), 1000, label);

    report(0, '读取云端索引…');
    final remoteIndex = await _readIndex(od, cancelToken);
    if (remoteIndex.isEmpty) {
      debugPrint('[Sync] down: remote Sync folder is empty');
      return null;
    }

    // ── 20‰..300‰ · local baseline (hashes only) → fetch set ─────────────
    List<String> toFetch;
    if (clearBeforeImport) {
      toFetch = remoteIndex.keys.toList();
    } else {
      report(20, '计算本地基线…');
      final local = await _buildLocalShards(modules,
          keepBytes: false,
          report: report,
          from: 20,
          to: 300,
          cancelToken: cancelToken);
      toFetch = [
        for (final s in remoteIndex.keys)
          if (remoteIndex[s] != local.index[s]) s,
      ];
      // Surface the content shards' fetch decision by NAME — the usual
      // "手账/图层没同步" report is impossible to diagnose from a bare count.
      // A shard NOT listed here hashed identically to the cloud (correctly
      // skipped: this device already holds that exact content).
      for (final s in const ['journal.zip', 'meta.zip']) {
        if (!remoteIndex.containsKey(s)) {
          debugPrint('[Sync] down: $s absent from cloud index');
        } else if (remoteIndex[s] == local.index[s]) {
          debugPrint('[Sync] down: $s unchanged (local == cloud) — skipped');
        } else {
          debugPrint('[Sync] down: $s CHANGED (local ${local.index[s]} '
              '!= cloud ${remoteIndex[s]}) — will fetch');
        }
      }
    }
    final fowFetch = toFetch.where((s) => s.startsWith('fow/')).length;
    final contentFetch = toFetch.where((s) => !s.startsWith('fow/')).toList();
    debugPrint('[Sync] down: ${toFetch.length} to fetch of '
        '${remoteIndex.length} shards '
        '($fowFetch fow tiles + content [${contentFetch.join(', ')}])');
    if (toFetch.isEmpty) {
      report(1000, '云端已是最新，无需下载');
      return ImportSummary();
    }

    // ── 300‰..800‰ · parallel downloads, unzip as they land ──────────────
    final files = <String, List<int>>{};
    final missing = <String>[];
    var doneCount = 0;
    await _forEachConcurrent<String>(
      toFetch,
      _kSmallTransferConcurrency,
      cancelToken,
      (s) async {
        report(300 + (500 * doneCount / toFetch.length).round(),
            '下载分片 ${doneCount + 1}/${toFetch.length} · $s');
        final bytes = await od.getSyncFile(s, cancelToken: cancelToken);
        if (bytes == null) {
          // Indexed but gone from the cloud (an interrupted old upload, a
          // manual deletion). Losing it silently reads as "nothing was
          // applied" — surface it in the summary instead.
          missing.add(s);
          debugPrint('[Sync] ↓ $s MISSING (indexed but not in the cloud)');
        } else {
          if (s.startsWith('fow/')) {
            // Raw native FoW tile — the shard IS the entry.
            files[s] = bytes;
          } else {
            // Unpack the shard's member entries back into the merged map.
            // Single-isolate event loop → no locking needed around `files`.
            _unzip(Uint8List.fromList(bytes))
                .forEach((k, v) => files[k] = v);
          }
        }
        doneCount++;
      },
    );

    // ── 800‰..1000‰ · merge-import with per-module progress ──────────────
    _throwIfCancelled(cancelToken);
    debugPrint('[Sync] importing ${files.length} files');
    final summary = await ref.read(backupServiceProvider).importFromFiles(
          files,
          modules: modules,
          clearBeforeImport: clearBeforeImport,
          restore: restore,
          onProgress: (d, t, l) =>
              report(800 + (t == 0 ? 0 : (200 * d / t).round()), l),
        );
    if (missing.isNotEmpty) {
      summary.errors['transport'] =
          '${missing.length} 个分片在云端缺失（索引已过期？重新同步一次即可修复）：'
          '${missing.take(3).join(', ')}${missing.length > 3 ? '…' : ''}';
    }
    report(1000, '完成');
    debugPrint('[Sync] down complete');
    return summary;
  }

  /// Test seam for [_splitOversized] — pure and worth pinning (the
  /// deterministic part-split is what keeps the MD5 diff incremental).
  @visibleForTesting
  static Map<String, Map<String, List<int>>> splitOversized(
          Map<String, Map<String, List<int>>> grouped) =>
      _splitOversized(grouped);

  /// Split any shard whose raw entries exceed [_kShardPartRawCap] into
  /// deterministic `.pN.zip` parts: entries sorted by name, greedy fill.
  /// Same content → same parts → same MD5s, so the incremental diff keeps
  /// working across the split.
  static Map<String, Map<String, List<int>>> _splitOversized(
      Map<String, Map<String, List<int>>> grouped) {
    final out = <String, Map<String, List<int>>>{};
    for (final e in grouped.entries) {
      final raw = e.value.values.fold<int>(0, (s, b) => s + b.length);
      // fow/ shards must stay whole to remain FoW-readable (a full tile is
      // ≤8 MiB raw and zlib-compressed well below the cap anyway).
      if (e.key.startsWith('fow/') || raw <= _kShardPartRawCap) {
        out[e.key] = e.value;
        continue;
      }
      final sorted = e.value.keys.toList()..sort();
      final parts = <Map<String, List<int>>>[];
      var part = <String, List<int>>{};
      var partRaw = 0;
      for (final k in sorted) {
        final b = e.value[k]!;
        if (partRaw + b.length > _kShardPartRawCap && part.isNotEmpty) {
          parts.add(part);
          part = {};
          partRaw = 0;
        }
        part[k] = b;
        partRaw += b.length;
      }
      if (part.isNotEmpty) parts.add(part);
      if (parts.length == 1) {
        // A single oversized entry (e.g. fog/index.json) can't split — keep
        // the ORIGINAL shard name. Renaming it `.p0` flipped the name back
        // and forth as the shard crossed the cap, forcing a pointless
        // delete+re-upload cycle and confusing the remote listing.
        out[e.key] = parts.single;
      } else {
        final base = e.key.substring(0, e.key.length - 4);
        for (var i = 0; i < parts.length; i++) {
          out['$base.p$i.zip'] = parts[i];
        }
      }
    }
    return out;
  }

  /// Run [fn] over [items] with up to [width] in flight. Fail-fast: the first
  /// error (or a cancel) stops workers from pulling further items, and the
  /// error propagates to the caller.
  static Future<void> _forEachConcurrent<T>(
    List<T> items,
    int width,
    CancelToken? cancelToken,
    Future<void> Function(T) fn,
  ) async {
    var next = 0;
    Object? failure;
    StackTrace? failureSt;
    Future<void> worker() async {
      while (failure == null) {
        if (cancelToken != null && cancelToken.isCancelled) return;
        final i = next++;
        if (i >= items.length) return;
        try {
          await fn(items[i]);
        } catch (e, st) {
          failure ??= e;
          failureSt ??= st;
          return;
        }
      }
    }

    await Future.wait(
        [for (var w = 0; w < width && w < items.length; w++) worker()]);
    _throwIfCancelled(cancelToken);
    if (failure != null) {
      Error.throwWithStackTrace(failure!, failureSt ?? StackTrace.current);
    }
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
}

/// Deterministic shard zip + MD5: entries sorted, mtime zeroed — so an
/// unchanged shard always hashes the same (otherwise wall-clock mtime would
/// change the MD5 every run and defeat the incremental diff). Top-level so
/// [compute] can run it in a background isolate for big shards.
(Uint8List, String) _packAndHash(Map<String, List<int>> entries) {
  final archive = Archive();
  final keys = entries.keys.toList()..sort();
  for (final k in keys) {
    final f = ArchiveFile(k, entries[k]!.length, entries[k]!);
    f.lastModTime = 0;
    archive.addFile(f);
  }
  final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
  return (bytes, md5.convert(bytes).toString());
}

final syncEngineProvider = Provider<SyncEngine>((ref) => SyncEngine(ref));
