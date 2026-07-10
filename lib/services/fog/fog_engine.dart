import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import '../../data/db/database.dart';

/// Fog of war engine — **Fog of World compatible**.
///
/// Coordinate system uses Web Mercator identical to FOW:
///   - 512 × 512  tile grid
///   - 128 × 128  block grid per tile
///   - 64  × 64   pixel bitmap per block  (512 bytes, MSB-first)
///
/// Total global pixels: 512 * 128 * 64 = 2^22 = 4 194 304  per axis.
/// At the equator each pixel ≈ 9.55 m.
class FogEngine {
  static const int mapWidth = 512;
  static const int tileWidth = 128;
  static const int bitmapWidth = 64;
  static const int full = mapWidth * tileWidth * bitmapWidth; // 2^22

  static const int bitmapBytes = bitmapWidth * bitmapWidth ~/ 8; // 512

  /// Zoom level that matches FOW tile grid.
  /// FOW uses mapWidth=512 tiles which corresponds to OSM zoom 9
  /// (2^9 = 512 tiles per axis).
  /// But each tile has 128*64 = 8192 pixels, so the effective resolution
  /// is zoom 9 + 13 bits = zoom 22 total pixel bits.
  /// For DB storage we use tileZoom=9 with blocks encoded in the bitmap.
  ///
  /// HOWEVER — to keep backward compat with the DB schema that stores
  /// (tileX, tileY, zoom, layerId, bitmap), we store one row per
  /// FOW **block** (128×128 blocks per tile). Each row's bitmap is
  /// 512 bytes (64×64 bits). The zoom field stores a sentinel value
  /// to distinguish from old data.
  static const int tileZoom = 100; // sentinel, not a real zoom

  final AppDb db;
  FogEngine(this.db);

  /// Rows written by the interactive reveal/erase paths, emitted as they
  /// land. The map's fog layer merges these into its in-memory snapshot
  /// instead of re-reading the whole fog_tiles table (which can be ~45k rows
  /// after a FOW import) on every recording tick. Bulk import does NOT emit —
  /// importers bump the global fog refresh once at the end instead.
  final _changes = StreamController<List<FogTile>>.broadcast();
  Stream<List<FogTile>> get changes => _changes.stream;

  void _emitChanged(List<FogTile> rows) {
    if (rows.isNotEmpty && _changes.hasListener) _changes.add(rows);
  }

  // ─── Web Mercator projection (matches FOW exactly) ───

  /// Longitude → global pixel X  (0 .. FULL-1).
  static int lngToGlobalX(double lng) =>
      ((lng + 180.0) / 360.0 * full).floor().clamp(0, full - 1);

