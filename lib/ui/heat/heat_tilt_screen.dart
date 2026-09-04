import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/heat/heat3d_camera.dart';
import '../../services/heat/heat_field.dart';
import '../../services/heat/heat_palette.dart';
import '../../services/heat/heat_source.dart';
import '../../services/heat/heat_tile_provider.dart';
import '../../services/heat/tile3d_engine.dart';
import '../../services/geo/region_cloud_source.dart';
import '../../services/geo/region_stats.dart';
import '../common/flag_badge.dart';
import '../common/pixel.dart';
import 'heat_style_sheet.dart';
import 'region_cloud_layer.dart';

/// 3D「热力山脊」— the map switched into a live 3D mode, Google-Maps style:
/// a perspective camera over a REAL tile plane. Tiles stream in continuously
/// as you move (near ground at native resolution, far ground from coarser
/// pyramid levels, cached ancestors standing in while fetches run), gestures
/// are anchored to the ground like a map — nothing is a frozen snapshot.
///
///   单指平移 · 双指缩放（围绕手指）/ 旋转 / 上下俯仰 · 双击放大 · 指南针回正
///
/// The heat ridges are a world-anchored density field over the visible
/// ground, rebuilt in the background when the camera settles somewhere new.
class Heat3DView extends ConsumerStatefulWidget {
  final Heat3DCamera initialCamera;
  final HeatSnapshot heat;

  /// Called with the final camera so the 2D map lands where 3D left off.
  final void Function(double lat, double lng, double zoom) onExit;
  const Heat3DView({
    super.key,
    required this.initialCamera,
    required this.heat,
    required this.onExit,
  });

  @override
  ConsumerState<Heat3DView> createState() => _Heat3DViewState();
}

