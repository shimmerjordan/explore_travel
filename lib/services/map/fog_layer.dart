import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../data/db/database.dart';
import '../../models/models.dart';
import '../fog/fog_engine.dart';
import '../geo/coord_converter.dart';

/// A GPS fix worse than this (in metres) is treated as junk — usually a
/// cell-tower / Wi-Fi fallback fix indoors — and dropped before it can
/// anchor a misleading line. Null-accuracy points (old data, web) are
/// always kept.
const double _kMaxAccuracyMeters = 150.0;

/// Implied speed (m/s) above which two consecutive fixes can't be one
/// continuous walk — a teleport spike. ~70 m/s = 252 km/h, above any
/// car / metro but below the per-sample distance a flight or HSR would
/// produce (those break on the distance gate first anyway).
const double _kMaxSpeedMps = 70.0;

/// Fallback corridor width (metres) for points recorded before per-point
/// width existed (`width` column is null). Kept independent of the live
/// size setting so historical trails don't shift when the user retunes it.
const double _kDefaultTrailWidthMeters = 14.0;

/// One sample on a trail: its position plus the corridor width (metres) it
/// was recorded with.
typedef _P = ({LatLng pt, double w});

class FogLayer extends StatefulWidget {
  /// Kept for API compatibility — callers still pass it, and stats /
  /// import code references the engine through other paths. The live
  /// renderer doesn't use it: the user-visible trail is drawn directly
  /// from `track_points` as an anti-aliased canvas stroke.
  final FogEngine engine;
  final AppDb db;
  final List<int> layerIds;
  final Color fogColor;
  final double fogOpacity;

  /// Manual erase/add brush radius (metres). Only used to size the gate
  /// that decides whether two consecutive samples belong to one walk; the
  /// visible corridor width comes from each point's own stored `width`.
  final double penRadiusMeters;
  final Object? refreshKey;
  final MapProvider mapProvider;
  const FogLayer({
    super.key,
    required this.engine,
    required this.db,
    required this.layerIds,
    required this.fogColor,
    required this.fogOpacity,
    required this.penRadiusMeters,
    required this.mapProvider,
    this.refreshKey,
  });

  @override
  State<FogLayer> createState() => _FogLayerState();
}

class _FogLayerState extends State<FogLayer> {
  /// Per-session sample lists loaded from track_points. Loaded once per
  /// (layerIds, refreshKey) change and cached; the painter strokes through
  /// these. Each inner list is one continuous walk (no GPS drop-out /
  /// teleport), and each sample carries the width it was recorded with.
  List<List<_P>> _trailSessions = const [];
  String _trailKey = '';

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
    final key = '${widget.layerIds.join(",")}|${widget.refreshKey}';
    if (key == _trailKey) return;
    _trailKey = key;
    _loadTrail();
  }

  Future<void> _loadTrail() async {
    final layerIds = widget.layerIds;
    if (layerIds.isEmpty) return;
    final sessions = <List<_P>>[];
    // Connect two consecutive samples into one continuous walk only when
    // ALL of these hold; any failure starts a fresh sub-path so we never
    // draw a straight line across a gap the user didn't actually walk:
    //
    //   * temporal: gap ≤ 30 s          → catches "no signal" pauses,
    //                                      backgrounded app, GPS sleep
    //   * spatial:  distance ≤ maxMeters → catches teleports (subway,
    //                                      flight, app resume far away)
    //   * speed:    distance/Δt ≤ 70 m/s → catches a fast GPS spike that
    //                                      is still *within* maxMeters
    //
    // Junk fixes (accuracy worse than 150 m) are dropped up front so a
    // single bad reading can't anchor a line on either side of itself.
    final maxAge = const Duration(seconds: 30);
    final maxMeters = math.max(widget.penRadiusMeters * 5.0, 50.0);
    for (final lid in layerIds) {
      final rows = await (widget.db.select(widget.db.trackPoints)
            ..where((p) => p.layerId.equals(lid))
            ..orderBy([(p) => OrderingTerm.asc(p.time)]))
          .get();
      var current = <_P>[];
      DateTime? lastT;
      double? lastLat, lastLng;
      for (final p in rows) {
        // Drop unreliable fixes outright — never let them anchor a line.
        if (p.accuracy != null && p.accuracy! > _kMaxAccuracyMeters) {
          continue;
        }
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
    }
    if (!mounted) return;
    setState(() => _trailSessions = sessions);
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    // Wrap in MobileLayerTransformer — exactly what flutter_map's own
    // PolylineLayer / CircleLayer / MarkerLayer do. The painter projects
    // points with `getOffsetFromOrigin`, which returns coordinates in the
    // *un-rotated* pixel frame; the transformer then rotates the whole
    // canvas by `camera.rotationRad` so the fog + revealed trail stay
    // glued to the tiles when the user rotates the map.
    return MobileLayerTransformer(
      child: IgnorePointer(
        child: CustomPaint(
          size: Size(camera.size.x, camera.size.y),
          painter: _FogPainter(
            camera: camera,
            layerIds: widget.layerIds,
            fogColor: widget.fogColor.withValues(alpha: widget.fogOpacity),
            mapProvider: widget.mapProvider,
            trailSessions: _trailSessions,
          ),
        ),
      ),
    );
  }
}

