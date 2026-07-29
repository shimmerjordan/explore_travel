import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:drift/drift.dart'
    show Value, Variable, UpdateKind, InsertMode;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/db/database.dart';
import '../fog/fow_compat.dart'
    show tileIdToFilename, buildFowTile, fowBlocksFromFile,
        looksLikeFowTileName;
import '../leaderboard/leaderboard_model.dart';
import '../leaderboard/leaderboard_service.dart';

/// Modular chunked zip backup. Schema v2.
///
/// Why chunked instead of one big JSON: per-tile fog (à la Fog of World),
/// per-month track points, per-peer chat let us:
///   * support incremental sync later (compare file hashes per chunk)
///   * keep individual files small enough to diff / fix by hand
///   * avoid pinning a multi-MB JSON in RAM on import
///
/// Layout (all paths are zip-internal):
/// ```
/// manifest.json                        v=3 + exportedAt + modules
/// journal/entries.jsonl                one entry per line (+updatedAt)
/// layers/layers.json                   (+id for layerId remapping, +updatedAt)
/// song_favorites/favorites.jsonl
/// track_points/<yyyy-mm>.jsonl         chunked by month
/// chat_messages/<peerId>.jsonl         chunked by peer
/// planner_history/<sessionId>.json
/// settings/app_settings.json           (+settings/meta.json updatedAt)
/// fow/<layerUuid>/<obfuscatedName>     NATIVE Fog of World tile files —
///                                      drop them straight into a FoW Sync
///                                      folder (and vice versa: FoW tiles
///                                      copied here import on the next sync)
/// fog/index.json                       v2: per-block updatedAt sidecar
/// fog/erases.jsonl                     erase masks（迷雾增量减）
/// imghost_uploads/registry.json
/// geocode/cell_cache.json
/// geocode/learned_regions.json
/// ```
/// v2 archives carried fog as `fog/<layerId>/<x>_<y>_<zoom>.bin`; import
/// still reads that layout, export no longer writes it.
/// (done, total, label) progress callback for export/import module steps.
typedef BackupProgress = void Function(int done, int total, String label);

class BackupService {
  final AppDb db;
  /// Optional — when set, the leaderboard module is auto-included on export
  /// and auto-merged on import. The user cannot opt out (it's a contract
  /// with the rest of the group sync system).
  final LeaderboardService? leaderboard;
  BackupService(this.db, {this.leaderboard});

  static const archiveVersion = 3;

  /// Module keys understood by [exportToArchive] / [importFromArchive].
  static const allModules = <String>[
    'journal',
    'layers',
    'fog_tiles',
    'song_favorites',
    'track_points',
    'chat_messages',
    'planner_history',
    'settings',
    'imghost_uploads',
    'geocode_cache',
    'learned_regions',
    'leaderboard',
    'tombstones',
  ];

  /// Modules that MUST be in every export — the UI checkbox is rendered
  /// disabled so the user can see them but can't deselect. Leaderboard is a
  /// contract with the gossip system; tombstones are what make deletes
  /// propagate (skipping them would resurrect erased data on every merge).
  static const requiredModules = <String>{'leaderboard', 'tombstones'};

  static const moduleLabels = <String, String>{
    'journal': '旅行手账',
    'layers': '图层',
    'fog_tiles': '迷雾瓦片（探索进度）',
    'song_favorites': '歌曲收藏',
    'track_points': '轨迹点',
    'chat_messages': '聊天记录',
    'planner_history': 'AI 规划记录',
    'settings': '应用设置',
    'imghost_uploads': '图床上传记录',
    'geocode_cache': '地理编码缓存',
    'learned_regions': '学习到的行政区',
    'leaderboard': '排行榜（自动包含）',
    'tombstones': '删除记录（自动包含）',
  };

  /// Logical tables whose deletes are tombstoned + applied on import.
  static const _tombstoneTables = <String>[
    'track_points',
    'track_layers',
    'journal_entries',
    'chat_messages',
    'song_favorites',
  ];

  /// Wipe one module's LOCAL data (DB rows or prefs entry). Used by the
  /// per-module "清除本机数据" buttons on the backup screen.
  ///
  /// This is a LOCAL clear, NOT a propagated delete: it does NOT record
  /// tombstones. Two reasons — (1) the button literally says "本地数据", so a
  /// later pull SHOULD restore from the cloud (users hit "清空后再从 OneDrive
  /// 拉取" and expect their data back; tombstones silently blocked every row);
  /// (2) tombstoning the whole table turns "I reset my local copy" into
  /// "delete everything everywhere forever". Deliberate single-item deletes
  /// (deleteLayer / deleteJournalById / …) still tombstone — those SHOULD
  /// propagate. Returns a short human-readable summary of what was cleared.
  Future<String> clearModule(String key) async {
    switch (key) {
      case 'journal':
        await db.delete(db.journalEntries).go();
        await db.customStatement('DELETE FROM journal_fts');
        return '已清除本机手账';
      case 'layers':
        // Re-home ALL content onto ONE fresh default layer — a genuine clean
        // slate. Deleting layers alone springs them back via the startup
        // self-heal (content still references their ids), which is why the
        // clear "没有清空全部".
        await db.resetContentToDefaultLayer();
        return '已清除本机图层（内容已归入单一默认图层）';
      case 'fog_tiles':
        await db.delete(db.fogTiles).go();
        await db.delete(db.fogErases).go();
        return '已清除本机迷雾';
      case 'track_points':
        await db.delete(db.trackPoints).go();
        return '已清除本机轨迹点';
      case 'chat_messages':
        await db.delete(db.chatMessages).go();
        return '已清除本机聊天记录';
      case 'song_favorites':
        await db.delete(db.songFavorites).go();
        return '已清除本机歌曲收藏';
      case 'planner_history':
        await (await SharedPreferences.getInstance())
            .remove('planner_history_v1');
        return '已清除本机 AI 规划记录';
      case 'imghost_uploads':
        await (await SharedPreferences.getInstance())
            .remove('img_host_uploads_v1');
        return '已清除本机图床上传记录';
      case 'geocode_cache':
        await (await SharedPreferences.getInstance())
            .remove('geocode_cell_cache_v1');
        return '已清除本机地理编码缓存';
      case 'learned_regions':
        await (await SharedPreferences.getInstance())
            .remove('learned_regions_v1');
        return '已清除本机学习到的行政区';
      case 'settings':
        // Never wipe credentials via this button — only the non-secret prefs.
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('app_settings_v1');
        if (raw != null) {
          final j = jsonDecode(raw) as Map<String, dynamic>;
          for (final k in j.keys.toList()) {
            if (!kVaultSecretKeys.contains(k)) j.remove(k);
          }
          await prefs.setString('app_settings_v1', jsonEncode(j));
        }
        return '已重置本机应用设置（保留登录凭据）';
      case 'leaderboard':
        return '排行榜为社区共享数据，未提供本机清除';
      case 'tombstones':
        await db.delete(db.tombstones).go();
        return '已清除本机删除记录';
      default:
        return '未知模块：$key';
    }
  }

  // ─── Export ─────────────────────────────────────────────────────────────