class _Heat3DViewState extends ConsumerState<Heat3DView>
    with SingleTickerProviderStateMixin {
  static const double _kRestPitch = 52;

  late final Heat3DCamera _cam = widget.initialCamera;
  Tile3DEngine? _engine;

  // World-anchored ridge field.
  HeatField? _field;
  Float32List? _corners;
  double _fieldOriginX01 = 0, _fieldOriginY01 = 0;
  double _fieldScale = 1; // world01 → field px at capture
  double _fieldZoom = 0;
  ({double x0, double y0, double x1, double y1})? _fieldCover01;
  Timer? _fieldDebounce;
  bool _buildingField = false;

  // Style signature → reload the heat snapshot when the sheet changes it.
  String _styleSig = '';

  /// 山脊 (the heat ridges) or 区域 (the administrative point cloud). Both
  /// share this screen's camera, so switching keeps you exactly where you are.
  bool _regionMode = false;
  RegionCloudSource? _cloud;

  /// 入场倾斜（0° → [_kRestPitch]，700 ms）。系统「移除动画」时**根本不建**，
  /// 所以它是可空的：原来写成 `late final … = AnimationController(vsync: this)`，
  /// 而 late final 是懒初始化——省掉动画那条路径下谁都没碰过它，直到 dispose()
  /// 里 `_enter.dispose()` 才第一次构造，此时 element 已经 deactivate，
  /// createTicker 去查 TickerMode 祖先就撞断言（"Looking up a deactivated
  /// widget's ancestor is unsafe"）：开了「移除动画」的用户每退出一次 3D 热图
  /// 就炸一次。
  AnimationController? _enter;
  bool _entered = false;

  // Gesture bookkeeping.
  double _gestureStartZoom = 16;
  double _gestureStartYaw = 0;
  ({double x01, double y01})? _anchor01;
  Offset? _lastFocal;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _engine = Tile3DEngine(
      provider: s.mapProvider,
      style: s.mapStyle,
      heat: widget.heat,
      customOsmUrl: s.customOsmTileUrl,
      ovitalUrl: s.ovitalTileUrl,
    );
    _styleSig = _sigOf(s);
    WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildField());
  }

  static String _sigOf(dynamic s) =>
      '${s.heatPalette}|${s.heatExposure}|${s.heatWidth}|${s.heatRange}'
      '|${s.heatRangeFromMs}|${s.heatRangeToMs}|${s.heatFogBaseline}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entered) return;
    _entered = true;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      // 一步到位落到最终俯仰角：不建控制器、不走那 700 ms。
      _cam.pitchDeg = _kRestPitch;
    } else {
      final ctrl = _enter = AnimationController(
          vsync: this, duration: const Duration(milliseconds: 700));
      final curve = CurvedAnimation(parent: ctrl, curve: Curves.easeOutCubic);
      curve.addListener(() {
        if (mounted) setState(() => _cam.pitchDeg = _kRestPitch * curve.value);
      });
      ctrl.forward();
    }
  }

  @override
  void dispose() {
    _fieldDebounce?.cancel();
    _enter?.dispose();
    _engine?.dispose();
    _cloud?.dispose();
    super.dispose();
  }

  // ─── 区域点云 ───

  /// Enter/leave the region cloud. The cloud loads lazily the first time and
  /// then follows the same time window as the heat map.
  Future<void> _toggleRegionMode() async {
    final on = !_regionMode;
    setState(() => _regionMode = on);
    if (!on) {
      // Back to the ridges: the field went stale while we were away.
      _rebuildField();
      return;
    }
    await _loadCloud();
    _fitAllRegions();
  }

  /// Frame every region at once — entering 区域 means "show me everywhere
  /// I've been", and from there the usual gestures dig into any corner.
  void _fitAllRegions() {
    final rs = _cloud?.regions ?? const <RegionStat>[];
    if (rs.isEmpty || _cam.viewport == Size.zero) return;
    var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0;
    for (final r in rs) {
      final x0 = HeatIndex.lngToWorldX(r.minLng);
      final x1 = HeatIndex.lngToWorldX(r.maxLng);
      final y0 = HeatIndex.latToWorldY(r.maxLat);
      final y1 = HeatIndex.latToWorldY(r.minLat);
      minX = math.min(minX, math.min(x0, x1));
      maxX = math.max(maxX, math.max(x0, x1));
      minY = math.min(minY, math.min(y0, y1));
      maxY = math.max(maxY, math.max(y0, y1));
    }
    // A tilted view spends the top half on distance, so fit into the lower
    // portion and leave room for the labels.
    final spanX = math.max(maxX - minX, 1e-6);
    final spanY = math.max(maxY - minY, 1e-6);
    final vp = _cam.viewport;
    final zx = math.log(vp.width * 0.72 / (spanX * 256)) / math.ln2;
    final zy = math.log(vp.height * 0.45 / (spanY * 256)) / math.ln2;
    setState(() {
      _cam.centerX01 = (minX + maxX) / 2;
      _cam.centerY01 = (minY + maxY) / 2;
      _cam.zoom = math.min(zx, zy).clamp(Heat3DCamera.minZoom, 16.0);
      _cam.clampAll();
    });
  }

  Future<void> _loadCloud() async {
    final s = ref.read(settingsProvider);
    final db = ref.read(dbProvider);
    _cloud ??= RegionCloudSource(
      db: db,
      geocoder: ref.read(geocodingServiceProvider),
    )..addListener(() {
        if (mounted) setState(() {});
      });
    final layers = await db.allLayers();
    final win = heatTimeWindow(s);
    await _cloud!.load(
      layerIds: layers.where((l) => l.visible).map((l) => l.id).toList(),
      from: win.$1,
      to: win.$2,
    );
  }

  /// Fly to a region and frame its extent, then hand it to the ridge view —
  /// "点开查看全部" in the small: tap a label, land in its streets.
  void _flyToRegion(RegionStat r) {
    final x0 = HeatIndex.lngToWorldX(r.minLng), x1 = HeatIndex.lngToWorldX(r.maxLng);
    final y0 = HeatIndex.latToWorldY(r.maxLat), y1 = HeatIndex.latToWorldY(r.minLat);
    final spanX = (x1 - x0).abs(), spanY = (y1 - y0).abs();
    final vp = _cam.viewport;
    // Fit the extent into ~70% of the viewport.
    var zoom = 12.0;
    if (spanX > 0 && spanY > 0) {
      final zx = math.log(vp.width * 0.7 / (spanX * 256)) / math.ln2;
      final zy = math.log(vp.height * 0.7 / (spanY * 256)) / math.ln2;
      zoom = math.min(zx, zy);
    }
    setState(() {
      _cam.centerX01 = HeatIndex.lngToWorldX(r.lng);
      _cam.centerY01 = HeatIndex.latToWorldY(r.lat);
      _cam.zoom = zoom.clamp(Heat3DCamera.minZoom, Heat3DCamera.maxZoom);
      _cam.clampAll();
      _regionMode = false;
    });
    _rebuildField();
  }

  /// The country you have the most days in — labels there stay bare
  /// (上海市), everywhere else gets its country appended (东京 · 日本).
  String? _homeCountry(List<RegionStat> regions) {
    final byCountry = <String, int>{};
    for (final r in regions) {
      if (r.country.isEmpty) continue;
      byCountry[r.country] = (byCountry[r.country] ?? 0) + r.dayCount;
    }
    if (byCountry.isEmpty) return null;
    return byCountry.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  Future<void> _showRegionList() async {
    final cloud = _cloud;
    if (cloud == null) return;
    final picked = await showModalBottomSheet<RegionStat>(
      context: context,
      useRootNavigator: true,
      backgroundColor: const Color(0xFF1A2733),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (ctx) => _RegionListSheet(regions: cloud.regions),
    );
    if (picked != null && mounted) _flyToRegion(picked);
  }

  // ─── World-anchored ridge field ───

  /// Visible ground bbox in world01, padded, far-clamped.
  ({double x0, double y0, double x1, double y1}) _groundBbox01() {
    double minX = _cam.centerX01, maxX = _cam.centerX01;
    double minY = _cam.centerY01, maxY = _cam.centerY01;
    final w = _cam.viewport.width, h = _cam.viewport.height;
    for (final p in [
      Offset(0, h),
      Offset(w, h),
      Offset.zero,
      Offset(w, 0),
      Offset(w / 2, 0),
      Offset(w / 2, h),
    ]) {
      final g = _cam.unproject(p);
      if (g == null) continue;
      final w01 = _cam.modelToWorld(g.mx, g.my);
      minX = math.min(minX, w01.x01);
      maxX = math.max(maxX, w01.x01);
      minY = math.min(minY, w01.y01);
      maxY = math.max(maxY, w01.y01);
    }
    final padX = (maxX - minX) * 0.15 + 1e-9;
    final padY = (maxY - minY) * 0.15 + 1e-9;
    return (
      x0: (minX - padX).clamp(0.0, 1.0),
      y0: (minY - padY).clamp(0.0, 1.0),
      x1: (maxX + padX).clamp(0.0, 1.0),
      y1: (maxY + padY).clamp(0.0, 1.0),
    );
  }

  /// [settle] = the gesture just ended: rebuild sooner and on a much smaller
  /// zoom drift, so the stretched-ridge window is short and shallow.
  void _scheduleFieldRebuild({bool settle = false}) {
    // The region cloud doesn't use the density field — don't burn CPU on it
    // while panning around the labels.
    if (_regionMode) return;
    _fieldDebounce?.cancel();
    _fieldDebounce =
        Timer(Duration(milliseconds: settle ? 70 : 280), () {
      if (!mounted) return;
      final cover = _fieldCover01;
      final needZoom = (_cam.zoom - _fieldZoom).abs() > (settle ? 0.08 : 0.35);
      var outside = cover == null;
      if (cover != null) {
        final now = _groundBbox01();
        outside = now.x0 < cover.x0 ||
            now.y0 < cover.y0 ||
            now.x1 > cover.x1 ||
            now.y1 > cover.y1;
      }
      if (needZoom || outside) _rebuildField();
    });
  }

  Future<void> _rebuildField() async {
    final engine = _engine;
    if (engine == null || _buildingField || _cam.viewport == Size.zero) return;
    _buildingField = true;
    try {
      final bbox = _groundBbox01();
      final snap = engine.heat;
      final scale = _cam.scale; // world01 → px at the capture zoom
      // ~3 screen px per cell at the centre; cap the grid for huge tilts.
      const cell = 3.0;
      final wPx = (bbox.x1 - bbox.x0) * scale;
      final hPx = (bbox.y1 - bbox.y0) * scale;
      final shrink =
          math.max(1.0, math.max(wPx / (cell * 420), hPx / (cell * 700)));
      final fScale = scale / shrink;
      final lines = <double>[], dots = <double>[], fogPts = <double>[];
      final fogW = <double>[];
      final segs = snap.index.segs;
      final fogBaseline =
          _cam.zoom.floor() <= kHeatFogBaselineMaxZoom;
      double px(double x01) => (x01 - bbox.x0) * fScale;
      double py(double y01) => (y01 - bbox.y0) * fScale;
      snap.index.forEachIn(bbox.x0, bbox.y0, bbox.x1, bbox.y1, (i) {
        final o = i << 2;
        if (snap.index.kinds[i] == 1) {
          if (!fogBaseline) return;
          fogPts
            ..add(px(segs[o]))
            ..add(py(segs[o + 1]));
          fogW.add(snap.index.weights[i]);
          return;
        }
        final ax = px(segs[o]), ay = py(segs[o + 1]);
        final bx = px(segs[o + 2]), by = py(segs[o + 3]);
        if ((ax - bx).abs() < 0.5 && (ay - by).abs() < 0.5) {
          dots
            ..add(ax)
            ..add(ay);
        } else {
          lines
            ..add(ax)
            ..add(ay)
            ..add(bx)
            ..add(by);
        }
      });
      final z = _cam.zoom - math.log(shrink) / math.ln2;
      final strokePx = heatStrokePx(z.floor(), snap.width) *
          math.pow(2.0, z - z.floor()).toDouble();
      final field = buildHeatField(
        width: (bbox.x1 - bbox.x0) * fScale,
        height: (bbox.y1 - bbox.y0) * fScale,
        input: HeatFieldInput(
          lines: Float32List.fromList(lines),
          dots: Float32List.fromList(dots),
          fogPts: Float32List.fromList(fogPts),
          fogW: Float32List.fromList(fogW),
          fogBlockPx: heatFogBlockPx(z.floor()) *
              math.pow(2.0, z - z.floor()).toDouble(),
        ),
        strokePx: strokePx,
        exposure: snap.exposure,
      );
      if (!mounted) return;
      setState(() {
        _field = field;
        _corners = field.cornerHeights();
        _fieldOriginX01 = bbox.x0;
        _fieldOriginY01 = bbox.y0;
        _fieldScale = fScale;
        _fieldZoom = _cam.zoom;
        _fieldCover01 = bbox;
      });
    } finally {
      _buildingField = false;
    }
  }

  Future<void> _reloadSnapshot() async {
    final s = ref.read(settingsProvider);
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    final win = heatTimeWindow(s);
    final snap = await loadHeatSnapshot(
      db: db,
      layerIds: layers.where((l) => l.visible).map((l) => l.id).toList(),
      mapProvider: s.mapProvider,
      style: HeatStyle(
          palette: s.heatPalette, exposure: s.heatExposure, width: s.heatWidth),
      from: win.$1,
      to: win.$2,
      includeFog: s.heatFogBaseline,
      generation: DateTime.now().millisecondsSinceEpoch,
    );
    if (!mounted) return;
    _engine?.heat = snap;
    _rebuildField();
  }

  // ─── Gestures ───

  void _onScaleStart(ScaleStartDetails d) {
    // 手一碰就掐掉入场动画；开了「移除动画」时它根本没建过（null）。
    _enter?.stop();
    _gestureStartZoom = _cam.zoom;
    _gestureStartYaw = _cam.yawDeg;
    _lastFocal = d.focalPoint;
    final g = _cam.unproject(d.focalPoint);
    _anchor01 = g == null ? null : _cam.modelToWorld(g.mx, g.my);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final last = _lastFocal ?? d.focalPoint;
    final delta = d.focalPoint - last;
    _lastFocal = d.focalPoint;
    setState(() {
      if (d.pointerCount >= 2) {
        _cam.zoom = (_gestureStartZoom + math.log(d.scale) / math.ln2)
            .clamp(Heat3DCamera.minZoom, Heat3DCamera.maxZoom);
        _cam.yawDeg = _gestureStartYaw + d.rotation * 180 / math.pi;
        // Tilt on parallel vertical movement (not while actively pinching).
        if ((d.scale - 1).abs() < 0.08) {
          _cam.pitchDeg = _cam.pitchDeg - delta.dy * 0.25;
        }
        _cam.clampAll();
      }
      final a = _anchor01;
      if (a != null) {
        _cam.anchorWorldToScreen(a.x01, a.y01, d.focalPoint);
        _cam.clampAll();
      }
    });
    _scheduleFieldRebuild();
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _anchor01 = null;
    _scheduleFieldRebuild(settle: true);
  }

  void _onDoubleTapDown(TapDownDetails d) {
    final g = _cam.unproject(d.localPosition);
    setState(() {
      final a = g == null ? null : _cam.modelToWorld(g.mx, g.my);
      _cam.zoom =
          (_cam.zoom + 1).clamp(Heat3DCamera.minZoom, Heat3DCamera.maxZoom);
      if (a != null) _cam.anchorWorldToScreen(a.x01, a.y01, d.localPosition);
      _cam.clampAll();
    });
    _scheduleFieldRebuild(settle: true);
  }

  void _resetView() {
    setState(() {
      _cam.yawDeg = 0;
      _cam.pitchDeg =
          math.min(_kRestPitch, Heat3DCamera.maxPitchForZoom(_cam.zoom));
    });
  }

  void _exit() {
    widget.onExit(
      HeatIndex.worldYToLat(_cam.centerY01),
      HeatIndex.worldXToLng(_cam.centerX01),
      _cam.zoom,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final sig = _sigOf(s);
    if (sig != _styleSig) {
      _styleSig = sig;
      // Style sheet (or the time chip) changed something — rebuild the
      // snapshot + field, and re-roll the region cloud on the new window.
      scheduleMicrotask(_reloadSnapshot);
      if (_regionMode) scheduleMicrotask(_loadCloud);
    }
    final palette = HeatPalette.byIndex(s.heatPalette);
    final engine = _engine!;
    return Material(
      color: const Color(0xFF0F1923),
      child: Stack(
        fit: StackFit.expand,
        children: [
          LayoutBuilder(builder: (ctx, c) {
            _cam.viewport = Size(c.maxWidth, c.maxHeight);
            final cloud = _cloud;
            final labels = _regionMode && cloud != null
                ? layoutRegionLabels(
                    regions: cloud.regions,
                    cam: _cam,
                    maxDayCount: cloud.maxDayCount,
                    homeCountry: _homeCountry(cloud.regions),
                  )
                : const <PlacedLabel>[];
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              onDoubleTapDown: _onDoubleTapDown,
              onDoubleTap: () {},
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _Heat3DPainter(
                      cam: _cam,
                      engine: engine,
                      field: _field,
                      corners: _corners,
                      fieldOriginX01: _fieldOriginX01,
                      fieldOriginY01: _fieldOriginY01,
                      fieldScale: _fieldScale,
                      fieldZoom: _fieldZoom,
                      palette: palette,
                      heightMul: s.heatHeight,
                      regionCells: _regionMode ? cloud?.cells : null,
                      regionMaxDays: cloud?.maxDayCount ?? 0,
                      camRev: Object.hash(_cam.centerX01, _cam.centerY01,
                          _cam.zoom, _cam.pitchDeg, _cam.yawDeg),
                    ),
                  ),
                  for (final l in labels)
                    Positioned(
                      left: l.rect.left,
                      top: l.rect.top,
                      child: RegionLabelChip(
                        placed: l,
                        onTap: () => _flyToRegion(l.region),
                      ),
                    ),
                ],
              ),
            );
          }),
          // Top scrim + chrome.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: Container(
                height: 120,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xB3000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '回到 2D 地图',
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      onPressed: _exit,
                    ),
                    // The chips take whatever is left after the fixed icon
                    // buttons and shrink to fit rather than overflow — the bar
                    // is tight on a narrow phone once every control is in.
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _ModeToggle(
                                regionMode: _regionMode,
                                onChanged: (want) {
                                  if (want != _regionMode) _toggleRegionMode();
                                },
                              ),
                              const SizedBox(width: 6),
                              _TimeRangeChip(settings: s),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '回正（朝北 · 默认俯仰）',
                      icon: Transform.rotate(
                        angle: -_cam.yawDeg * math.pi / 180,
                        child: const Icon(Icons.explore_outlined,
                            color: Colors.white),
                      ),
                      onPressed: _resetView,
                    ),
                    if (_regionMode)
                      IconButton(
                        tooltip: '查看全部区域',
                        icon: const Icon(Icons.format_list_bulleted_rounded,
                            color: Colors.white),
                        onPressed: _showRegionList,
                      )
                    else
                      IconButton(
                        tooltip: '热图样式',
                        icon:
                            const Icon(Icons.tune_rounded, color: Colors.white),
                        onPressed: () => showHeatStyleSheet(context),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (!_regionMode && _field != null && _field!.isEmpty)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 48,
              child: IgnorePointer(
                child: Center(
                  child: Text('这一片还没有轨迹热度 — 拖动地图去有足迹的地方',
                      style: TextStyle(color: Colors.white70)),
                ),
              ),
            ),
          if (_regionMode &&
              _cloud != null &&
              !_cloud!.loading &&
              _cloud!.regions.isEmpty)
            const Positioned(
              left: 24,
              right: 24,
              bottom: 48,
              child: IgnorePointer(
                child: Center(
                  child: Text('还没有可归属的记录 — 联网后会自动识别所在城市',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70)),
                ),
              ),
            ),
          // Zoom badge + whatever is loading, pixel-style, bottom-left. The
          // top bar is too tight to carry a spinner as well.
          Positioned(
            left: 12,
            bottom: 12,
            child: IgnorePointer(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('z${_cam.zoom.toStringAsFixed(1)}',
                        style: PixelText.label.copyWith(color: Colors.white70)),
                  ),
                  AnimatedBuilder(
                    animation: engine,
                    builder: (_, __) {
                      final busyRegion = _regionMode &&
                          (_cloud?.loading == true || _cloud?.naming == true);
                      final busyTiles = engine.inflight > 0;
                      if (!busyRegion && !busyTiles) {
                        return const SizedBox.shrink();
                      }
                      final text = busyRegion
                          ? (_cloud!.loading
                              ? '统计中…'
                              : '识别中 ${_cloud!.pending}')
                          : '载入瓦片…';
                      return Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const SizedBox(
                              width: 9,
                              height: 9,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.6, color: Colors.white54),
                            ),
                            const SizedBox(width: 6),
                            Text(text,
                                style: PixelText.label
                                    .copyWith(color: Colors.white70)),
                          ]),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws the live tile plane through the ground homography, then the
