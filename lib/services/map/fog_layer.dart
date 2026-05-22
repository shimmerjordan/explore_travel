import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../models/models.dart';
import '../fog/fog_engine.dart';
import '../geo/coord_converter.dart';

class FogLayer extends StatefulWidget {
  final FogEngine engine;
  final List<int> layerIds;
  final Color fogColor;
  final double fogOpacity;
  final Object? refreshKey;
  final MapProvider mapProvider;
  const FogLayer({
    super.key,
    required this.engine,
    required this.layerIds,
    required this.fogColor,
    required this.fogOpacity,
    required this.mapProvider,
    this.refreshKey,
  });

  @override
  State<FogLayer> createState() => _FogLayerState();
}

class _FogLayerState extends State<FogLayer> {
  final _cache = <String, Uint8List?>{};
  Object? _seenKey;
  MapProvider? _seenProvider;
  /// Bumped each time an async block load completes. We hand this into
  /// [_FogPainter] so `shouldRepaint` has something concrete to compare —
  /// without it, the painter sees the *same* Map<String,Uint8List?> reference
  /// (just mutated in place) and decides not to repaint, so newly-loaded
  /// tiles never appeared unless the camera coincidentally also moved.
  /// THIS was the long-standing "no record points" bug.
  int _loadRev = 0;

  @override
  Widget build(BuildContext context) {
    if (_seenKey != widget.refreshKey || _seenProvider != widget.mapProvider) {
      _cache.clear();
      _seenKey = widget.refreshKey;
      _seenProvider = widget.mapProvider;
    }
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: CustomPaint(
        size: Size(camera.size.x, camera.size.y),
        painter: _FogPainter(
          camera: camera,
          engine: widget.engine,
          layerIds: widget.layerIds,
          fogColor: widget.fogColor.withValues(alpha: widget.fogOpacity),
          mapProvider: widget.mapProvider,
          cache: _cache,
          loadRev: _loadRev,
          onTileLoaded: () {
            if (mounted) setState(() => _loadRev++);
          },
        ),
      ),
    );
  }
}

class _FogPainter extends CustomPainter {
  final MapCamera camera;
  final FogEngine engine;
  final int loadRev;
  final List<int> layerIds;
  final Color fogColor;
  final MapProvider mapProvider;
  final Map<String, Uint8List?> cache;
  final VoidCallback onTileLoaded;

