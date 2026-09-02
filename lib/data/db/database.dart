import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'connection/connection.dart';

part 'database.g.dart';

/// Single source of truth for fresh UUIDs across the insert helpers.
String _newUuid() => const Uuid().v4();

/// Device-independent uuid for the auto-created "默认图层". Fixed (not random)
/// so every device's default layer reconciles into ONE on sync instead of
/// proliferating a copy per device.
const kDefaultLayerUuid = 'default-layer';

class TrackPoints extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// Stable cross-device identity. Used by backup import to skip rows we
  /// already have. Auto-populated on insert when callers don't provide one.
  TextColumn get uuid => text().withDefault(const Constant(''))();
  RealColumn get lat => real()();
  RealColumn get lng => real()();
  DateTimeColumn get time => dateTime()();
  RealColumn get accuracy => real().nullable()();
  RealColumn get altitude => real().nullable()();
  RealColumn get speed => real().nullable()();
  /// Visible trail/point size (full corridor width, in metres) captured at
  /// record time. Stored per-point so changing the size setting only
  /// affects *new* points — historical trails keep the width they were
  /// recorded with. Null on rows predating this column → rendered at the
  /// renderer's default width.
  RealColumn get width => real().nullable()();
  IntColumn get layerId => integer()();
  /// Bit flags (see `PointFlags`). bit0 = GPS anomaly: the fix is kept for
  /// the record but heat map / visits / stats skip it. Marked, never
  /// deleted — a wrong "anomaly" call is recoverable, a delete isn't.
  IntColumn get flags => integer().withDefault(const Constant(0))();
}

class TrackLayers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withDefault(const Constant(''))();
  TextColumn get name => text()();
  IntColumn get colorValue => integer()();
  BoolColumn get visible => boolean().withDefault(const Constant(true))();
  TextColumn get tag => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  /// Per-layer path/fog style. All nullable — null means "inherit the
  /// global default" (settings.fogColor / fogOpacity / trailWidth), so
  /// existing layers render exactly as before until the user customises
  /// them. [pathColor] is the layer's fog-veil ARGB; [pathOpacity] its
  /// veil opacity (0..1); [pathWidth] the corridor width (metres) applied
  /// to NEWLY recorded points on this layer.
  IntColumn get pathColor => integer().nullable()();
  RealColumn get pathOpacity => real().nullable()();
  RealColumn get pathWidth => real().nullable()();
  /// Last local edit (rename, style, visibility). Sync merges rows by
  /// last-write-wins on this — null (pre-v8 rows, or never edited) loses to
  /// any non-null timestamp.
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

/// Tile-based fog storage. Each row is one tile at a given zoom; the bitmap is
/// a 64x64 grid (512 bytes) of explored sub-cells.
class FogTiles extends Table {
  IntColumn get tileX => integer()();
  IntColumn get tileY => integer()();
  IntColumn get zoom => integer()();
  IntColumn get layerId => integer()();
  BlobColumn get bitmap => blob()();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {tileX, tileY, zoom, layerId};
}

class JournalEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withDefault(const Constant(''))();
  DateTimeColumn get time => dateTime()();
  RealColumn get lat => real()();
  RealColumn get lng => real()();
  TextColumn get title => text()();
  TextColumn get richContent => text().withDefault(const Constant(''))();
  TextColumn get mediaPaths => text().withDefault(const Constant(''))(); // \n separated
  IntColumn get layerId => integer()();
  /// 'public' (默认) | 'private' — drives whether the upload queue routes
  /// images to the public or private GitHub repo.
  TextColumn get level => text().withDefault(const Constant('public'))();
  /// Peer id of the traveler this entry belongs to, or null for "self".
  /// Free-form because peers in this app are P2P UUIDs, not joined records.
  TextColumn get ownerPeerId => text().nullable()();
  /// Last local edit. Sync merges entries by last-write-wins on this — null
  /// (pre-v8 rows, or never edited) loses to any non-null timestamp.
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

class ChatMessages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withDefault(const Constant(''))();
  TextColumn get peerId => text()();
  TextColumn get author => text()();
  TextColumn get content => text()();
  DateTimeColumn get time => dateTime()();
  BoolColumn get outbound => boolean()();
}

class SongFavorites extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withDefault(const Constant(''))();
  TextColumn get songId => text()();
  TextColumn get title => text()();
  TextColumn get artist => text()();
  TextColumn get coverUrl => text().nullable()();
  TextColumn get source => text()();
  DateTimeColumn get addedAt => dateTime()();
  RealColumn get lat => real().nullable()();
  RealColumn get lng => real().nullable()();
}

/// Deletion markers for user-content rows. A local delete alone gets
/// resurrected by the next sync merge — the cloud copy still carries the row
/// and UUID-dedup treats it as "new" — so every delete records (table, uuid)
/// here. The backup/sync pipeline always exports these; import first deletes
/// matching local rows, then skips those uuids while merging ("增量减").
/// Garbage-collected at export time after ~180 days.
class Tombstones extends Table {
  /// Logical (SQL) table name, e.g. 'track_points', 'journal_entries'.
  TextColumn get tbl => text()();
  TextColumn get uuid => text()();
  DateTimeColumn get deletedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {tbl, uuid};
}

