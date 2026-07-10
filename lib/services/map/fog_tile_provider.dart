import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart'
    show SynchronousFuture, visibleForTesting;
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../data/db/database.dart';
import '../../models/models.dart';
import '../fog/fog_engine.dart';
import '../geo/coord_converter.dart';

/// Renders the explored "fog of war" as ordinary Web-Mercator map tiles, so it
/// is drawn by flutter_map's tile pipeline exactly like the base map: it pans,
/// pinches and zooms pixel-for-pixel with the base imagery, with the corridor
/// thickness FIXED in the baked pixels. There is no per-frame re-rasterisation
/// or custom painter — that dynamic rendering was the source of the thickness /
/// gesture artifacts. (Tiles above the fog's native zoom are baked per TILE
/// zoom — still through the same cache-keyed tile pipeline — so high zooms get
/// smooth feathered edges instead of scaled-up hard pixels; see
/// [_bakeTileSmooth].)
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

/// Test seam: bake one tile exactly as the provider would (integer punch at
/// native-and-below zooms, smooth disk+feather pass above). Lets tests
/// rasterise and pin the fog look without a running map.
@visibleForTesting
Future<ui.Image> bakeFogTileForTest(
        FogSnapshot snap, int tx, int ty, int z, int dim) =>
    _bakeTile(snap, tx, ty, z, dim);

/// Bake one (z,x,y) fog tile of [dim] px. Never throws — on any failure returns
/// a solid-veil tile (the safe fallback, since unexplored == veil).
Future<ui.Image> _bakeTile(
    FogSnapshot snap, int tx, int ty, int z, int dim) async {
  // Past the fog's native resolution each fog cell spans ≥2 tile px, so the
  // hard integer punch would show as a pixel staircase. Bake those zooms as a
  // smooth Fog-of-World-style reveal instead: every explored cell becomes an
  // anti-aliased disk and the union is feathered with one blur pass, so
  // corridor edges stay soft and rounded at any zoom. Falls back to the
  // integer punch on any failure.
  if (z > _kFogNativeZoom && !snap.isEmpty) {
    try {
      return await _bakeTileSmooth(snap, tx, ty, z, dim);
    } catch (_) {
      // fall through to the crisp integer bake
    }
  }
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
  final cLatGcj = _mercPxToLat(tyPpt.toDouble() * scale + dim / 2, worldPx);
  final cLngGcj = _mercPxToLng(txPpt.toDouble() * scale + dim / 2, worldPx);
  final wgs = CoordConverter.gcj02ToWgs84(cLatGcj, cLngGcj);
  final wgsGx = FogEngine.lngToGlobalX(wgs.lng).toDouble();
  final wgsGy = FogEngine.latToGlobalY(wgs.lat).toDouble();
  return (
    dim / 2 - (wgsGx - txPpt) * scale,
    dim / 2 - (wgsGy - tyPpt) * scale,
  );
}

/// Smooth overzoom bake (z > native): veil rect, then the explored cells are
/// drawn as slightly-overlapping anti-aliased disks into an unbounded
/// saveLayer whose paint erases the veil (dstOut) through a single gaussian
/// blur — soft feathered corridor edges, rounded corners, merged unions, the
/// Fog of World look. Disk radius 0.78·cell keeps diagonal runs connected;
/// σ = 0.45·cell keeps the feather proportional to the map (constant ground
/// width) instead of constant screen px.
Future<ui.Image> _bakeTileSmooth(
    FogSnapshot snap, int tx, int ty, int z, int dim) async {
  const full = FogEngine.full;
  const w = FogEngine.bitmapWidth; // 64
  final ppt = full >> z; // fog px per tile
  final scale = dim / ppt; // dest px per fog px (2,4,8 for z15..17)
  final txPpt = tx * ppt, tyPpt = ty * ppt;
  final (shiftX, shiftY) = _gcjShift(snap, tx, ty, z, dim);

  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  final dimD = dim.toDouble();
  canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, dimD, dimD), ui.Paint()..color = snap.veil);

  // Padded fog-px window: disks just outside the tile must still bleed their
  // blur across the edge or adjacent tiles would show seams.
  final r = scale * 0.78;
  final sigma = scale * 0.45;
  final padPx = r + sigma * 3 + 2; // dest px
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
    canvas.saveLayer(
      null,
      ui.Paint()
        ..blendMode = ui.BlendMode.dstOut
        ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
    final disk = ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..isAntiAlias = true;
    final lo = -padPx, hi = dimD + padPx;
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
            canvas.drawCircle(ui.Offset(cx, cy), r, disk);
          }
        }
      }
    });
    canvas.restore();
  }
  return rec.endRecording().toImage(dim, dim);
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
  final (shiftX, shiftY) = _gcjShift(snap, tx, ty, z, dim);

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
/// tile pixel at zoom 14. At and below this the integer punch is exact.
const int _kFogNativeZoom = 14;

