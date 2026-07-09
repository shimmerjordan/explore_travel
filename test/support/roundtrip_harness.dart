import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:explore_journal/services/sync/sync_storage.dart';

/// Shared local-only test harness for the backup / sync pipeline.
///
/// The whole point: exercise the REAL [BackupService.exportToFiles] →
/// (optionally wipe / mutate) → REAL [BackupService.importFromFiles] round-trip
/// with zero network and zero device. `exportToFiles` produces exactly the
/// path→bytes map a OneDrive/WebDAV/NAS upload would push; feeding that same
/// map back into `importFromFiles` is byte-for-byte what a pull applies. So a
/// round-trip test here catches merge/duplication/identity bugs that isolated
/// "hand-craft an archive and import it" tests never could (the layer-dup
/// regression is the cautionary tale).

/// In-memory [SyncStorage] — a Map plus call counters, standing in for any real
/// transport (OneDrive / WebDAV / GitHub / NAS). Honours the contract: a
/// missing read returns null, delete is idempotent. [getLog] records every rel
/// fetched in order so tests can assert WHICH shards a syncDown pulled.
class FakeSyncStorage implements SyncStorage {
  final Map<String, Uint8List> store = {};
  int puts = 0, gets = 0, deletes = 0;
  final List<String> getLog = [];