  /// Build the zip in memory and return its raw bytes.
  Future<Uint8List> exportToArchive(Set<String> selected,
      {BackupProgress? onProgress}) async {
    final files = await exportToFiles(selected, onProgress: onProgress);
    final archive = Archive();
    for (final e in files.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  /// Build the archive's entries as a plain path → bytes map, WITHOUT zipping.
  /// This is the sync engine's entry point: it regroups the entries into shard
  /// zips itself, so producing (and then re-inflating) one big zip here was
  /// pure wasted CPU — the single biggest cause of the sync dialog sitting at
  /// "0% 导出本地数据". [onProgress] ticks once per module so the UI can move.
  Future<Map<String, List<int>>> exportToFiles(
    Set<String> selected, {
    BackupProgress? onProgress,
    // Sync-path knobs (see SyncEngine._buildLocalShards):
    //  * deterministic — omit `exportedAt` so identical data always produces
    //    byte-identical output. With the timestamp in, meta.zip's MD5 changed
    //    on EVERY export, so every syncUp re-uploaded it and every syncDown
    //    re-fetched + re-merged it even when nothing had changed.
    //  * includeManifest/forceRequired/manifestModules — let the sync engine
    //    export one shard-group at a time (manifest only rides in the meta
    //    group) while the manifest still lists the FULL selected module set.
    bool deterministic = false,
    bool includeManifest = true,
    bool forceRequired = true,
    List<String>? manifestModules,
  }) async {
    // Force the required modules — caller can't opt out.
    final modules =
        forceRequired ? {...selected, ...requiredModules} : {...selected};
    final out = <String, List<int>>{};
    final total = modules.where(allModules.contains).length;
    var done = 0;
    Future<void> step(String key) async {
      onProgress?.call(done++, total, '导出 ${moduleLabels[key] ?? key}…');
      // Let the frame pump between heavy modules so the dialog repaints.
      await Future<void>.delayed(Duration.zero);
    }

    void addJson(String path, Object obj) {
      out[path] = utf8.encode(const JsonEncoder.withIndent('  ').convert(obj));
    }

    void addText(String path, String body) {
      out[path] = utf8.encode(body);
    }

    void addBytes(String path, List<int> bytes) {
      out[path] = bytes;
    }

    // Manifest first so reads can short-circuit on version mismatch.
    if (includeManifest) {
      addJson('manifest.json', {
        'version': archiveVersion,
        if (!deterministic) 'exportedAt': DateTime.now().toIso8601String(),
        'appVersion': '0.1.0',
        'modules': [...(manifestModules ?? modules)]..sort(),
      });
    }

    if (modules.contains('journal')) {
      await step('journal');
      final rows = await db.select(db.journalEntries).get();
      debugPrint('[BackupService] export journal — ${rows.length} entries '
          '(${rows.where((r) => r.uuid.isEmpty).length} with empty uuid)');
      addText(
          'journal/entries.jsonl',
          rows.map((r) => jsonEncode({
                'uuid': r.uuid,
                'time': r.time.toIso8601String(),
                'lat': r.lat,
                'lng': r.lng,
                'title': r.title,
                'richContent': r.richContent,
                'mediaPaths': r.mediaPaths,
                'layerId': r.layerId,
                'level': r.level,
                'ownerPeerId': r.ownerPeerId,
                'updatedAt': r.updatedAt?.toIso8601String(),
              })).join('\n'));
    }

    if (modules.contains('layers')) {
      await step('layers');
      final rows = await db.select(db.trackLayers).get();
      debugPrint('[BackupService] export layers — ${rows.length} layers '
          '[${rows.map((r) => '${r.id}:${r.uuid.isEmpty ? "∅" : r.uuid}:${r.name}').join(' | ')}]');
      addJson(
          'layers/layers.json',
          rows
              .map((r) => {
                    'uuid': r.uuid,
                    // Local autoincrement id — journal/track rows reference
                    // layers by this number, which differs across devices.
                    // Import uses id→uuid→local-id to remap them.
                    'id': r.id,
                    'name': r.name,
                    'colorValue': r.colorValue,
                    'visible': r.visible,
                    'tag': r.tag,
                    'createdAt': r.createdAt.toIso8601String(),
                    // Per-layer path style (null = inherit global default).
                    'pathColor': r.pathColor,
                    'pathOpacity': r.pathOpacity,
                    'pathWidth': r.pathWidth,
                    'updatedAt': r.updatedAt?.toIso8601String(),
                  })
              .toList());
    }

    if (modules.contains('song_favorites')) {
      await step('song_favorites');
      final rows = await db.select(db.songFavorites).get();
      addText(
          'song_favorites/favorites.jsonl',
          rows.map((r) => jsonEncode({
                'uuid': r.uuid,
                'songId': r.songId,
                'title': r.title,
                'artist': r.artist,
                'coverUrl': r.coverUrl,
                'source': r.source,
                'addedAt': r.addedAt.toIso8601String(),
                'lat': r.lat,
                'lng': r.lng,
              })).join('\n'));
    }

    if (modules.contains('track_points')) {
      await step('track_points');
      final rows = await db.select(db.trackPoints).get();
      // Group by yyyy-mm — track point counts can hit hundreds of
      // thousands; one file per month keeps each manageable.
      final byMonth = <String, List<Map<String, dynamic>>>{};
      for (final r in rows) {
        final ym =
            '${r.time.year}-${r.time.month.toString().padLeft(2, '0')}';
        (byMonth[ym] ??= []).add({
          'uuid': r.uuid,
          'lat': r.lat,
          'lng': r.lng,
          'time': r.time.toIso8601String(),
          'accuracy': r.accuracy,
          'altitude': r.altitude,
          'speed': r.speed,
          // Per-point render width (null on pre-v5 rows) — without it a
          // restore would flatten manual dabs / trails to the layer default.
          'width': r.width,
          'layerId': r.layerId,
        });
      }
      for (final entry in byMonth.entries) {
        addText('track_points/${entry.key}.jsonl',
            entry.value.map(jsonEncode).join('\n'));
      }
    }

    if (modules.contains('chat_messages')) {
      await step('chat_messages');
      final rows = await db.select(db.chatMessages).get();
      final byPeer = <String, List<Map<String, dynamic>>>{};
      for (final r in rows) {
        final pid = r.peerId.isEmpty ? '_unknown' : r.peerId;
        (byPeer[pid] ??= []).add({
          'uuid': r.uuid,
          'peerId': r.peerId,
          'author': r.author,
          'content': r.content,
          'time': r.time.toIso8601String(),
          'outbound': r.outbound,
        });
      }
      for (final entry in byPeer.entries) {
        // Strip slashes so peer ids don't accidentally create subpaths.
        final safe = entry.key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        addText('chat_messages/$safe.jsonl',
            entry.value.map(jsonEncode).join('\n'));
      }
    }

    if (modules.contains('planner_history')) {
      await step('planner_history');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('planner_history_v1');
      if (raw != null) {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        for (final session in list) {
          final id = (session['id']?.toString() ?? '_').replaceAll(
              RegExp(r'[^A-Za-z0-9_-]'), '_');
          addJson('planner_history/$id.json', session);
        }
      }
    }

    if (modules.contains('settings')) {
      await step('settings');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('app_settings_v1');
      if (raw != null) {
        // Strip secrets from the exported settings — backup files
        // routinely end up on cloud storage, shared with friends, or
        // pulled apart by the user themselves. The user re-enters
        // credentials on the receiving device. Anything stored in
        // platform secure storage (SecureCredentials) is never written
        // here in the first place; this guards the legacy-format
        // fields that still live in app_settings_v1.
        final scrubbed = _scrubSettings(raw);
        addText('settings/app_settings.json', scrubbed);
        // LWW sidecar — lets import keep the LOCAL settings when they are
        // newer than the archive's, instead of blindly overwriting.
        final ts = prefs.getString('settings_updated_at');
        if (ts != null) {
          addJson('settings/meta.json', {'updatedAt': ts});
        }
      }
    }

    if (modules.contains('fog_tiles')) {
      await step('fog_tiles');
      // NATIVE Fog of World layout: fow/<layerUuid>/<obfuscatedTileName>,
      // one FoW tile file per 128×128-block tile per layer. The files are
      // byte-compatible with FoW's own Sync folder — copy them there to
      // hand this data to Fog of World, or drop FoW's files in here to
      // bring them in — and double as our sync shards (a change in one
      // tile re-uploads only that tile).
      final layerUuidById = {
        for (final l in await db.allLayers())
          l.id: l.uuid.isNotEmpty ? l.uuid : 'layer-${l.id}',
      };
      final rows = await db.select(db.fogTiles).get();
      // Group blocks per (layer, FoW tile). tileX/tileY are block-global
      // coords (fowTile*128 + block).
      final grouped =
          <int, Map<(int, int), Map<(int, int), Uint8List>>>{};
      for (final r in rows) {
        if (r.zoom != 100) continue; // only the FOW-block sentinel rows
        final tiles = grouped.putIfAbsent(r.layerId, () => {});
        final blocks = tiles.putIfAbsent(
            (r.tileX ~/ 128, r.tileY ~/ 128), () => {});
        blocks[(r.tileX % 128, r.tileY % 128)] =
            Uint8List.fromList(r.bitmap);
      }
      for (final layerEntry in grouped.entries) {
        final layerKey =
            layerUuidById[layerEntry.key] ?? 'layer-${layerEntry.key}';
        for (final tileEntry in layerEntry.value.entries) {
          final (tx, ty) = tileEntry.key;
          final name = tileIdToFilename(ty * 512 + tx);
          addBytes('fow/$layerKey/$name',
              buildFowTile(tx, ty, tileEntry.value));
        }
      }
      // Side-car the FoW format can't carry: per-block updatedAt (drives
      // the LWW part of the merge) keyed by layer UUID so it survives
      // devices whose autoincrement layer ids differ.
      addJson('fog/index.json', {
        'v': 2,
        'blocks': [
          for (final r in rows)
            {
              'l': layerUuidById[r.layerId] ?? 'layer-${r.layerId}',
              'x': r.tileX,
              'y': r.tileY,
              'z': r.zoom,
              't': r.updatedAt.toIso8601String(),
            }
        ],
      });
      // Erase masks（迷雾增量减）: which pixels the eraser swept, and when.
      // Import unions bitmaps and then applies these to copies that predate
      // the erase — without them a union merge would resurrect every erase.
      await db.gcFogErases();
      final erases = await db.allFogErases();
      if (erases.isNotEmpty) {
        addText(
            'fog/erases.jsonl',
            erases
                .map((e) => jsonEncode({
                      'l': layerUuidById[e.layerId] ?? 'layer-${e.layerId}',
                      'x': e.tileX,
                      'y': e.tileY,
                      'z': e.zoom,
                      'mask': base64Encode(e.mask),
                      't': e.erasedAt.toIso8601String(),
                    }))
                .join('\n'));
      }
    }

    if (modules.contains('imghost_uploads')) {
      await step('imghost_uploads');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('img_host_uploads_v1');
      if (raw != null) {
        addText('imghost_uploads/registry.json', raw);
      }
    }

    if (modules.contains('geocode_cache')) {
      await step('geocode_cache');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('geocode_cell_cache_v1');
      if (raw != null) {
        addText('geocode/cell_cache.json', raw);
      }
    }

    if (modules.contains('learned_regions')) {
      await step('learned_regions');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('learned_regions_v1');
      if (raw != null) {
        addText('geocode/learned_regions.json', raw);
      }
    }

    if (modules.contains('tombstones')) {
      await step('tombstones');
      // Old markers have outlived every device's next sync — drop them so
      // the file doesn't grow forever.
      await db.gcTombstones();
      final rows = await db.allTombstones();
      if (rows.isNotEmpty) {
        addText(
            'tombstones/tombstones.jsonl',
            rows
                .map((t) => jsonEncode({
                      'tbl': t.tbl,
                      'uuid': t.uuid,
                      'deletedAt': t.deletedAt.toIso8601String(),
                    }))
                .join('\n'));
      }
    }

    if (modules.contains('leaderboard') && leaderboard != null) {
      await step('leaderboard');
      // One line per entry — same on-wire shape as the P2P gossip path,
      // so importing a backup is just "merge a batch from your past self".
      final list = leaderboard!.toExportList();
      addText(
        'leaderboard/entries.jsonl',
        list.map(jsonEncode).join('\n'),
      );
    }

    onProgress?.call(total, total, '导出完成');
    return out;
  }

  /// Write the archive bytes to a timestamped `.zip` under documents/ and
  /// return the file. Used by both local export and WebDAV upload — the
  /// archive bytes are identical, only the destination differs.
  Future<File> exportToFile(Set<String> modules) async {
    final bytes = await exportToArchive(modules);
    final dir = await getApplicationDocumentsDirectory();
    final ts =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final f = File(p.join(dir.path, 'explore_journal_backup_$ts.zip'));
    await f.writeAsBytes(bytes);
    return f;
  }

  // ─── Import ─────────────────────────────────────────────────────────────

  Future<ImportSummary> importFromArchive(
    Uint8List bytes, {
    required Set<String> modules,
    bool clearBeforeImport = false,
    bool restore = false,
    BackupProgress? onProgress,
  }) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, List<int>>{
      for (final f in archive.files)
        if (f.isFile) f.name: f.content as List<int>,
    };
    return importFromFiles(
      files,
      modules: modules,
      clearBeforeImport: clearBeforeImport,
      restore: restore,
      onProgress: onProgress,
    );
  }

  /// Same as [importFromArchive] but takes the entries as a plain path → bytes
  /// map. The sync engine already holds the entries after unzipping each shard
  /// — re-zipping them into one big archive just to inflate it again here was
  /// the import-side twin of the export-side waste.
  Future<ImportSummary> importFromFiles(
    Map<String, List<int>> files, {
    required Set<String> modules,
    bool clearBeforeImport = false,
    bool restore = false,
    BackupProgress? onProgress,
  }) async {
    modules = {...modules, ...requiredModules};
    final summary = ImportSummary();

    // Manifest is informational — we don't hard-fail on version mismatch
    // since the layout is forward-compatible (extra files are ignored).
    final manifestBytes = files['manifest.json'];
    if (manifestBytes == null) {
      // A diffed sync pull may legitimately arrive without meta.zip (and so
      // without the manifest) when only content shards changed. Only refuse
      // when NOTHING in the set looks like ours — that's a foreign zip.
      final recognised = files.keys.any((k) =>
          k.startsWith('journal/') ||
          k.startsWith('layers/') ||
          k.startsWith('track_points/') ||
          k.startsWith('chat_messages/') ||
          k.startsWith('song_favorites/') ||
          k.startsWith('fog/') ||
          k.startsWith('fow/') ||
          k.startsWith('tombstones/') ||
          k.startsWith('settings/') ||
          k.startsWith('leaderboard/'));
      if (!recognised) {
        // A Fog of World "Sync" folder / Sync.zip is raw FoW tile files
        // (obfuscated names under Sync/… or bare) — NOT an explore_journal
        // backup. Picking it in the BACKUP importer used to fail with the
        // cryptic "不是备份" below; point the user at the right button instead.
        final looksLikeFow = files.keys.any((k) {
          final base = k.split('/').last;
          return base.isNotEmpty && looksLikeFowTileName(base);
        });
        if (looksLikeFow) {
          throw const FormatException(
              '这是 Fog of World 的原始迷雾数据（Sync.zip / Sync 文件夹），不是 '
              'explore_journal 备份。请改用「Fog of World 兼容 → 导入 FOW 数据」'
              '按钮来导入迷雾。');
        }
        throw const FormatException(
            'manifest.json 不存在，这可能不是一个 explore_journal 备份');
      }
      debugPrint(
          '[BackupService] no manifest (partial sync set) — continuing');
    } else {
      final manifest =
          jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
      final v = manifest['version'] as int? ?? 1;
      if (v > archiveVersion) {
        debugPrint('[BackupService] importing newer archive version $v '
            '(supported: $archiveVersion) — extra fields will be skipped');
      }
    }

    String? readText(String path) {
      final b = files[path];
      return b == null ? null : utf8.decode(b);
    }

    Iterable<MapEntry<String, List<int>>> findUnder(String prefix) =>
        files.entries.where((e) => e.key.startsWith(prefix));

    final totalModules = modules.where(allModules.contains).length;
    var doneModules = 0;
    Future<void> wrap(String key, Future<void> Function() body) async {
      if (!modules.contains(key)) return;
      onProgress?.call(
          doneModules++, totalModules, '导入 ${moduleLabels[key] ?? key}…');
      // Let the frame pump between heavy modules so the dialog repaints.
      await Future<void>.delayed(Duration.zero);
      try {
        await body();
      } catch (e, st) {
        debugPrint('[BackupService] import "$key" failed: $e\n$st');
        summary.errors[key] = e.toString();
      }
    }

    // ── Helper: load existing UUIDs for a table so we can skip dupes ──
    // Without this, importing the same archive twice (or merging two
    // device backups that share history) would double everything because
    // autoincrement IDs differ across devices.
    Future<Set<String>> existingUuids(String tableName) async {
      try {
        final rows =
            await db.customSelect('SELECT uuid FROM $tableName').get();
        return rows
            .map((r) => r.read<String>('uuid'))
            .where((u) => u.isNotEmpty)
            .toSet();
      } catch (_) {
        return <String>{};
      }
    }

    Future<int> journalCount() async {
      final r = await db
          .customSelect('SELECT COUNT(*) AS c FROM journal_entries')
          .getSingle();
      return r.read<int>('c');
    }

    // ── Tombstones FIRST（增量减）──────────────────────────────────────────
    // Merge deletion markers arriving with the archive, apply them locally,
    // and build per-table skip sets — otherwise every merge would resurrect
    // rows the user deleted (the cloud copy still carries them and the
    // UUID-dedup below would treat them as "new").
    final tombstoned = <String, Set<String>>{};
    // uuids the ARCHIVE itself carries a tombstone for — deletions captured in
    // this snapshot. In restore mode ONLY these apply; a LOCAL-only tombstone
    // (a delete made AFTER this snapshot) must not block the snapshot from
    // bringing its row back. See the skip-set selection below.
    final archiveTombs = <String, Set<String>>{};
    await wrap('tombstones', () async {
      final raw = readText('tombstones/tombstones.jsonl');
      if (raw == null) return;
      final incoming = <TombstonesCompanion>[];
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
        try {
          final r = jsonDecode(line) as Map<String, dynamic>;
          final tbl = r['tbl']?.toString() ?? '';
          final uuid = r['uuid']?.toString() ?? '';
          if (!_tombstoneTables.contains(tbl) || uuid.isEmpty) continue;
          (archiveTombs[tbl] ??= <String>{}).add(uuid);
          incoming.add(TombstonesCompanion.insert(
            tbl: tbl,
            uuid: uuid,
            deletedAt:
                DateTime.tryParse(r['deletedAt']?.toString() ?? '') ??
                    DateTime.now(),
          ));
        } catch (_) {}
      }
      await db.mergeTombstones(incoming);
    });
    try {
      var applied = 0;
      for (final tbl in _tombstoneTables) {
        // SYNC (default): every local tombstone suppresses + deletes — a delete
        // must survive pulling the still-present cloud copy (test:
        // "local tombstone must block resurrection from old cloud").
        // RESTORE: only the tombstones the ARCHIVE carries apply; a local-only
        // delete made after this snapshot must NOT block the snapshot from
        // restoring its row — that was the "删除后再导入没恢复" report, and it
        // hit EVERY tombstoned module (journal / tracks / layers / chat /
        // songs) identically, so fixing it here fixes them all at once.
        final set = restore
            ? (archiveTombs[tbl] ?? const <String>{})
            : await db.tombstonedUuids(tbl);
        tombstoned[tbl] = set;
        if (set.isEmpty) continue;
        const chunk = 400;
        final list = set.toList();
        for (var i = 0; i < list.length; i += chunk) {
          final part = list.sublist(
              i, (i + chunk > list.length) ? list.length : i + chunk);
          final qs = List.filled(part.length, '?').join(',');
          if (tbl == 'journal_entries') {
            // Keep the FTS mirror consistent with the rows we drop.
            await db.customStatement(
                'DELETE FROM journal_fts WHERE rowid IN '
                '(SELECT id FROM journal_entries WHERE uuid IN ($qs))',
                part);
          }
          applied += await db.customUpdate(
            'DELETE FROM $tbl WHERE uuid IN ($qs)',
            variables: [for (final u in part) Variable.withString(u)],
            updateKind: UpdateKind.delete,
          );
        }
      }
      if (applied > 0) {
        debugPrint('[BackupService] tombstones removed $applied local rows');
      }
    } catch (e) {
      summary.errors['tombstones'] = e.toString();
    }

    // ── Layer-id remapping ────────────────────────────────────────────────
    // journal/track/fog rows reference layers by LOCAL autoincrement id,
    // which differs across devices. The archive's layers.json carries each
    // layer's (id, uuid); rows remap archive-id → uuid → local-id. Archives
    // predating the 'id' field fall back to the raw number (old behaviour).
    final archiveLayerUuidById = <int, String>{};
    final rawLayers = readText('layers/layers.json');
    if (rawLayers != null) {
      try {
        for (final r in (jsonDecode(rawLayers) as List).cast<Map>()) {
          final id = (r['id'] as num?)?.toInt();
          final uuid = r['uuid']?.toString() ?? '';
          if (id != null && uuid.isNotEmpty) archiveLayerUuidById[id] = uuid;
        }
      } catch (_) {}
    }
    // archive layer id → the LOCAL id it resolved to. Filled in by the layer
    // merge below for EVERY archive layer, INCLUDING the ones the same-name
    // collapse folds away. Content (tracks/journal/fog) referencing a
    // folded-away archive id follows it here to the surviving layer, instead of
    // being orphaned onto a non-existent id — which the self-heal then
    // re-materialised as a phantom "图层 N" (the duplicate-layer + lost-track bug).
    final archiveIdToLocalId = <int, int>{};
    // Live layer snapshot for remap's fallback, refreshed right after the layer
    // merge (the only step that inserts layers before content import).
    var liveLayerIds = <int>{};
    int? defaultLayerFallback;
    Future<void> refreshLayerState() async {
      final ls = await db.allLayers();
      liveLayerIds = ls.map((l) => l.id).toSet();
      defaultLayerFallback = ls.isEmpty
          ? null
          : ls
              .firstWhere((l) => l.uuid == kDefaultLayerUuid,
                  orElse: () => ls.reduce((a, b) => a.id < b.id ? a : b))
              .id;
    }

    Future<Map<String, int>> localLayerIdsByUuid() async => {
          for (final l in await db.allLayers())
            if (l.uuid.isNotEmpty) l.uuid: l.id,
        };
    // Resolves an ARCHIVE layer id to a REAL local layer id. Order: exact uuid
    // match → the merge's recorded mapping (collapse / name-match / insert) →
    // the raw id IFF it is itself a live local layer → the default layer. It
    // NEVER returns an id with no backing row, so ensureLayersForContent stops
    // fabricating phantom layers for imported content.
    int remapLayerId(int archiveId, Map<String, int> localByUuid) {
      final uuid = archiveLayerUuidById[archiveId];
      if (uuid != null) {
        final local = localByUuid[uuid];
        if (local != null) return local;
      }
      final mapped = archiveIdToLocalId[archiveId];
      if (mapped != null) return mapped;
      if (liveLayerIds.contains(archiveId)) return archiveId;
      return defaultLayerFallback ?? archiveId;
    }

    // Layers first so journal rows can reference layerIds.
    await wrap('layers', () async {
      final raw = rawLayers;
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).cast<Map>();
      // Only wipe when there's actually replacement data. Clearing to import
      // an EMPTY layer list leaves the app with zero layers → a blank map
      // (everything renders per-layer). The self-heal at import-end would
      // recover it, but never destroying in the first place is cleaner.
      if (clearBeforeImport && list.isNotEmpty) {
        await db.delete(db.trackLayers).go();
      }
      final tombs = tombstoned['track_layers'] ?? const <String>{};
      // uuid → existing row, so known uuids can take LWW UPDATES (imports
      // used to skip any known uuid, so edits never propagated).
      final localLayers = await db.allLayers();
      final existing = {
        for (final l in localLayers)
          if (l.uuid.isNotEmpty) l.uuid: l,
      };
      // name → local rows, for the NAME-FALLBACK match below. Devices whose
      // "默认图层" was minted with different (or empty) uuids historically
      // would otherwise never match by uuid → a fresh copy inserted on every
      // single pull (unbounded duplication — the exact "同步前一个图层，拉完
      // 一堆重复" report). Matching by name reunites them and re-stamps the
      // local uuid to the incoming one so future pulls match by uuid.
      final byName = <String, List<TrackLayer>>{};
      for (final l in localLayers) {
        (byName[l.name.trim()] ??= []).add(l);
      }
      final claimed = <int>{}; // local ids already matched this import
      // Name → the surviving LOCAL id for it this import. Lets a cloud that
      // itself carries duplicate same-named layers (e.g. 11 copies of 默认图层
      // from an old churn) collapse the 2nd..Nth onto the first instead of
      // inserting fresh duplicates — AND records which local row a folded-away
      // layer maps to, so content pointing at its archive id follows it there.
      final nameToLocalId = <String, int>{};
      debugPrint('[BackupService] layers import — incoming=${list.length} '
          'localBefore=${localLayers.length} '
          'localUuids=[${localLayers.map((l) => '${l.id}:${l.uuid.isEmpty ? "∅" : l.uuid}').join(',')}]');
      var skipped = 0, updated = 0, nameMatched = 0, inserted = 0, bad = 0;
      var collapsed = 0; // cloud-side duplicate same-named layers folded away

      Future<void> lwwUpdate(TrackLayer local, Map r, DateTime? incomingTs,
          {String? convergeUuid}) async {
        final localTs = local.updatedAt;
        final newer = incomingTs != null &&
            (localTs == null || incomingTs.isAfter(localTs));
        // Even when the incoming copy is older we still converge the uuid, so
        // the divergent identities stop spawning duplicates on later pulls.
        if (!newer && convergeUuid == null) {
          skipped++;
          return;
        }
        await (db.update(db.trackLayers)..where((l) => l.id.equals(local.id)))
            .write(TrackLayersCompanion(
          uuid: convergeUuid == null ? const Value.absent() : Value(convergeUuid),
          name: newer ? Value(r['name']?.toString() ?? local.name) : const Value.absent(),
          colorValue: newer
              ? Value((r['colorValue'] as num?)?.toInt() ?? local.colorValue)
              : const Value.absent(),
          visible: newer ? Value(r['visible'] == true) : const Value.absent(),
          tag: newer ? Value(r['tag']?.toString()) : const Value.absent(),
          pathColor: newer ? Value((r['pathColor'] as num?)?.toInt()) : const Value.absent(),
          pathOpacity: newer ? Value((r['pathOpacity'] as num?)?.toDouble()) : const Value.absent(),
          pathWidth: newer ? Value((r['pathWidth'] as num?)?.toDouble()) : const Value.absent(),
          updatedAt: newer ? Value(incomingTs) : const Value.absent(),
        ));
        if (newer) updated++;
      }

      for (final r in list) {
        // Row-level fault tolerance: one corrupt row must not abort the
        // whole module (it used to kill every row after it).
        try {
          final uuid = r['uuid']?.toString() ?? '';
          final name = (r['name']?.toString() ?? '').trim();
          final archiveId = (r['id'] as num?)?.toInt();
          final incomingTs =
              DateTime.tryParse(r['updatedAt']?.toString() ?? '');
          // Record which local layer this archive layer resolved to, so
          // remapLayerId can follow content off a folded-away id to the survivor.
          void mapArchive(int localId) {
            if (archiveId != null) archiveIdToLocalId[archiveId] = localId;
            if (name.isNotEmpty) nameToLocalId[name] = localId;
          }
          if (uuid.isNotEmpty && tombs.contains(uuid)) {
            skipped++;
            continue;
          }
          // 1) uuid match — the fast, exact path.
          final local = uuid.isEmpty ? null : existing[uuid];
          if (local != null) {
            claimed.add(local.id);
            mapArchive(local.id);
            await lwwUpdate(local, r, incomingTs);
            continue;
          }
          // 2) name-fallback — reunite divergent-uuid copies of the same
          //    logical layer instead of inserting a duplicate. Only when
          //    exactly ONE unclaimed local layer carries that name, so we
          //    never merge two genuinely distinct same-named layers.
          final sameName = (byName[name] ?? const <TrackLayer>[])
              .where((l) => !claimed.contains(l.id))
              .toList();
          if (name.isNotEmpty && sameName.length == 1) {
            final match = sameName.first;
            claimed.add(match.id);
            mapArchive(match.id);
            await lwwUpdate(match, r, incomingTs,
                convergeUuid: uuid.isEmpty ? null : uuid);
            nameMatched++;
            continue;
          }
          // 2b) incoming-incoming collapse — the cloud itself carries several
          //     layers with this name (old churn). We already settled a local
          //     row for it this import; fold the 2nd..Nth away rather than
          //     re-inserting the duplication we're trying to cure — and map
          //     this archive id onto the survivor so its content isn't orphaned.
          if (name.isNotEmpty && nameToLocalId.containsKey(name)) {
            if (archiveId != null) {
              archiveIdToLocalId[archiveId] = nameToLocalId[name]!;
            }
            collapsed++;
            continue;
          }
          // 3) genuinely new layer.
          final newLocalId = await db.into(db.trackLayers).insert(
                TrackLayersCompanion.insert(
                  uuid: Value(uuid),
                  name: r['name']?.toString() ?? '',
                  colorValue:
                      (r['colorValue'] as num?)?.toInt() ?? 0xFF00BCD4,
                  visible: Value(r['visible'] == true),
                  tag: Value(r['tag']?.toString()),
                  createdAt:
                      DateTime.tryParse(r['createdAt']?.toString() ?? '') ??
                          DateTime.now(),
                  // Per-layer style (older backups omit these → stay null).
                  pathColor: Value((r['pathColor'] as num?)?.toInt()),
                  pathOpacity:
                      Value((r['pathOpacity'] as num?)?.toDouble()),
                  pathWidth: Value((r['pathWidth'] as num?)?.toDouble()),
                  updatedAt: Value(incomingTs),
                ),
              );
          mapArchive(newLocalId);
          inserted++;
        } catch (e) {
          bad++;
          debugPrint('[BackupService] layers row skipped: $e');
        }
      }
      if (updated + inserted > 0) {
        summary.imported['layers'] = updated + inserted;
      }
      if (skipped > 0) summary.skipped['layers'] = skipped;
      if (bad > 0) summary.errors['layers'] = '$bad 行损坏已跳过';
      debugPrint('[BackupService] layers import done — inserted=$inserted '
          'updated=$updated nameMatched=$nameMatched collapsed=$collapsed '
          'skipped=$skipped bad=$bad → localAfter=${(await db.allLayers()).length}');
    });
    // Snapshot the post-merge layer table (runs even when 'layers' wasn't
    // selected) so remapLayerId's fallback resolves to a real, live layer.
    await refreshLayerState();

