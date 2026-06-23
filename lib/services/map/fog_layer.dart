import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../data/db/database.dart';
import '../../models/models.dart';
import '../geo/coord_converter.dart';

/// A GPS fix worse than this (in metres) is treated as junk and dropped.
const double _kMaxAccuracyMeters = 150.0;

/// Implied speed (m/s) above which two consecutive fixes can't be one walk.
const double _kMaxSpeedMps = 70.0;

/// Fallback line width (metres) for points with a null `width`.
const double _kDefaultTrailWidthMeters = 14.0;

typedef _P = ({LatLng pt, double w});

/// Per-layer style for the optional translucent COLOURED LINE drawn along a
/// recorded trail — "a line drawn in the fog". The explored-area fog itself is
/// rendered as baked map tiles ([FogTileLayer] in `fog_tile_provider.dart`);
/// this widget only draws the decorative coloured line for layers that set
/// [lineColor]. Imported Fog-of-World data has no TrackPoints, so it draws
/// nothing for imports.
class FogLayerStyle {
  final int layerId;
  final Color? lineColor; // opacity baked into alpha; null = no line
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

/// Screen-space overlay that draws each layer's optional coloured trail line on
/// top of the fog tiles. Pure decoration — the explored-area reveal lives in
/// [FogTileLayer].
class FogLayer extends StatefulWidget {
  final AppDb db;
  final List<FogLayerStyle> layers;

  /// Drives the trail-session split distance (mirrors recording's gap gate).
  final double penRadiusMeters;
  final Object? refreshKey;
  final MapProvider mapProvider;
  const FogLayer({
    super.key,
    required this.db,
    required this.layers,
    required this.penRadiusMeters,
    required this.mapProvider,
    this.refreshKey,
  });

  @override
  State<FogLayer> createState() => _FogLayerState();
}

class _FogLayerState extends State<FogLayer> {
  // Recorded trails grouped into continuous sessions, per layer.
  Map<int, List<List<_P>>> _sessionsByLayer = const {};
  String _trailKey = '';

  List<int> get _layerIds => widget.layers.map((l) => l.layerId).toList();

  /// True when at least one layer actually wants a coloured line — avoids
  /// querying TrackPoints when nothing would be drawn (e.g. pure FOW imports).
  bool get _anyLine =>
      widget.layers.any((l) => l.lineColor != null && l.lineColor!.a != 0);

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
    final key = '${_layerIds.join(",")}|${widget.refreshKey}|$_anyLine';
    if (key == _trailKey) return;
    _trailKey = key;
    _loadTrail();
  }

  Future<void> _loadTrail() async {
    final layerIds = _anyLine ? _layerIds : const <int>[];
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
          painter: _FogLinePainter(
            camera: camera,
            layers: widget.layers,
            mapProvider: widget.mapProvider,
            sessionsByLayer: _sessionsByLayer,
          ),
        ),
      ),
    );
  }
}

class _FogLinePainter extends CustomPainter {
  final MapCamera camera;
  final List<FogLayerStyle> layers;
  final MapProvider mapProvider;
  final Map<int, List<List<_P>>> sessionsByLayer;

  _FogLinePainter({
    required this.camera,
    required this.layers,
    required this.mapProvider,
    required this.sessionsByLayer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (layers.isEmpty || sessionsByLayer.isEmpty) return;

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
  bool shouldRepaint(covariant _FogLinePainter old) =>
      old.camera != camera ||
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
