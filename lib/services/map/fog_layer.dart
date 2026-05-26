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
  /// Meters — sets the on-screen stroke width of the "swept disk" trail.
  /// Same value as the recording pen radius so the user's slider tunes
  /// both storage radius and visible corridor width.
  final double trailRadiusMeters;
  final Object? refreshKey;
  final MapProvider mapProvider;
  const FogLayer({
    super.key,
    required this.engine,
    required this.db,
    required this.layerIds,
    required this.fogColor,
    required this.fogOpacity,
    required this.trailRadiusMeters,
    required this.mapProvider,
    this.refreshKey,
  });

  @override
  State<FogLayer> createState() => _FogLayerState();
}

class _FogLayerState extends State<FogLayer> {
  /// Per-session lists loaded from track_points.
  /// We load once per (layerIds, refreshKey) change and cache; the
  /// painter strokes through these to make the visible trail
  /// sub-pixel-smooth even when the FOW bitmap underneath is blocky.
  /// Each inner list is one continuous walk (no >10 min gap).
  List<List<LatLng>> _trailSessions = const [];
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
    final sessions = <List<LatLng>>[];
    // Mirror the recording controller's chain gate: connect two
    // consecutive samples only when *both* tests pass:
    //   * temporal: gap ≤ 30 s
    //   * spatial:  distance ≤ max(5 × penR, 50 m)
    // Either fails → start a fresh sub-path. This is what FOW does
    // when GPS drops or the user teleports (subway, airplane) — no
    // false straight line across the map. Long-term 10-min sessions
    // still naturally fall out of the temporal rule.
    final maxAge = const Duration(seconds: 30);
    final maxMeters =
        math.max(widget.trailRadiusMeters * 5.0, 50.0);
    for (final lid in layerIds) {
      final rows = await (widget.db.select(widget.db.trackPoints)
            ..where((p) => p.layerId.equals(lid))
            ..orderBy([(p) => OrderingTerm.asc(p.time)]))
          .get();
      var current = <LatLng>[];
      DateTime? lastT;
      double? lastLat, lastLng;
      for (final p in rows) {
        final breakHere = lastT != null &&
            (p.time.difference(lastT) > maxAge ||
                _haversineMeters(lastLat!, lastLng!, p.lat, p.lng) >
                    maxMeters);
        if (breakHere) {
          if (current.isNotEmpty) sessions.add(current);
          current = [];
        }
        current.add(LatLng(p.lat, p.lng));
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
    return IgnorePointer(
      child: CustomPaint(
        size: Size(camera.size.x, camera.size.y),
        painter: _FogPainter(
          camera: camera,
          layerIds: widget.layerIds,
          fogColor: widget.fogColor.withValues(alpha: widget.fogOpacity),
          mapProvider: widget.mapProvider,
          trailSessions: _trailSessions,
          trailRadiusMeters: widget.trailRadiusMeters,
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
  final List<List<LatLng>> trailSessions;
  final double trailRadiusMeters;

  _FogPainter({
    required this.camera,
    required this.layerIds,
    required this.fogColor,
    required this.mapProvider,
    required this.trailSessions,
    required this.trailRadiusMeters,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final fogPaint = Paint()..color = fogColor;
    if (layerIds.isEmpty) {
      canvas.drawRect(rect, fogPaint);
      return;
    }

    final needsGcj = CoordConverter.needsGcj02(mapProvider);

    // The fog bitmap (`fog_tiles`) is no longer used for live rendering
    // — it's still updated by the recording controller (so backups,
    // cross-device sync, and exploration-% stats stay correct), but the
    // user-visible trail is drawn as a single anti-aliased stroke along
    // the actual GPS sample points. This is exactly how Fog of World
    // does it: think "a Roomba sweeping sand" — the path is the
    // Minkowski sum of a disk and the polyline through the samples,
    // and Flutter's canvas stroke renders that shape natively with
    // sub-pixel AA. The previous "row-of-capsules from bitmap rows"
    // approach was fundamentally blocky on diagonals; no amount of
    // post-blur ever quite fixed it.

    canvas.saveLayer(rect, Paint());
    canvas.drawRect(rect, fogPaint);

    // Convert pen-radius (meters) → screen pixels at the current camera
    // scale by measuring on-screen distance between two points
    // separated by `trailRadiusMeters` of latitude near the camera
    // centre. Two-point measurement keeps this robust to whatever
    // projection flutter_map is currently using.
    final centre = camera.center;
    final dLat = trailRadiusMeters / 111320.0;
    final p0 = camera.getOffsetFromOrigin(centre);
    final p1 = camera.getOffsetFromOrigin(
        LatLng(centre.latitude + dLat, centre.longitude));
    final screenPxPerRadius = (p1 - p0).distance.abs().clamp(2.0, 400.0);

    // ── Build paths from sample points ──────────────────────────────
    // Multi-point sessions become an open lineTo polyline; isolated
    // single-sample sessions become an inscribed circle the same
    // diameter the stroke would render. Without the special case for
    // 1-point sessions, Path.moveTo by itself draws nothing and
    // isolated GPS recoveries would silently disappear.
    final trailPath = ui.Path();
    final dotsPath = ui.Path();
    for (final session in trailSessions) {
      if (session.isEmpty) continue;
      if (session.length == 1) {
        var lat = session.first.latitude;
        var lng = session.first.longitude;
        if (needsGcj) {
          final g = CoordConverter.wgs84ToGcj02(lat, lng);
          lat = g.lat;
          lng = g.lng;
        }
        final o = camera.getOffsetFromOrigin(LatLng(lat, lng));
        // Match the stroke half-width below (1.4 × R / 2 = 0.7 × R)
        // so a single-sample blob looks identical to the cap of a
        // multi-sample stroke — same blur sigma is applied, same
        // size, same alpha.
        dotsPath.addOval(Rect.fromCircle(
            center: o, radius: screenPxPerRadius * 0.7));
        continue;
      }
      bool started = false;
      for (final pt in session) {
        var lat = pt.latitude;
        var lng = pt.longitude;
        if (needsGcj) {
          final g = CoordConverter.wgs84ToGcj02(lat, lng);
          lat = g.lat;
          lng = g.lng;
        }
        final o = camera.getOffsetFromOrigin(LatLng(lat, lng));
        if (!started) {
          trailPath.moveTo(o.dx, o.dy);
          started = true;
        } else {
          trailPath.lineTo(o.dx, o.dy);
        }
      }
    }

    final empty = trailPath.getBounds().isEmpty && dotsPath.getBounds().isEmpty;
    if (empty) {
      canvas.restore();
      return;
    }

    // Single-pass feathered stroke — one paint, full alpha, with the
    // blur sigma tuned so the gaussian convolution of the stroke
    // *itself* is the gradient. This is the only way to get a truly
    // continuous alpha-vs-distance curve: any second pass introduces
    // a visible "where pass A ends, pass B begins" seam because
    // dstOut composes multiplicatively, not linearly.
    //
    // Geometry of the resulting alpha profile, where R = stroke
    // half-width and σ = blur sigma:
    //
    //   distance from path centre        alpha (= clearing)
    //   ─────────────────────────────────────────────────
    //   0  →  R − 2σ                     ≈ 100 % (solid clear)
    //   R − 2σ  →  R + 2σ                gaussian falloff
    //   beyond R + 2σ                    ≈ 0 % (fog intact)
    //
    // Picked W = 1.4 × penR, σ = 0.3 × penR so:
    //   • centre is fully cleared (R/σ = 2.33 ✓)
    //   • halo extends only ~ 1.3 × penR from the centre line —
    //     significantly tighter than the previous 2-layer setup
    //   • the transition is one smooth erf curve, no break point
    final blurSigma = (screenPxPerRadius * 0.30).clamp(1.5, 16.0);

    final stroke = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = screenPxPerRadius * 1.4
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma)
      ..isAntiAlias = true;
    final fill = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma)
      ..isAntiAlias = true;

    if (!trailPath.getBounds().isEmpty) canvas.drawPath(trailPath, stroke);
    if (!dotsPath.getBounds().isEmpty) canvas.drawPath(dotsPath, fill);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FogPainter old) =>
      old.camera != camera ||
      old.layerIds != layerIds ||
      old.fogColor != fogColor ||
      old.mapProvider != mapProvider ||
      old.trailRadiusMeters != trailRadiusMeters ||
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