  /// Latitude → global pixel Y  (0 .. FULL-1).
  static int latToGlobalY(double lat) {
    final latRad = lat * math.pi / 180.0;
    final y = (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
        2.0 * full;
    return y.floor().clamp(0, full - 1);
  }

  /// Global pixel X → longitude.
  static double globalXToLng(int gx) => gx / full * 360.0 - 180.0;

  /// Global pixel Y → latitude.
  static double globalYToLat(int gy) {
    final n = math.pi - 2.0 * math.pi * gy / full;
    return 180.0 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
  }

  /// Decompose a global pixel coordinate into (tile, block, pixel).
  static ({int tile, int block, int pixel}) decompose(int global) {
    final tile = global >> 13;   // / (128*64)
    final block = (global >> 6) & 0x7F; // / 64, mod 128
    final pixel = global & 0x3F; // mod 64
    return (tile: tile, block: block, pixel: pixel);
  }

  /// Compose (tile, block, pixel) → global pixel coordinate.
  static int compose(int tile, int block, int pixel) =>
      (tile << 13) | (block << 6) | pixel;

  // ─── Bitmap access (matches FOW bit ordering: MSB-first) ───

  /// Test if pixel (px, py) is set in a 512-byte bitmap.
  static bool isSet(Uint8List bitmap, int px, int py) {
    final byteIdx = (px >> 3) + py * 8;
    final bit = 7 - (px & 7);
    return (bitmap[byteIdx] >> bit) & 1 == 1;
  }

  /// Set pixel (px, py) in a 512-byte bitmap.
  static void setBit(Uint8List bitmap, int px, int py) {
    final byteIdx = (px >> 3) + py * 8;
    final bit = 7 - (px & 7);
    bitmap[byteIdx] |= (1 << bit);
  }

  /// Clear pixel (px, py) in a 512-byte bitmap.
  static void clearBit(Uint8List bitmap, int px, int py) {
    final byteIdx = (px >> 3) + py * 8;
    final bit = 7 - (px & 7);
    bitmap[byteIdx] &= ~(1 << bit);
  }

  // ─── DB key mapping ───
  // We store each FOW block as one DB row:
  //   tileX  = tileX * tileWidth + blockX   (unique block x in global grid)
  //   tileY  = tileY * tileWidth + blockY
  //   zoom   = tileZoom (sentinel=100)

  static int _dbX(int tileX, int blockX) => tileX * tileWidth + blockX;
  static int _dbY(int tileY, int blockY) => tileY * tileWidth + blockY;

  // ─── Public API ───

  /// Reveals exactly one FOW pixel at the given GPS position (WGS-84).
  /// This is the correct behavior for automatic recording — each GPS sample
  /// lights up a single ~9 m pixel, matching Fog of World behavior.
  Future<void> revealSinglePixel({
    required double lat,
    required double lng,
    required int layerId,
  }) async {
    _bumpRev();
    final gx = lngToGlobalX(lng);
    final gy = latToGlobalY(lat);
    final dx = decompose(gx);
    final dy = decompose(gy);
    final dbX = _dbX(dx.tile, dx.block);
    final dbY = _dbY(dy.tile, dy.block);

    final existing = await db.getFogTile(dbX, dbY, tileZoom, layerId);
    final bytes = existing == null
        ? Uint8List(bitmapBytes)
        : Uint8List.fromList(existing.bitmap);

    if (isSet(bytes, dx.pixel, dy.pixel)) return; // already set

    setBit(bytes, dx.pixel, dy.pixel);
    final row = FogTile(
      tileX: dbX,
      tileY: dbY,
      zoom: tileZoom,
      layerId: layerId,
      bitmap: bytes,
      updatedAt: DateTime.now(),
    );
    await db.upsertFogTile(row.toCompanion(false));
    _emitChanged([row]);
  }

  /// Erases exactly one FOW pixel at the given GPS position (WGS-84).
  Future<void> eraseSinglePixel({
    required double lat,
    required double lng,
    required int layerId,
  }) async {
    _bumpRev();
    final gx = lngToGlobalX(lng);
    final gy = latToGlobalY(lat);
    final dx = decompose(gx);
    final dy = decompose(gy);
    final dbX = _dbX(dx.tile, dx.block);
    final dbY = _dbY(dy.tile, dy.block);

    // Record the sweep BEFORE the bail-outs: the erase must reach other
    // devices even when this one has nothing lit here (their copy might).
    final eraseMask = Uint8List(512);
    setBit(eraseMask, dx.pixel, dy.pixel);
    await db.recordFogErase(dbX, dbY, tileZoom, layerId, eraseMask);

    final existing = await db.getFogTile(dbX, dbY, tileZoom, layerId);
    if (existing == null) return;
    final bytes = Uint8List.fromList(existing.bitmap);

    if (!isSet(bytes, dx.pixel, dy.pixel)) return; // already clear

    clearBit(bytes, dx.pixel, dy.pixel);
    final row = FogTile(
      tileX: dbX,
      tileY: dbY,
      zoom: tileZoom,
      layerId: layerId,
      bitmap: bytes,
      updatedAt: DateTime.now(),
    );
    await db.upsertFogTile(row.toCompanion(false));
    _emitChanged([row]);
  }

  /// Reveals fog in a circular area around a GPS position (WGS-84).
  /// Used for manual pen/brush editing, NOT for automatic recording.
  /// Reveal every FOW pixel along the straight line from (lat0,lng0) to
  /// (lat1,lng1). Used by recording to connect successive GPS samples
  /// when they're close enough that the user clearly walked from A to B
  /// in one go — otherwise you get a dotted constellation instead of a
  /// continuous trail.
  ///
  /// Sweep a disk of [radiusMeters] along the straight segment from
  /// (lat0,lng0) to (lat1,lng1). This is the **ambient fog clear**, NOT
  /// the visible trail — the visible trail is drawn as a real vector
  /// polyline on top of the map. The disk-sweep just creates a wide,
  /// soft corridor in the fog so the polyline rides inside cleared
  /// territory instead of fighting raster aliasing along its edge.
  ///
  /// Caller must gate this on a freshness / max-gap check — see
  /// [RecordingController]. We don't second-guess that here.
  Future<void> revealLine({
    required double lat0,
    required double lng0,
    required double lat1,
    required double lng1,
    required int layerId,
    required double radiusMeters,
  }) async {
    _bumpRev();
    final x0 = lngToGlobalX(lng0);
    final y0 = latToGlobalY(lat0);
    final x1 = lngToGlobalX(lng1);
    final y1 = latToGlobalY(lat1);
    final metersPerPixel = _metersPerPixelAt((lat0 + lat1) / 2);
    final rPx = (radiusMeters / metersPerPixel).ceil().clamp(1, 1 << 20);
    final segPx =
        math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2)).toDouble();
    // Step **per pixel** along the segment (not per half-radius). Each
    // disk is small (rPx is often 3–10 px); half-radius stepping left
    // visible scallops on diagonals where each disk's perimeter
    // protrudes between centres. Per-pixel stepping means the corridor
    // edge is a true Minkowski sum of disk + line, i.e. as smooth as
    // raster gets at this resolution. Hard cap so a runaway long line
    // (e.g. import bug producing a giant gap) can't queue 100k writes.
    final steps = segPx.ceil().clamp(1, 8192);

