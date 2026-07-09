import 'dart:async';
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

/// A point's stroke width in metres; null = the point predates per-point
/// widths (schema v5) and follows the layer's live style width instead.
typedef _P = ({LatLng pt, double? w});

/// One freshly-recorded point, pushed by the recording pipeline so the trail
/// layer can APPEND instead of re-reading every TrackPoint row per tick.
typedef LiveTrackPoint = ({
  double lat,
  double lng,
  DateTime time,
  int layerId,
  double? width,
  double? accuracy,
});

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

  /// Optional live feed of freshly-recorded points — appended to the loaded
  /// sessions in place of a full TrackPoints re-query per recording tick.
  final Stream<LiveTrackPoint>? livePoints;
  const FogLayer({
    super.key,
    required this.db,
    required this.layers,
    required this.penRadiusMeters,
    required this.mapProvider,
    this.refreshKey,
    this.livePoints,
  });

  @override
  State<FogLayer> createState() => _FogLayerState();
}

class _FogLayerState extends State<FogLayer> {
  // Recorded trails grouped into continuous sessions, per layer.
  Map<int, List<List<_P>>> _sessionsByLayer = const {};
  String _trailKey = '';

  // Last appended/loaded point per layer — the live-append path needs it to
  // apply the same session-split rules the full load uses.
  final Map<int, ({DateTime t, double lat, double lng})> _lastPt = {};
  StreamSubscription<LiveTrackPoint>? _liveSub;

  List<int> get _layerIds => widget.layers.map((l) => l.layerId).toList();

  /// True when at least one layer actually wants a coloured line — avoids
  /// querying TrackPoints when nothing would be drawn (e.g. pure FOW imports).
  bool get _anyLine =>
      widget.layers.any((l) => l.lineColor != null && l.lineColor!.a != 0);

  @override
  void initState() {
    super.initState();
    _subscribeLive();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeReloadTrail();
  }

  @override
  void didUpdateWidget(covariant FogLayer old) {
    super.didUpdateWidget(old);
    if (!identical(old.livePoints, widget.livePoints)) _subscribeLive();
    _maybeReloadTrail();
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    super.dispose();
  }

  void _subscribeLive() {
    _liveSub?.cancel();
    _liveSub = widget.livePoints?.listen(_appendLive);
  }

  /// Append one live point using the same gap/speed/accuracy gates as
  /// [_loadTrail], starting a new session when they fail. The outer map is
  /// shallow-copied so the painter's `identical` repaint check fires.
  void _appendLive(LiveTrackPoint p) {
    if (!mounted || !_anyLine) return;
    if (!_layerIds.contains(p.layerId)) return;
    if (p.accuracy != null && p.accuracy! > _kMaxAccuracyMeters) return;

    final maxMeters = math.max(widget.penRadiusMeters * 5.0, 50.0);
    final sessions =
        List<List<_P>>.of(_sessionsByLayer[p.layerId] ?? const []);
    final last = _lastPt[p.layerId];
    bool startNew;
    if (sessions.isEmpty || last == null) {
      startNew = true;
    } else {
      final dt = p.time.difference(last.t);
      final dist = _haversineMeters(last.lat, last.lng, p.lat, p.lng);
      final secs = dt.inMilliseconds / 1000.0;
      startNew = dt > const Duration(seconds: 30) ||
          dt.isNegative ||
          dist > maxMeters ||
          (secs > 0 && (dist / secs) > _kMaxSpeedMps);
    }
    final pt = (pt: LatLng(p.lat, p.lng), w: p.width);
    if (startNew) {
      sessions.add([pt]);
    } else {
      // In-place append is safe: repaint is driven by the OUTER map identity
      // changing below, and nothing retains the old inner list.
      sessions.last.add(pt);
    }
    _lastPt[p.layerId] = (t: p.time, lat: p.lat, lng: p.lng);
    setState(() {
      _sessionsByLayer = {..._sessionsByLayer, p.layerId: sessions};
    });
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
        current.add((pt: LatLng(p.lat, p.lng), w: p.width));
        lastT = p.time;
        lastLat = p.lat;
        lastLng = p.lng;
      }
      if (current.isNotEmpty) sessions.add(current);
      out[lid] = sessions;
      if (lastT != null) {
        _lastPt[lid] = (t: lastT, lat: lastLat!, lng: lastLng!);
      } else {
        _lastPt.remove(lid);
      }
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

    for (final st in layers) {
      final col = st.lineColor;
      if (col == null || col.a == 0) continue;
      final dotPaint = Paint()
        ..color = col
        ..isAntiAlias = true;
      Paint linePaint(double wMeters) => Paint()
        ..color = col
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokePx(wMeters)
        ..isAntiAlias = true;

      for (final session in sessionsByLayer[st.layerId] ?? const <List<_P>>[]) {
        if (session.isEmpty) continue;
        // Each point carries its own recorded width (the brush/size at record
        // time); legacy null-width points follow the layer's live style width.
        // Manual dabs land as single-point sessions → dots at their own size.
        if (session.length == 1) {
          final w = strokePx(session.first.w ?? st.widthMeters);
          canvas.drawCircle(project(session.first.pt), w / 2, dotPaint);
          continue;
        }
        // Stroke maximal constant-width runs so a width change mid-trail
        // doesn't retroactively fatten/thin what came before it. The joint
        // segment into the change-point keeps the OLD width; the new run
        // starts at that point.
        var runStart = 0;
        var runW = session.first.w ?? st.widthMeters;
        void flush(int endIdx, double wMeters) {
          if (endIdx <= runStart) return; // 1-point tail — cap already drawn
          final path = ui.Path();
          final first = project(session[runStart].pt);
          path.moveTo(first.dx, first.dy);
          for (var i = runStart + 1; i <= endIdx; i++) {
            final o = project(session[i].pt);
            path.lineTo(o.dx, o.dy);
          }
          canvas.drawPath(path, linePaint(wMeters));
        }

        for (var i = 1; i < session.length; i++) {
          final wi = session[i].w ?? st.widthMeters;
          if (wi != runW) {
            flush(i, runW);
            runStart = i;
            runW = wi;
          }
        }
        flush(session.length - 1, runW);
      }
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
