import 'dart:math' as math;
import 'dart:typed_data';
import 'package:drift/drift.dart' show Value;
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
    await db.upsertFogTile(FogTilesCompanion.insert(
      tileX: dbX,
      tileY: dbY,
      zoom: tileZoom,
      layerId: layerId,
      bitmap: bytes,
      updatedAt: DateTime.now(),
    ));
  }

  /// Erases exactly one FOW pixel at the given GPS position (WGS-84).
  Future<void> eraseSinglePixel({
    required double lat,
    required double lng,
    required int layerId,
  }) async {
    final gx = lngToGlobalX(lng);
    final gy = latToGlobalY(lat);
    final dx = decompose(gx);
    final dy = decompose(gy);
    final dbX = _dbX(dx.tile, dx.block);
    final dbY = _dbY(dy.tile, dy.block);

    final existing = await db.getFogTile(dbX, dbY, tileZoom, layerId);
    if (existing == null) return;
    final bytes = Uint8List.fromList(existing.bitmap);

    if (!isSet(bytes, dx.pixel, dy.pixel)) return; // already clear

    clearBit(bytes, dx.pixel, dy.pixel);
    await db.upsertFogTile(FogTilesCompanion(
      tileX: Value(dbX),
      tileY: Value(dbY),
      zoom: Value(tileZoom),
      layerId: Value(layerId),
      bitmap: Value(bytes),
      updatedAt: Value(DateTime.now()),
    ));
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
      await db.upsertFogTile(FogTilesCompanion.insert(
        tileX: dbX,
        tileY: dbY,
        zoom: tileZoom,
        layerId: layerId,
        bitmap: bytes,
        updatedAt: DateTime.now(),
      ));
    }
  }

  Future<void> revealPoint({
    required double lat,
    required double lng,
    required double radiusMeters,
    required int layerId,
  }) async {
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

      await db.upsertFogTile(FogTilesCompanion.insert(
        tileX: dbX,
        tileY: dbY,
        zoom: tileZoom,
        layerId: layerId,
        bitmap: bytes,
        updatedAt: DateTime.now(),
      ));
    }
  }

  /// Erase fog around a point.
  Future<void> erase({
    required double lat,
    required double lng,
    required double radiusMeters,
    required int layerId,
  }) async {
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

    for (final edit in touched.values) {
      final dbX = _dbX(edit.tileX, edit.blockX);
      final dbY = _dbY(edit.tileY, edit.blockY);
      final existing = await db.getFogTile(dbX, dbY, tileZoom, layerId);
      if (existing == null) continue;
      final bytes = Uint8List.fromList(existing.bitmap);

      for (final (px, py) in edit.sets) {
        clearBit(bytes, px, py);
      }

      await db.upsertFogTile(FogTilesCompanion(
        tileX: Value(dbX),
        tileY: Value(dbY),
        zoom: Value(tileZoom),
        layerId: Value(layerId),
        bitmap: Value(bytes),
        updatedAt: Value(DateTime.now()),
      ));
    }
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
    final km2 = await revealedAreaInBboxKm2(
      layerIds,
      minLat: -85.05,
      minLng: -180,
      maxLat: 85.05,
      maxLng: 180,
    );
    return (km2 / earthSurfaceKm2).clamp(0.0, 1.0);
  }

  /// Meters per global pixel at given latitude.
  static double _metersPerPixelAt(double lat) {
    const earthCircumference = 40075016.686;
    return earthCircumference * math.cos(lat * math.pi / 180.0) / full;
  }

  /// Area in km² actually revealed *inside* the given lat/lng bbox.
  /// Replaces the previous bbox-grid-sampling approach in the explore
  /// screen, which falsely reported 100% for small regions whose bbox
  /// happened to fall inside a single revealed block.
  ///
  /// Mechanism: walks every (tileX, tileY) we have a row for, OR-merges
  /// duplicates per layer, then for each block intersecting the bbox sums
  /// the area of every set pixel whose center is inside the bbox. Pixel
  /// area is weighted by latitude (Mercator-correct).
  Future<double> revealedAreaInBboxKm2(
    List<int> layerIds, {
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
  }) async {
    if (layerIds.isEmpty) return 0;
    final tiles = await db.fogTilesForLayers(layerIds, tileZoom);
    if (tiles.isEmpty) return 0;

    // Merge bitmaps across layers (so multi-layer users see the union).
    final merged = <String, Uint8List>{};
    for (final t in tiles) {
      final k = '${t.tileX}_${t.tileY}';
      final cur = merged[k];
      if (cur == null) {
        merged[k] = Uint8List.fromList(t.bitmap);
      } else {
        for (int i = 0; i < cur.length; i++) {
          cur[i] |= t.bitmap[i];
        }
      }
    }

    double areaM2 = 0;
    for (final entry in merged.entries) {
      final parts = entry.key.split('_');
      final tileX = int.parse(parts[0]);
      final tileY = int.parse(parts[1]);
      // Block bbox in lat/lng (each block = 64×64 global pixels).
      final blockLngW = globalXToLng(tileX * 64);
      final blockLngE = globalXToLng((tileX + 1) * 64);
      // y increases southward, so lat at smaller y is north.
      final blockLatN = globalYToLat(tileY * 64);
      final blockLatS = globalYToLat((tileY + 1) * 64);
      // Reject blocks that don't intersect the bbox at all.
      if (blockLatS > maxLat || blockLatN < minLat) continue;
      if (blockLngE < minLng || blockLngW > maxLng) continue;

      final centerLat = (blockLatN + blockLatS) / 2;
      final mpp = _metersPerPixelAt(centerLat);
      final cellAreaM2 = mpp * mpp;

      final fullyInside = blockLatS >= minLat &&
          blockLatN <= maxLat &&
          blockLngW >= minLng &&
          blockLngE <= maxLng;

      if (fullyInside) {
        // Hot path — popcount all 512 bytes.
        int bits = 0;
        for (final byte in entry.value) {
          var v = byte;
          while (v != 0) {
            v &= v - 1;
            bits++;
          }
        }
        areaM2 += bits * cellAreaM2;
      } else {
        // Cold path — per-pixel inclusion test for partial overlap.
        for (int py = 0; py < bitmapWidth; py++) {
          final pxLat = globalYToLat(tileY * 64 + py);
          if (pxLat < minLat || pxLat > maxLat) continue;
          for (int px = 0; px < bitmapWidth; px++) {
            if (!isSet(entry.value, px, py)) continue;
            final pxLng = globalXToLng(tileX * 64 + px);
            if (pxLng < minLng || pxLng > maxLng) continue;
            areaM2 += cellAreaM2;
          }
        }
      }
    }
    return areaM2 / 1000000.0;
  }

  /// Variant of [revealedAreaInBboxKm2] that processes MULTIPLE bboxes in
  /// one DB walk, attributing each revealed pixel to **exactly one** region
  /// — the smallest-area bbox that contains the pixel center. This fixes
  /// the "Shanghai shows up in Jiangsu + Zhejiang + Shanghai" triple-count
  /// bug from the previous per-region call, where overlapping bundled
  /// bboxes (which are coarse axis-aligned rects) all matched the same
  /// point.
  ///
  /// Input: a map of `key → bbox`. The key can be anything you like
  /// (e.g. `"中国|上海"`); output is `key → revealed km²` plus the bytes
  /// the engine scanned (for diagnostics).
  Future<Map<String, double>> revealedAreaByRegionsKm2(
    List<int> layerIds, {
    required Map<String, ({double minLat, double minLng, double maxLat, double maxLng})> regions,
  }) async {
    final out = <String, double>{for (final k in regions.keys) k: 0.0};
    if (layerIds.isEmpty || regions.isEmpty) return out;
    final tiles = await db.fogTilesForLayers(layerIds, tileZoom);
    if (tiles.isEmpty) return out;

    // Pre-compute bbox area for tie-breaking. We pick the bbox with the
    // smallest *area* containing a point — most-specific wins.
    final areas = <String, double>{
      for (final e in regions.entries)
        e.key: (e.value.maxLat - e.value.minLat) *
            (e.value.maxLng - e.value.minLng),
    };

    // Merge bitmaps across layers.
    final merged = <String, Uint8List>{};
    for (final t in tiles) {
      final k = '${t.tileX}_${t.tileY}';
      final cur = merged[k];
      if (cur == null) {
        merged[k] = Uint8List.fromList(t.bitmap);
      } else {
        for (int i = 0; i < cur.length; i++) {
          cur[i] |= t.bitmap[i];
        }
      }
    }

    String? pickRegionForPixel(double lat, double lng) {
      String? best;
      double bestArea = double.infinity;
      for (final entry in regions.entries) {
        final b = entry.value;
        if (lat < b.minLat || lat > b.maxLat) continue;
        if (lng < b.minLng || lng > b.maxLng) continue;
        final a = areas[entry.key]!;
        if (a < bestArea) {
          bestArea = a;
          best = entry.key;
        }
      }
      return best;
    }

    for (final entry in merged.entries) {
      final parts = entry.key.split('_');
      final tileX = int.parse(parts[0]);
      final tileY = int.parse(parts[1]);
      // Block bbox in lat/lng.
      final blockLngW = globalXToLng(tileX * 64);
      final blockLngE = globalXToLng((tileX + 1) * 64);
      final blockLatN = globalYToLat(tileY * 64);
      final blockLatS = globalYToLat((tileY + 1) * 64);
      final centerLat = (blockLatN + blockLatS) / 2;
      final mpp = _metersPerPixelAt(centerLat);
      final cellAreaM2 = mpp * mpp;

      // Cheap pre-filter: does this block intersect ANY region's bbox at
      // all? If not, every pixel will pick `null` and we can skip the
      // inner loop.
      bool maybeOverlaps = false;
      for (final r in regions.values) {
        if (blockLatS > r.maxLat || blockLatN < r.minLat) continue;
        if (blockLngE < r.minLng || blockLngW > r.maxLng) continue;
        maybeOverlaps = true;
        break;
      }
      if (!maybeOverlaps) continue;

      for (int py = 0; py < bitmapWidth; py++) {
        final pxLat = globalYToLat(tileY * 64 + py);
        for (int px = 0; px < bitmapWidth; px++) {
          if (!isSet(entry.value, px, py)) continue;
          final pxLng = globalXToLng(tileX * 64 + px);
          final k = pickRegionForPixel(pxLat, pxLng);
          if (k == null) continue;
          out[k] = out[k]! + cellAreaM2;
        }
      }
    }

    // m² → km²
    return out.map((k, v) => MapEntry(k, v / 1000000.0));
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
}

class _BlockEdit {
  final int tileX, tileY, blockX, blockY;
  final List<(int, int)> sets = [];
  _BlockEdit(this.tileX, this.tileY, this.blockX, this.blockY);
}