    await wrap('journal', () async {
      final raw = readText('journal/entries.jsonl');
      if (raw == null) return;
      if (clearBeforeImport) {
        await db.delete(db.journalEntries).go();
        await db.customStatement('DELETE FROM journal_fts');
      }
      final tombs = tombstoned['journal_entries'] ?? const <String>{};
      final localByUuid = await localLayerIdsByUuid();
      // uuid → local updatedAt, for LWW on known rows.
      final localTs = <String, DateTime?>{};
      {
        final q = db.selectOnly(db.journalEntries)
          ..addColumns([db.journalEntries.uuid, db.journalEntries.updatedAt]);
        for (final r in await q.get()) {
          final u = r.read(db.journalEntries.uuid);
          if (u != null && u.isNotEmpty) {
            localTs[u] = r.read(db.journalEntries.updatedAt);
          }
        }
      }
      var skipped = 0, bad = 0, updated = 0, insertedNew = 0, incoming = 0;
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
        incoming++;
        try {
          final r = jsonDecode(line) as Map<String, dynamic>;
          final uuid = r['uuid']?.toString() ?? '';
          if (uuid.isNotEmpty && tombs.contains(uuid)) {
            skipped++;
            continue;
          }
          final incomingTs =
              DateTime.tryParse(r['updatedAt']?.toString() ?? '');
          final layerId =
              remapLayerId((r['layerId'] as num).toInt(), localByUuid);
          if (uuid.isNotEmpty && localTs.containsKey(uuid)) {
            // Known entry — take the incoming copy only if strictly newer
            // (null updatedAt = never edited = oldest). This is what makes
            // EDITS finally propagate instead of being dedup-skipped.
            final lt = localTs[uuid];
            final newer = incomingTs != null &&
                (lt == null || incomingTs.isAfter(lt));
            if (!newer) {
              skipped++;
              continue;
            }
            await db.applyJournalUpdateByUuid(
                uuid,
                JournalEntriesCompanion(
                  time: Value(
                      DateTime.tryParse(r['time']?.toString() ?? '') ??
                          DateTime.now()),
                  lat: Value((r['lat'] as num).toDouble()),
                  lng: Value((r['lng'] as num).toDouble()),
                  title: Value(r['title']?.toString() ?? ''),
                  richContent: Value(r['richContent']?.toString() ?? ''),
                  mediaPaths: Value(r['mediaPaths']?.toString() ?? ''),
                  layerId: Value(layerId),
                  level: Value(r['level']?.toString() ?? 'public'),
                  ownerPeerId: Value(r['ownerPeerId']?.toString()),
                  updatedAt: Value(incomingTs),
                ));
            updated++;
            summary.imported['journal'] =
                (summary.imported['journal'] ?? 0) + 1;
            continue;
          }
          // Use db.insertJournal so the FTS index stays consistent.
          await db.insertJournal(JournalEntriesCompanion.insert(
            uuid: Value(uuid),
            time: DateTime.tryParse(r['time']?.toString() ?? '') ??
                DateTime.now(),
            lat: (r['lat'] as num).toDouble(),
            lng: (r['lng'] as num).toDouble(),
            title: r['title']?.toString() ?? '',
            richContent: Value(r['richContent']?.toString() ?? ''),
            mediaPaths: Value(r['mediaPaths']?.toString() ?? ''),
            layerId: layerId,
            level: Value(r['level']?.toString() ?? 'public'),
            ownerPeerId: Value(r['ownerPeerId']?.toString()),
            updatedAt: Value(incomingTs),
          ));
          if (uuid.isNotEmpty) localTs[uuid] = incomingTs;
          insertedNew++;
          summary.imported['journal'] =
              (summary.imported['journal'] ?? 0) + 1;
        } catch (e) {
          bad++;
          debugPrint('[BackupService] journal row skipped: $e');
        }
      }
      if (skipped > 0) summary.skipped['journal'] = skipped;
      if (bad > 0) summary.errors['journal'] = '$bad 行损坏已跳过';
      debugPrint('[BackupService] journal import done — incoming=$incoming '
          'insertedNew=$insertedNew updated=$updated skipped=$skipped '
          'bad=$bad → localAfter=${await journalCount()}');
    });

    await wrap('song_favorites', () async {
      final raw = readText('song_favorites/favorites.jsonl');
      if (raw == null) return;
      if (clearBeforeImport) await db.delete(db.songFavorites).go();
      final seen = await existingUuids('song_favorites')
        ..addAll(tombstoned['song_favorites'] ?? const {});
      var skipped = 0, bad = 0;
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
        try {
          final r = jsonDecode(line) as Map<String, dynamic>;
          final uuid = r['uuid']?.toString() ?? '';
          if (uuid.isNotEmpty && seen.contains(uuid)) {
            skipped++;
            continue;
          }
          await db.into(db.songFavorites).insert(
                SongFavoritesCompanion.insert(
                  uuid: Value(uuid),
                  songId: r['songId']?.toString() ?? '',
                  title: r['title']?.toString() ?? '',
                  artist: r['artist']?.toString() ?? '',
                  coverUrl: Value(r['coverUrl']?.toString()),
                  source: r['source']?.toString() ?? 'gd',
                  addedAt:
                      DateTime.tryParse(r['addedAt']?.toString() ?? '') ??
                          DateTime.now(),
                  lat: Value((r['lat'] as num?)?.toDouble()),
                  lng: Value((r['lng'] as num?)?.toDouble()),
                ),
              );
          if (uuid.isNotEmpty) seen.add(uuid);
          summary.imported['song_favorites'] =
              (summary.imported['song_favorites'] ?? 0) + 1;
        } catch (e) {
          bad++;
          debugPrint('[BackupService] song_favorites row skipped: $e');
        }
      }
      if (skipped > 0) summary.skipped['song_favorites'] = skipped;
      if (bad > 0) summary.errors['song_favorites'] = '$bad 行损坏已跳过';
    });

    await wrap('track_points', () async {
      final entries = findUnder('track_points/').toList();
      if (clearBeforeImport) await db.delete(db.trackPoints).go();
      final seen = await existingUuids('track_points')
        ..addAll(tombstoned['track_points'] ?? const {});
      final localByUuid = await localLayerIdsByUuid();
      var skipped = 0, bad = 0;
      // Batched — a big history is hundreds of thousands of rows and per-row
      // awaits took minutes; one insertAll per file is one transaction.
      for (final f in entries) {
        final raw = utf8.decode(f.value);
        final batch = <TrackPointsCompanion>[];
        for (final line in raw.split('\n')) {
          if (line.trim().isEmpty) continue;
          try {
            final r = jsonDecode(line) as Map<String, dynamic>;
            final uuid = r['uuid']?.toString() ?? '';
            if (uuid.isNotEmpty && seen.contains(uuid)) {
              skipped++;
              continue;
            }
            batch.add(TrackPointsCompanion.insert(
              uuid: Value(uuid),
              lat: (r['lat'] as num).toDouble(),
              lng: (r['lng'] as num).toDouble(),
              time: DateTime.tryParse(r['time']?.toString() ?? '') ??
                  DateTime.now(),
              accuracy: Value((r['accuracy'] as num?)?.toDouble()),
              altitude: Value((r['altitude'] as num?)?.toDouble()),
              speed: Value((r['speed'] as num?)?.toDouble()),
              width: Value((r['width'] as num?)?.toDouble()),
              layerId:
                  remapLayerId((r['layerId'] as num).toInt(), localByUuid),
            ));
            if (uuid.isNotEmpty) seen.add(uuid);
          } catch (e) {
            bad++;
            debugPrint('[BackupService] track_points row skipped: $e');
          }
        }
        if (batch.isNotEmpty) {
          await db.insertPoints(batch);
          summary.imported['track_points'] =
              (summary.imported['track_points'] ?? 0) + batch.length;
        }
      }
      if (skipped > 0) summary.skipped['track_points'] = skipped;
      if (bad > 0) summary.errors['track_points'] = '$bad 行损坏已跳过';
    });

    await wrap('chat_messages', () async {
      final entries = findUnder('chat_messages/').toList();
      if (clearBeforeImport) await db.delete(db.chatMessages).go();
      final seen = await existingUuids('chat_messages')
        ..addAll(tombstoned['chat_messages'] ?? const {});
      var skipped = 0, bad = 0;
      for (final f in entries) {
        final raw = utf8.decode(f.value);
        final batch = <ChatMessagesCompanion>[];
        for (final line in raw.split('\n')) {
          if (line.trim().isEmpty) continue;
          try {
            final r = jsonDecode(line) as Map<String, dynamic>;
            final uuid = r['uuid']?.toString() ?? '';
            if (uuid.isNotEmpty && seen.contains(uuid)) {
              skipped++;
              continue;
            }
            batch.add(ChatMessagesCompanion.insert(
              uuid: Value(uuid),
              peerId: r['peerId']?.toString() ?? '',
              author: r['author']?.toString() ?? '',
              content: r['content']?.toString() ?? '',
              time: DateTime.tryParse(r['time']?.toString() ?? '') ??
                  DateTime.now(),
              outbound: r['outbound'] == true,
            ));
            if (uuid.isNotEmpty) seen.add(uuid);
          } catch (e) {
            bad++;
            debugPrint('[BackupService] chat_messages row skipped: $e');
          }
        }
        if (batch.isNotEmpty) {
          await db.batch((b) => b.insertAll(db.chatMessages, batch));
          summary.imported['chat_messages'] =
              (summary.imported['chat_messages'] ?? 0) + batch.length;
        }
      }
      if (skipped > 0) summary.skipped['chat_messages'] = skipped;
      if (bad > 0) summary.errors['chat_messages'] = '$bad 行损坏已跳过';
    });

    await wrap('fog_tiles', () async {
      // Fog merges by BITWISE UNION of both sides, then each side's bits
      // are trimmed by the OTHER side's newer erase masks. The old scheme
      // (whole-block LWW replace) silently dropped exploration whenever two
      // devices had touched the same ~600 m block — the "sync pulled but
      // nothing/lost data" report. Union can't lose adds; the masks stop it
      // from resurrecting erases; re-exploration AFTER an erase (block ts >
      // erasedAt) survives it.
      if (clearBeforeImport) {
        await db.delete(db.fogTiles).go();
        await db.delete(db.fogErases).go();
      }

      final localByUuid = await localLayerIdsByUuid();
      final allLayers = await db.allLayers();
      final defaultLayerId = allLayers.isEmpty
          ? 1
          : allLayers.map((l) => l.id).reduce((a, b) => a < b ? a : b);
      // Archive layer keys are layer UUIDs (v3), 'layer-<n>' placeholders
      // (v3, uuid-less rows) or bare ints (v2). Unknown keys — e.g. tiles
      // hand-copied straight out of a Fog of World Sync folder — land on
      // the default layer rather than being dropped.
      int resolveLayerKey(String key) {
        final asInt = int.tryParse(key);
        if (asInt != null) return remapLayerId(asInt, localByUuid);
        if (key.startsWith('layer-')) {
          final n = int.tryParse(key.substring(6));
          if (n != null) return remapLayerId(n, localByUuid);
        }
        return localByUuid[key] ?? defaultLayerId;
      }

      // Per-block updatedAt side-car (v2 map or v1 list format).
      final cloudTs = <String, DateTime>{};
      final idxRaw = readText('fog/index.json');
      if (idxRaw != null) {
        try {
          final decoded = jsonDecode(idxRaw);
          if (decoded is Map && decoded['v'] == 2) {
            for (final e in (decoded['blocks'] as List)) {
              final m = e as Map<String, dynamic>;
              final t = DateTime.tryParse(m['t']?.toString() ?? '');
              if (t == null) continue;
              final lid = resolveLayerKey(m['l']?.toString() ?? '');
              cloudTs['$lid/${m['x']}_${m['y']}_${m['z']}'] = t;
            }
          } else if (decoded is List) {
            for (final e in decoded) {
              final m = e as Map<String, dynamic>;
              final t = DateTime.tryParse(m['updatedAt']?.toString() ?? '');
              if (t == null) continue;
              final lid = remapLayerId(
                  (m['layerId'] as num).toInt(), localByUuid);
              cloudTs['$lid/${m['tileX']}_${m['tileY']}_${m['zoom']}'] = t;
            }
          }
        } catch (_) {}
      }

      // Cloud erase masks（迷雾增量减）: block key → (sweptMask, erasedAt).
      final cloudErase = <String, (Uint8List, DateTime)>{};
      final erasesRaw = readText('fog/erases.jsonl');
      if (erasesRaw != null) {
        for (final line in erasesRaw.split('\n')) {
          if (line.trim().isEmpty) continue;
          try {
            final m = jsonDecode(line) as Map<String, dynamic>;
            final t = DateTime.tryParse(m['t']?.toString() ?? '');
            final mask = base64Decode(m['mask']?.toString() ?? '');
            if (t == null || mask.isEmpty) continue;
            final lid = resolveLayerKey(m['l']?.toString() ?? '');
            final key = '$lid/${m['x']}_${m['y']}_${m['z']}';
            final prev = cloudErase[key];
            if (prev == null) {
              cloudErase[key] = (mask, t);
            } else {
              final merged = Uint8List.fromList(prev.$1);
              for (var i = 0; i < merged.length && i < mask.length; i++) {
                merged[i] |= mask[i];
              }
              cloudErase[key] =
                  (merged, t.isAfter(prev.$2) ? t : prev.$2);
            }
          } catch (_) {}
        }
      }

      // Incoming blocks — native FoW tiles (v3) and legacy .bin (v2), OR'd
      // together per block if both appear.
      final incoming = <String, Uint8List>{};
      void addIncoming(String key, Uint8List bits) {
        final prev = incoming[key];
        if (prev == null) {
          incoming[key] = bits;
        } else {
          for (var i = 0; i < prev.length && i < bits.length; i++) {
            prev[i] |= bits[i];
          }
        }
      }

      for (final f in findUnder('fow/')) {
        // fow/<layerKey>/<name>, or fow/<name> for tiles hand-copied from
        // a Fog of World Sync folder (no layer segment → default layer).
        final parts = f.key.split('/');
        final name = parts.last;
        if (!looksLikeFowTileName(name)) continue;
        final lid = parts.length >= 3
            ? resolveLayerKey(parts[1])
            : defaultLayerId;
        try {
          for (final b
              in fowBlocksFromFile(name, Uint8List.fromList(f.value))) {
            final x = b.tileX * 128 + b.blockX;
            final y = b.tileY * 128 + b.blockY;
            addIncoming('$lid/${x}_${y}_100', b.bitmap);
          }
        } catch (e) {
          debugPrint('[BackupService] bad FoW tile ${f.key}: $e');
        }
      }
      for (final f in findUnder('fog/')) {
        // Legacy v2 path: fog/<layerId>/<tileX>_<tileY>_<zoom>.bin
        if (!f.key.endsWith('.bin')) continue;
        final parts = f.key.split('/');
        if (parts.length != 3) continue;
        final layerId = int.tryParse(parts[1]);
        if (layerId == null) continue;
        final tri = parts[2]
            .replaceAll('.bin', '')
            .split('_')
            .map(int.tryParse)
            .toList();
        if (tri.length != 3 || tri.any((x) => x == null)) continue;
        final lid = remapLayerId(layerId, localByUuid);
        addIncoming('$lid/${tri[0]}_${tri[1]}_${tri[2]}',
            Uint8List.fromList(f.value));
      }

      // Local counterparts of everything the merge may touch.
      final involved = <int>{
        for (final k in incoming.keys) int.parse(k.split('/').first),
        for (final k in cloudErase.keys) int.parse(k.split('/').first),
      }.toList();
      final localRows = <String, FogTile>{};
      final localErase = <String, FogErase>{};
      if (!clearBeforeImport) {
        if (involved.isNotEmpty) {
          for (final r in await db.fogTilesForLayers(involved, 100)) {
            localRows['${r.layerId}/${r.tileX}_${r.tileY}_${r.zoom}'] = r;
          }
        }
        for (final e in await db.allFogErases()) {
          localErase['${e.layerId}/${e.tileX}_${e.tileY}_${e.zoom}'] = e;
        }
      }

      DateTime? newest(DateTime? a, DateTime? b) =>
          a == null ? b : (b == null || a.isAfter(b) ? a : b);
      bool sameBits(Uint8List a, List<int> b) {
        if (a.length != b.length) return false;
        for (var i = 0; i < a.length; i++) {
          if (a[i] != b[i]) return false;
        }
        return true;
      }

      // Batched upsert — a FOW-scale import is ~45k blocks; per-row upserts
      // were tens of thousands of separate transactions.
      final batch = <FogTilesCompanion>[];
      var kept = 0;
      Future<void> flush() async {
        if (batch.isEmpty) return;
        await db.batchUpsertFogTiles(List.of(batch));
        summary.imported['fog_tiles'] =
            (summary.imported['fog_tiles'] ?? 0) + batch.length;
        batch.clear();
        await Future<void>.delayed(Duration.zero);
      }

      for (final e in incoming.entries) {
        final key = e.key;
        final kp = key.split('/');
        final lid = int.parse(kp.first);
        final tri = kp[1].split('_').map(int.parse).toList();
        final ct = cloudTs[key];
        final lo = localRows[key];
        final le = localErase[key];

        // Cloud bits, minus LOCAL erases newer than the cloud copy. A
        // side-car-less copy (hand-copied FoW tile, ct == null) counts as
        // arbitrarily old, so any local erase trims it.
        final cloudBits = Uint8List.fromList(e.value);
        if (le != null && (ct == null || le.erasedAt.isAfter(ct))) {
          for (var i = 0;
              i < cloudBits.length && i < le.mask.length;
              i++) {
            cloudBits[i] &= ~le.mask[i];
          }
        }

        final Uint8List merged;
        if (lo == null) {
          var any = false;
          for (final b in cloudBits) {
            if (b != 0) {
              any = true;
              break;
            }
          }
          if (!any) {
            kept++; // fully erased — don't create an empty row
            continue;
          }
          merged = cloudBits;
        } else {
          // Local bits, minus CLOUD erases newer than the local copy…
          final bits = Uint8List.fromList(lo.bitmap);
          final ce = cloudErase[key];
          if (ce != null && ce.$2.isAfter(lo.updatedAt)) {
            for (var i = 0; i < bits.length && i < ce.$1.length; i++) {
              bits[i] &= ~ce.$1[i];
            }
          }
          // …then union.
          for (var i = 0; i < bits.length && i < cloudBits.length; i++) {
            bits[i] |= cloudBits[i];
          }
          if (sameBits(bits, lo.bitmap)) {
            kept++;
            continue;
          }
          merged = bits;
        }
        batch.add(FogTilesCompanion.insert(
          tileX: tri[0],
          tileY: tri[1],
          zoom: tri[2],
          layerId: lid,
          bitmap: merged,
          // max(local, cloud) — both devices computing this merge converge
          // on identical (bits, ts). Stamping now() would make stale copies
          // look newest and beat later real edits.
          updatedAt: newest(lo?.updatedAt, ct) ?? DateTime.now(),
        ));
        if (batch.length >= 2000) await flush();
      }

      // Cloud erases must also reach local blocks the archive carries NO
      // bits for — a fully-erased block exports no FoW data at all.
      for (final e in cloudErase.entries) {
        if (incoming.containsKey(e.key)) continue; // merged above
        final lo = localRows[e.key];
        if (lo == null) continue;
        final (mask, t) = e.value;
        if (!t.isAfter(lo.updatedAt)) continue;
        final bits = Uint8List.fromList(lo.bitmap);
        var changed = false;
        for (var i = 0; i < bits.length && i < mask.length; i++) {
          final nb = bits[i] & ~mask[i] & 0xff;
          if (nb != bits[i]) {
            bits[i] = nb;
            changed = true;
          }
        }
        if (!changed) continue;
        final kp = e.key.split('/');
        final tri = kp[1].split('_').map(int.parse).toList();
        batch.add(FogTilesCompanion.insert(
          tileX: tri[0],
          tileY: tri[1],
          zoom: tri[2],
          layerId: int.parse(kp.first),
          bitmap: bits,
          updatedAt: t,
        ));
        if (batch.length >= 2000) await flush();
      }
      await flush();

      // Adopt the cloud's erase masks (OR, freshest timestamp) so this
      // device re-propagates them on its own next export.
      for (final e in cloudErase.entries) {
        final kp = e.key.split('/');
        final tri = kp[1].split('_').map(int.parse).toList();
        final le = localErase[e.key];
        var mask = e.value.$1;
        var t = e.value.$2;
        if (le != null) {
          final m2 = Uint8List.fromList(mask);
          for (var i = 0; i < m2.length && i < le.mask.length; i++) {
            m2[i] |= le.mask[i];
          }
          mask = m2;
          if (le.erasedAt.isAfter(t)) t = le.erasedAt;
        }
        await db.into(db.fogErases).insert(
              FogErasesCompanion.insert(
                tileX: tri[0],
                tileY: tri[1],
                zoom: tri[2],
                layerId: int.parse(kp.first),
                mask: Uint8List.fromList(mask),
                erasedAt: t,
              ),
              mode: InsertMode.insertOrReplace,
            );
      }
      if (kept > 0) summary.skipped['fog_tiles'] = kept;
    });

    await wrap('planner_history', () async {
      final entries = findUnder('planner_history/').toList();
      if (entries.isEmpty) return;
      final merged = <Map<String, dynamic>>[];
      for (final f in entries) {
        try {
          final r = jsonDecode(utf8.decode(f.value)) as Map<String, dynamic>;
          merged.add(r);
        } catch (_) {}
      }
      final prefs = await SharedPreferences.getInstance();
      if (clearBeforeImport) {
        await prefs.setString('planner_history_v1', jsonEncode(merged));
      } else {
        // Merge by id with imported sessions winning ties.
        final existingRaw = prefs.getString('planner_history_v1');
        final byId = <String, Map<String, dynamic>>{};
        if (existingRaw != null) {
          for (final e in (jsonDecode(existingRaw) as List)
              .cast<Map<String, dynamic>>()) {
            byId[e['id']?.toString() ?? ''] = e;
          }
        }
        for (final e in merged) {
          byId[e['id']?.toString() ?? ''] = e;
        }
        await prefs.setString(
            'planner_history_v1', jsonEncode(byId.values.toList()));
      }
      summary.imported['planner_history'] = merged.length;
    });

    await wrap('settings', () async {
      final raw = readText('settings/app_settings.json');
      if (raw == null) return;
      final prefs = await SharedPreferences.getInstance();
      // LWW — keep LOCAL settings when they're newer than the archive's
      // (blind overwrite made every sync-down clobber this device's
      // preferences). clearBeforeImport (explicit restore) still forces.
      DateTime? cloudTs;
      final metaRaw = readText('settings/meta.json');
      if (metaRaw != null) {
        try {
          cloudTs = DateTime.tryParse(
              (jsonDecode(metaRaw) as Map)['updatedAt']?.toString() ?? '');
        } catch (_) {}
      }
      final localTs =
          DateTime.tryParse(prefs.getString('settings_updated_at') ?? '');
      if (!clearBeforeImport &&
          localTs != null &&
          (cloudTs == null || !cloudTs.isAfter(localTs))) {
        summary.skipped['settings'] = 1;
        return;
      }
      // NEVER let a restore wipe local credentials. Exports scrub every
      // secret field to null, so writing the archive's settings verbatim
      // nulled the OneDrive refresh token (and WebDAV password, PATs, …)
      // — after the next app start OneDrive showed "未连接" and both sync
      // buttons went dead. Graft the LOCAL secret values back in wherever
      // the archive carries null. Applies to forced restores too.
      var incoming = raw;
      try {
        final cloud = jsonDecode(raw) as Map<String, dynamic>;
        if (cloud['scrubFailed'] == true) {
          // A backup whose secrets couldn't be stripped refuses to carry
          // settings at all — never overwrite ours with that stub.
          summary.skipped['settings'] = 1;
          return;
        }
        final localRaw = prefs.getString('app_settings_v1');
        if (localRaw != null) {
          final local = jsonDecode(localRaw) as Map<String, dynamic>;
          for (final k in kVaultSecretKeys) {
            if (cloud[k] == null && local[k] != null) {
              cloud[k] = local[k];
            }
          }
        }
        incoming = jsonEncode(cloud);
      } catch (_) {}
      await prefs.setString('app_settings_v1', incoming);
      if (cloudTs != null) {
        await prefs.setString(
            'settings_updated_at', cloudTs.toIso8601String());
      }
      summary.imported['settings'] = 1;
    });

    await wrap('imghost_uploads', () async {
      final raw = readText('imghost_uploads/registry.json');
      if (raw == null) return;
      final prefs = await SharedPreferences.getInstance();
      // Merge with the local registry (archive wins per key) — a blind
      // overwrite dropped records of uploads made on this device.
      var merged = raw;
      final existingRaw = prefs.getString('img_host_uploads_v1');
      if (!clearBeforeImport && existingRaw != null) {
        try {
          final a = jsonDecode(existingRaw);
          final b = jsonDecode(raw);
          if (a is Map<String, dynamic> && b is Map<String, dynamic>) {
            merged = jsonEncode({...a, ...b});
          } else if (a is List && b is List) {
            final seenKeys = <String>{};
            final out = <dynamic>[];
            for (final e in [...a, ...b]) {
              if (seenKeys.add(jsonEncode(e))) out.add(e);
            }
            merged = jsonEncode(out);
          }
        } catch (_) {}
      }
      await prefs.setString('img_host_uploads_v1', merged);
      summary.imported['imghost_uploads'] = 1;
    });

    await wrap('geocode_cache', () async {
      final raw = readText('geocode/cell_cache.json');
      if (raw == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('geocode_cell_cache_v1', raw);
      summary.imported['geocode_cache'] = 1;
    });

    await wrap('learned_regions', () async {
      final raw = readText('geocode/learned_regions.json');
      if (raw == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('learned_regions_v1', raw);
      summary.imported['learned_regions'] = 1;
    });

    await wrap('leaderboard', () async {
      final raw = readText('leaderboard/entries.jsonl');
      if (raw == null || leaderboard == null) return;
      final incoming = <LeaderboardEntry>[];
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
        try {
          incoming.add(LeaderboardEntry.fromJson(
              jsonDecode(line) as Map<String, dynamic>));
        } catch (_) {}
      }
      final changed = await leaderboard!.mergeBatch(incoming);
      summary.imported['leaderboard'] = changed;
      final skipped = incoming.length - changed;
      if (skipped > 0) summary.skipped['leaderboard'] = skipped;
    });

    // Self-heal the layer-driven render pipeline: imported content that
    // references a layerId with no matching layer row (cross-device id
    // skew, a cloud whose layers were wiped, a partial shard set) would
    // render as a blank map. Recreate any orphaned layers so the data shows.
    try {
      final healed = await db.ensureLayersForContent();
      if (healed > 0) {
        debugPrint('[BackupService] recreated $healed orphaned layer(s)');
        summary.imported['layers'] =
            (summary.imported['layers'] ?? 0) + healed;
      }
    } catch (e) {
      debugPrint('[BackupService] ensureLayersForContent failed: $e');
    }

    // In restore mode the archive is authoritative. Any row it just brought
    // back that STILL carries a local delete marker would be re-deleted on the
    // next syncUp (and re-suppressed on the next import). Drop the markers for
    // uuids that exist again now — leaving intact the tombstones for uuids the
    // restore did NOT resurrect (genuine deletions unrelated to this archive,
    // and the archive's OWN tombstones, whose rows were deleted above).
    if (restore) {
      try {
        var cleared = 0;
        for (final tbl in _tombstoneTables) {
          cleared += await db.customUpdate(
            'DELETE FROM tombstones WHERE tbl = ? '
            'AND uuid IN (SELECT uuid FROM $tbl)',
            variables: [Variable.withString(tbl)],
            updateKind: UpdateKind.delete,
          );
        }
        if (cleared > 0) {
          debugPrint(
              '[BackupService] restore cleared $cleared stale tombstone(s)');
        }
      } catch (e) {
        debugPrint('[BackupService] restore tombstone cleanup failed: $e');
      }
    }

    onProgress?.call(totalModules, totalModules, '导入完成');
    // One greppable line per import — this is what to look for in logcat
    // when "nothing seems to apply": it names every module's insert/skip
    // counts and any per-module error.
    debugPrint('[BackupService] import done — restore=$restore '
        'imported: ${summary.imported}, skipped: ${summary.skipped}, '
        'errors: ${summary.errors}');
    return summary;
  }
}

