import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../data/db/database.dart';
import '../../models/models.dart';
import '../fog/fog_engine.dart';
import '../geo/coord_converter.dart';

/// Renders the explored "fog of war" as ordinary Web-Mercator map tiles, so it
/// is drawn by flutter_map's tile pipeline exactly like the base map: it pans,
/// pinches and zooms pixel-for-pixel with the base imagery, with the corridor
/// thickness FIXED in the baked pixels. There is no per-zoom re-rasterisation
/// or custom painter — that dynamic rendering was the source of the thickness /
/// gesture artifacts.
///
/// Each tile is the FINAL composited fog (inverts the old veil + dstOut erase):
///   - unexplored pixel = veil colour (alpha baked in)
///   - explored pixel   = transparent (shows the bright base map underneath)
/// Drawn over the base-map TileLayer with normal srcOver.
///
/// The fog grid ([FogEngine.full] = 2^22) is exactly Web-Mercator zoom-14
/// pixels, so a tile (z,x,y) maps to fog pixels by pure integer scaling
/// (`pixelsPerTile = full >> z`); GCJ-02 providers (amap/google) apply a small
/// constant per-tile shift so the punch-through lines up with the shifted base.

/// Immutable bake input. Rebuilt with a bumped [generation] whenever the
/// explored rows, veil colour, or map provider change; [generation] is part of
/// the tile-image cache key so Flutter's ImageCache never serves a stale tile.
class FogSnapshot {
  final Color veil; // alpha baked in
  final MapProvider mapProvider;
  final int generation;

  /// Spatial index: FOW-tile bucket `(blockX>>7, blockY>>7)` → rows in it.
  final Map<int, List<FogTile>> _index;
  // Global block extent (inclusive) for a fast all-veil early-out.
  final int _minBX, _maxBX, _minBY, _maxBY;
  final bool isEmpty;

  FogSnapshot._(this.veil, this.mapProvider, this.generation, this._index,
      this._minBX, this._maxBX, this._minBY, this._maxBY, this.isEmpty);

