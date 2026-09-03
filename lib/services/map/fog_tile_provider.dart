import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart'
    show SynchronousFuture, visibleForTesting;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../core/geo_math.dart' as geo;
import '../../data/db/database.dart';
import '../../models/models.dart';
import '../fog/fog_engine.dart';
import '../geo/coord_converter.dart';
import 'tile_providers.dart' show kNativeTileKeepBuffer, kNativeTilePanBuffer;

/// Renders the explored "fog of war" as ordinary Web-Mercator map tiles, so it
/// is drawn by flutter_map's tile pipeline exactly like the base map: it pans,
/// pinches and zooms pixel-for-pixel with the base imagery, with the corridor
/// thickness FIXED in the baked pixels. There is no per-frame re-rasterisation
/// or custom painter — that dynamic rendering was the source of the thickness /
/// gesture artifacts. (Tiles above the fog's native zoom are baked per TILE
/// zoom — still through the same cache-keyed tile pipeline — so high zooms get
/// rounded anti-aliased disc edges instead of scaled-up hard pixels; see
/// [_bakeTileSmooth].)
///
/// Compositing ([FogTileLayer.build] / [_FogCompositor]): a synchronous
/// OPAQUE veil rect is erased by white corridor-mask tiles via dstOut, and
/// the whole group is blended at the fog opacity. Tiles carry only the
/// eraser mask (plus separate tint tiles for coloured layers) — never the
/// translucent veil itself, so flutter_map's cross-zoom tile overlap during
/// a pinch can't double-darken (黑色区块), and a camera jump can't drop the
/// cover (蒙版消失): the veil rect needs no tiles at all.
///
/// The fog grid ([FogEngine.full] = 2^22) is exactly Web-Mercator zoom-14
/// pixels, so a tile (z,x,y) maps to fog pixels by pure integer scaling
/// (`pixelsPerTile = full >> z`); GCJ-02 providers (amap/google) apply a small
/// constant per-tile shift so the punch-through lines up with the shifted base.

/// Immutable bake input. Rebuilt with a bumped [generation] whenever the
/// explored rows, veil colour, layer tints, or map provider change;
/// [generation] is part of the tile-image cache key so Flutter's ImageCache
/// never serves a stale tile.
class FogSnapshot {
  final Color veil; // alpha baked in
  final MapProvider mapProvider;
  final int generation;

  /// Per-layer corridor tint. Absent/null = plain reveal (transparent hole in
  /// the veil). Non-null = the SAME corridor geometry is additionally painted
  /// in this colour (alpha baked in) — one path style, only the colour
  /// differs. Keys are layerIds present in the rows.
  final Map<int, Color> tints;

  /// Spatial index: FOW-tile bucket `(blockX>>7, blockY>>7)` → rows in it.
  final Map<int, List<FogTile>> _index;
  // Global block extent (inclusive) for a fast all-veil early-out.
  final int _minBX, _maxBX, _minBY, _maxBY;
  final bool isEmpty;

  FogSnapshot._(this.veil, this.mapProvider, this.generation, this.tints,
      this._index, this._minBX, this._maxBX, this._minBY, this._maxBY,
      this.isEmpty);

  factory FogSnapshot({
    required List<FogTile> rows,
    required Color veil,
    required MapProvider mapProvider,
    required int generation,
    Map<int, Color> tints = const {},
  }) {
    if (rows.isEmpty) {
      return FogSnapshot._(veil, mapProvider, generation, tints, const {}, 0,
          -1, 0, -1, true);
    }
    final index = <int, List<FogTile>>{};
    var minBX = rows.first.tileX, maxBX = rows.first.tileX;
    var minBY = rows.first.tileY, maxBY = rows.first.tileY;
    for (final t in rows) {
      if (t.tileX < minBX) minBX = t.tileX;
      if (t.tileX > maxBX) maxBX = t.tileX;
      if (t.tileY < minBY) minBY = t.tileY;
      if (t.tileY > maxBY) maxBY = t.tileY;
      final key = ((t.tileX >> 7) << 16) | (t.tileY >> 7);
      (index[key] ??= <FogTile>[]).add(t);
    }
    return FogSnapshot._(veil, mapProvider, generation, tints, index, minBX,
        maxBX, minBY, maxBY, false);
  }

  /// LayerIds that want a coloured corridor, in ascending id order so overlap
  /// resolution is deterministic (later-created layer paints on top).
  List<int> get tintedLayerIds {
    final ids = tints.keys.where((id) => tints[id]!.a > 0).toList()..sort();
    return ids;
  }

  /// Visit every explored block whose global-block coords fall in
  /// [bxMin..bxMax] x [byMin..byMax] (inclusive). [layerId] filters to a
  /// single layer's rows (used for the per-layer tint passes).
  void forEachBlockInWindow(
      int bxMin, int bxMax, int byMin, int byMax, void Function(FogTile) fn,
      {int? layerId}) {
    if (isEmpty) return;
    if (bxMin < 0) bxMin = 0;
    if (byMin < 0) byMin = 0;
    final fxMin = bxMin >> 7, fxMax = bxMax >> 7;
    final fyMin = byMin >> 7, fyMax = byMax >> 7;
    for (int fx = fxMin; fx <= fxMax; fx++) {
      for (int fy = fyMin; fy <= fyMax; fy++) {
        final bucket = _index[(fx << 16) | fy];
        if (bucket == null) continue;
        for (final t in bucket) {
          if (t.tileX < bxMin ||
              t.tileX > bxMax ||
              t.tileY < byMin ||
              t.tileY > byMax) {
            continue;
          }
          if (layerId != null && t.layerId != layerId) continue;
          fn(t);
        }
      }
    }
  }