/// world-anchored heat ridges via per-vertex projection.
class _Heat3DPainter extends CustomPainter {
  final Heat3DCamera cam;
  final Tile3DEngine engine;
  final HeatField? field;
  final Float32List? corners;
  final double fieldOriginX01, fieldOriginY01, fieldScale;

  /// Camera zoom the field was built at — the ground stretches by
  /// 2^(zoom − fieldZoom) between rebuilds and the ridge must stretch with it.
  final double fieldZoom;
  final HeatPalette palette;
  final double heightMul;

  /// Non-null → draw the 区域点云 instead of the ridges.
  final List<CellAgg>? regionCells;
  final int regionMaxDays;
  final int camRev;

  _Heat3DPainter({
    required this.cam,
    required this.engine,
    required this.field,
    required this.corners,
    required this.fieldOriginX01,
    required this.fieldOriginY01,
    required this.fieldScale,
    required this.fieldZoom,
    required this.palette,
    required this.heightMul,
    required this.regionCells,
    required this.regionMaxDays,
    required this.camRev,
  }) : super(repaint: engine);

  static Int32List? _colorCache;
  static Object? _colorKey;
  static List<_RidgeBand>? _orderCache;
  static Object? _orderKey;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF0F1923));
    if (cam.viewport != size) cam.viewport = size;

    final tiles = selectVisibleTiles(cam);
    engine.markUsed([for (final t in tiles) (z: t.z, x: t.x, y: t.y)]);

    // ── Ground: live tiles under the plane homography. ──
    canvas.save();
    canvas.transform(cam.groundMatrix());
    final tilePaint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = false;
    final placeholder = Paint()..color = const Color(0xFFEAE6DE);
    var bounds = Rect.zero;
    for (final t in tiles) {
      // A hair of overlap hides the hairline seams perspective sampling
      // opens between neighbouring tiles.
      final dst = t.dstModel.inflate(t.dstModel.width * 0.002);
      bounds = bounds == Rect.zero ? dst : bounds.expandToInclude(dst);
      final got = engine.baseTileOrAncestor(t.z, t.x, t.y);
      if (got == null) {
        canvas.drawRect(dst, placeholder);
      } else {
        canvas.drawImageRect(got.image, got.src, dst, tilePaint);
      }
    }
    final region = regionCells;
    if (bounds != Rect.zero) {
      // Press the ground dark so the glow reads (same intent as the 2D dark
      // veil); the ridges above stay at full brightness. The region cloud
      // wants the map further back still — there the labels are the subject.
      canvas.drawRect(
          bounds,
          Paint()
            ..color = Colors.black
                .withValues(alpha: region != null ? 0.66 : 0.45));
      final heatPaint = Paint()..filterQuality = FilterQuality.medium;
      for (final t in tiles) {
        if (region != null) break; // the cloud replaces the glow
        final img = engine.heatTile(t.z, t.x, t.y);
        if (img != null) {
          canvas.drawImageRect(
              img,
              Rect.fromLTWH(
                  0, 0, img.width.toDouble(), img.height.toDouble()),
              t.dstModel,
              heatPaint);
        }
      }
    }
    canvas.restore();

    if (region != null) {
      paintRegionCloud(canvas, cam, region, regionMaxDays);
    } else {
      _paintRidges(canvas, size);
    }
  }

  void _paintRidges(Canvas canvas, Size size) {
    final f = field;
    final cs = corners;
    if (f == null || cs == null || f.isEmpty) return;
    final gw = f.gw, gh = f.gh;
    final w1 = gw + 1, h1 = gh + 1;
    // 0.22 × viewport = the height of a spot walked HeatField.refPasses
    // times; everything else is an absolute fraction of that.
    //
    // The ridge's aspect ratio must not depend on how far the camera has
    // drifted from the last field rebuild: the cell step below grows with
    // cam.scale, so the height budget grows with it too (clamped, so a wild
    // pinch can't build a wall before the rebuild lands).
    final drift =
        math.pow(2.0, (cam.zoom - fieldZoom).clamp(-1.0, 1.0)).toDouble();
    final hMax = 0.22 * size.height * heightMul * f.heightScale * drift;

    // Field frame → model px: constant offset + step per cell.
    final originMx = (fieldOriginX01 - cam.centerX01) * cam.scale;
    final originMy = (fieldOriginY01 - cam.centerY01) * cam.scale;
    final step = f.cell * cam.scale / fieldScale;

    final cols = _ridgeColors(hMax, step);
    final chunks = _cellOrder();
    if (chunks.isEmpty) return;

    final pos = Float32List(w1 * h1 * 2);
    for (var y = 0; y < h1; y++) {
      final my = originMy + y * step;
      for (var x = 0; x < w1; x++) {
        final k = y * w1 + x;
        final p = cam.project(originMx + x * step, my, cs[k] * hMax);
        pos[k * 2] = p.dx;
        pos[k * 2 + 1] = p.dy;
      }
    }
    // `Vertices.raw` indices are 16-bit, and the field can hold a few hundred
    // thousand vertices, so the mesh goes out in row bands small enough to
    // address — each band re-based on its own first row. Bands are ordered
    // far → near (as are the cells inside one), so the painter's algorithm
    // still resolves overlaps.
    for (final band in chunks) {
      final r0 = band.row0;
      final rows = band.rows;
      final base = r0 * w1;
      final vpos = Float32List.sublistView(pos, base * 2, (base + rows * w1) * 2);
      final vcol = Int32List.sublistView(cols, base, base + rows * w1);
      final idx = Uint16List(band.cells.length * 6);
      var n = 0;
      for (final c in band.cells) {
        final x = c % gw, y = c ~/ gw - r0;
        final a = y * w1 + x, b = a + 1, cc = a + w1, d = cc + 1;
        idx[n++] = a;
        idx[n++] = b;
        idx[n++] = cc;
        idx[n++] = b;
        idx[n++] = d;
        idx[n++] = cc;
      }
      canvas.drawVertices(
        ui.Vertices.raw(ui.VertexMode.triangles, vpos,
            colors: vcol, indices: idx),
        BlendMode.srcOver,
        Paint()..isAntiAlias = true,
      );
    }
  }

  /// Per-corner ARGB: palette by height, lit from the upper-left, white-hot
  /// peaks. Cached per (field, palette, height, zoom-bucket) — lighting uses
  /// the height/step ratio, which shifts as you zoom.
  Int32List _ridgeColors(double hMax, double stepModelPx) {
    final f = field!;
    final cs = corners!;
    final zoomBucket = (cam.zoom * 2).round();
    final key = Object.hash(
        identityHashCode(f), palette.name, heightMul, zoomBucket);
    if (_colorKey == key && _colorCache != null) return _colorCache!;
    final gw = f.gw, gh = f.gh;
    final w1 = gw + 1, h1 = gh + 1;
    final out = Int32List(w1 * h1);
    const lx = -0.45, ly = -0.45, lz = 0.77;
    for (var y = 0; y < h1; y++) {
      for (var x = 0; x < w1; x++) {
        final k = y * w1 + x;
        final h = cs[k];
        if (h <= 0.005) {
          out[k] = 0;
          continue;
        }
        final hl = cs[y * w1 + math.max(0, x - 1)];
        final hr = cs[y * w1 + math.min(gw, x + 1)];
        final hu = cs[math.max(0, y - 1) * w1 + x];
        final hd = cs[math.min(gh, y + 1) * w1 + x];
        var nx = -(hr - hl) * hMax / (2 * stepModelPx);
        var ny = -(hd - hu) * hMax / (2 * stepModelPx);
        var nz = 1.0;
        final len = math.sqrt(nx * nx + ny * ny + nz * nz);
        nx /= len;
        ny /= len;
        nz /= len;
        final ndl = (nx * lx + ny * ly + nz * lz).clamp(0.0, 1.0);
        final lit = 0.55 + 0.45 * ndl;
        var c = palette.at(h);
        if (h > 0.9) c = Color.lerp(c, Colors.white, (h - 0.9) / 0.1)!;
        final a = _smooth(0.02, 0.15, h);
        final r = (c.r * 255 * lit).round().clamp(0, 255);
        final g = (c.g * 255 * lit).round().clamp(0, 255);
        final b = (c.b * 255 * lit).round().clamp(0, 255);
        final ai = (a * 255).round().clamp(0, 255);
        out[k] = (ai << 24) | (r << 16) | (g << 8) | b;
      }
    }
    _colorKey = key;
    _colorCache = out;
    return out;
  }

  /// Lit cells far → near for the current yaw. Pan/zoom shift or scale every
  /// cell equally, so the order only depends on yaw (bucketed to 1°).
  List<_RidgeBand> _cellOrder() {
    final f = field!;
    final cs = corners!;
    final yawBucket = cam.yawDeg.round();
    final key = Object.hash(identityHashCode(f), yawBucket);
    if (_orderKey == key && _orderCache != null) return _orderCache!;
    final gw = f.gw, gh = f.gh;
    final w1 = gw + 1;
    final yawR = cam.yawDeg * math.pi / 180;
    final cosY = math.cos(yawR), sinY = math.sin(yawR);
    // Rows per band: as many as fit under the 16-bit vertex index (one extra
    // row of vertices closes the last cell row).
    final bandRows = math.max(1, 65500 ~/ w1 - 1);
    final bands = <_RidgeBand>[];
    for (var r0 = 0; r0 < gh; r0 += bandRows) {
      final r1 = math.min(gh, r0 + bandRows);
      final cells = <int>[];
      final depth = <double>[];
      for (var y = r0; y < r1; y++) {
        for (var x = 0; x < gw; x++) {
          final a = y * w1 + x;
          if (cs[a] <= 0.005 &&
              cs[a + 1] <= 0.005 &&
              cs[a + w1] <= 0.005 &&
              cs[a + w1 + 1] <= 0.005) {
            continue;
          }
          cells.add(y * gw + x);
          depth.add((x + 0.5) * sinY + (y + 0.5) * cosY);
        }
      }
      if (cells.isEmpty) continue;
      final orderIdx = List<int>.generate(cells.length, (i) => i)
        ..sort((a, b) => depth[a].compareTo(depth[b]));
      // Far-first inside the band; drop the nearest ones if a band is somehow
      // enormous (dense city at full tilt) rather than stalling the frame.
      final cap = math.min(orderIdx.length, 40000);
      final out = Int32List(cap);
      for (var i = 0; i < cap; i++) {
        out[i] = cells[orderIdx[i]];
      }
      bands.add(_RidgeBand(r0, r1 - r0 + 1, out));
    }
    // Bands far → near as well: rows run north-south, so which end is far
    // depends on the yaw.
    bands.sort((a, b) => cosY >= 0
        ? a.row0.compareTo(b.row0)
        : b.row0.compareTo(a.row0));
    _orderKey = key;
    _orderCache = bands;
    return bands;
  }

  static double _smooth(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  @override
  bool shouldRepaint(covariant _Heat3DPainter old) =>
      old.camRev != camRev ||
      old.field != field ||
      old.palette != palette ||
      old.heightMul != heightMul ||
      old.regionCells != regionCells ||
      old.regionMaxDays != regionMaxDays;
}

