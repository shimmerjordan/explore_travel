import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../models/models.dart';
import 'cached_tile_provider.dart';

/// Returns a TileLayer for the requested provider + style.
TileLayer buildTileLayer({
  required MapProvider provider,
  required MapStyle style,
  String? amapKey,
  String? googleKey,
  /// Optional override for the OSM raster URL. Useful from China where
  /// tile.openstreetmap.org is often unreachable.
  String? customOsmUrl,
}) {
  final ua = kIsWeb ? '' : 'com.explorejournal.app';

  switch (provider) {
    case MapProvider.amap:
      switch (style) {
        case MapStyle.standard:
          return TileLayer(
            urlTemplate:
                'https://wprd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&style=7&x={x}&y={y}&z={z}',
            subdomains: const ['1', '2', '3', '4'],
            userAgentPackageName: ua,
            tileProvider: CachedTileProvider(),
          );
        case MapStyle.satellite:
          return TileLayer(
            urlTemplate:
                'https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}',
            subdomains: const ['1', '2', '3', '4'],
            userAgentPackageName: ua,
            tileProvider: CachedTileProvider(),
          );
        case MapStyle.hybrid:
          return TileLayer(
            urlTemplate:
                'https://webst0{s}.is.autonavi.com/appmaptile?style=8&x={x}&y={y}&z={z}',
            subdomains: const ['1', '2', '3', '4'],
            userAgentPackageName: ua,
            tileProvider: CachedTileProvider(),
          );
      }
    case MapProvider.google:
      final t = switch (style) {
        MapStyle.standard => 'm',
        MapStyle.satellite => 's',
        MapStyle.hybrid => 'y',
      };
      return TileLayer(
        urlTemplate:
            'https://mt{s}.google.com/vt/lyrs=$t&x={x}&y={y}&z={z}',
        subdomains: const ['0', '1', '2', '3'],
        userAgentPackageName: ua,
            tileProvider: CachedTileProvider(),
      );
    case MapProvider.osm:
      final url = (customOsmUrl != null && customOsmUrl.trim().isNotEmpty)
          ? customOsmUrl.trim()
          : switch (style) {
              MapStyle.standard =>
                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              MapStyle.satellite =>
                'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
              MapStyle.hybrid =>
                'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
            };
      return TileLayer(
        urlTemplate: url,
        userAgentPackageName: ua,
        tileProvider: CachedTileProvider(),
      );
  }
}