/// `app_settings_v1` field names that hold weaponizable secrets (PATs,
/// passwords, tokens, bearer-equivalents) — stripped before any backup leaves
/// the device. Kept next to the backup logic so adding a new credential field
/// is hard to forget. **Public** so the roaming settings config (a separate
/// path that, unlike backup, KEEPS these — the console holds them encrypted at
/// rest) derives its secret set from the same single source of truth: a key
/// added here is covered by both, never one and not the other.
const kVaultSecretKeys = <String>{
  'webdavPass',
  'p2pPassphrase',
  'aiApiKey',
  'githubPat',
  'githubPrivatePat',
  'customAuthHeader',
  'leaderboardRepoPat',
  'leaderboardServerToken',
  // OneDrive refresh token — a long-lived bearer-equivalent for the user's
  // whole drive (app folder); must never ride along in an exported backup.
  'oneDriveRefreshToken',
  // Music cookies / OAuth tokens — also bearer-equivalents.
  'musicCredentials',
  // AI 旅伴语音链路的独立凭据（留空时复用 aiApiKey，本身已在上面）。
  'sttApiKey',
  'ttsApiKey',
  'volcTtsToken',
};

/// Returns a copy of the settings JSON with all credentials replaced
/// by `null`. Keeps everything else intact so the user's preferences
/// (map style, fog colour, etc.) survive the round-trip.
String _scrubSettings(String raw) {
  try {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    for (final k in kVaultSecretKeys) {
      if (j.containsKey(k)) j[k] = null;
    }
    return jsonEncode(j);
  } catch (_) {
    // Don't ship a backup we can't reason about. Returning a manifest
    // is better than no settings module at all, but actively
    // dangerous if we can't strip secrets — so refuse to include.
    return jsonEncode({'scrubFailed': true});
  }
}

class ImportSummary {
  final Map<String, int> imported = {};
  /// Rows skipped because the same UUID is already present locally.
  final Map<String, int> skipped = {};
  final Map<String, String> errors = {};

  String describe() {
    final parts = <String>[];
    for (final k in {...imported.keys, ...skipped.keys}) {
      final label = BackupService.moduleLabels[k] ?? k;
      final imp = imported[k] ?? 0;
      final skip = skipped[k] ?? 0;
      parts.add(skip > 0
          ? '$label: $imp 应用 / $skip 本地已是最新'
          : '$label: $imp 应用');
    }
    if (errors.isNotEmpty) {
      parts.add(
          '错误：${errors.entries.map((e) => "${e.key}=${e.value}").join("; ")}');
    }
    return parts.isEmpty
        ? '没有导入任何数据（云端与本地无差异，或所选模块在云端没有内容）'
        : parts.join('\n');
  }
}