/// Highest zoom we bake real tiles for. Between native+1 and here each tile
/// is baked with the smooth disk+feather pass (cells span 2/4/8 px — a hard
/// punch would be a visible staircase). Past this flutter_map overzooms the
/// z17 tiles, whose edges are already soft, so they stay smooth when scaled.
const int _kFogMaxNativeZoom = 17;

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
    this.refreshKey,
    this.changes,
  });

  @override
  State<FogTileLayer> createState() => _FogTileLayerState();
}

class _FogTileLayerState extends State<FogTileLayer> {
  /// Monotonic base across ALL FogTileLayer instances in this process. The
  /// baked-tile ImageCache key is (x,y,z,dim,generation) — if every state
  /// started again at generation 0, leaving and re-entering the map would
  /// collide with cached tiles baked from a DIFFERENT snapshot.
  static int _generationSeed = 0;

  late final FogTileProvider _provider = FogTileProvider(FogSnapshot(
    rows: const [],
    veil: widget.veil,
    mapProvider: widget.mapProvider,
    generation: _generation,
  ));
  String _dataKey = '';
  late int _generation = (_generationSeed += 1 << 20);

  /// In-memory mirror of the visible layers' fog rows, keyed by
  /// (tileX,tileY,layerId). Full reloads replace it; delta events patch it.
  final Map<int, FogTile> _rows = {};
  StreamSubscription<List<FogTile>>? _changesSub;

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
    if (relevant) _publish();
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
    // DIAG: which layers the map actually reads fog from. Compare against the
    // [FOW] import log's activeLayer — a mismatch is why re-imported fog after a
    // clear "没了" (written to a layer the map doesn't render).
    debugPrint('[FOG] reload visibleLayers=$ids → loaded=${rows.length} tiles');
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
      _provider.snapshot = FogSnapshot(
        rows: _rows.values.toList(growable: false),
        veil: widget.veil,
        mapProvider: widget.mapProvider,
        generation: _generation,
      );
    });
  }

  @override
  Widget build(BuildContext context) => TileLayer(
        // Remount when the snapshot flips empty↔non-empty. The in-place
        // reload below only re-bakes TileImages that ALREADY exist — on a
        // cold start the fog rows arrive from the DB after the layer
        // mounted, and if no tile had loaded yet (camera not laid out, no
        // map event since) nothing would ever load until the user pans or
        // zooms ("地图没有迷雾，点一下定位才出现"). A remount is guaranteed
        // to run a fresh load-and-prune pass against the current camera.
        key: ValueKey('fog-tiles-${_rows.isEmpty ? 'empty' : 'data'}'),
        tileProvider: _provider,
        // Changing this on a data change is what triggers an in-place reload.
        additionalOptions: {'gen': '$_generation'},
        tileSize: 256,
        maxNativeZoom: _kFogMaxNativeZoom, // smooth-baked past the native res
        // Instant (no fade) so the veil never flashes semi-transparent while
        // panning or after a data refresh.
        tileDisplay: const TileDisplay.instantaneous(),
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
      );
}