/// One horizontal slice of the ridge mesh, small enough for 16-bit indices.
/// [rows] counts VERTEX rows (one more than the cell rows it covers).
class _RidgeBand {
  final int row0;
  final int rows;

  /// Global cell indices (y·gw + x), far → near.
  final Int32List cells;
  const _RidgeBand(this.row0, this.rows, this.cells);
}

/// 山脊 ↔ 区域 switch in the top bar.
class _ModeToggle extends StatelessWidget {
  final bool regionMode;
  final ValueChanged<bool> onChanged;
  const _ModeToggle({required this.regionMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // 两段是一个二选一开关：选中态只靠底色深浅表示，读屏得靠 selected 才知道
    // 自己此刻在哪一段；图标与文字整块排除，标签统一给一份。
    // 注意 ExcludeSemantics 只包「画面」，绝不能包住 GestureDetector——那样会
    // 把它的 tap 动作一起排除掉，读屏就只能读、点不动了。
    Widget seg(String label, IconData icon, bool active, bool target) =>
        Semantics(
          button: true,
          selected: active,
          label: '$label视图',
          child: GestureDetector(
            onTap: () => onChanged(target),
            child: ExcludeSemantics(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: active ? Colors.white24 : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon,
                      size: 14,
                      color: active ? Colors.white : Colors.white54),
                  const SizedBox(width: 4),
                  Text(label,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: active ? Colors.white : Colors.white54)),
                ]),
              ),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('山脊', Icons.terrain_rounded, !regionMode, false),
        seg('区域', Icons.public_rounded, regionMode, true),
      ]),
    );
  }
}