    final touched = <String, _BlockEdit>{};
    void addPixel(int gx, int gy) {
      if (gx < 0 || gy < 0 || gx >= full || gy >= full) return;
      final decomX = decompose(gx);
      final decomY = decompose(gy);
      final key =
          '${decomX.tile}_${decomY.tile}_${decomX.block}_${decomY.block}';
      final edit = touched.putIfAbsent(
          key,
          () => _BlockEdit(
              decomX.tile, decomY.tile, decomX.block, decomY.block));
      edit.sets.add((decomX.pixel, decomY.pixel));
    }

    final rSq = rPx * rPx;
    for (int s = 0; s <= steps; s++) {
      final t = s / steps;
      final cx = (x0 + (x1 - x0) * t).round();
      final cy = (y0 + (y1 - y0) * t).round();
      final xMin = (cx - rPx).clamp(0, full - 1).toInt();
      final xMax = (cx + rPx).clamp(0, full - 1).toInt();
      final yMin = (cy - rPx).clamp(0, full - 1).toInt();
      final yMax = (cy + rPx).clamp(0, full - 1).toInt();
      for (int gy = yMin; gy <= yMax; gy++) {
        final dyP = gy - cy;
        for (int gx = xMin; gx <= xMax; gx++) {
          final dxP = gx - cx;
          if (dxP * dxP + dyP * dyP <= rSq) addPixel(gx, gy);
        }
      }
    }
    final changed = <FogTile>[];
    for (final edit in touched.values) {
      final dbX = _dbX(edit.tileX, edit.blockX);
      final dbY = _dbY(edit.tileY, edit.blockY);
      final existing = await db.getFogTile(dbX, dbY, tileZoom, layerId);
      final bytes = existing == null
          ? Uint8List(bitmapBytes)
          : Uint8List.fromList(existing.bitmap);
      for (final (px, py) in edit.sets) {
        setBit(bytes, px, py);
      }
      final row = FogTile(
        tileX: dbX,
        tileY: dbY,
        zoom: tileZoom,
        layerId: layerId,
        bitmap: bytes,
        updatedAt: DateTime.now(),
      );
      await db.upsertFogTile(row.toCompanion(false));
      changed.add(row);
    }
    _emitChanged(changed);
  }

  Future<void> revealPoint({
    required double lat,
    required double lng,
    required double radiusMeters,
    required int layerId,
  }) async {
    _bumpRev();
    final cx = lngToGlobalX(lng);
    final cy = latToGlobalY(lat);

    final metersPerPixel = _metersPerPixelAt(lat);
    final rPx = (radiusMeters / metersPerPixel).ceil();

    final xMin = (cx - rPx).clamp(0, full - 1);
    final xMax = (cx + rPx).clamp(0, full - 1);
    final yMin = (cy - rPx).clamp(0, full - 1);
    final yMax = (cy + rPx).clamp(0, full - 1);

    final rSq = rPx * rPx;

    final touched = <String, _BlockEdit>{};

    for (int gy = yMin; gy <= yMax; gy++) {
      final dy = gy - cy;
      for (int gx = xMin; gx <= xMax; gx++) {
        final dx = gx - cx;
        if (dx * dx + dy * dy > rSq) continue;

        final decomX = decompose(gx);
        final decomY = decompose(gy);
        final key = '${decomX.tile}_${decomY.tile}_${decomX.block}_${decomY.block}';
        final edit = touched.putIfAbsent(key, () => _BlockEdit(
          decomX.tile, decomY.tile, decomX.block, decomY.block,
        ));
        edit.sets.add((decomX.pixel, decomY.pixel));
      }
    }

    final changed = <FogTile>[];
    for (final edit in touched.values) {
      final dbX = _dbX(edit.tileX, edit.blockX);
      final dbY = _dbY(edit.tileY, edit.blockY);
      final existing = await db.getFogTile(dbX, dbY, tileZoom, layerId);
      final bytes = existing == null
          ? Uint8List(bitmapBytes)
          : Uint8List.fromList(existing.bitmap);

      for (final (px, py) in edit.sets) {
        setBit(bytes, px, py);
      }

      final row = FogTile(
        tileX: dbX,
        tileY: dbY,
        zoom: tileZoom,
        layerId: layerId,
        bitmap: bytes,
        updatedAt: DateTime.now(),
      );
      await db.upsertFogTile(row.toCompanion(false));
      changed.add(row);
    }
    _emitChanged(changed);
  }

  /// Erase fog around a point.
  Future<void> erase({
    required double lat,
    required double lng,
    required double radiusMeters,
    required int layerId,
  }) async {
    _bumpRev();
    final cx = lngToGlobalX(lng);
    final cy = latToGlobalY(lat);

    final metersPerPixel = _metersPerPixelAt(lat);
    final rPx = (radiusMeters / metersPerPixel).ceil();

    final xMin = (cx - rPx).clamp(0, full - 1);
    final xMax = (cx + rPx).clamp(0, full - 1);
    final yMin = (cy - rPx).clamp(0, full - 1);
    final yMax = (cy + rPx).clamp(0, full - 1);

    final rSq = rPx * rPx;
    final touched = <String, _BlockEdit>{};

    for (int gy = yMin; gy <= yMax; gy++) {
      final dy = gy - cy;
      for (int gx = xMin; gx <= xMax; gx++) {
        final dx = gx - cx;
        if (dx * dx + dy * dy > rSq) continue;

        final decomX = decompose(gx);
        final decomY = decompose(gy);
        final key = '${decomX.tile}_${decomY.tile}_${decomX.block}_${decomY.block}';
        final edit = touched.putIfAbsent(key, () => _BlockEdit(
          decomX.tile, decomY.tile, decomX.block, decomY.block,
        ));
        edit.sets.add((decomX.pixel, decomY.pixel));
      }
    }

    final changed = <FogTile>[];
    for (final edit in touched.values) {
      final dbX = _dbX(edit.tileX, edit.blockX);
      final dbY = _dbY(edit.tileY, edit.blockY);

      // Record the full swept mask (not just locally-lit pixels): the erase
      // must clear these pixels on other devices too, whose copies may hold
      // bits this device never had.
      final eraseMask = Uint8List(512);
      for (final (px, py) in edit.sets) {
        setBit(eraseMask, px, py);
      }
      await db.recordFogErase(dbX, dbY, tileZoom, layerId, eraseMask);

      final existing = await db.getFogTile(dbX, dbY, tileZoom, layerId);
      if (existing == null) continue;
      final bytes = Uint8List.fromList(existing.bitmap);

      for (final (px, py) in edit.sets) {
        clearBit(bytes, px, py);
      }

      final row = FogTile(
        tileX: dbX,
        tileY: dbY,
        zoom: tileZoom,
        layerId: layerId,
        bitmap: bytes,
        updatedAt: DateTime.now(),
      );
      await db.upsertFogTile(row.toCompanion(false));
      changed.add(row);
    }
    _emitChanged(changed);
  }

  /// Returns a merged bitmap for a given FOW block across all given layers.
  Future<Uint8List?> mergedBlockBitmap(
      int dbX, int dbY, List<int> layerIds) async {
    if (layerIds.isEmpty) return null;
    Uint8List? merged;
    for (final lid in layerIds) {
      final t = await db.getFogTile(dbX, dbY, tileZoom, lid);
      if (t == null) continue;
      if (merged == null) {
        merged = Uint8List.fromList(t.bitmap);
      } else {
        for (int i = 0; i < merged.length; i++) {
          merged[i] |= t.bitmap[i];
        }
      }
    }
    return merged;
  }

  /// Globally explored fraction of Earth's surface (incl. oceans).
  /// Single source of truth — both the home stats card and the explore
  /// screen's top "全球（含海洋）" number call this, so they always agree.
  ///
  /// Definition: total revealed area in km² (Mercator-corrected per
  /// latitude) divided by Earth's total surface (510 072 000 km², UN).
  Future<double> globalExplorationPercent(List<int> layerIds) async {
    const earthSurfaceKm2 = 510072000.0;
    final agg = await computeAggregates(layerIds);
    return (agg.globalKm2 / earthSurfaceKm2).clamp(0.0, 1.0);
  }

  /// Meters per global pixel at given latitude.
  static double _metersPerPixelAt(double lat) {
    const earthCircumference = 40075016.686;
    return earthCircumference * math.cos(lat * math.pi / 180.0) / full;
  }

  /// Area in km² actually revealed *inside* the given lat/lng bbox.
  /// Thin wrapper over [computeAggregates] — heavy lifting happens on a
  /// background isolate with result caching.
  Future<double> revealedAreaInBboxKm2(
    List<int> layerIds, {
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
  }) async {
    final agg = await computeAggregates(layerIds, bboxes: {
      '_': (minLat: minLat, minLng: minLng, maxLat: maxLat, maxLng: maxLng),
    });
    return agg.bboxes['_'] ?? 0;
  }

  /// Multi-bbox variant attributing each revealed pixel to exactly one
  /// region (smallest containing bbox wins). Thin wrapper over
  /// [computeAggregates].
  Future<Map<String, double>> revealedAreaByRegionsKm2(
    List<int> layerIds, {
    required Map<String, ({double minLat, double minLng, double maxLat, double maxLng})> regions,
  }) async {
    final agg = await computeAggregates(layerIds, regions: regions);
    return {for (final k in regions.keys) k: agg.regions[k] ?? 0};
  }

  // ─── Aggregates: one fetch, one background isolate, cached ──────────────
  //
  // The fog table can hold ~45k rows × 512-byte bitmaps after a FOW import.
  // The old per-caller walks (global %, per-region attribution, per-learned-
  // region bbox — each a full fetch + Dart pixel loops ON THE MAIN ISOLATE)
  // froze the UI for seconds (ANR). Now every caller funnels through
  // [computeAggregates]: rows are fetched once, packed into flat typed
  // arrays, and popcount/attribution run inside `compute()`. Results are
  // memoized against a cheap (rev, COUNT, MAX(rowid)) probe so reopening
  // the explore page or profile sheet is instant until fog data changes.

  /// Bumped by every engine write; part of the aggregate cache key.
  int _dataRev = 0;
  void _bumpRev() => _dataRev++;

  final _aggCache = <String, FogAggregates>{};

  /// [regions] and [regions2] are two INDEPENDENT attribution passes (e.g.
  /// country-level and province-level dedup) computed in the same isolate
  /// run over one fetch — callers that need both should pass both instead
  /// of calling twice.
  Future<FogAggregates> computeAggregates(
    List<int> layerIds, {
    Map<String, ({double minLat, double minLng, double maxLat, double maxLng})>?
        regions,
    Map<String, ({double minLat, double minLng, double maxLat, double maxLng})>?
        regions2,
    Map<String, ({double minLat, double minLng, double maxLat, double maxLng})>?
        bboxes,
  }) async {
    FogAggregates empty() => FogAggregates(
          globalKm2: 0,
          regions: {for (final k in (regions ?? const {}).keys) k: 0.0},
          regions2: {for (final k in (regions2 ?? const {}).keys) k: 0.0},
          bboxes: {for (final k in (bboxes ?? const {}).keys) k: 0.0},
        );
    if (layerIds.isEmpty) return empty();

    // Cheap staleness probe: catches external bulk writes (backup restore,
    // FOW import via batchUpsertFogTiles) that don't go through the engine.
    final probe = await db.customSelect(
      'SELECT COUNT(*) AS c, IFNULL(MAX(rowid), 0) AS m FROM fog_tiles',
    ).getSingle();
    final probeKey = '${probe.read<int>('c')}_${probe.read<int>('m')}';

    String bboxSig(
            Map<String, ({double minLat, double minLng, double maxLat, double maxLng})>?
                m) =>
        m == null
            ? ''
            : (m.entries
                    .map((e) =>
                        '${e.key}:${e.value.minLat},${e.value.minLng},${e.value.maxLat},${e.value.maxLng}')
                    .toList()
                  ..sort())
                .join(';');

    final key = '${layerIds.join(",")}|$_dataRev|$probeKey'
        '|${bboxSig(regions).hashCode}|${bboxSig(regions2).hashCode}'
        '|${bboxSig(bboxes).hashCode}';
    final hit = _aggCache[key];
    if (hit != null) return hit;

    final sw = Stopwatch()..start();
    // Lean fetch: only the three columns the aggregation needs. The full
    // drift row (id/zoom/layerId/updatedAt) costs measurably more to
    // deserialize at ~46k rows.
    final rows = await db.customSelect(
      'SELECT tile_x, tile_y, bitmap FROM fog_tiles '
      'WHERE zoom = $tileZoom AND layer_id IN (${layerIds.join(",")})',
    ).get();
    final fetchMs = sw.elapsedMilliseconds;

    final FogAggregates result;
    if (rows.isEmpty) {
      result = empty();
    } else {
      // Pack rows into flat arrays: cheap to message-pass to the isolate.
      final n = rows.length;
      final xs = Int32List(n);
      final ys = Int32List(n);
      final blob = Uint8List(n * bitmapBytes);
      for (var i = 0; i < n; i++) {
        final r = rows[i];
        xs[i] = r.read<int>('tile_x');
        ys[i] = r.read<int>('tile_y');
        final bm = r.read<Uint8List>('bitmap');
        blob.setRange(i * bitmapBytes,
            i * bitmapBytes + math.min(bitmapBytes, bm.length), bm);
      }
      List<double> flat(
              ({double minLat, double minLng, double maxLat, double maxLng})
                  b) =>
          [b.minLat, b.minLng, b.maxLat, b.maxLng];
      final raw = await compute(_aggregateFog, <String, dynamic>{
        'xs': xs,
        'ys': ys,
        'blob': blob,
        'regions': {
          for (final e in (regions ?? const {}).entries) e.key: flat(e.value)
        },
        'regions2': {
          for (final e in (regions2 ?? const {}).entries) e.key: flat(e.value)
        },
        'bboxes': {
          for (final e in (bboxes ?? const {}).entries) e.key: flat(e.value)
        },
      });
      result = FogAggregates(
        globalKm2: raw['global'] as double,
        regions: (raw['regions'] as Map).cast<String, double>(),
        regions2: (raw['regions2'] as Map).cast<String, double>(),
        bboxes: (raw['bboxes'] as Map).cast<String, double>(),
      );
    }
    assert(() {
      // ignore: avoid_print
      print('[FogAgg] rows=${rows.length} fetch=${fetchMs}ms '
          'total=${sw.elapsedMilliseconds}ms '
          'r1=${regions?.length ?? 0} r2=${regions2?.length ?? 0} '
          'bb=${bboxes?.length ?? 0}');
      return true;
    }());

    // Tiny LRU: aggregates are small, but don't let keys pile up forever.
    if (_aggCache.length >= 6) _aggCache.remove(_aggCache.keys.first);
    _aggCache[key] = result;
    return result;
  }

  /// Approximate area of a lat/lng bbox in km². Mercator-flat approximation
  /// — good enough for the bbox-as-denominator case (provinces / learned
  /// regions). Not for use as a region's "true" area; for countries use the
  /// known constants in `iso_country_areas.dart`.
  static double bboxAreaKm2(
      double minLat, double minLng, double maxLat, double maxLng) {
    const kmPerDegLat = 111.32;
    final centerLat = (minLat + maxLat) / 2;
    final kmPerDegLng =
        kmPerDegLat * math.cos(centerLat * math.pi / 180.0).abs();
    final dLat = (maxLat - minLat).abs();
    final dLng = (maxLng - minLng).abs();
    return dLat * kmPerDegLat * dLng * kmPerDegLng;
  }

  // ─── FOW Import/Export helpers ───

  /// Get all block bitmaps for a given tile (for export).
  Future<Map<(int, int), Uint8List>> getBlocksForTile(
      int tileX, int tileY, List<int> layerIds) async {
    final result = <(int, int), Uint8List>{};
    for (int by = 0; by < tileWidth; by++) {
      for (int bx = 0; bx < tileWidth; bx++) {
        final dbX = _dbX(tileX, bx);
        final dbY = _dbY(tileY, by);
        final merged = await mergedBlockBitmap(dbX, dbY, layerIds);
        if (merged != null) {
          result[(bx, by)] = merged;
        }
      }
    }
    return result;
  }

  /// Import a single block bitmap (from FOW file).
  Future<void> importBlock({
    required int tileX,
    required int tileY,
    required int blockX,
    required int blockY,
    required Uint8List bitmap,
    required int layerId,
  }) async {
    _bumpRev();
    final dbX = _dbX(tileX, blockX);
    final dbY = _dbY(tileY, blockY);
    final existing = await db.getFogTile(dbX, dbY, tileZoom, layerId);
    final bytes = existing == null
        ? Uint8List(bitmapBytes)
        : Uint8List.fromList(existing.bitmap);

    for (int i = 0; i < bitmapBytes; i++) {
      bytes[i] |= bitmap[i];
    }

    await db.upsertFogTile(FogTilesCompanion.insert(
      tileX: dbX,
      tileY: dbY,
      zoom: tileZoom,
      layerId: layerId,
      bitmap: bytes,
      updatedAt: DateTime.now(),
    ));
  }

  /// Bulk-import FOW blocks into [layerId] in ONE transaction.
  ///
  /// Reads the layer's existing tiles once, OR-merges every incoming block in
  /// memory, then writes the lot with a single batched upsert. A full Fog of
  /// World "Sync" folder is ~45k blocks; the per-block [importBlock] path fires
  /// ~90k awaited DB round-trips (minutes of frozen spinner on a phone), which
  /// is why FOW import looked broken. Returns the number of block-tiles written.
  Future<int> importBlocks({
    required int layerId,
    required List<
            ({
              int tileX,
              int tileY,
              int blockX,
              int blockY,
              Uint8List bitmap
            })>
        blocks,
  }) async {
    _bumpRev();
    if (blocks.isEmpty) return 0;

    // One read for the whole layer, keyed by DB (x, y).
    final tiles = <(int, int), Uint8List>{};
    for (final t in await db.fogTilesForLayers([layerId], tileZoom)) {
      tiles[(t.tileX, t.tileY)] = Uint8List.fromList(t.bitmap);
    }

    // OR-merge every incoming block in memory; track touched keys so we only
    // rewrite tiles that actually changed.
    final touched = <(int, int)>{};
    for (final b in blocks) {
      final key = (_dbX(b.tileX, b.blockX), _dbY(b.tileY, b.blockY));
      touched.add(key);
      final cur = tiles[key];
      if (cur == null) {
        tiles[key] = Uint8List.fromList(b.bitmap);
      } else {
        final n = math.min(cur.length, b.bitmap.length);
        for (int i = 0; i < n; i++) {
          cur[i] |= b.bitmap[i];
        }
      }
    }

    final now = DateTime.now();
    final rows = [
      for (final key in touched)
        FogTilesCompanion.insert(
          tileX: key.$1,
          tileY: key.$2,
          zoom: tileZoom,
          layerId: layerId,
          bitmap: tiles[key]!,
          updatedAt: now,
        ),
    ];
    await db.batchUpsertFogTiles(rows);
    return touched.length;
  }
}

