import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_map/flutter_map.dart';

/// Persistent on-disk cache for map tiles.
///
/// `cached_network_image`'s DEFAULT manager keeps only 200 objects and
/// expires them after 30 days — for a map that's a few seconds of panning,
/// so tiles got evicted almost immediately and the map looked like it
/// "forgot" everything after a restart. This dedicated manager keeps up to
/// 100k tiles for a year on disk, so a region you've loaded stays usable
/// fully offline across app restarts.
final mapTileCacheManager = CacheManager(
  Config(
    'explore_map_tiles',
    stalePeriod: const Duration(days: 365),
    maxNrOfCacheObjects: 100000,
  ),
);

/// A flutter_map TileProvider that delegates to `cached_network_image` so
/// tiles are persisted to disk (or IndexedDB on web). After your first trip
/// the map keeps working completely offline within the covered region.
///
/// NOTE: the parent `TileProvider` mutates its `headers` map to inject
/// `User-Agent`, so we MUST pass a fresh, mutable map (`<String, String>{}`)
/// — never `const {}`, which would throw
/// "Cannot modify unmodifiable map" when the parent tries to add headers.
class CachedTileProvider extends TileProvider {
  CachedTileProvider({Map<String, String>? headers})
      : super(headers: headers ?? <String, String>{});

  @override
  ImageProvider<Object> getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    return CachedNetworkImageProvider(
      url,
      headers: headers,
      cacheKey: url,
      cacheManager: mapTileCacheManager,
    );
  }
}
