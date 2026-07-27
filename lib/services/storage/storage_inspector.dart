import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/db/database.dart';
import '../map/cached_tile_provider.dart';

/// One measured bucket of on-disk data: total bytes + file count.
class StorageSlice {
  final int bytes;
  final int count;
  const StorageSlice(this.bytes, this.count);
  static const zero = StorageSlice(0, 0);
}

/// Row counts of the user-facing tables, for the database tile's subtitle.
class DbCounts {
  final int trackPoints;
  final int fogTiles;
  final int journals;
  final int chats;
  const DbCounts(this.trackPoints, this.fogTiles, this.journals, this.chats);
}

class StorageReport {
  /// explore_journal.sqlite + its -wal / -shm side files.
  final StorageSlice db;
  final DbCounts dbCounts;

  /// Media files referenced by journal entries and AI chat messages. These
  /// mostly live in the cache dir (image_picker output) but are NOT cache:
  /// deleting them destroys journal photos, so they are counted separately
  /// and excluded from every cleanup sweep.
  final StorageSlice photos;

  /// Referenced media paths whose file no longer exists on disk.
  final int photosMissing;

  /// Map tile cache (`<cache>/explore_map_tiles`).
  final StorageSlice tiles;

  /// AI companion chat history file.
  final StorageSlice ai;
  final int aiSessions;
  final int aiMessages;

  /// Downloaded admin-region boundary GeoJSON (`<docs>/admin_regions`).
  final StorageSlice regions;

  /// Cleanable temp files: everything else under the cache dir that is not
  /// a referenced photo, not the tile cache, and older than [tempGraceMs].
  final StorageSlice temp;

  /// Temp files skipped because they were modified within the grace window
  /// (possibly still in use: a TTS clip being played, a photo just picked).
  final int tempSkippedRecent;

  /// Everything else in the app's private dirs (pending track buffer,
  /// leaderboard records, cache-manager index, ...). Shown, never cleaned.
  final StorageSlice other;

  const StorageReport({
    required this.db,
    required this.dbCounts,
    required this.photos,
    required this.photosMissing,
    required this.tiles,
    required this.ai,
    required this.aiSessions,
    required this.aiMessages,
    required this.regions,
    required this.temp,
    required this.tempSkippedRecent,
    required this.other,
  });

  int get totalBytes =>
      db.bytes +
      photos.bytes +
      tiles.bytes +
      ai.bytes +
      regions.bytes +
      temp.bytes +
      other.bytes;
}

/// Scans the app's private storage into named buckets and performs the
/// cleanup actions the storage settings screen offers.
///
/// Safety invariant: no action here may touch user data — journal photos
/// (even though they sit in the cache dir), the database, the pending track
/// buffer and leaderboard records are only ever measured, never deleted.
class StorageInspector {
  final AppDb _db;
  StorageInspector(this._db);

  /// Files modified more recently than this are never swept as temp: a photo
  /// picked but not yet saved, or a TTS clip mid-playback, looks exactly like
  /// an orphan until its message/journal is committed.
  static const tempGraceMs = 60 * 60 * 1000;

  Future<StorageReport> scan() async {
    final paths = await _paths();
    final refs = await _referencedMedia(paths.docs);
    final counts = await _dbCounts();
    final ai = await _aiStats(paths.docs);

    // Pure dart:io from here on — off the UI isolate, the tile cache alone
    // can hold tens of thousands of files.
    final r = await Isolate.run(() => _scanDirs(paths, refs));

    return StorageReport(
      db: r.db,
      dbCounts: counts,
      photos: r.photos,
      photosMissing: r.photosMissing,
      tiles: r.tiles,
      ai: r.ai,
      aiSessions: ai.$1,
      aiMessages: ai.$2,
      regions: r.regions,
      temp: r.temp,
      tempSkippedRecent: r.tempSkippedRecent,
      other: r.other,
    );
  }