class _BlockEdit {
  final int tileX, tileY, blockX, blockY;
  final List<(int, int)> sets = [];
  _BlockEdit(this.tileX, this.tileY, this.blockX, this.blockY);
}

/// Result bundle from [FogEngine.computeAggregates].
class FogAggregates {
  /// Total revealed area on Earth, km² (Mercator-corrected).
  final double globalKm2;

  /// Revealed km² per region key — each pixel attributed to exactly ONE
  /// region of the group (the smallest containing bbox).
  final Map<String, double> regions;

  /// Second independent attribution group (e.g. provinces alongside
  /// countries) — computed in the same pass.
  final Map<String, double> regions2;

  /// Revealed km² per bbox key — pixels may count in several overlapping
  /// bboxes (no exclusive attribution).
  final Map<String, double> bboxes;

  const FogAggregates({
    required this.globalKm2,
    required this.regions,
    this.regions2 = const {},
    required this.bboxes,
  });
}

/// One attribution group's flattened state inside the isolate.
class _RegionGroup {
  final List<String> keys;
  final List<List<double>> boxes; // [minLat,minLng,maxLat,maxLng]
  final List<double> areas; // deg² — for smallest-wins tie-breaking
  final List<double> out;
  // Reused per block:
  final List<int> candidates = [];
  bool perPixel = false; // does THIS block need the pixel loop?
  int fastIdx = -1; // block-level winner when !perPixel