  @override
  Future<void> putSyncFile(String rel, List<int> bytes,
      {CancelToken? cancelToken}) async {
    puts++;
    store[rel] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> getSyncFile(String rel, {CancelToken? cancelToken}) async {
    gets++;
    getLog.add(rel);
    return store[rel];
  }

  @override
  Future<void> deleteSyncFile(String rel, {CancelToken? cancelToken}) async {
    deletes++;
    store.remove(rel);
  }
}

/// The SharedPreferences keys the backup pipeline reads/writes for the
/// prefs-backed modules. Kept here so a test can seed / wipe them by name.
const kPlannerKey = 'planner_history_v1';
const kSettingsKey = 'app_settings_v1';
const kSettingsUpdatedAtKey = 'settings_updated_at';
const kImgHostKey = 'img_host_uploads_v1';
const kGeocodeKey = 'geocode_cell_cache_v1';
const kLearnedRegionsKey = 'learned_regions_v1';

/// Layer ids created by [seedRealisticData], so tests can attach content or
/// assert remapping without re-querying by name.
class SeededLayers {
  final int defaultId; // the auto-created 默认图层 (id 1)
  final int hikeId;
  final int workId;
  const SeededLayers(this.defaultId, this.hikeId, this.workId);
}

/// Populate [db] (and SharedPreferences — the caller must have installed a mock
/// via `SharedPreferences.setMockInitialValues({})`) with a realistic,
/// cross-module dataset: three layers, journals/tracks/fog spread across them,
/// chat, favourites, and every prefs-backed module. Every row carries a stable
/// uuid and an updatedAt so LWW + dedup behaviour is observable.
///
/// Returns the layer ids. Counts are pinned by [expectedSeedCounts].
Future<SeededLayers> seedRealisticData(AppDb db) async {
  final t = DateTime(2026, 6, 1, 12);

  // ── layers (default id 1 already exists from onCreate) ──────────────────
  final hikeId = await db.insertLayer(TrackLayersCompanion.insert(
    uuid: const Value('layer-hike'),
    name: '徒步路线',
    colorValue: 0xFF11AA22,
    createdAt: DateTime(2026, 3, 1),
    updatedAt: Value(t),
  ));
  final workId = await db.insertLayer(TrackLayersCompanion.insert(
    uuid: const Value('layer-work'),
    name: '通勤',
    colorValue: 0xFF2277EE,
    createdAt: DateTime(2026, 3, 2),
    updatedAt: Value(t),
  ));

  // ── journal (3 entries across 2 layers) ─────────────────────────────────
  await db.insertJournal(JournalEntriesCompanion.insert(
    uuid: const Value('j-1'),
    time: t,
    lat: 30.65,
    lng: 104.06,
    title: '成都',
    richContent: const Value('宽窄巷子'),
    layerId: 1,
    updatedAt: Value(t),
  ));
  await db.insertJournal(JournalEntriesCompanion.insert(
    uuid: const Value('j-2'),
    time: t.add(const Duration(days: 1)),
    lat: 29.56,
    lng: 106.55,
    title: '重庆',
    richContent: const Value('洪崖洞'),
    layerId: hikeId,
    updatedAt: Value(t),
  ));
  await db.insertJournal(JournalEntriesCompanion.insert(
    uuid: const Value('j-3'),
    time: t.add(const Duration(days: 2)),
    lat: 30.57,
    lng: 104.07,
    title: '上班路上',
    richContent: const Value('堵车'),
    layerId: workId,
    updatedAt: Value(t),
  ));

  // ── track points (5, across layers) ─────────────────────────────────────
  await db.insertPoints([
    for (var i = 0; i < 3; i++)
      TrackPointsCompanion.insert(
        uuid: Value('tp-h$i'),
        lat: 30.6 + i * 0.001,
        lng: 104.0 + i * 0.001,
        time: t.add(Duration(minutes: i)),
        width: const Value(8),
        layerId: hikeId,
      ),
    for (var i = 0; i < 2; i++)
      TrackPointsCompanion.insert(
        uuid: Value('tp-w$i'),
        lat: 30.57 + i * 0.001,
        lng: 104.07 + i * 0.001,
        time: t.add(Duration(minutes: 10 + i)),
        layerId: workId,
      ),
  ]);

  // ── fog (2 explored blocks on 2 layers) ─────────────────────────────────
  // Exploration is stored at BLOCK granularity (zoom=100) via FogEngine, which
  // is exactly what the native-FoW export reads. Seeding raw zoom≤14 baked
  // tiles would export nothing — the round-trip must exercise the real path.
  final bmp1 = Uint8List(FogEngine.bitmapBytes);
  FogEngine.setBit(bmp1, 3, 4);
  final bmp2 = Uint8List(FogEngine.bitmapBytes);
  FogEngine.setBit(bmp2, 10, 11);
  await FogEngine(db).importBlocks(layerId: hikeId, blocks: [
    (tileX: 100, tileY: 200, blockX: 3, blockY: 4, bitmap: bmp1),
  ]);
  await FogEngine(db).importBlocks(layerId: workId, blocks: [
    (tileX: 101, tileY: 201, blockX: 5, blockY: 6, bitmap: bmp2),
  ]);

  // ── chat (2 messages, one peer) ─────────────────────────────────────────
  await db.into(db.chatMessages).insert(ChatMessagesCompanion.insert(
        uuid: const Value('c-1'),
        peerId: 'peer-1',
        author: '我',
        content: '出发了',
        time: t,
        outbound: true,
      ));
  await db.into(db.chatMessages).insert(ChatMessagesCompanion.insert(
        uuid: const Value('c-2'),
        peerId: 'peer-1',
        author: '同伴',
        content: '收到',
        time: t.add(const Duration(minutes: 1)),
        outbound: false,
      ));

  // ── song favourites (2) ─────────────────────────────────────────────────
  await db.into(db.songFavorites).insert(SongFavoritesCompanion.insert(
        uuid: const Value('s-1'),
        songId: 'song-1',
        title: '成都',
        artist: '赵雷',
        source: 'gd',
        addedAt: t,
        lat: const Value(30.65),
        lng: const Value(104.06),
      ));
  await db.into(db.songFavorites).insert(SongFavoritesCompanion.insert(
        uuid: const Value('s-2'),
        songId: 'song-2',
        title: '成都府',
        artist: 'X',
        source: 'gd',
        addedAt: t,
      ));

  // ── prefs-backed modules ────────────────────────────────────────────────
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(kPlannerKey,
      jsonEncode([
        {'id': 'plan-1', 'title': '川西行', 'days': 5},
        {'id': 'plan-2', 'title': '滇西行', 'days': 7},
      ]));
  await prefs.setString(kSettingsKey,
      jsonEncode({
        'mapStyle': 'dark',
        'trailWidth': 8.0,
        // A real vault-secret key so the export scrub is actually exercised.
        'oneDriveRefreshToken': 'SECRET-TOKEN',
      }));
  await prefs.setString(kSettingsUpdatedAtKey, t.toIso8601String());
  await prefs.setString(kImgHostKey,
      jsonEncode({'a.jpg': 'https://img/a', 'b.jpg': 'https://img/b'}));
  await prefs.setString(kGeocodeKey, jsonEncode({'cell-1': '成都市', 'cell-2': '重庆市'}));
  await prefs.setString(kLearnedRegionsKey,
      jsonEncode([{'name': '四川'}, {'name': '重庆'}]));

  return SeededLayers(1, hikeId, workId);
}

/// The row counts [seedRealisticData] produces, per DB table. A round-trip into
/// a fresh device must reproduce exactly these.
const expectedSeedCounts = <String, int>{
  'track_layers': 3,
  'journal_entries': 3,
  'track_points': 5,
  'fog_tiles': 2,
  'chat_messages': 2,
  'song_favorites': 2,
};

/// A comparable snapshot of the DB-backed modules: per-table row count plus the
/// set of stable uuids (identity). Duplication shows up as an inflated count
/// with an unchanged uuid set; loss shows up as a shrunken set.
class DbSnapshot {
  final Map<String, int> counts;
  final Map<String, Set<String>> uuids;
  const DbSnapshot(this.counts, this.uuids);

  @override
  String toString() => 'DbSnapshot(counts: $counts)';
}

Future<DbSnapshot> snapshotDb(AppDb db) async {
  Future<int> count(String tbl) async => (await db
          .customSelect('SELECT COUNT(*) AS c FROM $tbl')
          .getSingle())
      .read<int>('c');
  Future<Set<String>> uuidsOf(String tbl) async => (await db
          .customSelect('SELECT uuid FROM $tbl')
          .get())
      .map((r) => r.read<String>('uuid'))
      .toSet();

  const dbTables = [
    'track_layers',
    'journal_entries',
    'track_points',
    'fog_tiles',
    'chat_messages',
    'song_favorites',
  ];
  const uuidTables = [
    'track_layers',
    'journal_entries',
    'track_points',
    'chat_messages',
    'song_favorites',
  ];
  return DbSnapshot(
    {for (final t in dbTables) t: await count(t)},
    {for (final t in uuidTables) t: await uuidsOf(t)},
  );
}
