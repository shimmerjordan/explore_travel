import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../data/db/database.dart';
import '../../models/models.dart';
import '../fog/fog_engine.dart';
import '../geo/coord_converter.dart';
import '../map/fog_tile_provider.dart' show coalescedTileUpdates;
import '../map/tile_providers.dart';
import 'heat_palette.dart';
import 'heat_source.dart';

/// Baked "personal heat map" tiles: every walked segment is stroked twice
/// (a wide soft halo + a narrow core) with **additive** blending, so streets
/// walked ten times glow ten times brighter and saturate to the palette's
/// white peak — the Strava / 人生点点 look. The accumulated coverage is then
/// pushed through the palette LUT.
///
/// Same lifecycle as the fog tiles: an immutable [HeatSnapshot] with a
/// generation number in the image-cache key; swapping the snapshot re-bakes
/// in place.
class HeatTileProvider extends TileProvider {
  HeatSnapshot snapshot;
  HeatTileProvider(this.snapshot);

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _HeatTileImage(snapshot, coordinates.x, coordinates.y, coordinates.z,
          options.tileSize.round());
}

@immutable
class _HeatTileKey {
  final HeatSnapshot snapshot;
  final int x, y, z, dim;
  const _HeatTileKey(this.snapshot, this.x, this.y, this.z, this.dim);

  @override
  bool operator ==(Object other) =>
      other is _HeatTileKey &&
      other.x == x &&
      other.y == y &&
      other.z == z &&
      other.dim == dim &&
      other.snapshot.generation == snapshot.generation;

  @override
  int get hashCode => Object.hash(x, y, z, dim, snapshot.generation);
}

class _HeatTileImage extends ImageProvider<_HeatTileKey> {
  final _HeatTileKey _key;
  _HeatTileImage(HeatSnapshot snapshot, int x, int y, int z, int dim)
      : _key = _HeatTileKey(snapshot, x, y, z, dim);

  @override
  Future<_HeatTileKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(_key);

  @override
  ImageStreamCompleter loadImage(_HeatTileKey key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_bake(key));

  static Future<ImageInfo> _bake(_HeatTileKey key) async {
    final img =
        await bakeHeatTile(key.snapshot, key.x, key.y, key.z, key.dim);
    return ImageInfo(image: img, scale: 1.0);
  }
}

/// Zoom above which flutter_map overzooms the last baked level instead of
/// asking for finer tiles (the halo is already soft; scaling it is fine).
const int kHeatMaxNativeZoom = 18;

/// Core stroke width in *tile pixels* at zoom [z] for a tile of [dim] px.
/// 3 px at z14 (one fog cell), doubling per zoom, clamped so a street is at
/// least a hairline at country scale and doesn't become a blob up close.
double heatStrokePx(int z, double widthMul, {int dim = 256}) {
  final base = 3.0 * math.pow(2.0, z - 14).toDouble();
  return base.clamp(1.0, 14.0) * widthMul * (dim / 256.0);
}

/// Highest zoom at which fog blocks are drawn as heat baseline (block = 64 px
/// there; one level further they are 128 px slabs).
const int kHeatFogBaselineMaxZoom = 14;

/// Side length in tile px of one fog block (64 fog cells; 1 cell = 1 px @z14).
double heatFogBlockPx(int z, {int dim = 256}) =>
    (64.0 * math.pow(2.0, z - 14).toDouble() * (dim / 256.0)).clamp(1.0, 512.0);

/// Bake one heat tile. Never throws: any failure yields a transparent tile.
Future<ui.Image> bakeHeatTile(
    HeatSnapshot snap, int tx, int ty, int z, int dim) async {
  if (!snap.isEmpty) {
    try {
      final img = await _bakeHeatTile(snap, tx, ty, z, dim);
      if (img != null) return img;
    } catch (e) {
      debugPrint('[HEAT] bake $z/$tx/$ty failed: $e');
    }
  }
  final rec = ui.PictureRecorder();
  ui.Canvas(rec);
  return rec.endRecording().toImage(dim, dim);
}