  bool windowOutsideExtent(int bxMin, int bxMax, int byMin, int byMax) =>
      isEmpty ||
      bxMax < _minBX ||
      bxMin > _maxBX ||
      byMax < _minBY ||
      byMin > _maxBY;
}

/// What a fog tile carries. The veil itself is NOT in the tiles any more —
/// tiles are combined with a full-screen opaque veil by [FogTileLayer]:
///
///   * [mask]: white-where-explored, transparent elsewhere. Erases the veil
///     via dstOut. Erasing is IDEMPOTENT, so when flutter_map keeps stale
///     other-zoom tiles alive through a pinch, overlap changes nothing —
///     the old translucent-veil-per-tile design stacked to near-black
///     ("缩放时的黑色区块") or missed entirely (veil 消失).
///   * [tint]: the coloured-layer corridors (alpha baked in), drawn srcOver
///     on top of the veil composite.
enum FogTileMode { mask, tint }

/// A flutter_map [TileProvider] that synthesises fog tiles in memory. Holds a
/// mutable [snapshot]; swap it and emit on the layer's `reset` stream to
/// refresh (the snapshot's [generation] busts the image cache).
class FogTileProvider extends TileProvider {
  FogSnapshot snapshot;
  final FogTileMode mode;
  FogTileProvider(this.snapshot, {this.mode = FogTileMode.mask});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _FogTileImage(snapshot, coordinates.x, coordinates.y, coordinates.z,
          options.tileSize.round(), mode);
}

@immutable
class _FogTileKey {
  final FogSnapshot snapshot;
  final int x, y, z, dim;
  final FogTileMode mode;
  const _FogTileKey(this.snapshot, this.x, this.y, this.z, this.dim, this.mode);

  @override
  bool operator ==(Object other) =>
      other is _FogTileKey &&
      other.x == x &&
      other.y == y &&
      other.z == z &&
      other.dim == dim &&
      other.mode == mode &&
      other.snapshot.generation == snapshot.generation;

  @override
  int get hashCode => Object.hash(x, y, z, dim, mode, snapshot.generation);
}

class _FogTileImage extends ImageProvider<_FogTileKey> {
  final _FogTileKey _key;
  _FogTileImage(
      FogSnapshot snapshot, int x, int y, int z, int dim, FogTileMode mode)
      : _key = _FogTileKey(snapshot, x, y, z, dim, mode);

  @override
  Future<_FogTileKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(_key);

  @override
  ImageStreamCompleter loadImage(_FogTileKey key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_bake(key));

  static Future<ImageInfo> _bake(_FogTileKey key) async {
    final img = await _bakeTile(
        key.snapshot, key.x, key.y, key.z, key.dim, key.mode);
    return ImageInfo(image: img, scale: 1.0);
  }
}

const int _maxBlockIndex = (FogEngine.full >> 6) - 1; // 2^16 - 1

/// Test seam: bake one tile exactly as the provider would (integer punch at
/// native-and-below zooms, smooth disk pass above). Lets tests rasterise and
/// pin the fog look without a running map.
@visibleForTesting
Future<ui.Image> bakeFogTileForTest(
        FogSnapshot snap, int tx, int ty, int z, int dim,
        {FogTileMode mode = FogTileMode.mask}) =>
    _bakeTile(snap, tx, ty, z, dim, mode);

/// Bake one (z,x,y) fog tile of [dim] px. Never throws — on any failure
/// returns a fully-transparent tile (the safe fallback: nothing is erased
/// from the veil, so the area just stays fogged until re-baked).
Future<ui.Image> _bakeTile(
    FogSnapshot snap, int tx, int ty, int z, int dim, FogTileMode mode) async {
  // Past the fog's native resolution each fog cell spans ≥2 tile px, so the
  // hard integer punch would show as a pixel staircase. Bake those zooms as
  // a disc reveal instead: every explored cell becomes an anti-aliased disk,
  // so corridor edges stay rounded (and crisp — no blur) at any zoom.
  if (z > _kFogNativeZoom && !snap.isEmpty) {
    try {
      return await _bakeTileSmooth(snap, tx, ty, z, dim, mode);
    } catch (_) {
      // fall through to the masked bake below
    }
  }
  if (!snap.isEmpty) {
    try {
      return await _bakeTileMasked(snap, tx, ty, z, dim, mode);
    } catch (_) {
      // fall through to the transparent tile
    }
  }
  final rec = ui.PictureRecorder();
  ui.Canvas(rec); // nothing drawn — fully transparent
  return rec.endRecording().toImage(dim, dim);
}

/// Corridor half-width floor at-and-below the native zoom, in dest px.
/// 0.5 → a trail bottoms out at ~1 px on screen (the mask's own granularity)
/// and otherwise shrinks proportionally with the map — zooming out makes
/// paths thinner, never a constant-screen-width inflation ("缩小后线条特别粗").
const double _kMinHalfPx = 0.5;