  /// Empty the map tile cache. Returns bytes freed.
  Future<int> cleanTiles() async {
    final paths = await _paths();
    final dir = Directory(p.join(paths.cache, 'explore_map_tiles'));
    final before = await _dirSize(dir);
    await mapTileCacheManager.emptyCache();
    // emptyCache clears the index; sweep any stragglers on disk too.
    if (await dir.exists()) {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
    return before - await _dirSize(dir);
  }

  /// Delete unreferenced temp files older than the grace window. Same
  /// classification as [scan], so the number shown is the number freed.
  Future<int> cleanTemp() async {
    final paths = await _paths();
    final refs = await _referencedMedia(paths.docs);
    return Isolate.run(() => _sweepTemp(paths, refs, delete: true).bytes);
  }

  /// Delete downloaded admin-region boundaries; they re-download on demand.
  Future<int> cleanRegions() async {
    final docs = (await getApplicationDocumentsDirectory()).path;
    final dir = Directory(p.join(docs, 'admin_regions'));
    final before = await _dirSize(dir);
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    return before - await _dirSize(dir);
  }

  /// VACUUM the database (after a WAL checkpoint) and return bytes freed.
  /// Reclaims pages left behind by deleted rows; touches no live data.
  Future<int> vacuumDb() async {
    final support = (await getApplicationSupportDirectory()).path;
    final before = await _dbFilesSize(support);
    await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await _db.customStatement('VACUUM');
    return before - await _dbFilesSize(support);
  }

  // ── internals ──

  Future<_Paths> _paths() async => (
        support: (await getApplicationSupportDirectory()).path,
        docs: (await getApplicationDocumentsDirectory()).path,
        cache: (await getTemporaryDirectory()).path,
      );

  Future<DbCounts> _dbCounts() async {
    Future<int> count(String table) async {
      final row = await _db
          .customSelect('SELECT COUNT(*) AS c FROM $table')
          .getSingle();
      return row.read<int>('c');
    }

    return DbCounts(
      await count('track_points'),
      await count('fog_tiles'),
      await count('journal_entries'),
      await count('chat_messages'),
    );
  }

  /// Absolute paths of every media file referenced by journals or the AI
  /// companion history — the do-not-touch set for cache sweeps. mediaPaths
  /// can also hold image-host URLs (https://...); those are remote, not
  /// local files, so they belong in neither the photo bucket nor "missing".
  Future<Set<String>> _referencedMedia(String docs) async {
    final refs = <String>{};
    final rows = await _db
        .customSelect('SELECT media_paths AS m FROM journal_entries')
        .get();
    for (final row in rows) {
      for (final path in row.read<String>('m').split('\n')) {
        if (path.startsWith('/')) refs.add(path);
      }
    }
    final (_, _, images) = await _readAiHistory(docs);
    refs.addAll(images.where((p) => p.startsWith('/')));
    return refs;
  }

  Future<(int, int)> _aiStats(String docs) async {
    final (sessions, messages, _) = await _readAiHistory(docs);
    return (sessions, messages);
  }

  /// Parses the companion history file (v2 `{v,sessions:[...]}` or the
  /// legacy v1 plain message list) into (sessions, messages, imagePaths).
  Future<(int, int, List<String>)> _readAiHistory(String docs) async {
    final f = File(p.join(docs, 'ai_companion_history.json'));
    try {
      if (!await f.exists()) return (0, 0, const <String>[]);
      final j = jsonDecode(await f.readAsString());
      final images = <String>[];
      var sessions = 0;
      var messages = 0;
      void takeMessages(List msgs) {
        messages += msgs.length;
        for (final m in msgs) {
          final img = (m as Map)['image'];
          if (img is String && img.isNotEmpty) images.add(img);
        }
      }

      if (j is Map && j['sessions'] is List) {
        for (final s in j['sessions'] as List) {
          sessions++;
          final msgs = (s as Map)['messages'];
          if (msgs is List) takeMessages(msgs);
        }
      } else if (j is List) {
        sessions = 1;
        takeMessages(j);
      }
      return (sessions, messages, images);
    } catch (_) {
      return (0, 0, const <String>[]);
    }
  }

  Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }

  Future<int> _dbFilesSize(String support) async {
    var total = 0;
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File(p.join(support, 'explore_journal.sqlite$suffix'));
      try {
        if (await f.exists()) total += await f.length();
      } catch (_) {}
    }
    return total;
  }
}

typedef _Paths = ({String support, String docs, String cache});

class _ScanResult {
  StorageSlice db = StorageSlice.zero;
  StorageSlice photos = StorageSlice.zero;
  int photosMissing = 0;
  StorageSlice tiles = StorageSlice.zero;
  StorageSlice ai = StorageSlice.zero;
  StorageSlice regions = StorageSlice.zero;
  StorageSlice temp = StorageSlice.zero;
  int tempSkippedRecent = 0;
  StorageSlice other = StorageSlice.zero;
}