class _FogPainter extends CustomPainter {
  final MapCamera camera;
  final List<int> layerIds;
  final Color fogColor;
  final MapProvider mapProvider;
  final List<List<_P>> trailSessions;

  _FogPainter({
    required this.camera,
    required this.layerIds,
    required this.fogColor,
    required this.mapProvider,
    required this.trailSessions,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // The MobileLayerTransformer rotates this canvas about the screen
    // centre, so a rect the exact size of the viewport would leave the
    // four corners un-fogged when the map is rotated off-north. Pad each
    // axis by exactly what the current rotation needs (zero when
    // north-up) so the saveLayer below stays viewport-sized in the common
    // case instead of always allocating a diagonal-sized offscreen layer.
    final c = math.cos(camera.rotationRad).abs();
    final s = math.sin(camera.rotationRad).abs();
    final halfW = size.width / 2, halfH = size.height / 2;
    final padX = (halfW * c + halfH * s) - halfW + 1;
    final padY = (halfW * s + halfH * c) - halfH + 1;
    final rect = Rect.fromLTRB(
        -padX, -padY, size.width + padX, size.height + padY);
    final fogPaint = Paint()..color = fogColor;
    if (layerIds.isEmpty) {
      canvas.drawRect(rect, fogPaint);
      return;
    }

    final needsGcj = CoordConverter.needsGcj02(mapProvider);
    Offset project(LatLng p) {
      if (needsGcj) {
        final g = CoordConverter.wgs84ToGcj02(p.latitude, p.longitude);
        return camera.getOffsetFromOrigin(LatLng(g.lat, g.lng));
      }
      return camera.getOffsetFromOrigin(p);
    }

    // Screen pixels per metre at the current camera scale, measured near
    // the camera centre over a 100 m reference span (the projection is
    // linear, so the reference length just buys numerical stability).
    final centre = camera.center;
    const refM = 100.0;
    final refDLat = refM / 111320.0;
    final pxPerMeter = ((camera.getOffsetFromOrigin(
                LatLng(centre.latitude + refDLat, centre.longitude)) -
            camera.getOffsetFromOrigin(centre))
        .distance
        .abs()) /
        refM;

    double strokePx(double widthMeters) =>
        (widthMeters * pxPerMeter).clamp(1.0, 600.0);

    // The fog bitmap (`fog_tiles`) is no longer used for live rendering —
    // it's still updated by the recording controller (so backups, sync,
    // and exploration-% stats stay correct), but the user-visible reveal
    // is drawn here as crisp anti-aliased strokes along the actual GPS
    // samples: the places you've walked "light up" by erasing the grey
    // fog. No blur — a hard-edged swept corridor, which is what reads as
    // clear and clean. Each width-run is stroked at its own width so
    // changing the size setting never reshapes older trails.
    canvas.saveLayer(rect, Paint());
    canvas.drawRect(rect, fogPaint);

    // Bucket widths to ~0.1 m so float noise doesn't fragment a uniform
    // trail into thousands of single-segment runs.
    int bucket(double w) => (w * 10).round();

    final base = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = const Color(0xFFFFFFFF)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    void strokeRun(List<Offset> pts, double widthM) {
      if (pts.isEmpty) return;
      final w = strokePx(widthM);
      if (pts.length == 1) {
        canvas.drawCircle(
            pts.first, w / 2, base..style = PaintingStyle.fill);
        return;
      }
      final path = ui.Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(
          path,
          base
            ..style = PaintingStyle.stroke
            ..strokeWidth = w);
    }

    for (final session in trailSessions) {
      if (session.isEmpty) continue;
      if (session.length == 1) {
        strokeRun([project(session.first.pt)], session.first.w);
        continue;
      }
      // Split the session into maximal runs of equal width, sharing the
      // boundary point between adjacent runs so the corridor stays
      // continuous across a width change.
      var runPts = <Offset>[project(session.first.pt)];
      var runW = session.first.w;
      for (var i = 1; i < session.length; i++) {
        final o = project(session[i].pt);
        if (bucket(session[i].w) == bucket(runW)) {
          runPts.add(o);
        } else {
          runPts.add(o);
          strokeRun(runPts, runW);
          runPts = [o];
          runW = session[i].w;
        }
      }
      strokeRun(runPts, runW);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FogPainter old) =>
      old.camera != camera ||
      old.layerIds != layerIds ||
      old.fogColor != fogColor ||
      old.mapProvider != mapProvider ||
      !identical(old.trailSessions, trailSessions);
}

/// Standard haversine — meters between two WGS-84 points. Inlined here so
/// the renderer doesn't have to depend on a math util module just to
/// decide whether to break a polyline at a GPS drop-out.
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