/// Native-and-below bake. The exact integer skeleton (every explored cell's
/// true footprint, the same spans the old bit-exact punch produced) is filled
/// into a binary mask; at z14 a small GPU dilate tops the cell up to its
/// ground-proportional width (matching the overzoom disk radius so z14↔z15
/// don't jump), below that the raw ≥1px mask is used as-is.
///
/// [FogTileMode.mask] emits WHITE corridors on transparency (the veil eraser);
/// [FogTileMode.tint] emits the same geometry filled with each coloured
/// layer's tint, ascending id so overlaps resolve deterministically. No blur
/// pass — corridor edges stay crisp ("路径边缘不要光晕"). Bounded by dim²
/// regardless of how dense the explored area is (a per-cell disk pass would
/// explode on dense FOW imports at low zoom).
Future<ui.Image> _bakeTileMasked(
    FogSnapshot snap, int tx, int ty, int z, int dim, FogTileMode mode) async {
  const full = FogEngine.full;
  final ppt = full >> z; // fog px per tile
  if (ppt <= 0) throw StateError('zoom past native');
  final scale = dim / ppt; // dest px per fog px (≤1 here)

  // Corridor sizing: the mask already gives each cell max(scale,1) px, so the
  // dilation only needs to add the difference up to the target half-width.
  final cellHalf = math.max(scale, 1.0) / 2;
  final targetHalf = math.max(scale * 0.78, _kMinHalfPx);
  final dilateR = math.max(0.0, targetHalf - cellHalf);

  // Pad so corridors just outside the tile still dilate across the edge
  // (otherwise every tile border shows a seam).
  final pad = (targetHalf + 1).ceil();
  final mdim = dim + 2 * pad;

  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  // Sub-pixel dilate only (no blur — crisp edges). null = draw the raw mask.
  final filter = dilateR > 0.01
      ? ui.ImageFilter.dilate(radiusX: dilateR, radiusY: dilateR)
      : null;
  final off = ui.Offset(-pad.toDouble(), -pad.toDouble());

  if (mode == FogTileMode.mask) {
    final mask = Uint8List(mdim * mdim);
    if (_fillMask(snap, mask, tx, ty, z, dim, pad)) {
      final maskImg = await _maskToImage(mask, mdim);
      try {
        canvas.drawImage(maskImg, off, ui.Paint()..imageFilter = filter);
      } finally {
        maskImg.dispose();
      }
    }
  } else {
    for (final lid in snap.tintedLayerIds) {
      final lmask = Uint8List(mdim * mdim);
      if (!_fillMask(snap, lmask, tx, ty, z, dim, pad, layerId: lid)) {
        continue;
      }
      final lImg = await _maskToImage(lmask, mdim);
      try {
        canvas.drawImage(
            lImg,
            off,
            ui.Paint()
              ..imageFilter = filter
              ..colorFilter =
                  ui.ColorFilter.mode(snap.tints[lid]!, ui.BlendMode.srcIn));
      } finally {
        lImg.dispose();
      }
    }
  }
  return rec.endRecording().toImage(dim, dim);
}

/// White-where-set alpha image from a byte mask.
Future<ui.Image> _maskToImage(Uint8List mask, int mdim) {
  final rgba = Uint8List(mdim * mdim * 4);
  // One 32-bit store per set pixel instead of four byte stores. Opaque white
  // is 0xFF in every byte, so endianness can't matter.
  final px = Uint32List.view(rgba.buffer);
  for (int i = 0; i < mask.length; i++) {
    if (mask[i] != 0) px[i] = 0xFFFFFFFF;
  }
  return _decode(rgba, mdim);
}

/// Constant per-tile GCJ-02 shift (dest px) so punched holes line up with the
/// shifted base imagery of amap/google. (0,0) for WGS-84 providers.
(double, double) _gcjShift(FogSnapshot snap, int tx, int ty, int z, int dim) {
  if (!CoordConverter.needsGcj02(snap.mapProvider)) return (0, 0);
  const full = FogEngine.full;
  final ppt = full >> z;
  final scale = dim / ppt;
  final txPpt = tx * ppt, tyPpt = ty * ppt;
  // Where the GCJ tile-centre's WGS coordinate would land if drawn with the
  // plain WGS formula, vs the centre. The GCJ↔WGS offset varies slowly, so
  // one value per tile is accurate to a fraction of a px.
  final worldPx = dim * (1 << z).toDouble();
  final cLatGcj =
      geo.worldYToLat((tyPpt.toDouble() * scale + dim / 2) / worldPx);
  final cLngGcj =
      geo.worldXToLng((txPpt.toDouble() * scale + dim / 2) / worldPx);
  final wgs = CoordConverter.gcj02ToWgs84(cLatGcj, cLngGcj);
  final wgsGx = FogEngine.lngToGlobalX(wgs.lng).toDouble();
  final wgsGy = FogEngine.latToGlobalY(wgs.lat).toDouble();
  return (
    dim / 2 - (wgsGx - txPpt) * scale,
    dim / 2 - (wgsGy - tyPpt) * scale,
  );
}

