import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value, InsertMode;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/db/database.dart';
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
/// manifest.json                        v=2 + exportedAt + modules
/// journal/entries.jsonl                one entry per line
/// layers/layers.json
/// song_favorites/favorites.jsonl
/// track_points/<yyyy-mm>.jsonl         chunked by month
/// chat_messages/<peerId>.jsonl         chunked by peer
/// planner_history/<sessionId>.json
/// settings/app_settings.json
/// fog/<layerId>/<tileX>_<tileY>_<zoom>.bin   raw bitmap bytes
/// imghost_uploads/registry.json
/// geocode/cell_cache.json
/// geocode/learned_regions.json
/// ```
class BackupService {
  final AppDb db;
  /// Optional — when set, the leaderboard module is auto-included on export
  /// and auto-merged on import. The user cannot opt out (it's a contract
  /// with the rest of the group sync system).
  final LeaderboardService? leaderboard;
  BackupService(this.db, {this.leaderboard});

  static const archiveVersion = 2;

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
  ];

  /// Modules that MUST be in every export — the UI checkbox is rendered
  /// disabled so the user can see them but can't deselect. Required for
  /// the decentralised leaderboard's gossip-via-backup story.
  static const requiredModules = <String>{'leaderboard'};

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
  };

  // ─── Export ─────────────────────────────────────────────────────────────

  /// Build the zip in memory and return its raw bytes.
  Future<Uint8List> exportToArchive(Set<String> selected) async {
    // Force the required modules — caller can't opt out.
    final modules = {...selected, ...requiredModules};
    final archive = Archive();

    void addJson(String path, Object obj) {
      final data =
          utf8.encode(const JsonEncoder.withIndent('  ').convert(obj));
      archive.addFile(ArchiveFile(path, data.length, data));
    }

    void addText(String path, String body) {
      final data = utf8.encode(body);
      archive.addFile(ArchiveFile(path, data.length, data));
    }

    void addBytes(String path, List<int> bytes) {
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    // Manifest first so reads can short-circuit on version mismatch.
    addJson('manifest.json', {
      'version': archiveVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'appVersion': '0.1.0',
      'modules': modules.toList()..sort(),
    });

    if (modules.contains('journal')) {
      final rows = await db.select(db.journalEntries).get();
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
              })).join('\n'));
    }

    if (modules.contains('layers')) {
      final rows = await db.select(db.trackLayers).get();
      addJson(
          'layers/layers.json',
          rows
              .map((r) => {
                    'uuid': r.uuid,
                    'name': r.name,
                    'colorValue': r.colorValue,
                    'visible': r.visible,
                    'tag': r.tag,
                    'createdAt': r.createdAt.toIso8601String(),
                    // Per-layer path style (null = inherit global default).
                    'pathColor': r.pathColor,
                    'pathOpacity': r.pathOpacity,
                    'pathWidth': r.pathWidth,
                  })
              .toList());
    }

    if (modules.contains('song_favorites')) {
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
          'layerId': r.layerId,
        });
      }
      for (final entry in byMonth.entries) {
        addText('track_points/${entry.key}.jsonl',
            entry.value.map(jsonEncode).join('\n'));
      }
    }

    if (modules.contains('chat_messages')) {
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
      }
    }

    if (modules.contains('fog_tiles')) {
      // One file per tile — Fog of World does the same. Naming includes
      // layerId so multi-layer users keep separate trees.
      final rows = await db.select(db.fogTiles).get();
      for (final r in rows) {
        addBytes(
          'fog/${r.layerId}/${r.tileX}_${r.tileY}_${r.zoom}.bin',
          r.bitmap,
        );
      }
      // Side-car manifest so import doesn't have to parse paths.
      addJson(
          'fog/index.json',
          rows
              .map((r) => {
                    'layerId': r.layerId,
                    'tileX': r.tileX,
                    'tileY': r.tileY,
                    'zoom': r.zoom,
                    'updatedAt': r.updatedAt.toIso8601String(),
                  })
              .toList());
    }

    if (modules.contains('imghost_uploads')) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('img_host_uploads_v1');
      if (raw != null) {
        addText('imghost_uploads/registry.json', raw);
      }
    }

    if (modules.contains('geocode_cache')) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('geocode_cell_cache_v1');
      if (raw != null) {
        addText('geocode/cell_cache.json', raw);
      }
    }

    if (modules.contains('learned_regions')) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('learned_regions_v1');
      if (raw != null) {
        addText('geocode/learned_regions.json', raw);
      }
    }

    if (modules.contains('leaderboard') && leaderboard != null) {
      // One line per entry — same on-wire shape as the P2P gossip path,
      // so importing a backup is just "merge a batch from your past self".
      final list = leaderboard!.toExportList();
      addText(
        'leaderboard/entries.jsonl',
        list.map(jsonEncode).join('\n'),
      );
    }

    // `encode` is `List<int>?` in recent archive versions; we know it's
    // non-null because we always added at least manifest.json.
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
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
  }) async {
    modules = {...modules, ...requiredModules};
    final archive = ZipDecoder().decodeBytes(bytes);
    final summary = ImportSummary();

    // Manifest is informational — we don't hard-fail on version mismatch
    // since the layout is forward-compatible (extra files are ignored).
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) {
      throw const FormatException(
          'manifest.json 不存在，这可能不是一个 explore_journal 备份');
    }
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>))
        as Map<String, dynamic>;
    final v = manifest['version'] as int? ?? 1;
    if (v > archiveVersion) {
      debugPrint('[BackupService] importing newer archive version $v '
          '(supported: $archiveVersion) — extra fields will be skipped');
    }

    String? readText(String path) {
      final f = archive.findFile(path);
      if (f == null) return null;
      return utf8.decode(f.content as List<int>);
    }

    Iterable<ArchiveFile> findUnder(String prefix) =>
        archive.files.where((f) => f.name.startsWith(prefix) && f.isFile);

    Future<void> wrap(String key, Future<void> Function() body) async {
      if (!modules.contains(key)) return;
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

    // Layers first so journal rows can reference layerIds.
    await wrap('layers', () async {
      final raw = readText('layers/layers.json');
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).cast<Map>();
      if (clearBeforeImport) await db.delete(db.trackLayers).go();
      final seen = await existingUuids('track_layers');
      var skipped = 0;
      for (final r in list) {
        final uuid = r['uuid']?.toString() ?? '';
        if (uuid.isNotEmpty && seen.contains(uuid)) {
          skipped++;
          continue;
        }
        await db.into(db.trackLayers).insert(
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
                pathOpacity: Value((r['pathOpacity'] as num?)?.toDouble()),
                pathWidth: Value((r['pathWidth'] as num?)?.toDouble()),
              ),
            );
        if (uuid.isNotEmpty) seen.add(uuid);
        summary.imported['layers'] = (summary.imported['layers'] ?? 0) + 1;
      }
      if (skipped > 0) summary.skipped['layers'] = skipped;
    });

    await wrap('journal', () async {
      final raw = readText('journal/entries.jsonl');
      if (raw == null) return;
      if (clearBeforeImport) {
        await db.delete(db.journalEntries).go();
        await db.customStatement('DELETE FROM journal_fts');
      }
      final seen = await existingUuids('journal_entries');
      var skipped = 0;
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
        final r = jsonDecode(line) as Map<String, dynamic>;
        final uuid = r['uuid']?.toString() ?? '';
        if (uuid.isNotEmpty && seen.contains(uuid)) {
          skipped++;
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
          layerId: (r['layerId'] as num).toInt(),
          level: Value(r['level']?.toString() ?? 'public'),
          ownerPeerId: Value(r['ownerPeerId']?.toString()),
        ));
        if (uuid.isNotEmpty) seen.add(uuid);
        summary.imported['journal'] = (summary.imported['journal'] ?? 0) + 1;
      }
      if (skipped > 0) summary.skipped['journal'] = skipped;
    });

    await wrap('song_favorites', () async {
      final raw = readText('song_favorites/favorites.jsonl');
      if (raw == null) return;
      if (clearBeforeImport) await db.delete(db.songFavorites).go();
      final seen = await existingUuids('song_favorites');
      var skipped = 0;
      for (final line in raw.split('\n')) {
        if (line.trim().isEmpty) continue;
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
      }
      if (skipped > 0) summary.skipped['song_favorites'] = skipped;
    });

    await wrap('track_points', () async {
      final files = findUnder('track_points/').toList();
      if (clearBeforeImport) await db.delete(db.trackPoints).go();
      final seen = await existingUuids('track_points');
      var skipped = 0;
      for (final f in files) {
        final raw = utf8.decode(f.content as List<int>);
        for (final line in raw.split('\n')) {
          if (line.trim().isEmpty) continue;
          final r = jsonDecode(line) as Map<String, dynamic>;
          final uuid = r['uuid']?.toString() ?? '';
          if (uuid.isNotEmpty && seen.contains(uuid)) {
            skipped++;
            continue;
          }
          await db.into(db.trackPoints).insert(
                TrackPointsCompanion.insert(
                  uuid: Value(uuid),
                  lat: (r['lat'] as num).toDouble(),
                  lng: (r['lng'] as num).toDouble(),
                  time: DateTime.tryParse(r['time']?.toString() ?? '') ??
                      DateTime.now(),
                  accuracy: Value((r['accuracy'] as num?)?.toDouble()),
                  altitude: Value((r['altitude'] as num?)?.toDouble()),
                  speed: Value((r['speed'] as num?)?.toDouble()),
                  layerId: (r['layerId'] as num).toInt(),
                ),
              );
          if (uuid.isNotEmpty) seen.add(uuid);
          summary.imported['track_points'] =
              (summary.imported['track_points'] ?? 0) + 1;
        }
      }
      if (skipped > 0) summary.skipped['track_points'] = skipped;
    });

    await wrap('chat_messages', () async {
      final files = findUnder('chat_messages/').toList();
      if (clearBeforeImport) await db.delete(db.chatMessages).go();
      final seen = await existingUuids('chat_messages');
      var skipped = 0;
      for (final f in files) {
        final raw = utf8.decode(f.content as List<int>);
        for (final line in raw.split('\n')) {
          if (line.trim().isEmpty) continue;
          final r = jsonDecode(line) as Map<String, dynamic>;
          final uuid = r['uuid']?.toString() ?? '';
          if (uuid.isNotEmpty && seen.contains(uuid)) {
            skipped++;
            continue;
          }
          await db.into(db.chatMessages).insert(
                ChatMessagesCompanion.insert(
                  uuid: Value(uuid),
                  peerId: r['peerId']?.toString() ?? '',
                  author: r['author']?.toString() ?? '',
                  content: r['content']?.toString() ?? '',
                  time: DateTime.tryParse(r['time']?.toString() ?? '') ??
                      DateTime.now(),
                  outbound: r['outbound'] == true,
                ),
              );
          if (uuid.isNotEmpty) seen.add(uuid);
          summary.imported['chat_messages'] =
              (summary.imported['chat_messages'] ?? 0) + 1;
        }
      }
      if (skipped > 0) summary.skipped['chat_messages'] = skipped;
    });

    await wrap('fog_tiles', () async {
      final files = findUnder('fog/')
          .where((f) => f.name.endsWith('.bin'))
          .toList();
      if (clearBeforeImport) await db.delete(db.fogTiles).go();
      for (final f in files) {
        // Path: fog/<layerId>/<tileX>_<tileY>_<zoom>.bin
        final parts = f.name.split('/');
        if (parts.length != 3) continue;
        final layerId = int.tryParse(parts[1]);
        if (layerId == null) continue;
        final base = parts[2].replaceAll('.bin', '');
        final tri = base.split('_').map(int.tryParse).toList();
        if (tri.length != 3 || tri.any((x) => x == null)) continue;
        await db.into(db.fogTiles).insert(
              FogTilesCompanion.insert(
                tileX: tri[0]!,
                tileY: tri[1]!,
                zoom: tri[2]!,
                layerId: layerId,
                bitmap: Uint8List.fromList(f.content as List<int>),
                updatedAt: DateTime.now(),
              ),
              mode: InsertMode.insertOrReplace,
            );
        summary.imported['fog_tiles'] =
            (summary.imported['fog_tiles'] ?? 0) + 1;
      }
    });

    await wrap('planner_history', () async {
      final files = findUnder('planner_history/').toList();
      if (files.isEmpty) return;
      final merged = <Map<String, dynamic>>[];
      for (final f in files) {
        try {
          final r = jsonDecode(utf8.decode(f.content as List<int>))
              as Map<String, dynamic>;
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
      await prefs.setString('app_settings_v1', raw);
      summary.imported['settings'] = 1;
    });

    await wrap('imghost_uploads', () async {
      final raw = readText('imghost_uploads/registry.json');
      if (raw == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('img_host_uploads_v1', raw);
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

    return summary;
  }
}

/// List of `app_settings_v1` field names that must be stripped before
/// any backup leaves the device. Kept here next to the backup logic so
/// adding a new credential field is hard to forget — every reviewer of
/// a settings change will see this list nearby.
const _kSecretSettingsKeys = <String>{
  'webdavPass',
  'p2pPassphrase',
  'aiApiKey',
  'githubPat',
  'githubPrivatePat',
  'customAuthHeader',
  'leaderboardRepoPat',
  'leaderboardServerToken',
  // Music cookies / OAuth tokens — also bearer-equivalents.
  'musicCredentials',
};

/// Returns a copy of the settings JSON with all credentials replaced
/// by `null`. Keeps everything else intact so the user's preferences
/// (map style, fog colour, etc.) survive the round-trip.
String _scrubSettings(String raw) {
  try {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    for (final k in _kSecretSettingsKeys) {
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
          ? '$label: $imp 新增 / $skip 已存在（按 UUID 跳过）'
          : '$label: $imp 新增');
    }
    if (errors.isNotEmpty) {
      parts.add(
          '错误：${errors.entries.map((e) => "${e.key}=${e.value}").join("; ")}');
    }
    return parts.isEmpty ? '没有导入任何数据' : parts.join('\n');
  }
}