  _RegionGroup(Map<String, List<double>> src)
      : keys = src.keys.toList(growable: false),
        boxes = src.values.toList(growable: false),
        areas = src.values
            .map((b) => (b[2] - b[0]) * (b[3] - b[1]))
            .toList(growable: false),
        out = List<double>.filled(src.length, 0);

  /// Classify this block: fill [candidates], decide fast path vs per-pixel.
  ///
  /// Fast path: if some candidate FULLY CONTAINS the block, and no candidate
  /// with a SMALLER area partially overlaps it, then every set pixel in the
  /// block picks that same containing region — attribute popcount×area in one
  /// go. This covers the vast majority of blocks (a 64px block is ~600 m; the
  /// bboxes are provinces/countries), leaving the per-pixel loop only for
  /// blocks crossing a bbox edge.
  void classify(double blockLatN, double blockLatS, double blockLngW,
      double blockLngE) {
    candidates.clear();
    perPixel = false;
    fastIdx = -1;
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      if (blockLatS > b[2] || blockLatN < b[0]) continue;
      if (blockLngE < b[1] || blockLngW > b[3]) continue;
      candidates.add(i);
    }
    if (candidates.isEmpty) return;
    var bestFull = -1;
    var bestFullArea = double.infinity;
    for (final i in candidates) {
      final b = boxes[i];
      final full = blockLatS >= b[0] &&
          blockLatN <= b[2] &&
          blockLngW >= b[1] &&
          blockLngE <= b[3];
      if (full && areas[i] < bestFullArea) {
        bestFullArea = areas[i];
        bestFull = i;
      }
    }
    if (bestFull < 0) {
      perPixel = true;
      return;
    }
    // A partial candidate smaller than the full winner could steal pixels.
    for (final i in candidates) {
      if (i == bestFull) continue;
      if (areas[i] < bestFullArea) {
        final b = boxes[i];
        final full = blockLatS >= b[0] &&
            blockLatN <= b[2] &&
            blockLngW >= b[1] &&
            blockLngE <= b[3];
        if (!full) {
          perPixel = true;
          return;
        }
        // Fully-containing and smaller → it IS the better winner.
        bestFull = i;
        bestFullArea = areas[i];
      }
    }
    fastIdx = bestFull;
  }

  /// Per-pixel attribution for one set pixel (only when [perPixel]).
  void attributePixel(double lat, double lng, double cellAreaM2) {
    var best = -1;
    var bestArea = double.infinity;
    for (final i in candidates) {
      final b = boxes[i];
      if (lat < b[0] || lat > b[2]) continue;
      if (lng < b[1] || lng > b[3]) continue;
      if (areas[i] < bestArea) {
        bestArea = areas[i];
        best = i;
      }
    }
    if (best >= 0) out[best] += cellAreaM2;
  }

  Map<String, double> toKm2() =>
      {for (var i = 0; i < keys.length; i++) keys[i]: out[i] / 1e6};
}

