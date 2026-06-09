import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../data/db/database.dart';
import '../../models/models.dart';
import '../fog/fog_engine.dart';
import '../geo/coord_converter.dart';

/// A GPS fix worse than this (in metres) is treated as junk and dropped.
const double _kMaxAccuracyMeters = 150.0;

/// Implied speed (m/s) above which two consecutive fixes can't be one walk.
const double _kMaxSpeedMps = 70.0;

/// Fallback corridor width (metres) for points with a null `width`.
const double _kDefaultTrailWidthMeters = 14.0;

typedef _P = ({LatLng pt, double w});

/// Per-layer style. The single dark veil ("fog") is global; each layer
/// reveals its own corridor (width [widthMeters]) and, if [lineColor] is
/// non-null, draws a translucent coloured line along that corridor — a
/// "line drawn in the fog". [lineColor] already bakes its opacity into the
/// alpha channel; null = no coloured line (plain reveal).
class FogLayerStyle {
  final int layerId;
  final Color? lineColor;
  final double widthMeters;
  const FogLayerStyle({
    required this.layerId,
    required this.lineColor,
    required this.widthMeters,
  });

  @override
  bool operator ==(Object other) =>
      other is FogLayerStyle &&
      other.layerId == layerId &&
      other.lineColor == lineColor &&
      other.widthMeters == widthMeters;
  @override
  int get hashCode => Object.hash(layerId, lineColor, widthMeters);
}

class FogLayer extends StatefulWidget {
  final FogEngine engine;
  final AppDb db;
  final List<FogLayerStyle> layers;

  /// The single fog veil colour (alpha baked in). Light mode = the global
  /// fog colour/opacity; dark mode = a strong dark scrim. The veil covers
  /// the map and is erased along every layer's trail to reveal it.
  final Color veil;

  final double penRadiusMeters;
  final Object? refreshKey;
  final MapProvider mapProvider;
  const FogLayer({
    super.key,
    required this.engine,
    required this.db,
    required this.layers,
    required this.veil,
    required this.penRadiusMeters,
    required this.mapProvider,
    this.refreshKey,
  });

  @override
  State<FogLayer> createState() => _FogLayerState();
}

class _FogLayerState extends State<FogLayer> {
  Map<int, List<List<_P>>> _sessionsByLayer = const {};
  String _trailKey = '';

  List<int> get _layerIds => widget.layers.map((l) => l.layerId).toList();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeReloadTrail();
  }

  @override
  void didUpdateWidget(covariant FogLayer old) {
    super.didUpdateWidget(old);
    _maybeReloadTrail();
  }

  void _maybeReloadTrail() {
    final key = '${_layerIds.join(",")}|${widget.refreshKey}';
    if (key == _trailKey) return;
    _trailKey = key;
    _loadTrail();
  }

  Future<void> _loadTrail() async {
    final layerIds = _layerIds;
    if (layerIds.isEmpty) {
      if (mounted && _sessionsByLayer.isNotEmpty) {
        setState(() => _sessionsByLayer = const {});
      }
      return;
    }
    final maxAge = const Duration(seconds: 30);
    final maxMeters = math.max(widget.penRadiusMeters * 5.0, 50.0);
    final out = <int, List<List<_P>>>{};
    for (final lid in layerIds) {
      final rows = await (widget.db.select(widget.db.trackPoints)
            ..where((p) => p.layerId.equals(lid))
            ..orderBy([(p) => OrderingTerm.asc(p.time)]))
          .get();
      final sessions = <List<_P>>[];
      var current = <_P>[];
      DateTime? lastT;
      double? lastLat, lastLng;
      for (final p in rows) {
        if (p.accuracy != null && p.accuracy! > _kMaxAccuracyMeters) continue;
        if (lastT != null) {
          final dt = p.time.difference(lastT);
          final dist = _haversineMeters(lastLat!, lastLng!, p.lat, p.lng);
          final secs = dt.inMilliseconds / 1000.0;
          final tooOld = dt > maxAge || dt.isNegative;
          final tooFar = dist > maxMeters;
          final tooFast = secs > 0 && (dist / secs) > _kMaxSpeedMps;
          if (tooOld || tooFar || tooFast) {
            if (current.isNotEmpty) sessions.add(current);
            current = [];
          }
        }
        current.add((
          pt: LatLng(p.lat, p.lng),
          w: p.width ?? _kDefaultTrailWidthMeters,
        ));
        lastT = p.time;
        lastLat = p.lat;
        lastLng = p.lng;
      }
      if (current.isNotEmpty) sessions.add(current);
      out[lid] = sessions;
    }
    if (!mounted) return;
    setState(() => _sessionsByLayer = out);
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return MobileLayerTransformer(
      child: IgnorePointer(
        child: CustomPaint(
          size: Size(camera.size.x, camera.size.y),
          painter: _FogPainter(
            camera: camera,
            layers: widget.layers,
            veil: widget.veil,
            mapProvider: widget.mapProvider,
            sessionsByLayer: _sessionsByLayer,
          ),
        ),
      ),
    );
  }
}