/// The heat map's time window, promoted out of the style sheet: one tap to
/// switch, and it always shows what is currently in effect.
class _TimeRangeChip extends ConsumerWidget {
  final dynamic settings;
  const _TimeRangeChip({required this.settings});

  static String labelOf(dynamic s) {
    switch (s.heatRange) {
      case 1:
        return '今年';
      case 2:
        return '近 30 天';
      case 3:
        final f = s.heatRangeFromMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(s.heatRangeFromMs)
            : null;
        final t = s.heatRangeToMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(s.heatRangeToMs)
            : null;
        String d(DateTime? x) =>
            x == null ? '' : '${x.month}/${x.day}';
        final a = d(f), b = d(t);
        return a.isEmpty && b.isEmpty ? '自定义' : '$a-$b';
      default:
        return '全部';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = settings;
    return PopupMenuButton<int>(
      // tooltip 置空（PopupMenuButton 不给就会用英文的 "Show menu"）：语义由下面
      // 的 Semantics 一次给全，否则读屏会先念「全部」再念一遍 tooltip。
      tooltip: '',
      color: const Color(0xFF1A2733),
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final (v, t) in const [(0, '全部'), (1, '今年'), (2, '近 30 天')])
          PopupMenuItem(
            value: v,
            height: 40,
            child: Row(children: [
              Icon(
                  s.heatRange == v
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 16,
                  color: Colors.white70),
              const SizedBox(width: 8),
              Text(t, style: const TextStyle(color: Colors.white)),
            ]),
          ),
        const PopupMenuItem(
          value: 3,
          height: 40,
          child: Row(children: [
            Icon(Icons.date_range_rounded, size: 16, color: Colors.white70),
            SizedBox(width: 8),
            Text('自定义…', style: TextStyle(color: Colors.white)),
          ]),
        ),
      ],
      onSelected: (v) async {
        final upd = ref.read(settingsProvider.notifier);
        if (v != 3) {
          upd.update((p) => p.copyWith(heatRange: v));
          return;
        }
        if (!context.mounted) return;
        final now = DateTime.now();
        final picked = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2000),
          lastDate: DateTime(now.year + 1),
          initialDateRange: s.heatRangeFromMs > 0
              ? DateTimeRange(
                  start: DateTime.fromMillisecondsSinceEpoch(s.heatRangeFromMs),
                  end: s.heatRangeToMs > 0
                      ? DateTime.fromMillisecondsSinceEpoch(s.heatRangeToMs)
                      : now)
              : null,
        );
        if (picked == null) return;
        upd.update((p) => p.copyWith(
              heatRange: 3,
              heatRangeFromMs: picked.start.millisecondsSinceEpoch,
              heatRangeToMs: picked.end
                  .add(const Duration(days: 1))
                  .millisecondsSinceEpoch,
            ));
      },
      // 可见的只有「全部」「今年」这类词，听不出它说的是哪一维；标签补上「时间
      // 范围」这个主语，并说清点按会打开菜单。
      child: Semantics(
        button: true,
        label: '时间范围：${labelOf(s)}，点按切换',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.schedule_rounded, size: 13, color: Colors.white70),
            const SizedBox(width: 4),
            Text(labelOf(s),
                style: const TextStyle(fontSize: 11.5, color: Colors.white)),
            const Icon(Icons.arrow_drop_down_rounded,
                size: 16, color: Colors.white70),
          ]),
        ),
      ),
    );
  }
}