/// Smooth overzoom bake (z > native): the explored cells are drawn as
/// slightly-overlapping anti-aliased disks — rounded corners and merged
/// unions with crisp AA edges (no gaussian feather: the blur read as a hazy
/// "光晕" along every path). Disk radius 0.78·cell keeps diagonal runs
/// connected. [FogTileMode.mask] = white disks on transparency (the veil
/// eraser); [FogTileMode.tint] = the same discs per coloured layer, tinted.
Future<ui.Image> _bakeTileSmooth(
    FogSnapshot snap, int tx, int ty, int z, int dim, FogTileMode mode) async {
  const full = FogEngine.full;
  const w = FogEngine.bitmapWidth; // 64
  final ppt = full >> z; // fog px per tile
  final scale = dim / ppt; // dest px per fog px (2,4,8 for z15..17)
  final txPpt = tx * ppt, tyPpt = ty * ppt;
  final (shiftX, shiftY) = _gcjShift(snap, tx, ty, z, dim);

  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  final dimD = dim.toDouble();

  // Padded fog-px window: disks just outside the tile must still reach
  // across the edge or adjacent tiles would show seams.
  final r = scale * 0.78;
  final padPx = r + 2; // dest px
  final padFog = padPx / scale;
  final shiftFogX = shiftX / scale, shiftFogY = shiftY / scale;
  var bxMin = ((txPpt - shiftFogX - padFog) / w).floor() - 1;
  var bxMax = ((txPpt + ppt - shiftFogX + padFog) / w).floor() + 1;
  var byMin = ((tyPpt - shiftFogY - padFog) / w).floor() - 1;
  var byMax = ((tyPpt + ppt - shiftFogY + padFog) / w).floor() + 1;
  if (bxMin < 0) bxMin = 0;
  if (byMin < 0) byMin = 0;
  if (bxMax > _maxBlockIndex) bxMax = _maxBlockIndex;
  if (byMax > _maxBlockIndex) byMax = _maxBlockIndex;

  if (!snap.windowOutsideExtent(bxMin, bxMax, byMin, byMax)) {
    // Every explored cell is one round-capped point of diameter 2r — the
    // same anti-aliased disc drawCircle produced, but the whole tile goes to
    // the GPU as ONE draw call instead of up to 16k (z15 over a dense FOW
    // import), which is what made a pinch past z14 stutter.
    final disk = ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..isAntiAlias = true
      ..strokeCap = ui.StrokeCap.round
      ..strokeWidth = r * 2;
    final lo = -padPx, hi = dimD + padPx;
    final centres = _PointBuffer();
    void drawDiscs({int? layerId}) {
      centres.clear();
      snap.forEachBlockInWindow(bxMin, bxMax, byMin, byMax, (t) {
        final bm = t.bitmap;
        final baseGx = t.tileX * w, baseGy = t.tileY * w;
        for (int py = 0; py < w; py++) {
          final cy = (baseGy + py + 0.5 - tyPpt) * scale + shiftY;
          if (cy < lo || cy > hi) continue;
          final rowBase = py * 8;
          for (int byteCol = 0; byteCol < 8; byteCol++) {
            final bval = bm[rowBase + byteCol];
            if (bval == 0) continue;
            for (int bit = 0; bit < 8; bit++) {
              if (((bval >> (7 - bit)) & 1) == 0) continue;
              final gx = baseGx + byteCol * 8 + bit;
              final cx = (gx + 0.5 - txPpt) * scale + shiftX;
              if (cx < lo || cx > hi) continue;
              centres.add(cx, cy);
            }
          }
        }
      }, layerId: layerId);
      if (centres.length > 0) {
        canvas.drawRawPoints(ui.PointMode.points, centres.view(), disk);
      }
    }

    if (mode == FogTileMode.mask) {
      // The veil eraser: the union of every layer's discs, in plain white.
      drawDiscs();
    } else {
      // Tint passes: the SAME disc geometry per coloured layer, tinted via a
      // srcIn colour filter at restore time (so overlapping discs inside one
      // layer can't double-blend a translucent colour).
      for (final lid in snap.tintedLayerIds) {
        canvas.saveLayer(
          null,
          ui.Paint()
            ..colorFilter =
                ui.ColorFilter.mode(snap.tints[lid]!, ui.BlendMode.srcIn),
        );
        drawDiscs(layerId: lid);
        canvas.restore();
      }
    }
  }
  return rec.endRecording().toImage(dim, dim);
}

/// Growable flat (x,y,x,y…) buffer for [ui.Canvas.drawRawPoints].
class _PointBuffer {
  Float32List _buf = Float32List(2048);
  int _n = 0; // floats used

  int get length => _n >> 1;

  void clear() => _n = 0;

  void add(double x, double y) {
    if (_n + 2 > _buf.length) {
      final grown = Float32List(_buf.length * 2);
      grown.setRange(0, _n, _buf);
      _buf = grown;
    }
    _buf[_n++] = x;
    _buf[_n++] = y;
  }

  Float32List view() => Float32List.sublistView(_buf, 0, _n);
}

/// Per-row bake accelerators, keyed by row object identity (delta updates
/// replace the row object, so stale entries drop out with their row).
///
/// Low-zoom bakes used to re-scan EVERY row's full 512-byte bitmap for every
/// tile — a country-wide view over a ~46k-row FOW import re-read ~23 MB per
/// tile on the UI isolate, which is where the "缩放的时候很卡" jank came
/// from. Both memos are computed once per row and reused by every tile and
/// every generation the row survives.
final Expando<bool> _rowNonEmpty = Expando('fogRowNonEmpty');
final Expando<Uint8List> _rowSub8 = Expando('fogRowSub8');

bool _nonEmptyOf(FogTile t) {
  final cached = _rowNonEmpty[t];
  if (cached != null) return cached;
  var v = false;
  for (final b in t.bitmap) {
    if (b != 0) {
      v = true;
      break;
    }
  }
  _rowNonEmpty[t] = v;
  return v;
}

/// 8×8-cell sub-block occupancy of a 64×64 block: 64 bits packed into 8
/// bytes, bit (sy*8+sx) set when ANY cell in that sub-block is explored.
Uint8List _sub8Of(FogTile t) {
  var v = _rowSub8[t];
  if (v == null) {
    v = Uint8List(8);
    final bm = t.bitmap;
    for (var py = 0; py < 64; py++) {
      final rowBase = py * 8;
      final sy = py >> 3;
      for (var byteCol = 0; byteCol < 8; byteCol++) {
        if (bm[rowBase + byteCol] != 0) {
          // byteCol == sx: one bitmap byte spans exactly one 8-cell run.
          v[sy] |= 1 << byteCol;
        }
      }
    }
    _rowSub8[t] = v;
  }
  return v;
}