class _FogPainter extends CustomPainter {
  final MapCamera camera;
  final List<FogLayerStyle> layers;
  final Color veil;
  final MapProvider mapProvider;
  final Map<int, List<List<_P>>> sessionsByLayer;

  _FogPainter({
    required this.camera,
    required this.layers,
    required this.veil,
    required this.mapProvider,
    required this.sessionsByLayer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Pad for rotation so a rotated viewport's corners stay covered.
    final c = math.cos(camera.rotationRad).abs();
    final s = math.sin(camera.rotationRad).abs();
    final halfW = size.width / 2, halfH = size.height / 2;
    final padX = (halfW * c + halfH * s) - halfW + 1;
    final padY = (halfW * s + halfH * c) - halfH + 1;
    final rect = Rect.fromLTRB(
        -padX, -padY, size.width + padX, size.height + padY);

    if (layers.isEmpty && veil.a == 0) return;

    final needsGcj = CoordConverter.needsGcj02(mapProvider);
    Offset project(LatLng p) {
      if (needsGcj) {
        final g = CoordConverter.wgs84ToGcj02(p.latitude, p.longitude);
        return camera.getOffsetFromOrigin(LatLng(g.lat, g.lng));
      }
      return camera.getOffsetFromOrigin(p);
    }

    final centre = camera.center;
    const refM = 100.0;
    final refDLat = refM / 111320.0;
    final pxPerMeter = ((camera.getOffsetFromOrigin(
                LatLng(centre.latitude + refDLat, centre.longitude)) -
            camera.getOffsetFromOrigin(centre))
        .distance
        .abs()) /
        refM;
    double strokePx(double m) => (m * pxPerMeter).clamp(1.0, 600.0);

    // Build a polyline path (in screen space) for a layer's sessions, and a
    // separate list of single-sample dots.
    void forEachStroke(
      List<List<_P>> sessions,
      void Function(ui.Path path) onPath,
      void Function(Offset c) onDot,
    ) {
      for (final session in sessions) {
        if (session.isEmpty) continue;
        if (session.length == 1) {
          onDot(project(session.first.pt));
          continue;
        }
        final path = ui.Path();
        final first = project(session.first.pt);
        path.moveTo(first.dx, first.dy);
        for (var i = 1; i < session.length; i++) {
          final o = project(session[i].pt);
          path.lineTo(o.dx, o.dy);
        }
        onPath(path);
      }
    }

    // ── 1. Fog veil + reveal corridors ──────────────────────────────
    // One dark veil over the whole map; each layer's trail is erased out of
    // it (dstOut) so the walked corridor reveals the map beneath.
    canvas.saveLayer(rect, Paint());
    canvas.drawRect(rect, Paint()..color = veil);
    final eraser = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = const Color(0xFFFFFFFF)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    for (final st in layers) {
      final w = strokePx(st.widthMeters);
      forEachStroke(
        sessionsByLayer[st.layerId] ?? const [],
        (path) => canvas.drawPath(
            path,
            eraser
              ..style = PaintingStyle.stroke
              ..strokeWidth = w),
        (dot) => canvas.drawCircle(
            dot, w / 2, eraser..style = PaintingStyle.fill),
      );
    }
    canvas.restore();

    // ── 2. Coloured line in the fog ─────────────────────────────────
    // For layers with a line colour, draw a translucent coloured line along
    // the same corridor — the "line drawn in the fog". Opacity is baked into
    // the colour's alpha; transparent / null = no line (plain reveal).
    for (final st in layers) {
      final col = st.lineColor;
      if (col == null || col.a == 0) continue;
      final w = strokePx(st.widthMeters);
      final line = Paint()
        ..color = col
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..isAntiAlias = true;
      forEachStroke(
        sessionsByLayer[st.layerId] ?? const [],
        (path) => canvas.drawPath(path, line),
        (dot) => canvas.drawCircle(
            dot, w / 2, Paint()..color = col..isAntiAlias = true),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FogPainter old) =>
      old.camera != camera ||
      old.veil != veil ||
      old.mapProvider != mapProvider ||
      !listEquals(old.layers, layers) ||
      !identical(old.sessionsByLayer, sessionsByLayer);
}

/// Standard haversine — meters between two WGS-84 points.
double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