Future<ui.Image?> _bakeHeatTile(
    HeatSnapshot snap, int tx, int ty, int z, int dim) async {
  final scale = (1 << z).toDouble();
  final core = heatStrokePx(z, snap.width, dim: dim);
  final wide = core * 3;
  final blockPx = heatFogBlockPx(z, dim: dim);
  final marginPx = math.max(wide, blockPx) / 2 + 1;
  final tileWorld = 1.0 / scale;
  final mWorld = marginPx / dim * tileWorld;
  final wx0 = tx / scale - mWorld, wx1 = (tx + 1) / scale + mWorld;
  final wy0 = ty / scale - mWorld, wy1 = (ty + 1) / scale + mWorld;

  final lines = _F32Buf();
  final dots = _F32Buf();
  // Fog blocks binned by weight (8 alpha steps → 8 draw calls, not 4k).
  final fogBins = List.generate(8, (_) => _F32Buf());
  final segs = snap.index.segs;
  snap.index.forEachIn(wx0, wy0, wx1, wy1, (i) {
    final o = i << 2;
    final px0 = (segs[o] * scale - tx) * dim;
    final py0 = (segs[o + 1] * scale - ty) * dim;
    final px1 = (segs[o + 2] * scale - tx) * dim;
    final py1 = (segs[o + 3] * scale - ty) * dim;
    if (snap.index.kinds[i] == 1) {
      // Past z14 a fog block is ≥128 px: as a flat square it reads as a grey
      // slab on the map, not "faint heat". The fog veil already shows the
      // explored area at those zooms — leave the baseline to the overview.
      if (z > kHeatFogBaselineMaxZoom) return;
      final w = snap.index.weights[i];
      final bin = (w * 7.999).floor().clamp(0, 7);
      fogBins[bin].add2(px0, py0);
      return;
    }
    final dx = px1 - px0, dy = py1 - py0;
    if (dx * dx + dy * dy < 0.25) {
      dots.add2(px0, py0);
    } else {
      lines.add4(px0, py0, px1, py1);
    }
  });
  if (lines.isEmpty && dots.isEmpty && fogBins.every((b) => b.isEmpty)) {
    return null;
  }

  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(
      rec, ui.Rect.fromLTWH(0, 0, dim.toDouble(), dim.toDouble()));
  final exp = snap.exposure;
  ui.Paint stroke(double width, double alpha, {ui.StrokeCap cap = ui.StrokeCap.round}) =>
      ui.Paint()
        ..color = ui.Color.fromRGBO(255, 255, 255, alpha.clamp(0.0, 1.0))
        ..strokeWidth = width
        ..strokeCap = cap
        ..style = ui.PaintingStyle.stroke
        ..blendMode = ui.BlendMode.plus
        ..isAntiAlias = true;

  // Fog baseline first (faint, square blocks) so real tracks stack on top.
  for (var b = 0; b < 8; b++) {
    final buf = fogBins[b];
    if (buf.isEmpty) continue;
    final w = (b + 1) / 8.0;
    canvas.drawRawPoints(ui.PointMode.points, buf.view(),
        stroke(blockPx, 0.05 * exp * w, cap: ui.StrokeCap.square));
  }
  final halo = stroke(wide, 0.035 * exp);
  final body = stroke(core, 0.10 * exp);
  if (!lines.isEmpty) {
    final v = lines.view();
    canvas.drawRawPoints(ui.PointMode.lines, v, halo);
    canvas.drawRawPoints(ui.PointMode.lines, v, body);
  }
  if (!dots.isEmpty) {
    final v = dots.view();
    canvas.drawRawPoints(ui.PointMode.points, v, halo);
    canvas.drawRawPoints(ui.PointMode.points, v, body);
  }
  final coverage = await rec.endRecording().toImage(dim, dim);
  final bd = await coverage.toByteData(format: ui.ImageByteFormat.rawRgba);
  coverage.dispose();
  if (bd == null) return null;

  // Coverage alpha (top byte of each little-endian RGBA word) → palette.
  final src = bd.buffer.asUint32List(bd.offsetInBytes, dim * dim);
  final out = Uint32List(dim * dim);
  final lut = snap.lut;
  for (var i = 0; i < out.length; i++) {
    out[i] = lut[src[i] >>> 24];
  }
  return _decode(out.buffer.asUint8List(), dim);
}

Future<ui.Image> _decode(Uint8List rgba, int dim) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      rgba, dim, dim, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// Growable Float32List (drawRawPoints wants a Float32List view).
class _F32Buf {
  Float32List _buf = Float32List(256);
  int _len = 0;
  bool get isEmpty => _len == 0;
  void _grow(int need) {
    if (_len + need <= _buf.length) return;
    final n = Float32List(math.max(_buf.length * 2, _len + need));
    n.setRange(0, _len, _buf);
    _buf = n;
  }