/// Fill the exact integer footprint of every explored cell into [mask] (a
/// (dim+2·pad)² byte grid whose origin is (-pad,-pad) in tile dest space).
/// This is the bit-exact skeleton the old punch produced — pure integer
/// scaling for WGS-84 providers, constant per-tile shift for GCJ-02. Returns
/// true when anything was set. [layerId] restricts to one layer's rows.
bool _fillMask(FogSnapshot snap, Uint8List mask, int tx, int ty, int z,
    int dim, int pad,
    {int? layerId}) {
  const full = FogEngine.full;
  const w = FogEngine.bitmapWidth; // 64
  final ppt = full >> z; // fog pixels per tile
  if (ppt <= 0) return false;
  final scale = dim / ppt; // dest px per fog px
  final txPpt = tx * ppt, tyPpt = ty * ppt;
  final (shiftX, shiftY) = _gcjShift(snap, tx, ty, z, dim);
  final mdim = dim + 2 * pad;

  // Fog-pixel window this tile covers (shifted for GCJ), padded for the mask
  // margin + a couple of blocks, then clamped and converted to blocks.
  final shiftFogX = shiftX / scale, shiftFogY = shiftY / scale;
  final padFog = pad / scale;
  final gxLo = txPpt - shiftFogX - padFog, gxHi = txPpt + ppt - shiftFogX + padFog;
  final gyLo = tyPpt - shiftFogY - padFog, gyHi = tyPpt + ppt - shiftFogY + padFog;
  var bxMin = (gxLo / w).floor() - 2, bxMax = (gxHi / w).floor() + 2;
  var byMin = (gyLo / w).floor() - 2, byMax = (gyHi / w).floor() + 2;
  if (bxMin < 0) bxMin = 0;
  if (byMin < 0) byMin = 0;
  if (bxMax > _maxBlockIndex) bxMax = _maxBlockIndex;
  if (byMax > _maxBlockIndex) byMax = _maxBlockIndex;
  if (snap.windowOutsideExtent(bxMin, bxMax, byMin, byMax)) return false;

  // Three resolution tiers, chosen by how many dest px one 64-cell block
  // spans. Coarser tiers read the per-row memos instead of the raw bitmap,
  // so a country-wide view never re-scans megabytes per tile, and corridor
  // width degrades in uniform ≥1px steps instead of jumping ("缩小很多之后
  // 路径不清晰、粗细不对").
  final blockPx = scale * w;
  final coarse = blockPx < 1.0; // a whole block is sub-pixel
  final subblock = !coarse && blockPx <= 8.0; // an 8×8 sub-block is ≤1px
  var any = false;

  snap.forEachBlockInWindow(bxMin, bxMax, byMin, byMax, (t) {
    final bm = t.bitmap;
    final baseGx = t.tileX * w, baseGy = t.tileY * w;
    if (coarse) {
      if (!_nonEmptyOf(t)) return;
      // Light the whole block's footprint so a thin route stays connected.
      any = _maskSpan(
              mask,
              ((baseGx - txPpt) * scale + shiftX).floor() + pad,
              ((baseGx + w - txPpt) * scale + shiftX).floor() + pad,
              ((baseGy - tyPpt) * scale + shiftY).floor() + pad,
              ((baseGy + w - tyPpt) * scale + shiftY).floor() + pad,
              mdim) ||
          any;
      return;
    }
    if (subblock) {
      final sub = _sub8Of(t);
      for (var sy = 0; sy < 8; sy++) {
        final bits = sub[sy];
        if (bits == 0) continue;
        final gy0 = baseGy + sy * 8;
        final y0 = ((gy0 - tyPpt) * scale + shiftY).floor() + pad;
        final y1 = ((gy0 + 8 - tyPpt) * scale + shiftY).floor() + pad;
        for (var sx = 0; sx < 8; sx++) {
          if ((bits >> sx) & 1 == 0) continue;
          final gx0 = baseGx + sx * 8;
          any = _maskSpan(
                  mask,
                  ((gx0 - txPpt) * scale + shiftX).floor() + pad,
                  ((gx0 + 8 - txPpt) * scale + shiftX).floor() + pad,
                  y0,
                  y1,
                  mdim) ||
              any;
        }
      }
      return;
    }
    // Per-cell tier (z12–14). Walk 8×8 sub-blocks through the same occupancy
    // memo the sub-block tier uses, so the 512-byte bitmap is only read where
    // something is set: a typical GPS corridor lights a handful of the 64
    // sub-blocks, and z12 used to test all 4096 bits of every block in the
    // window — the 64× cost cliff between z11 and z12 that pinches always
    // crossed.
    final sub = _sub8Of(t);
    for (int sy = 0; sy < 8; sy++) {
      final bits = sub[sy];
      if (bits == 0) continue;
      for (int py = sy << 3; py < (sy << 3) + 8; py++) {
        final gy = baseGy + py;
        final y0 = ((gy - tyPpt) * scale + shiftY).floor() + pad;
        final y1 = ((gy + 1 - tyPpt) * scale + shiftY).floor() + pad;
        final rowBase = py * 8;
        for (int byteCol = 0; byteCol < 8; byteCol++) {
          if ((bits >> byteCol) & 1 == 0) continue;
          final bval = bm[rowBase + byteCol];
          if (bval == 0) continue;
          for (int bit = 0; bit < 8; bit++) {
            if (((bval >> (7 - bit)) & 1) == 0) continue;
            final gx = baseGx + byteCol * 8 + bit;
            any = _maskSpan(
                    mask,
                    ((gx - txPpt) * scale + shiftX).floor() + pad,
                    ((gx + 1 - txPpt) * scale + shiftX).floor() + pad,
                    y0,
                    y1,
                    mdim) ||
                any;
          }
        }
      }
    }
  }, layerId: layerId);
  return any;
}

