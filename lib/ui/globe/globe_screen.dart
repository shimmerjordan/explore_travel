import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' show Position;
import '../../app/providers.dart';
import '../../services/fog/fog_engine.dart';
import '../common/map_chrome.dart';

/// A 3D globe (Google-Earth style) reached by trying to zoom the 2D map out
/// past its minimum. Real day (Blue-Marble) + night (city-lights) textures
/// blended along the current day/night terminator. Visited places render as
/// a NIGHT-style heat map: footprints are binned by location and drawn as
/// additive glows, so the more you've been somewhere the brighter it burns —
/// like city lights from orbit. Drag to spin (surface follows the finger),
/// pinch to zoom. No auto-rotation.
class GlobeScreen extends ConsumerStatefulWidget {
  const GlobeScreen({super.key});
  @override
  ConsumerState<GlobeScreen> createState() => _GlobeScreenState();
}

class _GlobeScreenState extends ConsumerState<GlobeScreen>
    with SingleTickerProviderStateMixin {
  int _rawCount = 0;
  bool _loading = true;

  // Current-location marker (null until "locate me" succeeds) + the fly-to
  // animation that rotates the globe to centre it.
  _Pt? _myPos;
  bool _showMyPos = true;
  bool _locating = false;
  late final AnimationController _flyCtrl;
  double _flyStartLng = 0, _flyStartLat = 0, _flyDeltaLng = 0, _flyTargetLat = 0;

  ui.Image? _earth; // day
  ui.Image? _earthNight; // night city lights
  ui.Image? _glow; // soft radial sprite for the heat map

  List<_Pt> _grid = const [];
  List<double> _gridU = const [];
  List<double> _gridV = const [];
  Int32List _nightCol = Int32List(0);
  int _rows = 0, _cols = 0;

  // Heat-map cells: one per visited ~13 km bin, with a 0..1 intensity from
  // how many footprints fell in it.
  List<_Cell> _cells = const [];

  List<List<_Pt>> _land = const []; // vector fallback

  double _rotLng = 0;
  double _rotLat = 0.3;
  double _scale = 1.0;

  double _gestureStartScale = 1.0;
  Offset _lastFocal = Offset.zero;

  // "Zoom in 3× at max → back to the 2D map" (mirror of the 2D→globe gesture).
  static const double _maxScale = 6.0;
  bool _atMaxAtStart = false;
  bool _countedGesture = false;
  int _zoomInTries = 0;
  Timer? _zoomInReset;

  static const int _stepDeg = 3; // finer mesh = smoother, sharper sphere
  static const double _cellDeg = 0.02; // heat-map bin (~2 km) → fine dots
  static const int _maxCells = 60000; // cap so drawAtlas stays cheap

  @override
  void initState() {
    super.initState();
    _flyCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..addListener(() {
        final v = Curves.easeInOut.transform(_flyCtrl.value);
        setState(() {
          _rotLng = _flyStartLng + _flyDeltaLng * v;
          _rotLat = _flyStartLat + (_flyTargetLat - _flyStartLat) * v;
        });
      });
    _buildGrid();
    _computeDayNight();
    _load();
  }

  /// Fetch the current GPS fix, drop a marker on the globe and spin it so
  /// that point faces the viewer.
  Future<void> _locate() async {
    if (_locating) return;
    setState(() => _locating = true);
    Position? pos;
    try {
      pos = await ref.read(locationServiceProvider).currentOnce();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _locating = false);
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法获取当前定位')));
      return;
    }
    final lat = pos.latitude, lng = pos.longitude;
    final targetLng = -lng * math.pi / 180.0;
    final targetLat = (lat * math.pi / 180.0).clamp(-1.3, 1.3).toDouble();
    _flyStartLng = _rotLng;
    _flyStartLat = _rotLat;
    // Shortest angular path for the spin (don't wind the long way round).
    _flyDeltaLng = math.atan2(
        math.sin(targetLng - _rotLng), math.cos(targetLng - _rotLng));
    _flyTargetLat = targetLat;
    setState(() {
      _myPos = _toSphere(lat, lng);
      _showMyPos = true; // locating always reveals it
    });
    _flyCtrl.forward(from: 0);
  }

  static _Pt _toSphere(double lat, double lng) {
    final latR = lat * math.pi / 180.0;
    final lngR = lng * math.pi / 180.0;
    final cosLat = math.cos(latR);
    return _Pt(cosLat * math.sin(lngR), math.sin(latR), cosLat * math.cos(lngR));
  }

  void _buildGrid() {
    final grid = <_Pt>[];
    final us = <double>[];
    final vs = <double>[];
    var rows = 0;
    for (var lat = -90; lat <= 90; lat += _stepDeg) {
      rows++;
      var cols = 0;
      for (var lng = -180; lng <= 180; lng += _stepDeg) {
        cols++;
        grid.add(_toSphere(lat.toDouble(), lng.toDouble()));
        us.add((lng + 180) / 360.0);
        vs.add((90 - lat) / 180.0);
      }
      _cols = cols;
    }
    _rows = rows;
    _grid = grid;
    _gridU = us;
    _gridV = vs;
  }

  void _computeDayNight() {
    final now = DateTime.now().toUtc();
    final doy = now.difference(DateTime.utc(now.year, 1, 1)).inDays;
    final declDeg = -23.44 * math.cos(2 * math.pi / 365.0 * (doy + 10));
    final utcHours = now.hour + now.minute / 60.0 + now.second / 3600.0;
    final subsolarLng = -15.0 * (utcHours - 12.0);
    final sun = _toSphere(declDeg, subsolarLng);
    final col = Int32List(_grid.length);
    for (var i = 0; i < _grid.length; i++) {
      final g = _grid[i];
      final cosSun = g.x * sun.x + g.y * sun.y + g.z * sun.z;
      var t = ((cosSun + 0.18) / 0.36).clamp(0.0, 1.0);
      t = t * t * (3 - 2 * t);
      final nightA = ((1.0 - t) * 255).round().clamp(0, 255);
      col[i] = (nightA << 24) | 0x00FFFFFF;
    }
    _nightCol = col;
  }

  Future<ui.Image?> _decode(String asset, {int? targetWidth}) async {
    try {
      final data = await rootBundle.load(asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(),
          targetWidth: targetWidth);
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null;
    }
  }

  /// Soft white radial sprite (transparent at the rim). Tinted + accumulated
  /// additively per heat-map cell to build the glow.
  Future<ui.Image> _makeGlowSprite() async {
    const s = 64;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final c = const Offset(s / 2, s / 2);
    // Tight core, quick falloff — so even scaled down to a couple of pixels a
    // single footprint reads as a fine point, not a fat blob.
    canvas.drawCircle(
      c,
      s / 2,
      Paint()
        ..shader = ui.Gradient.radial(c, s / 2, [
          const Color(0xFFFFFFFF),
          const Color(0xFFFFFFFF),
          const Color(0x00FFFFFF),
        ], [
          0.0,
          0.32,
          1.0,
        ]),
    );
    return rec.endRecording().toImage(s, s);
  }

  Future<void> _loadTexture() async {
    // Decode the day map at full native resolution (5400×2700) for the
    // sharpest detail when zoomed in; the night lights stay 2048.
    _earth = await _decode('assets/textures/earth.jpg');
    _earthNight =
        await _decode('assets/textures/earth_night.jpg', targetWidth: 2048);
    if (_earth == null) await _loadLandFallback();
  }

  Future<void> _loadLandFallback() async {
    try {
      final raw =
          await rootBundle.loadString('assets/boundaries/world_land.json');
      final rings = (jsonDecode(raw) as Map<String, dynamic>)['rings'] as List;
      final out = <List<_Pt>>[];
      for (final r in rings) {
        final flat = r as List;
        final ring = <_Pt>[];
        for (var i = 0; i + 1 < flat.length; i += 2) {
          ring.add(_toSphere(
              (flat[i + 1] as num).toDouble(), (flat[i] as num).toDouble()));
        }
        if (ring.length >= 2) out.add(ring);
      }
      _land = out;
    } catch (_) {
      _land = const [];
    }
  }

  Future<void> _load() async {
    await _loadTexture();
    _glow = await _makeGlowSprite();
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    final ids = layers.where((l) => l.visible).map((l) => l.id).toList();

    // Bin every footprint into ~2 km cells and count density. This preserves
    // "more visits → brighter" (a plain downsample would erase it).
    const mul = 20000; // > max lng index at _cellDeg, keeps keys unique
    final counts = <int, int>{};
    var total = 0;
    for (final id in ids) {
      // Fog is the authoritative "explored" record for a layer — it covers
      // both imported Fog-of-World data AND natively recorded trails (every
      // recorded fix reveals fog). Bin it for EVERY layer. The old code was
      // either/or: a single recorded TrackPoint made it skip the layer's
      // entire fog, so a layer holding a big FOW import plus one walk showed
      // almost nothing ("路径在3D地球里不显示"). Each fog block (~0.6 km)
      // bins at its centre, weighted by how many of its 64×64 cells are
      // explored, so denser exploration reads brighter.
      const bw = FogEngine.bitmapWidth;
      for (final t in await db.fogTilesForLayers([id], FogEngine.tileZoom)) {
        var c = 0;
        for (final b in t.bitmap) {
          if (b != 0) c += _popcount8(b);
        }
        if (c == 0) continue;
        final lat = FogEngine.globalYToLat(t.tileY * bw + bw ~/ 2);
        final lng = FogEngine.globalXToLng(t.tileX * bw + bw ~/ 2);
        final li = ((lat + 90) / _cellDeg).floor();
        final gi = ((lng + 180) / _cellDeg).floor();
        counts[li * mul + gi] = (counts[li * mul + gi] ?? 0) + c;
        total += c;
      }
      // GPS track points stack on top as revisit density — fog is binary per
      // cell, so without this a daily commute and a one-off walk would burn
      // equally bright.
      for (final p in await db.pointsForLayer(id)) {
        final li = ((p.lat + 90) / _cellDeg).floor();
        final gi = ((p.lng + 180) / _cellDeg).floor();
        counts[li * mul + gi] = (counts[li * mul + gi] ?? 0) + 1;
        total++;
      }
    }
    _rawCount = total;
    var maxC = 1;
    for (final v in counts.values) {
      if (v > maxC) maxC = v;
    }
    final denom = math.log(1 + maxC);
    var cells = <_Cell>[];
    double sumLat = 0, sumLng = 0;
    counts.forEach((key, count) {
      final li = key ~/ mul;
      final gi = key % mul;
      final lat = (li + 0.5) * _cellDeg - 90;
      final lng = (gi + 0.5) * _cellDeg - 180;
      // log scale so a handful of mega-visited cells don't flatten everything.
      final t = denom > 0 ? (math.log(1 + count) / denom).clamp(0.0, 1.0) : 1.0;
      cells.add(_Cell(_toSphere(lat, lng), t.toDouble()));
      sumLat += lat * count;
      sumLng += lng * count;
    });
    // Cap: keep the densest cells so a huge history doesn't bog drawAtlas.
    if (cells.length > _maxCells) {
      cells.sort((a, b) => b.intensity.compareTo(a.intensity));
      cells = cells.sublist(0, _maxCells);
    }

    if (total > 0) {
      _rotLng = -(sumLng / total) * math.pi / 180.0;
      _rotLat = ((sumLat / total) * math.pi / 180.0).clamp(-1.3, 1.3);
    }
    if (!mounted) return;
    setState(() {
      _cells = cells;
      _loading = false;
    });
  }

  void _onScaleStart(ScaleStartDetails d) {
    _gestureStartScale = _scale;
    _lastFocal = d.focalPoint;
    _atMaxAtStart = _scale >= _maxScale - 0.05;
    _countedGesture = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      if (d.scale != 1.0) {
        _scale = (_gestureStartScale * d.scale).clamp(0.6, _maxScale);
      }
      final delta = d.focalPoint - _lastFocal;
      _lastFocal = d.focalPoint;
      const k = 0.005;
      _rotLng += delta.dx * k / _scale;
      _rotLat = (_rotLat + delta.dy * k / _scale)
          .clamp(-math.pi / 2 + 0.05, math.pi / 2 - 0.05);
    });
    // Already fully zoomed in and still pinching out → counts toward exiting
    // to the 2D map (one count per gesture).
    if (_atMaxAtStart && !_countedGesture && d.scale > 1.2) {
      _countedGesture = true;
      _registerZoomInTry();
    }
    // Zooming the globe back out cancels the streak.
    if (_scale < 5.0 && _zoomInTries != 0) {
      _zoomInReset?.cancel();
      setState(() => _zoomInTries = 0);
    }
  }

  void _registerZoomInTry() {
    _zoomInReset?.cancel();
    setState(() => _zoomInTries++);
    if (_zoomInTries >= 3) {
      _zoomInTries = 0;
      if (mounted) Navigator.of(context).maybePop(); // back to the 2D map
      return;
    }
    _zoomInReset = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _zoomInTries = 0);
    });
  }

  @override
  void dispose() {
    _flyCtrl.dispose();
    _zoomInReset?.cancel();
    super.dispose();
  }

  Widget _circleButton({
    required VoidCallback onTap,
    String? tooltip,
    IconData? icon,
    Color? iconColor,
    Widget? child,
  }) {
    final btn = Material(
      color: const Color(0xFF1A2733),
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: child ?? Icon(icon, color: iconColor ?? Colors.white),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF02060E),
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              child: CustomPaint(
                painter: _GlobePainter(
                  cells: _cells,
                  glow: _glow,
                  myPos: _showMyPos ? _myPos : null,
                  earth: _earth,
                  earthNight: _earthNight,
                  grid: _grid,
                  gridU: _gridU,
                  gridV: _gridV,
                  nightCol: _nightCol,
                  rows: _rows,
                  cols: _cols,
                  land: _land,
                  rotLng: _rotLng,
                  rotLat: _rotLat,
                  scale: _scale,
                ),
                size: Size.infinite,
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Column(
                children: [
                  const Text('🌐 3D 地球',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    _loading
                        ? '加载中…'
                        : '$_rawCount 个足迹 · 越常去越亮 · 拖动旋转 · 双指缩放',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 6,
            left: 8,
            child: Material(
              color: Colors.white12,
              shape: const CircleBorder(),
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          if (_zoomInTries > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 60,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '🗺️ 再放大 ${3 - _zoomInTries} 次返回 2D 地图',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
          // Locate-me + hide/show-marker buttons.
          Positioned(
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Toggle visibility of the "you are here" dot — only once we
                // actually have a location.
                if (_myPos != null) ...[
                  _circleButton(
                    icon: _showMyPos
                        ? Icons.location_on_rounded
                        : Icons.location_off_rounded,
                    iconColor:
                        _showMyPos ? const Color(0xFF00B0FF) : Colors.white70,
                    tooltip: _showMyPos ? '隐藏当前位置' : '显示当前位置',
                    onTap: () => setState(() => _showMyPos = !_showMyPos),
                  ),
                  const SizedBox(height: 10),
                ],
                _circleButton(
                  tooltip: '定位当前位置',
                  onTap: _locate,
                  child: _locating
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.my_location_rounded,
                          color: Color(0xFF00B0FF)),
                ),
              ],
            ),
          ),
          if (_loading)
            // 地球画布是**固定深色**（#02060E，跟主题无关，和地图浮层同一类），
            // 所以这里不能用 Theme.of(context).status.*：亮色主题下警告色是
            // 深棕 #875200，压在这块黑底上只剩 3.13:1，刚够图形、暗得像没在转。
            // 改用浮层的次要前景色（11.20:1），和本屏其它 white70 / white54
            // 归成一族——原来的 Colors.amber 对比度本身没问题，只是它是这屏上
            // 唯一一枚游离的 Material 直出色。
            const Center(
                child: CircularProgressIndicator(
                    color: MapChrome.onChromeMuted)),
          if (!_loading && _rawCount == 0)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Text(
                  '还没有任何足迹。\n开始记录后，走过的地方会在这里点亮地球。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pt {
  final double x, y, z;
  const _Pt(this.x, this.y, this.z);
}

class _Cell {
  final _Pt v;
  final double intensity; // 0..1
  const _Cell(this.v, this.intensity);
}

/// Number of set bits in a byte (0..255) — used to weight a fog block by how
/// many of its cells are explored when lighting the globe from fog tiles.
int _popcount8(int b) {
  b = b - ((b >> 1) & 0x55);
  b = (b & 0x33) + ((b >> 2) & 0x33);
  return (b + (b >> 4)) & 0x0F;
}

class _GlobePainter extends CustomPainter {
  final List<_Cell> cells;
  final ui.Image? glow;
  final _Pt? myPos;
  final ui.Image? earth;
  final ui.Image? earthNight;
  final List<_Pt> grid;
  final List<double> gridU, gridV;
  final Int32List nightCol;
  final int rows, cols;
  final List<List<_Pt>> land;
  final double rotLng, rotLat, scale;

  _GlobePainter({
    required this.cells,
    required this.glow,
    required this.myPos,
    required this.earth,
    required this.earthNight,
    required this.grid,
    required this.gridU,
    required this.gridV,
    required this.nightCol,
    required this.rows,
    required this.cols,
    required this.land,
    required this.rotLng,
    required this.rotLat,
    required this.scale,
  });

  static final Float64List _identity = Float64List.fromList(
      <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = math.min(size.width, size.height) / 2 * 0.82 * scale;
    final centre = Offset(cx, cy);

    final ca = math.cos(rotLng), sa = math.sin(rotLng);
    final cb = math.cos(rotLat), sb = math.sin(rotLat);

    canvas.drawCircle(
        centre,
        r * 1.18,
        Paint()
          ..shader = ui.Gradient.radial(centre, r * 1.18,
              [const Color(0x5532A8FF), const Color(0x0032A8FF)], [0.82, 1.0]));

    canvas.drawCircle(
        centre,
        r,
        Paint()
          ..shader = ui.Gradient.radial(
              Offset(cx - r * 0.3, cy - r * 0.3), r * 1.35, [
            const Color(0xFF11365F),
            const Color(0xFF0A1C36),
            const Color(0xFF030A18),
          ], [
            0.0,
            0.55,
            1.0
          ]));

    canvas.save();
    canvas.clipPath(
        ui.Path()..addOval(Rect.fromCircle(center: centre, radius: r)));

    if (earth != null && grid.isNotEmpty) {
      _paintTexturedSphere(canvas, cx, cy, r, ca, sa, cb, sb);
    } else {
      _paintVectorFallback(canvas, cx, cy, r, ca, sa, cb, sb);
    }
    // Dim veil over the surface BEFORE the footprints. The footprint glows
    // are additive, so over already-bright terrain (snow, desert, cloud)
    // white points would have nothing to rise above and vanish. Darkening
    // the surface gives every glow headroom to stand out.
    canvas.drawCircle(centre, r, Paint()..color = const Color(0x9E0A1422));
    _paintHeatmap(canvas, cx, cy, r, ca, sa, cb, sb);
    _paintMyPos(canvas, cx, cy, r, ca, sa, cb, sb);
    canvas.restore();

    canvas.drawCircle(
        centre,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0x5562A8FF));
  }

  void _paintTexturedSphere(Canvas canvas, double cx, double cy, double r,
      double ca, double sa, double cb, double sb) {
    final n = grid.length;
    final sx = Float64List(n), sy = Float64List(n), sz = Float64List(n);
    for (var i = 0; i < n; i++) {
      final p = grid[i];
      final x1 = p.x * ca + p.z * sa;
      final z1 = -p.x * sa + p.z * ca;
      final y1 = p.y;
      final y2 = y1 * cb - z1 * sb;
      final z2 = y1 * sb + z1 * cb;
      sx[i] = cx + x1 * r;
      sy[i] = cy - y2 * r;
      sz[i] = z2;
    }

    var vis = 0;
    for (var ri = 0; ri < rows - 1; ri++) {
      for (var ci = 0; ci < cols - 1; ci++) {
        final tl = ri * cols + ci;
        if (sz[tl] > 0 &&
            sz[tl + 1] > 0 &&
            sz[tl + cols] > 0 &&
            sz[tl + cols + 1] > 0) {
          vis++;
        }
      }
    }
    if (vis == 0) return;

    final m = vis * 6;
    final pos = Float32List(m * 2);
    final dW = earth!.width.toDouble(), dH = earth!.height.toDouble();
    final tDay = Float32List(m * 2);
    final hasNight = earthNight != null && nightCol.length == n;
    final nW = hasNight ? earthNight!.width.toDouble() : 0.0;
    final nH = hasNight ? earthNight!.height.toDouble() : 0.0;
    final tNight = hasNight ? Float32List(m * 2) : null;
    final colNight = hasNight ? Int32List(m) : null;
    var kv = 0;
    void emit(int idx) {
      final p2 = kv * 2;
      pos[p2] = sx[idx];
      pos[p2 + 1] = sy[idx];
      tDay[p2] = gridU[idx] * dW;
      tDay[p2 + 1] = gridV[idx] * dH;
      if (tNight != null) {
        tNight[p2] = gridU[idx] * nW;
        tNight[p2 + 1] = gridV[idx] * nH;
        colNight![kv] = nightCol[idx];
      }
      kv++;
    }

    for (var ri = 0; ri < rows - 1; ri++) {
      for (var ci = 0; ci < cols - 1; ci++) {
        final tl = ri * cols + ci;
        final tr = tl + 1, bl = tl + cols, br = bl + 1;
        if (!(sz[tl] > 0 && sz[tr] > 0 && sz[bl] > 0 && sz[br] > 0)) continue;
        emit(tl);
        emit(tr);
        emit(bl);
        emit(tr);
        emit(br);
        emit(bl);
      }
    }

    canvas.drawVertices(
      ui.Vertices.raw(ui.VertexMode.triangles, pos, textureCoordinates: tDay),
      BlendMode.srcOver,
      Paint()
        ..isAntiAlias = true
        ..filterQuality = FilterQuality.high
        ..shader =
            ui.ImageShader(earth!, TileMode.clamp, TileMode.clamp, _identity),
    );

    if (hasNight) {
      canvas.drawVertices(
        ui.Vertices.raw(ui.VertexMode.triangles, pos,
            textureCoordinates: tNight, colors: colNight),
        BlendMode.modulate,
        Paint()
          ..isAntiAlias = true
          ..filterQuality = FilterQuality.high
          ..shader = ui.ImageShader(
              earthNight!, TileMode.clamp, TileMode.clamp, _identity),
      );
    }
  }

  void _paintVectorFallback(Canvas canvas, double cx, double cy, double r,
      double ca, double sa, double cb, double sb) {
    final coast = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xCC57C98A)
      ..isAntiAlias = true;
    for (final ring in land) {
      ui.Path? path;
      for (final v in ring) {
        final x1 = v.x * ca + v.z * sa;
        final z1 = -v.x * sa + v.z * ca;
        final y1 = v.y;
        final y2 = y1 * cb - z1 * sb;
        final z2 = y1 * sb + z1 * cb;
        if (z2 > 0) {
          final o = Offset(cx + x1 * r, cy - y2 * r);
          if (path == null) {
            path = ui.Path()..moveTo(o.dx, o.dy);
          } else {
            path.lineTo(o.dx, o.dy);
          }
        } else if (path != null) {
          canvas.drawPath(path, coast);
          path = null;
        }
      }
      if (path != null) canvas.drawPath(path, coast);
    }
  }

  /// Additive heat map: one soft glow sprite per visited cell, sized + tinted
  /// by visit density. Additive blending means overlapping / repeatedly
  /// visited areas accumulate to a white-hot core — the "city lights" look.
  void _paintHeatmap(Canvas canvas, double cx, double cy, double r, double ca,
      double sa, double cb, double sb) {
    if (glow == null || cells.isEmpty) return;
    final s = glow!.width.toDouble();
    final n = cells.length;

    // Count visible cells first, then fill raw Float32List buffers (no
    // per-frame object garbage even with tens of thousands of points).
    var vis = 0;
    for (final cell in cells) {
      final v = cell.v;
      final z2 = v.y * sb + (-v.x * sa + v.z * ca) * cb;
      if (z2 > 0) vis++;
    }
    if (vis == 0) return;

    final rstt = Float32List(vis * 4);
    final rects = Float32List(vis * 4);
    final colors = Int32List(vis);
    var i = 0;
    for (var ci = 0; ci < n; ci++) {
      final v = cells[ci].v;
      final x1 = v.x * ca + v.z * sa;
      final z1 = -v.x * sa + v.z * ca;
      final y1 = v.y;
      final y2 = y1 * cb - z1 * sb;
      final z2 = y1 * sb + z1 * cb;
      if (z2 <= 0) continue;
      final t = cells[ci].intensity;
      final edge = z2.clamp(0.0, 1.0);
      // Very fine: a lone footprint is well under 1 px; density (many
      // overlapping points), not size, is what builds a big bright area. diam
      // scales with the globe radius r (= …·zoom); the low floor lets footprints
      // THIN as you zoom the globe out instead of staying a fixed fat dot —
      // sparse points fade, dense clusters stay bright via additive blending.
      final diam = (r * (0.0012 + 0.0012 * t)).clamp(0.3, 1.5);
      final scl = diam / s;
      final b = i * 4;
      rstt[b] = scl; // scos (rotation 0)
      rstt[b + 1] = 0; // ssin
      rstt[b + 2] = (cx + x1 * r) - diam / 2; // tx (centre the sprite)
      rstt[b + 3] = (cy - y2 * r) - diam / 2; // ty
      rects[b] = 0;
      rects[b + 1] = 0;
      rects[b + 2] = s;
      rects[b + 3] = s;
      // Dim amber when rare → warm white when frequent; additive blending
      // pushes dense clusters the rest of the way to white-hot.
      final col = Color.lerp(
          const Color(0xFFFF8A1E), const Color(0xFFFFF4D6), t)!;
      // Slightly higher alpha to compensate for the tinier dot size.
      colors[i] =
          col.withValues(alpha: (0.55 + 0.45 * t) * edge).toARGB32();
      i++;
    }
    canvas.drawRawAtlas(
      glow!,
      rstt,
      rects,
      colors,
      BlendMode.modulate,
      null,
      Paint()
        ..blendMode = BlendMode.plus
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true,
    );
  }

  /// Distinct cyan "you are here" marker (solid, not additive) so it never
  /// gets confused with the amber footprint heat map.
  void _paintMyPos(Canvas canvas, double cx, double cy, double r, double ca,
      double sa, double cb, double sb) {
    final p = myPos;
    if (p == null) return;
    final x1 = p.x * ca + p.z * sa;
    final z1 = -p.x * sa + p.z * ca;
    final y1 = p.y;
    final y2 = y1 * cb - z1 * sb;
    final z2 = y1 * sb + z1 * cb;
    if (z2 <= 0) return; // on the far side
    final o = Offset(cx + x1 * r, cy - y2 * r);
    final cr = (r * 0.013).clamp(4.0, 11.0);
    canvas.drawCircle(
        o, cr * 2.6, Paint()..color = const Color(0x5500E5FF)); // halo
    canvas.drawCircle(o, cr + 2.2, Paint()..color = Colors.white); // ring
    canvas.drawCircle(o, cr, Paint()..color = const Color(0xFF00B0FF)); // core
  }

  @override
  bool shouldRepaint(covariant _GlobePainter old) =>
      old.rotLng != rotLng ||
      old.rotLat != rotLat ||
      old.scale != scale ||
      !identical(old.myPos, myPos) ||
      !identical(old.cells, cells) ||
      !identical(old.glow, glow) ||
      !identical(old.earth, earth) ||
      !identical(old.earthNight, earthNight) ||
      !identical(old.land, land);
}
