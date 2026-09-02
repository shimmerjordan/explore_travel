import 'package:flutter/painting.dart' show decodeImageFromList;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/models.dart';
import '../map/cached_tile_provider.dart' show mapTileCacheManager;
import '../map/tile_providers.dart' show rasterTileUrl;
import 'heat_source.dart';
import 'heat_tile_provider.dart' show bakeHeatTile;

/// Tile store behind the 3D heat map — the loading half of the
/// Google-Maps-style renderer:
///
///  * base raster tiles fetched through the SAME on-disk cache as the 2D map
///    (`mapTileCacheManager`), so anything you've browsed in 2D is instantly
///    there in 3D and everything works offline within covered regions;
///  * while a tile is in flight the renderer asks [baseTileOrAncestor] and
///    draws the best cached ANCESTOR's sub-rect scaled up (the classic
///    "blurry-then-sharp" progressive loading);
///  * heat glow tiles baked locally from the [HeatSnapshot] (no network);
///  * bounded memory: images not referenced by the latest [markUsed] set are
///    evicted once the cache exceeds its cap — never one the painter may
///    still be drawing this frame.
///
/// Listeners fire once per arrived tile batch; the painter repaints on it.
class Tile3DEngine extends ChangeNotifier {
  final MapProvider provider;
  final MapStyle style;
  final String? customOsmUrl;
  final String? ovitalUrl;
  HeatSnapshot _heat;

  Tile3DEngine({
    required this.provider,
    required this.style,
    required HeatSnapshot heat,
    this.customOsmUrl,
    this.ovitalUrl,
  }) : _heat = heat;

  set heat(HeatSnapshot snap) {
    if (identical(snap, _heat)) return;
    _heat = snap;
    for (final img in _heatTiles.values) {
      img.dispose();
    }
    _heatTiles.clear();
    _heatFailed.clear();
    notifyListeners();
  }

  HeatSnapshot get heat => _heat;

  static const int _cap = 240;

  final _baseTiles = <int, ui.Image>{};
  final _heatTiles = <int, ui.Image>{};
  final _pendingBase = <int>{};
  final _pendingHeat = <int>{};
  final _baseFailed = <int, DateTime>{};
  final _heatFailed = <int>{};
  final _used = <int>{};
  Dio? _dio;
  bool _disposed = false;

  static int _key(int z, int x, int y) => (z << 40) | (x << 20) | y;

  int get inflight => _pendingBase.length + _pendingHeat.length;

  /// The renderer's current working set — everything else becomes evictable.
  void markUsed(Iterable<({int z, int x, int y})> tiles) {
    _used
      ..clear()
      ..addAll(tiles.map((t) => _key(t.z, t.x, t.y)));
    _evict(_baseTiles);
    _evict(_heatTiles);
  }

  void _evict(Map<int, ui.Image> cache) {
    if (cache.length <= _cap) return;
    final victims = <int>[];
    for (final k in cache.keys) {
      if (!_used.contains(k)) victims.add(k);
      if (cache.length - victims.length <= _cap) break;
    }
    for (final k in victims) {
      cache.remove(k)?.dispose();
    }
  }

  /// Cached base tile, or null (fetch kicked off in the background).
  ui.Image? baseTile(int z, int x, int y) {
    final k = _key(z, x, y);
    final img = _baseTiles.remove(k);
    if (img != null) {
      _baseTiles[k] = img; // LRU touch
      return img;
    }
    _fetchBase(z, x, y, k);
    return null;
  }

  /// The tile itself, or the nearest cached ancestor with the source rect
  /// covering (z,x,y)'s footprint inside it. Null when nothing is cached yet.
  ({ui.Image image, ui.Rect src})? baseTileOrAncestor(int z, int x, int y) {
    final own = baseTile(z, x, y);
    if (own != null) {
      return (
        image: own,
        src: ui.Rect.fromLTWH(
            0, 0, own.width.toDouble(), own.height.toDouble())
      );
    }
    var az = z, ax = x, ay = y;
    for (var up = 1; up <= 4 && az > 0; up++) {
      az--;
      ax >>= 1;
      ay >>= 1;
      final k = _key(az, ax, ay);
      final img = _baseTiles[k];
      if (img != null) {
        final f = 1 << up;
        final sw = img.width / f, sh = img.height / f;
        return (
          image: img,
          src: ui.Rect.fromLTWH((x - (ax << up)) * sw, (y - (ay << up)) * sh,
              sw, sh)
        );
      }
    }
    return null;
  }

  /// Cached heat glow tile, or null (bake kicked off). Empty snapshots bake
  /// nothing.
  ui.Image? heatTile(int z, int x, int y) {
    if (_heat.isEmpty) return null;
    final k = _key(z, x, y);
    final img = _heatTiles.remove(k);
    if (img != null) {
      _heatTiles[k] = img;
      return img;
    }
    if (_pendingHeat.contains(k) || _heatFailed.contains(k)) return null;
    _pendingHeat.add(k);
    final snap = _heat;
    bakeHeatTile(snap, x, y, z, 256).then((image) {
      _pendingHeat.remove(k);
      if (_disposed || !identical(snap, _heat)) {
        image.dispose();
        return;
      }
      _heatTiles[k] = image;
      notifyListeners();
    }).catchError((Object e) {
      _pendingHeat.remove(k);
      _heatFailed.add(k);
    });
    return null;
  }

  void _fetchBase(int z, int x, int y, int k) {
    if (_pendingBase.contains(k)) return;
    final failedAt = _baseFailed[k];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(seconds: 15)) {
      return;
    }
    _pendingBase.add(k);
    () async {
      try {
        final url = rasterTileUrl(
          provider: provider,
          style: style,
          customOsmUrl: customOsmUrl,
          ovitalUrl: ovitalUrl,
          z: z,
          x: x,
          y: y,
        );
        Uint8List bytes;
        if (kIsWeb) {
          // No file system on web; the browser HTTP cache does the caching.
          _dio ??= Dio();
          final r = await _dio!.get<List<int>>(url,
              options: Options(responseType: ResponseType.bytes));
          bytes = Uint8List.fromList(r.data ?? const []);
        } else {
          // Same persistent cache as the 2D map — shared offline coverage.
          final f = await mapTileCacheManager.getSingleFile(url);
          bytes = await f.readAsBytes();
        }
        if (bytes.isEmpty) throw StateError('empty tile');
        final img = await decodeImageFromList(bytes);
        if (_disposed) {
          img.dispose();
          return;
        }
        _baseTiles[k] = img;
        _baseFailed.remove(k);
        notifyListeners();
      } catch (e) {
        _baseFailed[k] = DateTime.now();
        debugPrint('[HEAT3D] tile $z/$x/$y failed: $e');
      } finally {
        _pendingBase.remove(k);
      }
    }();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final img in _baseTiles.values) {
      img.dispose();
    }
    for (final img in _heatTiles.values) {
      img.dispose();
    }
    _baseTiles.clear();
    _heatTiles.clear();
    super.dispose();
  }
}