/// Fog erase markers — the fog counterpart of [Tombstones]. Each row records
/// WHICH pixels of one block the eraser swept ([mask], same 64×64-bit layout
/// as [FogTiles.bitmap], repeated erases OR together) and WHEN ([erasedAt]).
/// Sync merges fog by bitwise union, which alone would resurrect erased
/// pixels from the other side's copy; these masks let the merge clear a
/// pixel from a copy that predates the erase, while bits re-explored AFTER
/// the erase (block updatedAt > erasedAt) survive. GC'd after ~180 days.
class FogErases extends Table {
  IntColumn get tileX => integer()();
  IntColumn get tileY => integer()();
  IntColumn get zoom => integer()();
  IntColumn get layerId => integer()();
  BlobColumn get mask => blob()();
  DateTimeColumn get erasedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {tileX, tileY, zoom, layerId};
}

/// Persisted location pings received from group peers. Lets the playback
/// screen show peers' trails during the same time window, even after the
/// group session ended.
class PeerLocations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get peerId => text()();
  TextColumn get peerName => text().withDefault(const Constant(''))();
  RealColumn get lat => real()();
  RealColumn get lng => real()();
  DateTimeColumn get time => dateTime()();
}

/// A named spot the user keeps coming back to — the target of [Visits].
/// Machine-minted (source 0) when a stay is detected somewhere no place
/// exists yet; the user can rename it (→ source 1, name locked against
/// re-geocoding) or fold other places into it.
class Places extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withDefault(const Constant(''))();
  TextColumn get name => text()();
  RealColumn get lat => real()();
  RealColumn get lng => real()();
  /// Match radius in metres for attributing new stays (default 100).
  RealColumn get radius => real().withDefault(const Constant(100))();
  /// 0 = auto (detected), 1 = manual (user named / created).
  IntColumn get source => integer().withDefault(const Constant(0))();
  TextColumn get country => text().nullable()();
  TextColumn get province => text().nullable()();
  TextColumn get city => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

/// One stay at a [Places] row: "you were HERE from A to B". Detected from
/// track points (Dawarich's stay-detection pipeline ported to Dart) or
/// created by hand. `status` 0 suggested / 1 confirmed / 2 declined;
/// `deletedAt` is a soft-delete tombstone so the detector never re-suggests
/// a stay the user threw away. Machine rows (status 0, no tombstone) are
/// rebuilt wholesale on every detection run; user rows are anchors.
class Visits extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withDefault(const Constant(''))();
  IntColumn get placeId => integer().nullable()();
  IntColumn get layerId => integer()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime()();
  RealColumn get lat => real()();
  RealColumn get lng => real()();
  RealColumn get radius => real()();
  IntColumn get pointCount => integer()();
  /// Seconds of silence bridged into this stay (same place, gap > 1 h).
  IntColumn get bridgedSec => integer().withDefault(const Constant(0))();
  IntColumn get status => integer().withDefault(const Constant(0))();
  IntColumn get confidence => integer().withDefault(const Constant(0))();
  TextColumn get confidenceJson => text().withDefault(const Constant(''))();
  IntColumn get detectionVersion => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

/// A user-made bundle of replay sessions ("把这几段合成一次旅行"). Purely
/// referential: [segmentsJson] is a list of `{layer: layerUuid, startMs,
/// endMs}` windows — the underlying track points are never moved or retimed,
/// so layers, fog and sync stay untouched and the bundle survives layer-id
/// remapping on other devices (layers are referenced by uuid).
class MergedTrips extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withDefault(const Constant(''))();
  TextColumn get name => text()();
  TextColumn get segmentsJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

@DriftDatabase(tables: [
  TrackPoints,
  TrackLayers,
  FogTiles,
  JournalEntries,
  ChatMessages,
  SongFavorites,
  PeerLocations,
  Tombstones,
  FogErases,
  Places,
  Visits,
  MergedTrips,
])
class AppDb extends _$AppDb {
  AppDb() : super(openConnection());

  /// Test-only: build against an injected executor (e.g. `NativeDatabase.memory()`).
  AppDb.forTesting(super.e);

  @override
  int get schemaVersion => 11;