  void add2(double a, double b) {
    _grow(2);
    _buf[_len++] = a;
    _buf[_len++] = b;
  }

  void add4(double a, double b, double c, double d) {
    _grow(4);
    _buf[_len++] = a;
    _buf[_len++] = b;
    _buf[_len++] = c;
    _buf[_len++] = d;
  }

  Float32List view() => Float32List.sublistView(_buf, 0, _len);
}

/// Test seam.
@visibleForTesting
Future<ui.Image> bakeHeatTileForTest(
        HeatSnapshot snap, int tx, int ty, int z, int dim) =>
    bakeHeatTile(snap, tx, ty, z, dim);

/// Style knobs, straight from AppSettings.
class HeatStyle {
  final int palette;
  final double exposure;
  final double width;
  const HeatStyle(
      {required this.palette, required this.exposure, required this.width});

  @override
  bool operator ==(Object other) =>
      other is HeatStyle &&
      other.palette == palette &&
      other.exposure == exposure &&
      other.width == width;
  @override
  int get hashCode => Object.hash(palette, exposure, width);
}

/// flutter_map layer that draws the heat map for [layerIds] within an
/// optional time window. Loads clean track points (+ fog blocks when
/// [includeFog]) and builds the segment index off the UI isolate.
class HeatTileLayer extends StatefulWidget {
  final AppDb db;
  final List<int> layerIds;
  final MapProvider mapProvider;
  final HeatStyle style;
  final DateTime? from;
  final DateTime? to;
  final bool includeFog;
  final Object? refreshKey;
  const HeatTileLayer({
    super.key,
    required this.db,
    required this.layerIds,
    required this.mapProvider,
    required this.style,
    this.from,
    this.to,
    this.includeFog = true,
    this.refreshKey,
  });

  /// Latest published snapshot of the mounted layer (null when none). The
  /// tilt view reads the segment index from here instead of re-querying.
  static final ValueNotifier<HeatSnapshot?> latest = ValueNotifier(null);

  @override
  State<HeatTileLayer> createState() => _HeatTileLayerState();
}

/// Load clean points (+ fog blocks) and build a ready-to-bake [HeatSnapshot]
/// — shared by the (test-covered) 2D tile layer and the 3D heat mode, which
/// builds its snapshot directly instead of mounting a map layer first.
Future<HeatSnapshot> loadHeatSnapshot({
  required AppDb db,
  required List<int> layerIds,
  required MapProvider mapProvider,
  required HeatStyle style,
  DateTime? from,
  DateTime? to,
  bool includeFog = true,
  int generation = 1,
}) async {
  final pts = await db.cleanPoints(layerIds, from: from, to: to);
  final fog = includeFog && layerIds.isNotEmpty
      ? await db.fogTilesForLayers(layerIds, FogEngine.tileZoom)
      : const <FogTile>[];
  final n = pts.length;
  final lat = Float64List(n), lng = Float64List(n);
  final timeMs = Int64List(n);
  final layer = Int32List(n);
  for (var i = 0; i < n; i++) {
    final p = pts[i];
    lat[i] = p.lat;
    lng[i] = p.lng;
    timeMs[i] = p.time.millisecondsSinceEpoch;
    layer[i] = p.layerId;
  }
  final fogBx = Int32List(fog.length), fogBy = Int32List(fog.length);
  final fogPop = Int32List(fog.length);
  for (var i = 0; i < fog.length; i++) {
    final t = fog[i];
    fogBx[i] = t.tileX;
    fogBy[i] = t.tileY;
    var c = 0;
    for (final b in t.bitmap) {
      if (b != 0) c += _popcount8(b);
    }
    fogPop[i] = c;
  }
  final input = HeatBuildInput(
    lat: lat,
    lng: lng,
    timeMs: timeMs,
    layer: layer,
    gcj02: CoordConverter.needsGcj02(mapProvider),
    fogBx: fogBx,
    fogBy: fogBy,
    fogPop: fogPop,
  );
  final index = kIsWeb
      ? buildHeatIndex(input)
      : await compute(buildHeatIndexFromMap, input.toMap());
  return HeatSnapshot(
    index: index,
    lut: HeatPalette.byIndex(style.palette).lut(),
    exposure: style.exposure,
    width: style.width,
    generation: generation,
  );
}