/// Set the half-open rect [x0,x1) x [y0,y1) in [mask]. Always at least 1 px
/// so sub-pixel cells stay connected (never dotted) at low zoom. Returns true
/// when at least one byte was set.
bool _maskSpan(Uint8List mask, int x0, int x1, int y0, int y1, int mdim) {
  if (x1 <= x0) x1 = x0 + 1;
  if (y1 <= y0) y1 = y0 + 1;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > mdim) x1 = mdim;
  if (y1 > mdim) y1 = mdim;
  if (x0 >= mdim || y0 >= mdim || x1 <= x0 || y1 <= y0) return false;
  for (int yy = y0; yy < y1; yy++) {
    final row = yy * mdim;
    for (int xx = x0; xx < x1; xx++) {
      mask[row + xx] = 1;
    }
  }
  return true;
}

Future<ui.Image> _decode(Uint8List rgba, int dim) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      rgba, dim, dim, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// The fog grid's native zoom: `full = 2^22 = 256 · 2^14`, so 1 fog cell == 1
/// tile pixel at zoom 14. At and below this the integer punch is exact.
const int _kFogNativeZoom = 14;

/// Highest zoom we bake real tiles for. Between native+1 and here each tile
/// is baked with the smooth disk+feather pass (cells span 2/4/8 px — a hard
/// punch would be a visible staircase). Past this flutter_map overzooms the
/// z17 tiles, whose edges are already soft, so they stay smooth when scaled.
const int _kFogMaxNativeZoom = 17;

/// Shared gesture-coalescing tile updater for every baked-in-memory layer
/// (fog, heat). One pass 120 ms after events stop, and at least one every
/// 400 ms during a long gesture — see [_FogTileLayerState._coalesced].
final TileUpdateTransformer coalescedTileUpdates = coalescedTileUpdateTransformer(
  quiet: const Duration(milliseconds: 120),
  maxWait: const Duration(milliseconds: 400),
);

/// Build a [TileUpdateTransformer] that swallows the per-frame MapEvents of a
/// gesture and emits the LATEST one once things go quiet for [quiet], or at
/// the latest every [maxWait] while the gesture continues.
TileUpdateTransformer coalescedTileUpdateTransformer(
    {required Duration quiet, required Duration maxWait}) {
  Timer? quietTimer, maxTimer;
  TileUpdateEvent? pending;
  return StreamTransformer.fromHandlers(
    handleData: (event, sink) {
      if (event.wasTriggeredByTap()) return;
      pending = event;
      void emit() {
        quietTimer?.cancel();
        maxTimer?.cancel();
        quietTimer = null;
        maxTimer = null;
        final e = pending;
        pending = null;
        if (e != null) sink.add(e);
      }

      quietTimer?.cancel();
      quietTimer = Timer(quiet, emit);
      maxTimer ??= Timer(maxWait, emit);
    },
    handleDone: (sink) {
      quietTimer?.cancel();
      maxTimer?.cancel();
      sink.close();
    },
  );
}

/// Drop-in flutter_map layer that draws the explored fog as baked tiles. Owns
/// the [FogTileProvider] + a persistent reset stream; loads the explored rows
/// for the visible layers and re-bakes (via the reset stream + a bumped
/// generation) whenever the layer set, veil colour, provider, or [refreshKey]
/// changes. Place it directly above the base-map TileLayer.
class FogTileLayer extends StatefulWidget {
  final AppDb db;
  final List<int> layerIds;
  final Color veil;
  final MapProvider mapProvider;
  final Object? refreshKey;

  /// Per-layer corridor tint (alpha baked in). Layers absent here render as
  /// plain transparent reveals; layers present render the same corridor
  /// geometry filled with the colour.
  final Map<int, Color> tints;

  /// Optional live-edit feed ([FogEngine.changes]). Rows arriving here are
  /// merged into the in-memory snapshot instead of re-reading the whole
  /// fog_tiles table — recording at 1 Hz used to trigger a full-table read
  /// (~45k rows after a FOW import) every refresh tick.
  final Stream<List<FogTile>>? changes;
  const FogTileLayer({
    super.key,
    required this.db,
    required this.layerIds,
    required this.veil,
    required this.mapProvider,
    this.tints = const {},
    this.refreshKey,
    this.changes,
  });

  @override
  State<FogTileLayer> createState() => _FogTileLayerState();

  /// Tell the fog layer whether a map gesture is in progress; live-recording
  /// re-bakes are deferred while it is. Wire to the map's pointer listener.
  static void setGestureActive(bool active) {
    if (_FogTileLayerState.gestureActive.value != active) {
      _FogTileLayerState.gestureActive.value = active;
    }
  }
}

class _FogTileLayerState extends State<FogTileLayer> {
  /// True while a finger is on the map (set by the map screen's pointer
  /// listener). A live-recording publish re-bakes every retained fog tile;
  /// doing that mid-pinch is the worst possible moment, so publishes are
  /// held until the gesture ends (see [_applyDelta]).
  static final ValueNotifier<bool> gestureActive = ValueNotifier(false);

  /// Monotonic base across ALL FogTileLayer instances in this process. The
  /// baked-tile ImageCache key is (x,y,z,dim,generation) — if every state
  /// started again at generation 0, leaving and re-entering the map would
  /// collide with cached tiles baked from a DIFFERENT snapshot.
  static int _generationSeed = 0;