  factory FogSnapshot({
    required List<FogTile> rows,
    required Color veil,
    required MapProvider mapProvider,
    required int generation,
  }) {
    if (rows.isEmpty) {
      return FogSnapshot._(veil, mapProvider, generation, const {}, 0, -1, 0, -1,
          true);
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
    return FogSnapshot._(veil, mapProvider, generation, index, minBX, maxBX,
        minBY, maxBY, false);
  }

  /// Visit every explored block whose global-block coords fall in
  /// [bxMin..bxMax] x [byMin..byMax] (inclusive).
  void forEachBlockInWindow(
      int bxMin, int bxMax, int byMin, int byMax, void Function(FogTile) fn) {
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

/// A flutter_map [TileProvider] that synthesises fog tiles in memory. Holds a
/// mutable [snapshot]; swap it and emit on the layer's `reset` stream to
/// refresh (the snapshot's [generation] busts the image cache).
class FogTileProvider extends TileProvider {
  FogSnapshot snapshot;
  FogTileProvider(this.snapshot);

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _FogTileImage(snapshot, coordinates.x, coordinates.y, coordinates.z,
          options.tileSize.round());
}

@immutable
class _FogTileKey {
  final FogSnapshot snapshot;
  final int x, y, z, dim;
  const _FogTileKey(this.snapshot, this.x, this.y, this.z, this.dim);

  @override
  bool operator ==(Object other) =>
      other is _FogTileKey &&
      other.x == x &&
      other.y == y &&
      other.z == z &&
      other.dim == dim &&
      other.snapshot.generation == snapshot.generation;

  @override
  int get hashCode => Object.hash(x, y, z, dim, snapshot.generation);
}

class _FogTileImage extends ImageProvider<_FogTileKey> {
  final _FogTileKey _key;
  _FogTileImage(FogSnapshot snapshot, int x, int y, int z, int dim)
      : _key = _FogTileKey(snapshot, x, y, z, dim);

  @override
  Future<_FogTileKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(_key);

  @override
  ImageStreamCompleter loadImage(_FogTileKey key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_bake(key));

  static Future<ImageInfo> _bake(_FogTileKey key) async {
    final img = await _bakeTile(key.snapshot, key.x, key.y, key.z, key.dim);
    return ImageInfo(image: img, scale: 1.0);
  }
}

const int _maxBlockIndex = (FogEngine.full >> 6) - 1; // 2^16 - 1

/// Bake one (z,x,y) fog tile of [dim] px. Never throws — on any failure returns
/// a solid-veil tile (the safe fallback, since unexplored == veil).
Future<ui.Image> _bakeTile(
    FogSnapshot snap, int tx, int ty, int z, int dim) async {
  final argb = snap.veil.toARGB32();
  final vA = (argb >> 24) & 0xFF;
  final vR = (argb >> 16) & 0xFF;
  final vG = (argb >> 8) & 0xFF;
  final vB = argb & 0xFF;

  final rgba = Uint8List(dim * dim * 4);
  for (int i = 0; i < rgba.length; i += 4) {
    rgba[i] = vR;
    rgba[i + 1] = vG;
    rgba[i + 2] = vB;
    rgba[i + 3] = vA;
  }

  if (!snap.isEmpty) {
    try {
      _punch(snap, rgba, tx, ty, z, dim);
    } catch (_) {
      // fall back to the solid-veil buffer already filled
    }
  }
  return _decode(rgba, dim);
}

/// Punch explored cells transparent into [rgba]. Pure integer scaling for
/// WGS-84 providers; a constant per-tile shift (computed at the tile centre)
/// for GCJ-02 providers (amap/google) so the holes line up with the shifted
/// base imagery.
void _punch(FogSnapshot snap, Uint8List rgba, int tx, int ty, int z, int dim) {
  const full = FogEngine.full;
  const w = FogEngine.bitmapWidth; // 64
  final ppt = full >> z; // fog pixels per tile
  if (ppt <= 0) return;
  final scale = dim / ppt; // dest px per fog px
  final txPpt = tx * ppt, tyPpt = ty * ppt;

  double shiftX = 0, shiftY = 0;
  if (CoordConverter.needsGcj02(snap.mapProvider)) {
    // Constant shift: where the GCJ tile-centre's WGS coordinate would land if
    // drawn with the plain WGS formula, vs the centre. The GCJ↔WGS offset
    // varies slowly, so one value per tile is accurate to a fraction of a px.
    final worldPx = dim * (1 << z).toDouble();
    final cLatGcj = _mercPxToLat(tyPpt.toDouble() * scale + dim / 2, worldPx);
    final cLngGcj = _mercPxToLng(txPpt.toDouble() * scale + dim / 2, worldPx);
    final wgs = CoordConverter.gcj02ToWgs84(cLatGcj, cLngGcj);
    final wgsGx = FogEngine.lngToGlobalX(wgs.lng).toDouble();
    final wgsGy = FogEngine.latToGlobalY(wgs.lat).toDouble();
    shiftX = dim / 2 - (wgsGx - txPpt) * scale;
    shiftY = dim / 2 - (wgsGy - tyPpt) * scale;
  }

  // Fog-pixel window this tile covers (shifted for GCJ), padded a couple of
  // blocks for the shift / footprint, then clamped and converted to blocks.
  final shiftFogX = shiftX / scale, shiftFogY = shiftY / scale;
  final gxLo = txPpt - shiftFogX, gxHi = txPpt + ppt - shiftFogX;
  final gyLo = tyPpt - shiftFogY, gyHi = tyPpt + ppt - shiftFogY;
  var bxMin = (gxLo / w).floor() - 2, bxMax = (gxHi / w).floor() + 2;
  var byMin = (gyLo / w).floor() - 2, byMax = (gyHi / w).floor() + 2;
  if (bxMin < 0) bxMin = 0;
  if (byMin < 0) byMin = 0;
  if (bxMax > _maxBlockIndex) bxMax = _maxBlockIndex;
  if (byMax > _maxBlockIndex) byMax = _maxBlockIndex;
  if (snap.windowOutsideExtent(bxMin, bxMax, byMin, byMax)) return;

  final coarse = scale * w < 1.0; // a whole block is sub-pixel (low zoom)

  snap.forEachBlockInWindow(bxMin, bxMax, byMin, byMax, (t) {
    final bm = t.bitmap;
    final baseGx = t.tileX * w, baseGy = t.tileY * w;
    if (coarse) {
      var any = false;
      for (var i = 0; i < bm.length; i++) {
        if (bm[i] != 0) {
          any = true;
          break;
        }
      }
      if (!any) return;
      // Light the whole block's footprint so a thin route stays connected.
      _punchSpan(
          rgba,
          ((baseGx - txPpt) * scale + shiftX).floor(),
          ((baseGx + w - txPpt) * scale + shiftX).floor(),
          ((baseGy - tyPpt) * scale + shiftY).floor(),
          ((baseGy + w - tyPpt) * scale + shiftY).floor(),
          dim);
      return;
    }
    for (int py = 0; py < w; py++) {
      final gy = baseGy + py;
      final y0 = ((gy - tyPpt) * scale + shiftY).floor();
      final y1 = ((gy + 1 - tyPpt) * scale + shiftY).floor();
      final rowBase = py * 8;
      for (int byteCol = 0; byteCol < 8; byteCol++) {
        final bval = bm[rowBase + byteCol];
        if (bval == 0) continue;
        for (int bit = 0; bit < 8; bit++) {
          if (((bval >> (7 - bit)) & 1) == 0) continue;
          final gx = baseGx + byteCol * 8 + bit;
          _punchSpan(
              rgba,
              ((gx - txPpt) * scale + shiftX).floor(),
              ((gx + 1 - txPpt) * scale + shiftX).floor(),
              y0,
              y1,
              dim);
        }
      }
    }
  });
}

/// Clear the half-open dest rect [x0,x1) x [y0,y1) to transparent. Always at
/// least 1 px so sub-pixel cells stay connected (never dotted) at low zoom.
void _punchSpan(Uint8List rgba, int x0, int x1, int y0, int y1, int dim) {
  if (x1 <= x0) x1 = x0 + 1;
  if (y1 <= y0) y1 = y0 + 1;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > dim) x1 = dim;
  if (y1 > dim) y1 = dim;
  if (x0 >= dim || y0 >= dim) return;
  for (int yy = y0; yy < y1; yy++) {
    final row = yy * dim;
    for (int xx = x0; xx < x1; xx++) {
      final o = (row + xx) * 4;
      rgba[o] = 0;
      rgba[o + 1] = 0;
      rgba[o + 2] = 0;
      rgba[o + 3] = 0;
    }
  }
}

double _mercPxToLng(double px, double worldPx) => px / worldPx * 360.0 - 180.0;

double _mercPxToLat(double px, double worldPx) {
  final n = math.pi - 2.0 * math.pi * px / worldPx;
  return 180.0 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
}

Future<ui.Image> _decode(Uint8List rgba, int dim) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      rgba, dim, dim, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// The fog grid's native zoom: `full = 2^22 = 256 · 2^14`, so 1 fog cell == 1
/// tile pixel at zoom 14. Above this flutter_map overzooms (scales) the z14
/// tiles — fixed thickness, like the base map past its max native zoom.
const int _kFogNativeZoom = 14;

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
  const FogTileLayer({
    super.key,
    required this.db,
    required this.layerIds,
    required this.veil,
    required this.mapProvider,
    this.refreshKey,
  });

  @override
  State<FogTileLayer> createState() => _FogTileLayerState();
}

class _FogTileLayerState extends State<FogTileLayer> {
  late final FogTileProvider _provider = FogTileProvider(FogSnapshot(
    rows: const [],
    veil: widget.veil,
    mapProvider: widget.mapProvider,
    generation: 0,
  ));
  String _dataKey = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _maybeReload();
  }