class _HeatTileLayerState extends State<HeatTileLayer> {
  static int _generationSeed = 0;
  late int _generation = (_generationSeed += 1 << 20);
  late final HeatTileProvider _provider = HeatTileProvider(HeatSnapshot(
    index: HeatIndex.empty,
    lut: HeatPalette.byIndex(widget.style.palette).lut(),
    exposure: widget.style.exposure,
    width: widget.style.width,
    generation: _generation,
  ));
  HeatIndex _index = HeatIndex.empty;
  String _dataKey = '';
  String _styleKey = '';
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _maybeReload();
  }

  @override
  void didUpdateWidget(covariant HeatTileLayer old) {
    super.didUpdateWidget(old);
    _maybeReload();
  }

  @override
  void dispose() {
    if (HeatTileLayer.latest.value == _provider.snapshot) {
      HeatTileLayer.latest.value = null;
    }
    super.dispose();
  }

  void _maybeReload() {
    final data = '${widget.layerIds.join(",")}|${widget.refreshKey}'
        '|${widget.mapProvider}|${widget.from?.millisecondsSinceEpoch}'
        '|${widget.to?.millisecondsSinceEpoch}|${widget.includeFog}';
    final style =
        '${widget.style.palette}|${widget.style.exposure}|${widget.style.width}';
    if (data != _dataKey) {
      _dataKey = data;
      _styleKey = style;
      _reload();
    } else if (style != _styleKey) {
      _styleKey = style;
      _publish();
    }
  }

  Future<void> _reload() async {
    final seq = ++_loadSeq;
    final ids = widget.layerIds;
    if (ids.isEmpty) {
      _index = HeatIndex.empty;
      _publish();
      return;
    }
    final sw = Stopwatch()..start();
    final pts = await widget.db.cleanPoints(ids, from: widget.from, to: widget.to);
    final fog = widget.includeFog
        ? await widget.db.fogTilesForLayers(ids, FogEngine.tileZoom)
        : const <FogTile>[];
    if (!mounted || seq != _loadSeq) return;

    final n = pts.length;
    final lat = Float64List(n), lng = Float64List(n);
    final timeMs = Int64List(n);
    final layer = Int32List(n);
    for (var i = 0; i < n; i++) {
      final p = pts[i];
      lat[i] = p.lat;
      lng[i] = p.lng;
      timeMs[i] = p.time.millisecondsSinceEpoch;
      layer[i] = p.layerId;
    }
    final fogBx = Int32List(fog.length), fogBy = Int32List(fog.length);
    final fogPop = Int32List(fog.length);
    for (var i = 0; i < fog.length; i++) {
      final t = fog[i];
      fogBx[i] = t.tileX;
      fogBy[i] = t.tileY;
      var c = 0;
      for (final b in t.bitmap) {
        if (b != 0) c += _popcount8(b);
      }
      fogPop[i] = c;
    }
    final input = HeatBuildInput(
      lat: lat,
      lng: lng,
      timeMs: timeMs,
      layer: layer,
      gcj02: CoordConverter.needsGcj02(widget.mapProvider),
      fogBx: fogBx,
      fogBy: fogBy,
      fogPop: fogPop,
    );
    final index = kIsWeb
        ? buildHeatIndex(input)
        : await compute(buildHeatIndexFromMap, input.toMap());
    if (!mounted || seq != _loadSeq) return;
    debugPrint('[HEAT] index points=$n fog=${fog.length} → segs=${index.count} '
        'in ${sw.elapsedMilliseconds} ms');
    _index = index;
    _publish();
  }

  void _publish() {
    setState(() {
      _generation++;
      final snap = HeatSnapshot(
        index: _index,
        lut: HeatPalette.byIndex(widget.style.palette).lut(),
        exposure: widget.style.exposure,
        width: widget.style.width,
        generation: _generation,
      );
      _provider.snapshot = snap;
      HeatTileLayer.latest.value = snap;
    });
  }

  @override
  Widget build(BuildContext context) => TileLayer(
        key: ValueKey('heat-${_index.isEmpty ? 'empty' : 'data'}'),
        tileProvider: _provider,
        additionalOptions: {'gen': '$_generation'},
        tileSize: 256,
        maxNativeZoom: kHeatMaxNativeZoom,
        keepBuffer: kNativeTileKeepBuffer,
        panBuffer: kNativeTilePanBuffer,
        tileUpdateTransformer: coalescedTileUpdates,
        tileDisplay: const TileDisplay.instantaneous(),
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
      );
}

int _popcount8(int b) {
  b = b - ((b >> 1) & 0x55);
  b = (b & 0x33) + ((b >> 2) & 0x33);
  return (b + (b >> 4)) & 0x0F;
}