/// 「查看全部」— every region, busiest first.
class _RegionListSheet extends StatelessWidget {
  final List<RegionStat> regions;
  const _RegionListSheet({required this.regions});

  @override
  Widget build(BuildContext context) {
    final maxDays = regions.isEmpty ? 1 : regions.first.dayCount;
    final totalDays = <int>{for (final r in regions) ...r.days}.length;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(children: [
              const Text('去过的地方',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
              Text('${regions.length} 个地区 · $totalDays 天',
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
          if (regions.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 28),
              child: Text('还没有可归属的记录 — 联网后会自动识别所在城市',
                  style: TextStyle(color: Colors.white54)),
            ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: regions.length,
              itemBuilder: (_, i) {
                final r = regions[i];
                return ListTile(
                  dense: true,
                  leading: SizedBox(
                    width: 34,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FlagBadge(country: r.country, size: 20),
                    ),
                  ),
                  title: Text(r.displayName,
                      style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    [
                      if (r.province.isNotEmpty && r.province != r.displayName)
                        r.province,
                      if (r.country.isNotEmpty) r.country,
                    ].join(' · '),
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${r.dayCount} 天',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize:
                                  12 + 4 * (r.dayCount / maxDays).clamp(0, 1))),
                      Text('${r.points} 点',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 10)),
                    ],
                  ),
                  onTap: () => Navigator.of(context).pop(r),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