/// Background-isolate entry point for [FogEngine.computeAggregates].
/// Everything here is pure CPU over flat arrays — no DB, no Flutter.
Map<String, dynamic> _aggregateFog(Map<String, dynamic> args) {
  final xs = args['xs'] as Int32List;
  final ys = args['ys'] as Int32List;
  final blob = args['blob'] as Uint8List;
  final g1 = _RegionGroup((args['regions'] as Map).cast<String, List<double>>());
  final g2 =
      _RegionGroup((args['regions2'] as Map).cast<String, List<double>>());
  final bboxesIn = (args['bboxes'] as Map).cast<String, List<double>>();
  const bytesPerBlock = FogEngine.bitmapBytes;
  const bmw = FogEngine.bitmapWidth;

  // 256-entry popcount table.
  final pop = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    pop[i] = (i & 1) + pop[i >> 1];
  }

  // Merge duplicate (x,y) blocks across layers into views over the blob;
  // only copy when a duplicate actually needs OR-merging.
  final mergedIdx = <int, int>{}; // key → first row index
  final mergedOwn = <int, Uint8List>{}; // key → merged copy (dup case only)
  for (var i = 0; i < xs.length; i++) {
    final key = xs[i] * 131072 + ys[i];
    final first = mergedIdx[key];
    if (first == null) {
      mergedIdx[key] = i;
    } else {
      final own = mergedOwn.putIfAbsent(
        key,
        () => Uint8List.fromList(Uint8List.sublistView(
            blob, first * bytesPerBlock, (first + 1) * bytesPerBlock)),
      );
      final off = i * bytesPerBlock;
      for (var b = 0; b < bytesPerBlock; b++) {
        own[b] |= blob[off + b];
      }
    }
  }

  final bboxKeys = bboxesIn.keys.toList(growable: false);
  final bboxBoxes = bboxKeys.map((k) => bboxesIn[k]!).toList(growable: false);
  final bboxOut = List<double>.filled(bboxKeys.length, 0);

  double globalM2 = 0;

  for (final entry in mergedIdx.entries) {
    final key = entry.key;
    final tileX = key ~/ 131072;
    final tileY = key % 131072;
    final bm = mergedOwn[key] ??
        Uint8List.sublistView(blob, entry.value * bytesPerBlock,
            (entry.value + 1) * bytesPerBlock);

    final blockLngW = FogEngine.globalXToLng(tileX * 64);
    final blockLngE = FogEngine.globalXToLng((tileX + 1) * 64);
    final blockLatN = FogEngine.globalYToLat(tileY * 64);
    final blockLatS = FogEngine.globalYToLat((tileY + 1) * 64);
    final centerLat = (blockLatN + blockLatS) / 2;
    final mpp = FogEngine._metersPerPixelAt(centerLat);
    final cellAreaM2 = mpp * mpp;

    // Popcount once per block — powers the global number, the fully-inside
    // bbox case and the region fast path.
    var bits = 0;
    for (var b = 0; b < bytesPerBlock; b++) {
      bits += pop[bm[b]];
    }
    if (bits == 0) continue;
    globalM2 += bits * cellAreaM2;

    // Per-bbox accumulation (fully-inside → popcount, partial → per-pixel).
    var bboxNeedsPixels = false;
    for (var bi = 0; bi < bboxBoxes.length; bi++) {
      final b = bboxBoxes[bi];
      if (blockLatS > b[2] || blockLatN < b[0]) continue;
      if (blockLngE < b[1] || blockLngW > b[3]) continue;
      final fullyInside = blockLatS >= b[0] &&
          blockLatN <= b[2] &&
          blockLngW >= b[1] &&
          blockLngE <= b[3];
      if (fullyInside) {
        bboxOut[bi] += bits * cellAreaM2;
      } else {
        bboxNeedsPixels = true;
      }
    }

    // Region groups: block-level classification, fast-path attribution.
    g1.classify(blockLatN, blockLatS, blockLngW, blockLngE);
    if (g1.fastIdx >= 0) g1.out[g1.fastIdx] += bits * cellAreaM2;
    g2.classify(blockLatN, blockLatS, blockLngW, blockLngE);
    if (g2.fastIdx >= 0) g2.out[g2.fastIdx] += bits * cellAreaM2;

    if (!bboxNeedsPixels && !g1.perPixel && !g2.perPixel) continue;

    // ONE pixel loop shared by everything that needs per-pixel work on
    // this (edge) block.
    for (var py = 0; py < bmw; py++) {
      final rowOff = py * 8;
      var any = false;
      for (var b8 = 0; b8 < 8; b8++) {
        if (bm[rowOff + b8] != 0) {
          any = true;
          break;
        }
      }
      if (!any) continue;
      final pxLat = FogEngine.globalYToLat(tileY * 64 + py);
      for (var px = 0; px < bmw; px++) {
        if ((bm[rowOff + (px >> 3)] >> (7 - (px & 7))) & 1 == 0) continue;
        final pxLng = FogEngine.globalXToLng(tileX * 64 + px);
        if (g1.perPixel) g1.attributePixel(pxLat, pxLng, cellAreaM2);
        if (g2.perPixel) g2.attributePixel(pxLat, pxLng, cellAreaM2);
        if (bboxNeedsPixels) {
          for (var bi = 0; bi < bboxBoxes.length; bi++) {
            final b = bboxBoxes[bi];
            if (blockLatS > b[2] || blockLatN < b[0]) continue;
            if (blockLngE < b[1] || blockLngW > b[3]) continue;
            final fullyInside = blockLatS >= b[0] &&
                blockLatN <= b[2] &&
                blockLngW >= b[1] &&
                blockLngE <= b[3];
            if (fullyInside) continue; // already counted via popcount
            if (pxLat < b[0] || pxLat > b[2]) continue;
            if (pxLng < b[1] || pxLng > b[3]) continue;
            bboxOut[bi] += cellAreaM2;
          }
        }
      }
    }
  }

  return <String, dynamic>{
    'global': globalM2 / 1e6,
    'regions': g1.toKm2(),
    'regions2': g2.toKm2(),
    'bboxes': {
      for (var i = 0; i < bboxKeys.length; i++) bboxKeys[i]: bboxOut[i] / 1e6,
    },
  };
}