  late final FogTileProvider _maskProvider = FogTileProvider(_emptySnapshot());
  late final FogTileProvider _tintProvider =
      FogTileProvider(_emptySnapshot(), mode: FogTileMode.tint);

  FogSnapshot _emptySnapshot() => FogSnapshot(
        rows: const [],
        veil: widget.veil,
        mapProvider: widget.mapProvider,
        generation: _generation,
      );
  String _dataKey = '';
  late int _generation = (_generationSeed += 1 << 20);

  /// In-memory mirror of the visible layers' fog rows, keyed by
  /// (tileX,tileY,layerId). Full reloads replace it; delta events patch it.
  final Map<int, FogTile> _rows = {};
  StreamSubscription<List<FogTile>>? _changesSub;

  /// Throttles live-recording publishes. Every publish bumps [_generation]
  /// and re-bakes EVERY visible fog tile — at 1 Hz recording the tile
  /// pyramid never reaches flutter_map's "all current-zoom tiles loaded"
  /// state, so stale other-zoom tiles are kept alive through a pinch and the
  /// two TRANSLUCENT veils stack up (veil² ≈ 近黑的"未加载黑色区块"). A
  /// recording reveal can lag a couple of seconds; a black flash cannot.
  Timer? _deltaThrottle;
  bool _deltaDirty = false;

  // tileX/tileY are block-global (< 2^16), layerId is small — pack the three
  // into one int key so the hot merge path doesn't allocate strings.
  static int _key(FogTile t) =>
      (t.layerId << 32) | (t.tileX << 16) | t.tileY;

  @override
  void initState() {
    super.initState();
    _subscribe();
    _maybeReload();
  }

  @override
  void didUpdateWidget(covariant FogTileLayer old) {
    super.didUpdateWidget(old);
    if (!identical(old.changes, widget.changes)) _subscribe();
    _maybeReload();
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _deltaThrottle?.cancel();
    super.dispose();
  }

  void _subscribe() {
    _changesSub?.cancel();
    _changesSub = widget.changes?.listen(_applyDelta);
  }

  void _applyDelta(List<FogTile> rows) {
    if (!mounted) return;
    var relevant = false;
    for (final t in rows) {
      if (t.zoom != FogEngine.tileZoom) continue;
      if (!widget.layerIds.contains(t.layerId)) continue;
      _rows[_key(t)] = t;
      relevant = true;
    }
    if (!relevant) return;
    // First delta publishes immediately; the rest of a recording burst is
    // batched every few seconds (see [_deltaThrottle]).
    if (_deltaThrottle?.isActive ?? false) {
      _deltaDirty = true;
      return;
    }
    if (gestureActive.value) {
      // Never re-bake the whole pyramid under a moving finger — hold it and
      // let the throttle expiry retry once the gesture is over.
      _deltaDirty = true;
      _armDeltaThrottle();
      return;
    }
    _publish();
    _armDeltaThrottle();
  }

  /// While the throttle window is armed, deltas only mark [_deltaDirty];
  /// each expiry flushes at most one publish and re-arms until quiet. An
  /// expiry that lands mid-gesture re-arms (shorter) without publishing.
  void _armDeltaThrottle() {
    final wait = gestureActive.value
        ? const Duration(milliseconds: 500)
        : const Duration(seconds: 3);
    _deltaThrottle = Timer(wait, () {
      if (!mounted) return;
      if (!_deltaDirty) return;
      if (gestureActive.value) {
        _armDeltaThrottle();
        return;
      }
      _deltaDirty = false;
      _publish();
      _armDeltaThrottle();
    });
  }

  void _maybeReload() {
    final tintSig = (widget.tints.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key}:${e.value.toARGB32()}')
        .join(',');
    final key = '${widget.layerIds.join(",")}|${widget.refreshKey}'
        '|${widget.veil.toARGB32()}|${widget.mapProvider}|$tintSig';
    if (key == _dataKey) return;
    _dataKey = key;
    _reload();
  }

  Future<void> _reload() async {
    final ids = widget.layerIds;
    final sw = Stopwatch()..start();
    final rows = ids.isEmpty
        ? const <FogTile>[]
        : await widget.db.fogTilesForLayers(ids, FogEngine.tileZoom);
    if (!mounted) return;
    // DIAG: which layers the map actually reads fog from. Compare against the
    // [FOW] import log's activeLayer — a mismatch is why re-imported fog after a
    // clear "没了" (written to a layer the map doesn't render). The timing is
    // the whole query + row materialisation for a full-table read.
    debugPrint('[FOG] reload visibleLayers=$ids → loaded=${rows.length} tiles '
        'in ${sw.elapsedMilliseconds}ms');
    _rows
      ..clear()
      ..addEntries(rows.map((t) => MapEntry(_key(t), t)));
    _publish();
  }

  /// Bump generation + snapshot, then setState so the rebuilt TileLayer gets a
  /// new `additionalOptions` — flutter_map's didUpdateWidget then reloads tiles
  /// IN PLACE (old tiles stay until the new bake decodes → no veil flash), and
  /// the generation in the image key busts Flutter's ImageCache. (TileLayer's
  /// `reset` stream is broken in flutter_map 7.0.2 — its subscription is a
  /// `late final` only read in dispose — so we drive refresh via this instead.)
  void _publish() {
    setState(() {
      _generation++;
      final snap = FogSnapshot(
        rows: _rows.values.toList(growable: false),
        veil: widget.veil,
        mapProvider: widget.mapProvider,
        generation: _generation,
        tints: widget.tints,
      );
      _maskProvider.snapshot = snap;
      _tintProvider.snapshot = snap;
    });
  }