  /// Secondary indexes, created idempotently on every open (so a DB that
  /// predates them gets them without a schema bump, and a fresh one gets
  /// them right after createAll). Every reader of track_points filters by
  /// layer and/or time; without these each map open / replay / stats pass
  /// was a full scan of the whole history.
  static const _indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_track_points_layer_time '
        'ON track_points(layer_id, time)',
    'CREATE INDEX IF NOT EXISTS idx_track_points_time ON track_points(time)',
    'CREATE INDEX IF NOT EXISTS idx_visits_started ON visits(started_at)',
    'CREATE INDEX IF NOT EXISTS idx_visits_place ON visits(place_id)',
  ];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          for (final s in _indexStatements) {
            await customStatement(s);
          }
        },
        onCreate: (m) async {
          await m.createAll();
          await into(trackLayers).insert(TrackLayersCompanion.insert(
            name: '默认图层',
            colorValue: 0xFF00BCD4,
            createdAt: DateTime.now(),
            // Stable, device-INDEPENDENT uuid. Without this every device's
            // default layer got a random uuid → they never matched on sync →
            // the default layer proliferated (one per device) and content
            // scattered across the duplicates. A fixed uuid makes all
            // devices' default layers reconcile into one.
            uuid: const Value(kDefaultLayerUuid),
          ));
          // FTS5 virtual table for journal full text search
          await customStatement('''
            CREATE VIRTUAL TABLE IF NOT EXISTS journal_fts USING fts5(
              title, content, content_rowid='id'
            );
          ''');
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // v2: per-journal privacy level + owner peer id.
            await m.addColumn(journalEntries, journalEntries.level);
            await m.addColumn(journalEntries, journalEntries.ownerPeerId);
          }
          if (from < 4) {
            // v4: per-peer location history for playback rewinds.
            await m.createTable(peerLocations);
          }
          if (from < 5) {
            // v5: per-point trail width so the size control only affects
            // newly recorded points. Existing rows stay null and render at
            // the renderer's default width.
            await m.addColumn(trackPoints, trackPoints.width);
          }
          if (from < 6) {
            // v6: per-layer path/fog style. Null = inherit global default,
            // so existing layers look unchanged until customised.
            await m.addColumn(trackLayers, trackLayers.pathColor);
            await m.addColumn(trackLayers, trackLayers.pathOpacity);
            await m.addColumn(trackLayers, trackLayers.pathWidth);
          }
          if (from < 7) {
            // v7: deletion tombstones so deletes propagate through sync.
            await m.createTable(tombstones);
          }
          if (from < 8) {
            // v8: last-write-wins merge metadata. updatedAt lets sync apply
            // EDITS to existing rows (imports used to skip any known uuid, so
            // edits never propagated); fog_erases records erased pixels so
            // the fog union-merge doesn't resurrect them.
            await m.addColumn(journalEntries, journalEntries.updatedAt);
            await m.addColumn(trackLayers, trackLayers.updatedAt);
            await m.createTable(fogErases);
          }
          if (from < 3) {
            // v3: stable UUID on every user-content table so backup
            // import can dedup across devices instead of inserting clones
            // every time. Existing rows get a fresh UUID right away —
            // this happens once per existing row at migration time.
            await m.addColumn(trackPoints, trackPoints.uuid);
            await m.addColumn(trackLayers, trackLayers.uuid);
            await m.addColumn(journalEntries, journalEntries.uuid);
            await m.addColumn(chatMessages, chatMessages.uuid);
            await m.addColumn(songFavorites, songFavorites.uuid);
            // SQLite has lower(hex(randomblob(16))) — formats as a 32-char
            // hex string. Good enough as an identity (collision odds 1/2^128).
            const expr = "lower(hex(randomblob(16)))";
            await customStatement(
                "UPDATE track_points  SET uuid = $expr WHERE uuid = ''");
            await customStatement(
                "UPDATE track_layers  SET uuid = $expr WHERE uuid = ''");
            await customStatement(
                "UPDATE journal_entries SET uuid = $expr WHERE uuid = ''");
            await customStatement(
                "UPDATE chat_messages SET uuid = $expr WHERE uuid = ''");
            await customStatement(
                "UPDATE song_favorites SET uuid = $expr WHERE uuid = ''");
          }
          if (from < 9) {
            // v9: converge the per-device default layer onto a stable uuid so
            // it stops proliferating across devices. Re-stamp the ORIGINAL
            // default (lowest id) — but only if no layer already holds the
            // stable uuid, to avoid a duplicate-uuid collision.
            final has = await customSelect(
                "SELECT 1 FROM track_layers WHERE uuid = ? LIMIT 1",
                variables: [Variable.withString(kDefaultLayerUuid)]).get();
            if (has.isEmpty) {
              await customStatement(
                "UPDATE track_layers SET uuid = ? "
                "WHERE id = (SELECT MIN(id) FROM track_layers)",
                [kDefaultLayerUuid],
              );
            }
          }
          if (from < 10) {
            // v10: GPS anomaly flag on points + visits/places (stay detection).
            await m.addColumn(trackPoints, trackPoints.flags);
            await m.createTable(places);
            await m.createTable(visits);
          }
          if (from < 11) {
            // v11: user-named bundles of replay sessions.
            await m.createTable(mergedTrips);
          }
        },
      );

  Stream<List<TrackLayer>> watchLayers() => select(trackLayers).watch();
  Future<List<TrackLayer>> allLayers() => select(trackLayers).get();

  /// Self-heal the layer-driven render pipeline. The map, trail and journal
  /// layers all iterate over `track_layers`, so content (points / fog /
  /// journals) that references a layerId with NO matching layer row renders
  /// as **nothing** — a DB whose layers got wiped (an over-eager tombstone,
  /// a bad merge, a partial restore) shows a blank map despite holding all
  /// its data. This recreates a visible layer row for every orphaned id
  /// (reusing that id so existing content re-homes with no row rewrites),
  /// and seeds a default layer if there are none at all.
  ///
  /// The uuid is DETERMINISTIC per id (`recovered-layer-<id>`, or the stable
  /// default uuid for id 1) so every device recovering the same orphan
  /// converges on one uuid instead of spawning a copy per device.
  ///
  /// Recreating a layer is an "undelete" — so it also CLEARS any tombstone
  /// for that layer's uuid. Without this, a tombstone for a recovered uuid
  /// deleted the layer on the next sync, recovery recreated the same
  /// (still-tombstoned) uuid, and the two fought forever — the "recreated N
  /// orphaned layer(s)" churn seen on every sync.
  /// Returns how many layers it created.
  Future<int> ensureLayersForContent() async {
    final referenced = <int>{};
    for (final t in ['track_points', 'fog_tiles', 'journal_entries']) {
      final rows =
          await customSelect('SELECT DISTINCT layer_id AS lid FROM $t').get();
      referenced.addAll(rows.map((r) => r.read<int>('lid')));
    }
    final existing = (await allLayers()).map((l) => l.id).toSet();
    final orphans = referenced.difference(existing).toList()..sort();

    String uuidForId(int id) => id == 1 ? kDefaultLayerUuid : 'recovered-layer-$id';

    if (orphans.isEmpty) {
      if (existing.isEmpty) {
        // Content-free but layer-less (e.g. layers wiped, nothing recorded
        // yet): reseed the default so the app is never in a zero-layer state.
        await _clearLayerTombstone(kDefaultLayerUuid);
        await into(trackLayers).insert(TrackLayersCompanion.insert(
          name: '默认图层',
          colorValue: 0xFF00BCD4,
          createdAt: DateTime.now(),
          uuid: const Value(kDefaultLayerUuid),
          // Fresh timestamp so this restore wins LWW against an older
          // delete propagated from the cloud.
          updatedAt: Value(DateTime.now()),
        ));
        return 1;
      }
      return 0;
    }
    for (final id in orphans) {
      final uuid = uuidForId(id);
      await _clearLayerTombstone(uuid);
      await into(trackLayers).insert(
        TrackLayersCompanion.insert(
          name: id == 1 ? '默认图层' : '图层 $id',
          colorValue: 0xFF00BCD4,
          createdAt: DateTime.now(),
          visible: const Value(true),
          uuid: Value(uuid),
          updatedAt: Value(DateTime.now()),
        ).copyWith(id: Value(id)),
        mode: InsertMode.insertOrIgnore,
      );
    }
    return orphans.length;
  }

  /// Drop a stale track_layers tombstone (a layer being restored/recovered).
  Future<void> _clearLayerTombstone(String uuid) => (delete(tombstones)
        ..where((t) => t.tbl.equals('track_layers') & t.uuid.equals(uuid)))
      .go();

  /// Wipe every layer and re-home ALL content onto ONE fresh default layer.
  /// This is what "清除本机图层" means to the user — a clean slate, exactly one
  /// layer left — as opposed to [ensureLayersForContent], which deliberately
  /// recreates one layer per distinct orphaned id (grouping-preserving
  /// corruption recovery). Without this, clearing layers immediately springs
  /// them all back because points/fog still reference their ids.
  /// Returns the new default layer's local id.
  Future<int> resetContentToDefaultLayer() async {
    return transaction(() async {
      await delete(trackLayers).go();
      await _clearLayerTombstone(kDefaultLayerUuid);
      final id = await into(trackLayers).insert(TrackLayersCompanion.insert(
        name: '默认图层',
        colorValue: 0xFF00BCD4,
        createdAt: DateTime.now(),
        uuid: const Value(kDefaultLayerUuid),
        updatedAt: Value(DateTime.now()),
      ));
      for (final t in ['track_points', 'fog_tiles', 'journal_entries', 'fog_erases']) {
        await customUpdate('UPDATE $t SET layer_id = ?',
            variables: [Variable.withInt(id)], updateKind: UpdateKind.update);
      }
      return id;
    });
  }

  /// Stamp a stable uuid on any content row that still has an empty one.
  /// Sync identity (dedup + LWW) is keyed on uuid — a row with `uuid=''`
  /// can't be matched across devices, so it silently fails to update AND can
  /// duplicate on re-import ("备份时就出问题"). Migration v3 backfilled once,
  /// but this is a cheap idempotent guard against any row that slipped
  /// through a code path that didn't stamp one. Returns the rows fixed.
  Future<int> backfillMissingUuids() async {
    const expr = "lower(hex(randomblob(16)))";
    var fixed = 0;
    for (final t in [
      'journal_entries',
      'track_layers',
      'track_points',
      'chat_messages',
      'song_favorites',
    ]) {
      fixed += await customUpdate(
        "UPDATE $t SET uuid = $expr WHERE uuid IS NULL OR uuid = ''",
        updateKind: UpdateKind.update,
      );
    }
    return fixed;
  }
  Future<int> insertLayer(TrackLayersCompanion data) =>
      into(trackLayers).insert(_withUuid(data));

  /// Stamp a fresh UUID on a layer companion when the caller didn't
  /// supply one. Keeps backup-import paths (which DO supply uuid) honest
  /// while leaving normal callers terse.
  TrackLayersCompanion _withUuid(TrackLayersCompanion d) =>
      (d.uuid.present && d.uuid.value.isNotEmpty)
          ? d
          : d.copyWith(uuid: Value(_newUuid()));
  /// Every layer edit stamps [TrackLayers.updatedAt] so the edit wins
  /// last-write-wins sync merges against older copies on other devices.
  Future<bool> updateLayer(TrackLayer l) => update(trackLayers)
      .replace(l.copyWith(updatedAt: Value(DateTime.now())));

  /// Force a single layer's visibility. Used by FOW import so freshly-imported
  /// fog can never land on a layer whose eye is off (map only renders visible
  /// layers) and read as "导入不生效/没了".
  Future<void> setLayerVisible(int id, bool visible) =>
      (update(trackLayers)..where((l) => l.id.equals(id))).write(
          TrackLayersCompanion(
              visible: Value(visible), updatedAt: Value(DateTime.now())));
  Future<int> deleteLayer(int id) async {
    final row = await (select(trackLayers)..where((l) => l.id.equals(id)))
        .getSingleOrNull();
    if (row != null) await recordTombstones('track_layers', [row.uuid]);
    return (delete(trackLayers)..where((l) => l.id.equals(id))).go();
  }

  Future<int> insertPoint(TrackPointsCompanion p) =>
      into(trackPoints).insert((p.uuid.present && p.uuid.value.isNotEmpty)
          ? p
          : p.copyWith(uuid: Value(_newUuid())));

  /// Bulk-insert points in one batch (single transaction). Used by track-file
  /// import where a GPX/KML can carry thousands of points — per-row inserts
  /// would be far slower. Stamps a fresh UUID on any row lacking one.
  Future<void> insertPoints(List<TrackPointsCompanion> pts) =>
      batch((b) => b.insertAll(
            trackPoints,
            pts
                .map((p) => (p.uuid.present && p.uuid.value.isNotEmpty)
                    ? p
                    : p.copyWith(uuid: Value(_newUuid())))
                .toList(),
          ));
  Future<List<TrackPoint>> pointsBetween(DateTime from, DateTime to) =>
      (select(trackPoints)..where((t) => t.time.isBetweenValues(from, to))).get();
  Future<List<TrackPoint>> pointsForLayer(int layerId) =>
      (select(trackPoints)..where((t) => t.layerId.equals(layerId))).get();

  /// Clean (non-anomaly) points of [layerIds], optionally windowed by time,
  /// ordered by (layer, time) — the shape every analytic reader wants (heat
  /// map, stay detection, stats). Hits idx_track_points_layer_time.
  Future<List<TrackPoint>> cleanPoints(
    List<int> layerIds, {
    DateTime? from,
    DateTime? to,
  }) {
    final q = select(trackPoints)
      ..where((t) {
        var e = t.layerId.isIn(layerIds) & t.flags.equals(0);
        if (from != null) e = e & t.time.isBiggerOrEqualValue(from);
        if (to != null) e = e & t.time.isSmallerOrEqualValue(to);
        return e;
      })
      ..orderBy([
        (t) => OrderingTerm.asc(t.layerId),
        (t) => OrderingTerm.asc(t.time),
      ]);
    return q.get();
  }

  /// Dedup keys (`timeMs|lat6|lng6`) of the points already on [layerId]
  /// inside [from, to]. Track-file import uses this so re-importing the
  /// same GPX twice (or a GPX that overlaps a recorded session) doesn't
  /// double every point — Dawarich's `(user, timestamp, lonlat)` unique
  /// index, done at ingest time because our sync identity is the uuid.
  Future<Set<String>> pointDedupKeys(
      int layerId, DateTime from, DateTime to) async {
    final rows = await (select(trackPoints)
          ..where((t) =>
              t.layerId.equals(layerId) & t.time.isBetweenValues(from, to)))
        .get();
    return {for (final r in rows) pointDedupKey(r.time, r.lat, r.lng)};
  }

  static String pointDedupKey(DateTime t, double lat, double lng) =>
      '${t.millisecondsSinceEpoch}|${(lat * 1e6).round()}|${(lng * 1e6).round()}';

  /// Earliest / latest point time across all layers (null when empty).
  Future<(DateTime, DateTime)?> pointTimeSpan() async {
    final q = selectOnly(trackPoints)
      ..addColumns([trackPoints.time.min(), trackPoints.time.max()]);
    final row = await q.getSingleOrNull();
    final lo = row?.read(trackPoints.time.min());
    final hi = row?.read(trackPoints.time.max());
    if (lo == null || hi == null) return null;
    return (lo, hi);
  }

  /// Newest sample time stored for a layer, or null if it has no points.
  /// Used to dedup the background sample-buffer drain — only file samples
  /// newer than this were captured while the main isolate wasn't writing.
  Future<DateTime?> lastPointTime(int layerId) async {
    final q = selectOnly(trackPoints)
      ..addColumns([trackPoints.time.max()])
      ..where(trackPoints.layerId.equals(layerId));
    final row = await q.getSingleOrNull();
    return row?.read(trackPoints.time.max());
  }
  Stream<List<TrackPoint>> watchPointsForLayer(int layerId) =>
      (select(trackPoints)..where((t) => t.layerId.equals(layerId))).watch();

  Future<FogTile?> getFogTile(int x, int y, int z, int layer) async {
    return (select(fogTiles)
          ..where((t) =>
              t.tileX.equals(x) &
              t.tileY.equals(y) &
              t.zoom.equals(z) &
              t.layerId.equals(layer)))
        .getSingleOrNull();
  }

  Future<void> upsertFogTile(FogTilesCompanion data) =>
      into(fogTiles).insertOnConflictUpdate(data);

  /// Bulk-upsert fog tiles in a single transaction. The composite primary key
  /// (tileX, tileY, zoom, layerId) makes `insertOrReplace` an upsert, so each
  /// row must already carry the FINAL merged bitmap. Used by FOW import, where
  /// a Fog of World "Sync" folder can be ~45k blocks — per-row upserts would be
  /// tens of thousands of separate transactions (minutes on a phone).
  Future<void> batchUpsertFogTiles(List<FogTilesCompanion> rows) =>
      batch((b) =>
          b.insertAll(fogTiles, rows, mode: InsertMode.insertOrReplace));

  Future<List<FogTile>> fogTilesForLayers(List<int> layerIds, int zoom) =>
      (select(fogTiles)
            ..where(
                (t) => t.layerId.isIn(layerIds) & t.zoom.equals(zoom)))
          .get();

  /// Fog tiles for [layerIds] at [zoom] whose block-grid coords fall within an
  /// inclusive (minX..maxX, minY..maxY) window. The map uses this to render
  /// only the on-screen fog bitmap — imported Fog of World data can be ~45k
  /// tiles, so drawing them all every frame is hopeless.
  Future<List<FogTile>> fogTilesInRange(
    List<int> layerIds,
    int zoom,
    int minX,
    int maxX,
    int minY,
    int maxY,
  ) =>
      (select(fogTiles)
            ..where((t) =>
                t.layerId.isIn(layerIds) &
                t.zoom.equals(zoom) &
                t.tileX.isBetweenValues(minX, maxX) &
                t.tileY.isBetweenValues(minY, maxY)))
          .get();

  Future<int> insertJournal(JournalEntriesCompanion j) async {
    final stamped = (j.uuid.present && j.uuid.value.isNotEmpty)
        ? j
        : j.copyWith(uuid: Value(_newUuid()));
    final id = await into(journalEntries).insert(stamped);
    await customStatement(
      'INSERT INTO journal_fts(rowid, title, content) VALUES (?, ?, ?)',
      [id, stamped.title.value, stamped.richContent.value],
    );
    return id;
  }

  Future<List<JournalEntry>> searchJournal(String query) async {
    final rows = await customSelect(
      'SELECT j.* FROM journal_entries j '
      'JOIN journal_fts f ON f.rowid = j.id '
      'WHERE journal_fts MATCH ? ORDER BY j.time DESC LIMIT 100',
      variables: [Variable.withString(query)],
      readsFrom: {journalEntries},
    ).get();
    return rows.map((r) => journalEntries.map(r.data)).toList();
  }

  Future<List<JournalEntry>> recentJournal({int limit = 50}) =>
      (select(journalEntries)
            ..orderBy([(j) => OrderingTerm.desc(j.time)])
            ..limit(limit))
          .get();

  Future<void> mergeLayers(List<int> sourceLayerIds, int destLayerId) async {
    await (update(trackPoints)..where((p) => p.layerId.isIn(sourceLayerIds)))
        .write(TrackPointsCompanion(layerId: Value(destLayerId)));
    await (update(journalEntries)
          ..where((j) => j.layerId.isIn(sourceLayerIds)))
        .write(JournalEntriesCompanion(
      layerId: Value(destLayerId),
      // The move is an edit — stamp it so it propagates over older copies.
      updatedAt: Value(DateTime.now()),
    ));
    // Content rows moved (not deleted) — only the layer rows get tombstones.
    final gone = await (select(trackLayers)
          ..where((l) => l.id.isIn(sourceLayerIds)))
        .get();
    await recordTombstones('track_layers', gone.map((l) => l.uuid));
    await (delete(trackLayers)..where((l) => l.id.isIn(sourceLayerIds))).go();
  }

  /// Erase points in a circular region (path editing - erase).
  /// Insert a single manually-painted track point (the map "add" tool).
  /// Carries its own [width] so it renders at the brush size, independent
  /// of whatever the recording size setting is later changed to.
  Future<int> insertManualPoint({
    required double lat,
    required double lng,
    required int layerId,
    required double width,
  }) =>
      insertPoint(TrackPointsCompanion.insert(
        lat: lat,
        lng: lng,
        time: DateTime.now(),
        layerId: layerId,
        width: Value(width),
      ));

  Future<int> erasePointsAround(double lat, double lng, double radiusMeters) async {
    final dLat = radiusMeters / 111320.0;
    final dLng = radiusMeters / (111320.0 * (lat.abs() < 89 ? 1 : 0.01));
    Expression<bool> inBox($TrackPointsTable p) =>
        p.lat.isBetweenValues(lat - dLat, lat + dLat) &
        p.lng.isBetweenValues(lng - dLng, lng + dLng);
    // Tombstone BEFORE deleting so an erase survives the next sync merge
    // instead of being resurrected from the cloud copy.
    final doomed = await (select(trackPoints)..where(inBox)).get();
    await recordTombstones(
        'track_points', doomed.map((p) => p.uuid).where((u) => u.isNotEmpty));
    return (delete(trackPoints)..where(inBox)).go();
  }

  /// Delete one journal entry (row + FTS index) and tombstone its uuid.
  Future<void> deleteJournalById(int id) async {
    final row = await (select(journalEntries)..where((j) => j.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    if (row.uuid.isNotEmpty) {
      await recordTombstones('journal_entries', [row.uuid]);
    }
    await (delete(journalEntries)..where((j) => j.id.equals(id))).go();
    await customStatement('DELETE FROM journal_fts WHERE rowid=?', [id]);
  }

  /// Delete one song favorite and tombstone its uuid.
  Future<void> deleteSongFavoriteById(int id) async {
    final row = await (select(songFavorites)..where((f) => f.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    if (row.uuid.isNotEmpty) {
      await recordTombstones('song_favorites', [row.uuid]);
    }
    await (delete(songFavorites)..where((f) => f.id.equals(id))).go();
  }

  // ─── Places & visits（到访地点）──────────────────────────────────────────

  Future<List<Place>> allPlaces() => select(places).get();

  Future<int> insertPlace(PlacesCompanion p) =>
      into(places).insert((p.uuid.present && p.uuid.value.isNotEmpty)
          ? p
          : p.copyWith(uuid: Value(_newUuid())));

  Future<void> updatePlace(int id, PlacesCompanion patch) =>
      (update(places)..where((p) => p.id.equals(id)))
          .write(patch.copyWith(updatedAt: Value(DateTime.now())));

  /// Delete a place; its visits are re-pointed to [reassignTo] (or left
  /// place-less) so history is never lost with a rename-and-merge.
  Future<void> deletePlace(int id, {int? reassignTo}) async {
    await (update(visits)..where((v) => v.placeId.equals(id)))
        .write(VisitsCompanion(
      placeId: Value(reassignTo),
      updatedAt: Value(DateTime.now()),
    ));
    final row =
        await (select(places)..where((p) => p.id.equals(id))).getSingleOrNull();
    if (row != null && row.uuid.isNotEmpty) {
      await recordTombstones('places', [row.uuid]);
    }
    await (delete(places)..where((p) => p.id.equals(id))).go();
  }

  /// Visits whose interval intersects [from, to]. Soft-deleted rows are
  /// excluded unless [includeDeleted]; declined rows are included (they're
  /// anchors for the detector) — UI filters on status.
  Future<List<Visit>> visitsBetween(DateTime from, DateTime to,
      {bool includeDeleted = false, List<int>? layerIds}) {
    final q = select(visits)
      ..where((v) {
        var e = v.startedAt.isSmallerOrEqualValue(to) &
            v.endedAt.isBiggerOrEqualValue(from);
        if (!includeDeleted) e = e & v.deletedAt.isNull();
        if (layerIds != null) e = e & v.layerId.isIn(layerIds);
        return e;
      })
      ..orderBy([(v) => OrderingTerm.asc(v.startedAt)]);
    return q.get();
  }

  Future<void> insertVisits(List<VisitsCompanion> rows) => batch((b) =>
      b.insertAll(
          visits,
          rows
              .map((v) => (v.uuid.present && v.uuid.value.isNotEmpty)
                  ? v
                  : v.copyWith(uuid: Value(_newUuid())))
              .toList()));

  /// Hard-delete machine rows (status 0, never touched by the user) — the
  /// detector rebuilds them wholesale; there is nothing to tombstone.
  Future<int> deleteMachineVisits(List<int> ids) => ids.isEmpty
      ? Future.value(0)
      : (delete(visits)
            ..where((v) =>
                v.id.isIn(ids) & v.status.equals(0) & v.deletedAt.isNull()))
          .go();

  Future<void> updateVisit(int id, VisitsCompanion patch) =>
      (update(visits)..where((v) => v.id.equals(id)))
          .write(patch.copyWith(updatedAt: Value(DateTime.now())));

  /// Soft delete: the row stays as a tombstone so detection never suggests
  /// this stay again. (A confirmed visit the user deletes is still an anchor.)
  Future<void> softDeleteVisit(int id) => updateVisit(
      id, VisitsCompanion(deletedAt: Value(DateTime.now())));

  /// (placeId → visit count) over live, non-declined visits.
  Future<Map<int, int>> visitCountsByPlace() async {
    final rows = await customSelect(
      'SELECT place_id AS pid, COUNT(*) AS c FROM visits '
      'WHERE deleted_at IS NULL AND status != 2 AND place_id IS NOT NULL '
      'GROUP BY place_id',
      readsFrom: {visits},
    ).get();
    return {for (final r in rows) r.read<int>('pid'): r.read<int>('c')};
  }

  /// Local calendar days (yyyy-mm-dd) that have any clean point, within
  /// [from, to]. Drives the timeline's date strip weight.
  Future<Set<String>> daysWithPoints(DateTime from, DateTime to) async {
    final rows = await customSelect(
      "SELECT DISTINCT date(time, 'unixepoch', 'localtime') AS d "
      'FROM track_points WHERE time BETWEEN ? AND ? AND flags = 0',
      variables: [
        Variable.withInt(from.millisecondsSinceEpoch ~/ 1000),
        Variable.withInt(to.millisecondsSinceEpoch ~/ 1000),
      ],
      readsFrom: {trackPoints},
    ).get();
    return {for (final r in rows) r.read<String>('d')};
  }

  Future<List<JournalEntry>> journalBetween(DateTime from, DateTime to) =>
      (select(journalEntries)
            ..where((j) => j.time.isBetweenValues(from, to))
            ..orderBy([(j) => OrderingTerm.asc(j.time)]))
          .get();

  // ─── Merged trips（合并记录）─────────────────────────────────────────────

  Future<List<MergedTrip>> allMergedTrips() => (select(mergedTrips)
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
      .get();

  Future<int> insertMergedTrip(MergedTripsCompanion t) =>
      into(mergedTrips).insert((t.uuid.present && t.uuid.value.isNotEmpty)
          ? t
          : t.copyWith(uuid: Value(_newUuid())));

  Future<void> renameMergedTrip(int id, String name) =>
      (update(mergedTrips)..where((t) => t.id.equals(id))).write(
          MergedTripsCompanion(
              name: Value(name), updatedAt: Value(DateTime.now())));

  /// 解散合并记录：只删这条“捆绑”，原始轨迹段一个点都不动。
  Future<void> deleteMergedTrip(int id) async {
    final row = await (select(mergedTrips)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    if (row.uuid.isNotEmpty) {
      await recordTombstones('merged_trips', [row.uuid]);
    }
    await (delete(mergedTrips)..where((t) => t.id.equals(id))).go();
  }

  // ─── Tombstones（增量减）────────────────────────────────────────────────

  /// Record deletion markers. insertOrReplace refreshes deletedAt so a
  /// repeated delete extends the tombstone's GC lifetime.
  Future<void> recordTombstones(String tbl, Iterable<String> uuids) async {
    final now = DateTime.now();
    final rows = [
      for (final u in uuids)
        if (u.isNotEmpty)
          TombstonesCompanion.insert(tbl: tbl, uuid: u, deletedAt: now),
    ];
    if (rows.isEmpty) return;
    await batch(
        (b) => b.insertAll(tombstones, rows, mode: InsertMode.insertOrReplace));
  }

  Future<List<Tombstone>> allTombstones() => select(tombstones).get();

  /// Tombstoned uuids of one logical table — the import skip-set.
  Future<Set<String>> tombstonedUuids(String tbl) async {
    final rows =
        await (select(tombstones)..where((t) => t.tbl.equals(tbl))).get();
    return rows.map((r) => r.uuid).toSet();
  }

  /// Merge tombstones arriving from a backup/sync (keeps the freshest
  /// deletedAt) — used to re-propagate deletes to further devices.
  Future<void> mergeTombstones(List<TombstonesCompanion> rows) async {
    if (rows.isEmpty) return;
    await batch(
        (b) => b.insertAll(tombstones, rows, mode: InsertMode.insertOrReplace));
  }

  /// Drop markers older than [keep] — a delete only needs to outlive every
  /// device's next sync, so ~180 days is generous for personal use.
  Future<int> gcTombstones({Duration keep = const Duration(days: 180)}) =>
      (delete(tombstones)
            ..where((t) =>
                t.deletedAt.isSmallerThanValue(DateTime.now().subtract(keep))))
          .go();

  // ─── Fog erase markers（迷雾增量减）──────────────────────────────────────

  /// Record that the eraser swept the pixels set in [maskBits] of one block.
  /// Repeated erases OR into the existing mask; erasedAt is refreshed so the
  /// newest sweep decides LWW against re-explorations from other devices.
  Future<void> recordFogErase(
    int tileX,
    int tileY,
    int zoom,
    int layerId,
    Uint8List maskBits, {
    DateTime? at,
  }) async {
    final existing = await (select(fogErases)
          ..where((e) =>
              e.tileX.equals(tileX) &
              e.tileY.equals(tileY) &
              e.zoom.equals(zoom) &
              e.layerId.equals(layerId)))
        .getSingleOrNull();
    final merged = Uint8List.fromList(maskBits);
    if (existing != null) {
      final old = existing.mask;
      for (var i = 0; i < merged.length && i < old.length; i++) {
        merged[i] |= old[i];
      }
    }
    await into(fogErases).insert(
      FogErasesCompanion.insert(
        tileX: tileX,
        tileY: tileY,
        zoom: zoom,
        layerId: layerId,
        mask: merged,
        erasedAt: at ?? DateTime.now(),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<List<FogErase>> allFogErases() => select(fogErases).get();

  Future<List<FogErase>> fogErasesForLayer(int layerId) =>
      (select(fogErases)..where((e) => e.layerId.equals(layerId))).get();

  /// Drop erase markers older than [keep] — same lifetime as [gcTombstones].
  Future<int> gcFogErases({Duration keep = const Duration(days: 180)}) async {
    final cutoff = DateTime.now().subtract(keep);
    // Probe first: drift fires a table-update notification for every executed
    // DELETE even when 0 rows match, which would invalidate the sync engine's
    // fog export cache on every single export. Only touch the table when
    // there's actually something to collect.
    final probe = await (select(fogErases)
          ..where((e) => e.erasedAt.isSmallerThanValue(cutoff))
          ..limit(1))
        .get();
    if (probe.isEmpty) return 0;
    return (delete(fogErases)
          ..where((e) => e.erasedAt.isSmallerThanValue(cutoff)))
        .go();
  }

  // ─── Sync merge helpers（行级 LWW 更新）─────────────────────────────────

  /// Overwrite an existing journal entry (matched by uuid) with imported
  /// fields and keep the FTS mirror in step. Used by the sync merge when the
  /// incoming copy is strictly newer than ours.
  Future<void> applyJournalUpdateByUuid(
      String uuid, JournalEntriesCompanion data) async {
    await (update(journalEntries)..where((j) => j.uuid.equals(uuid)))
        .write(data);
    // limit(1): uuid SHOULD be unique, but historical double-imports could
    // have cloned rows — getSingle would throw and abort the whole module.
    final rows = await (select(journalEntries)
          ..where((j) => j.uuid.equals(uuid))
          ..limit(1))
        .get();
    if (rows.isEmpty) return;
    final row = rows.first;
    // FTS5 rows are cheapest to refresh as delete+insert.
    await customStatement(
        'DELETE FROM journal_fts WHERE rowid=?', [row.id]);
    await customStatement(
      'INSERT INTO journal_fts(rowid, title, content) VALUES (?, ?, ?)',
      [row.id, row.title, row.richContent],
    );
  }
}