  _FogPainter({
    required this.camera,
    required this.engine,
    required this.layerIds,
    required this.fogColor,
    required this.mapProvider,
    required this.cache,
    required this.loadRev,
    required this.onTileLoaded,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final fogPaint = Paint()..color = fogColor;
    if (layerIds.isEmpty) {
      canvas.drawRect(rect, fogPaint);
      return;
    }

    final bounds = camera.visibleBounds;
    final needsGcj = CoordConverter.needsGcj02(mapProvider);

    double wgsNorth = bounds.north, wgsWest = bounds.west;
    double wgsSouth = bounds.south, wgsEast = bounds.east;
    if (needsGcj) {
      final nw = CoordConverter.gcj02ToWgs84(bounds.north, bounds.west);
      final se = CoordConverter.gcj02ToWgs84(bounds.south, bounds.east);
      wgsNorth = nw.lat;
      wgsWest = nw.lng;
      wgsSouth = se.lat;
      wgsEast = se.lng;
    }

    final gxMin = FogEngine.lngToGlobalX(wgsWest);
    final gxMax = FogEngine.lngToGlobalX(wgsEast);
    final gyMin = FogEngine.latToGlobalY(wgsNorth);
    final gyMax = FogEngine.latToGlobalY(wgsSouth);

    final blockXMin = gxMin >> 6;
    final blockXMax = gxMax >> 6;
    final blockYMin = gyMin >> 6;
    final blockYMax = gyMax >> 6;

    final blockCount =
        (blockXMax - blockXMin + 1) * (blockYMax - blockYMin + 1);
    if (blockCount > 400) {
      canvas.drawRect(rect, fogPaint);
      return;
    }

    // Collect all bitmaps first; skip painting if any are still loading
    final bitmaps = <(int, int), Uint8List>{};
    for (int by = blockYMin; by <= blockYMax; by++) {
      for (int bx = blockXMin; bx <= blockXMax; bx++) {
        final tileX = bx >> 7;
        final tileY = by >> 7;
        final blockX = bx & 0x7F;
        final blockY = by & 0x7F;
        final dbX = tileX * FogEngine.tileWidth + blockX;
        final dbY = tileY * FogEngine.tileWidth + blockY;

        final key = '$dbX-$dbY-${layerIds.join(",")}';
        if (cache.containsKey(key)) {
          final b = cache[key];
          if (b != null) bitmaps[(bx, by)] = b;
        } else {
          cache[key] = null;
          engine.mergedBlockBitmap(dbX, dbY, layerIds).then((b) {
            cache[key] = b;
            onTileLoaded();
          });
        }
      }
    }

    canvas.saveLayer(rect, Paint());
    canvas.drawRect(rect, fogPaint);

    // Collect all revealed runs into a single Path of capsule (stadium)
    // shapes — a length-1 run becomes a circle, longer runs become rounded
    // pills. Drawing once with `BlendMode.clear` + `MaskFilter.blur` punches
    // soft-edged "mist dissolving" holes through the fog.
    final clearPath = ui.Path();

    for (int by = blockYMin; by <= blockYMax; by++) {
      for (int py = 0; py < 64; py++) {
        final gy = by * 64 + py;
        if (gy < gyMin || gy > gyMax) continue;

        int? runStart;

        for (int bx = blockXMin; bx <= blockXMax; bx++) {
          final bitmap = bitmaps[(bx, by)];
          for (int px = 0; px < 64; px++) {
            final gx = bx * 64 + px;
            if (gx < gxMin || gx > gxMax + 1) continue;

            final set = bitmap != null && FogEngine.isSet(bitmap, px, py);
            if (set && runStart == null) {
              runStart = gx;
            } else if (!set && runStart != null) {
              _addRunToPath(clearPath, runStart, gx, gy, needsGcj);
              runStart = null;
            }
          }
        }
        if (runStart != null) {
          final endGx = (blockXMax + 1) * 64;
          _addRunToPath(clearPath, runStart, endGx, gy, needsGcj);
        }
      }
    }

    // Restored original two-pass clear — outer soft halo + inner hard
    // clear. Critical: at low/mid zoom each FOW pixel is sub-pixel on
    // screen, and the blur is what makes tiny dstOut-erases actually
    // visible. Removing the blur entirely (my earlier "no-halo" attempt)
    // made small reveals invisible. The ghosting the user reported was
    // from a separate 3-pass random-stipple I had added on top of this,
    // not from the blur itself — that stipple is gone now, this is just
    // the original known-good rendering.
    final outerHalo = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = const Color(0xB0FFFFFF) // ~70% punch
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);
    final innerClear = Paint()
      ..blendMode = BlendMode.dstOut
      ..color = const Color(0xFFFFFFFF)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.3);
    canvas.drawPath(clearPath, outerHalo);
    canvas.drawPath(clearPath, innerClear);

    canvas.restore();
  }

  /// Add a horizontal run from global pixel [x0] to [x1) at row [gy] to the
  /// path as a capsule (stadium): a length-1 run becomes a circle, longer
  /// runs become rounded pills with semicircular caps.
  void _addRunToPath(
      ui.Path path, int x0, int x1, int gy, bool needsGcj) {
    double lng0 = FogEngine.globalXToLng(x0);
    double lat0 = FogEngine.globalYToLat(gy);
    double lng1 = FogEngine.globalXToLng(x1);
    double lat1 = FogEngine.globalYToLat(gy + 1);

    if (needsGcj) {
      final gc0 = CoordConverter.wgs84ToGcj02(lat0, lng0);
      final gc1 = CoordConverter.wgs84ToGcj02(lat1, lng1);
      lng0 = gc0.lng;
      lat0 = gc0.lat;
      lng1 = gc1.lng;
      lat1 = gc1.lat;
    }

    final p0 = camera.getOffsetFromOrigin(LatLng(lat0, lng0));
    final p1 = camera.getOffsetFromOrigin(LatLng(lat1, lng1));

    final rect = Rect.fromLTRB(p0.dx, p0.dy, p1.dx, p1.dy);
    final radius = rect.shortestSide / 2;
    path.addRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
    );
  }

  @override
  bool shouldRepaint(covariant _FogPainter old) =>
      old.camera != camera ||
      old.layerIds != layerIds ||
      old.fogColor != fogColor ||
      old.mapProvider != mapProvider ||
      old.loadRev != loadRev ||
      !identical(old.cache, cache);
}
