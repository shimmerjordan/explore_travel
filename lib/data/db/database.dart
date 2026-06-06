import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'connection/connection.dart';

part 'database.g.dart';

/// Single source of truth for fresh UUIDs across the insert helpers.
String _newUuid() => const Uuid().v4();

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
}

class TrackLayers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withDefault(const Constant(''))();
  TextColumn get name => text()();
  IntColumn get colorValue => integer()();
  BoolColumn get visible => boolean().withDefault(const Constant(true))();
  TextColumn get tag => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
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

@DriftDatabase(tables: [
  TrackPoints,
  TrackLayers,
  FogTiles,
  JournalEntries,
  ChatMessages,
  SongFavorites,
  PeerLocations,
])
class AppDb extends _$AppDb {
  AppDb() : super(openConnection());

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await into(trackLayers).insert(TrackLayersCompanion.insert(
            name: '默认图层',
            colorValue: 0xFF00BCD4,
            createdAt: DateTime.now(),
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
        },
      );

  Stream<List<TrackLayer>> watchLayers() => select(trackLayers).watch();
  Future<List<TrackLayer>> allLayers() => select(trackLayers).get();
  Future<int> insertLayer(TrackLayersCompanion data) =>
      into(trackLayers).insert(_withUuid(data));

  /// Stamp a fresh UUID on a layer companion when the caller didn't
  /// supply one. Keeps backup-import paths (which DO supply uuid) honest
  /// while leaving normal callers terse.
  TrackLayersCompanion _withUuid(TrackLayersCompanion d) =>
      (d.uuid.present && d.uuid.value.isNotEmpty)
          ? d
          : d.copyWith(uuid: Value(_newUuid()));
  Future<bool> updateLayer(TrackLayer l) => update(trackLayers).replace(l);
  Future<int> deleteLayer(int id) =>
      (delete(trackLayers)..where((l) => l.id.equals(id))).go();

  Future<int> insertPoint(TrackPointsCompanion p) =>
      into(trackPoints).insert((p.uuid.present && p.uuid.value.isNotEmpty)
          ? p
          : p.copyWith(uuid: Value(_newUuid())));
  Future<List<TrackPoint>> pointsBetween(DateTime from, DateTime to) =>
      (select(trackPoints)..where((t) => t.time.isBetweenValues(from, to))).get();
  Future<List<TrackPoint>> pointsForLayer(int layerId) =>
      (select(trackPoints)..where((t) => t.layerId.equals(layerId))).get();

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

  Future<List<FogTile>> fogTilesForLayers(List<int> layerIds, int zoom) =>
      (select(fogTiles)
            ..where(
                (t) => t.layerId.isIn(layerIds) & t.zoom.equals(zoom)))
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
        .write(JournalEntriesCompanion(layerId: Value(destLayerId)));
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
    return (delete(trackPoints)
          ..where((p) =>
              p.lat.isBetweenValues(lat - dLat, lat + dLat) &
              p.lng.isBetweenValues(lng - dLng, lng + dLng)))
        .go();
  }
}