  /// Fog tile updates during a gesture. Every MapEvent (one per pinch FRAME)
  /// used to run load+prune, so the moment `zoom.round()` crossed a .5
  /// boundary mid-pinch a whole new pyramid level was baked on the UI
  /// isolate, in the gesture frame. This coalesces: nothing happens while
  /// events keep coming, ONE pass fires 120 ms after they stop (fingers
  /// lifted / fling settled), and a long continuous gesture still gets a
  /// pass at least every 400 ms so a slow pan never runs out of tiles.
  /// Meanwhile the retained tiles are simply rescaled — the same thing the
  /// reference WebGL fog does through a zoom animation.
  static final TileUpdateTransformer _coalesced = coalescedTileUpdates;

  TileLayer _tiles(FogTileProvider provider, String kind) => TileLayer(
        // Remount when the snapshot flips empty↔non-empty. The in-place
        // reload below only re-bakes TileImages that ALREADY exist — on a
        // cold start the fog rows arrive from the DB after the layer
        // mounted, and if no tile had loaded yet (camera not laid out, no
        // map event since) nothing would ever load until the user pans or
        // zooms ("地图没有迷雾，点一下定位才出现"). A remount is guaranteed
        // to run a fresh load-and-prune pass against the current camera.
        key: ValueKey('fog-$kind-${_rows.isEmpty ? 'empty' : 'data'}'),
        tileProvider: provider,
        // Changing this on a data change is what triggers an in-place reload.
        additionalOptions: {'gen': '$_generation'},
        tileSize: 256,
        maxNativeZoom: _kFogMaxNativeZoom, // smooth-baked past the native res
        // Same off-screen ring as the base map (see tile_providers.dart) —
        // with fewer fog tiles kept than base tiles, the base stayed while
        // the fog was pruned and the strip showed veil over visible imagery.
        keepBuffer: kNativeTileKeepBuffer,
        panBuffer: kNativeTilePanBuffer,
        tileUpdateTransformer: _coalesced,
        // Instant (no fade) so the veil never flashes semi-transparent while
        // panning or after a data refresh.
        tileDisplay: const TileDisplay.instantaneous(),
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
      );

  @override
  Widget build(BuildContext context) {
    final hasTints = widget.tints.values.any((c) => c.a > 0);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Veil + eraser, composited as ONE translucent group:
        //   saveLayer(alpha = veil opacity)
        //     ├─ opaque veil rect (synchronous — the cover can never vanish,
        //     │  however far a locate-jump moves the camera)
        //     └─ dstOut ⊕ white corridor-mask tiles (erasing is idempotent,
        //        so flutter_map's stale other-zoom tiles overlapping during
        //        a pinch can't double-darken — the old translucent-veil
        //        tiles stacked to near-black "缩放黑色区块")
        _FogCompositor(
          veil: widget.veil,
          child: _tiles(_maskProvider, 'mask'),
        ),
        // Coloured corridors on top (alpha baked into the tint tiles).
        if (hasTints) _tiles(_tintProvider, 'tint'),
      ],
    );
  }
}

/// Paints an opaque veil rect, then erases its child's alpha out of it
/// (dstOut), inside one translucent saveLayer group — see [FogTileLayer.build].
class _FogCompositor extends SingleChildRenderObjectWidget {
  final Color veil;
  const _FogCompositor({required this.veil, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFogCompositor(veil);

  @override
  void updateRenderObject(
      BuildContext context, _RenderFogCompositor renderObject) {
    renderObject.veil = veil;
  }
}

class _RenderFogCompositor extends RenderProxyBox {
  _RenderFogCompositor(this._veil);

  Color _veil;
  set veil(Color v) {
    if (v == _veil) return;
    _veil = v;
    markNeedsPaint();
  }

  Color get veil => _veil;

  // The mask must rasterise into THIS canvas's layer for the colour filter
  // below to see it — never let the child subtree get its own compositing
  // layer.
  @override
  bool get alwaysNeedsCompositing => false;

  /// 5×4 colour matrix that turns the composited corridor masks into the
  /// veil itself: constant veil RGB, alpha = veilAlpha · (1 − maskAlpha).
  /// Mask-free pixels (nothing baked, camera jumped, tile still loading)
  /// therefore come out as full veil — the cover can never vanish — and
  /// erasing stays idempotent: overlapping white tiles composite (srcOver)
  /// to a1 + a2(1−a1), so the veil left is (1−a1)(1−a2), exactly what two
  /// successive dstOut erases produced.
  static List<double> veilMatrix(Color veil) {
    final a = veil.a;
    return <double>[
      0, 0, 0, 0, veil.r * 255.0, //
      0, 0, 0, 0, veil.g * 255.0, //
      0, 0, 0, 0, veil.b * 255.0, //
      0, 0, 0, -a, a * 255.0,
    ];
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final rect = offset & size;
    // ONE full-screen offscreen group instead of the previous two (an
    // opacity group holding an opaque veil rect + a dstOut group for the
    // masks). Both approaches yield identical pixels; the extra saveLayer was
    // a fixed per-frame raster-thread cost the whole time the map moved.
    context.canvas.saveLayer(
        rect, ui.Paint()..colorFilter = ui.ColorFilter.matrix(veilMatrix(_veil)));
    super.paint(context, offset);
    context.canvas.restore();
  }
}

/// Test seam: the veil compositor around an arbitrary child, so a test can
/// paint a known mask and check the resulting veil pixels.
@visibleForTesting
Widget fogCompositorForTest({required Color veil, required Widget child}) =>
    _FogCompositor(veil: veil, child: child);