/// Synchronous directory classification — runs inside [Isolate.run].
_ScanResult _scanDirs(_Paths paths, Set<String> refs) {
  final r = _ScanResult();

  StorageSlice add(StorageSlice s, int bytes) =>
      StorageSlice(s.bytes + bytes, s.count + 1);

  int sizeOf(FileSystemEntity e) {
    try {
      return (e as File).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  // Referenced photos: stat wherever they live (cache, docs, external).
  for (final path in refs) {
    final f = File(path);
    if (f.existsSync()) {
      r.photos = add(r.photos, f.lengthSync());
    } else {
      r.photosMissing++;
    }
  }

  // Support dir: database files vs everything else (pending track buffer...).
  final support = Directory(paths.support);
  if (support.existsSync()) {
    for (final e in support.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.startsWith('explore_journal.sqlite')) {
        r.db = add(r.db, sizeOf(e));
      } else {
        r.other = add(r.other, sizeOf(e));
      }
    }
  }

  // Documents dir: AI history and region cache are their own buckets.
  // `flutter_assets/` also lives here on Android (the engine puts debug
  // kernel blobs etc. under app_flutter) — that's program payload, not user
  // data, so it must not show up in the report at all.
  final docs = Directory(paths.docs);
  final regionsPrefix = p.join(paths.docs, 'admin_regions');
  final assetsPrefix = p.join(paths.docs, 'flutter_assets');
  if (docs.existsSync()) {
    for (final e in docs.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (p.isWithin(assetsPrefix, e.path)) continue;
      if (refs.contains(e.path)) continue; // counted as photos already
      if (p.basename(e.path) == 'ai_companion_history.json') {
        r.ai = add(r.ai, sizeOf(e));
      } else if (p.isWithin(regionsPrefix, e.path)) {
        r.regions = add(r.regions, sizeOf(e));
      } else {
        r.other = add(r.other, sizeOf(e));
      }
    }
  }

  // Cache dir: tile cache is its own bucket; referenced photos are excluded;
  // the rest is the cleanable temp bucket (same judgement as the sweep).
  final tilesDir = Directory(p.join(paths.cache, 'explore_map_tiles'));
  if (tilesDir.existsSync()) {
    for (final e in tilesDir.listSync(recursive: true, followLinks: false)) {
      if (e is File) r.tiles = add(r.tiles, sizeOf(e));
    }
  }
  final sweep = _sweepTemp(paths, refs, delete: false);
  r.temp = StorageSlice(sweep.bytes, sweep.count);
  r.tempSkippedRecent = sweep.skippedRecent;

  return r;
}

/// Shared temp-file judgement for both the panel numbers (`delete: false`)
/// and the actual cleanup (`delete: true`) — one code path, so what the user
/// sees is what gets freed. Skips the tile cache subtree, every referenced
/// photo, and files newer than [StorageInspector.tempGraceMs].
({int bytes, int count, int skippedRecent}) _sweepTemp(
  _Paths paths,
  Set<String> refs, {
  required bool delete,
}) {
  final cache = Directory(paths.cache);
  if (!cache.existsSync()) return (bytes: 0, count: 0, skippedRecent: 0);
  final tilesPrefix = p.join(paths.cache, 'explore_map_tiles');
  final cutoff = DateTime.now()
      .subtract(const Duration(milliseconds: StorageInspector.tempGraceMs));
  var bytes = 0;
  var count = 0;
  var skippedRecent = 0;

  for (final e in cache.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    if (e.path == tilesPrefix || p.isWithin(tilesPrefix, e.path)) continue;
    if (refs.contains(e.path)) continue;
    int size;
    DateTime mtime;
    try {
      final st = e.statSync();
      size = st.size;
      mtime = st.modified;
    } catch (_) {
      continue;
    }
    if (mtime.isAfter(cutoff)) {
      skippedRecent++;
      continue;
    }
    if (delete) {
      try {
        e.deleteSync();
      } catch (_) {
        continue;
      }
    }
    bytes += size;
    count++;
  }
  return (bytes: bytes, count: count, skippedRecent: skippedRecent);
}