  @override
  void didUpdateWidget(covariant FogTileLayer old) {
    super.didUpdateWidget(old);
    _maybeReload();
  }

  void _maybeReload() {
    final key = '${widget.layerIds.join(",")}|${widget.refreshKey}'
        '|${widget.veil.toARGB32()}|${widget.mapProvider}';
    if (key == _dataKey) return;
    _dataKey = key;
    _reload();
  }

  Future<void> _reload() async {
    final ids = widget.layerIds;
    final rows = ids.isEmpty
        ? const <FogTile>[]
        : await widget.db.fogTilesForLayers(ids, FogEngine.tileZoom);
    if (!mounted) return;
    // Bump generation + snapshot, then setState so the rebuilt TileLayer gets a
    // new `additionalOptions` — flutter_map's didUpdateWidget then reloads tiles
    // IN PLACE (old tiles stay until the new bake decodes → no veil flash), and
    // the generation in the image key busts Flutter's ImageCache. (TileLayer's
    // `reset` stream is broken in flutter_map 7.0.2 — its subscription is a
    // `late final` only read in dispose — so we drive refresh via this instead.)
    setState(() {
      _generation++;
      _provider.snapshot = FogSnapshot(
        rows: rows,
        veil: widget.veil,
        mapProvider: widget.mapProvider,
        generation: _generation,
      );
    });
  }

  @override
  Widget build(BuildContext context) => TileLayer(
        tileProvider: _provider,
        // Changing this on a data change is what triggers an in-place reload.
        additionalOptions: {'gen': '$_generation'},
        tileSize: 256,
        maxNativeZoom: _kFogNativeZoom, // overzoom past the fog's native res
        // Instant (no fade) so the veil never flashes semi-transparent while
        // panning or after a data refresh.
        tileDisplay: const TileDisplay.instantaneous(),
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
      );
}
