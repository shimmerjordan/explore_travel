import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../models/models.dart';
import 'cached_tile_provider.dart';

/// Fallback when 奥维 is selected but no tile URL has been configured. Ovital
/// has no public tile endpoint (see [MapProvider.ovital]), so the only honest
/// default is a working public map plus the "未配置" hint in settings.
const String _kOsmStandardUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Normalise a user-entered tile template to flutter_map's placeholders.
/// Ovital's own dialog writes `{$z}/{$x}/{$y}` and `{$serverpart}`; people
/// paste those verbatim. Returns null when nothing usable remains.
String? normalizeTileTemplate(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.isEmpty) return null;
  s = s
      .replaceAll(r'{$z}', '{z}')
      .replaceAll(r'{$x}', '{x}')
      .replaceAll(r'{$y}', '{y}')
      .replaceAll(r'{$serverpart}', '{s}')
      .replaceAll(r'{$s}', '{s}');
  if (!s.contains('{z}') || !s.contains('{x}') || !s.contains('{y}')) {
    return null;
  }
  return s;
}

/// Returns a TileLayer for the requested provider + style.
TileLayer buildTileLayer({
  required MapProvider provider,
  required MapStyle style,
  String? amapKey,
  String? googleKey,
  /// Optional override for the OSM raster URL. Useful from China where
  /// tile.openstreetmap.org is often unreachable.
  String? customOsmUrl,
  /// 奥维 WEB 瓦片服务 template (AppSettings.ovitalTileUrl).
  String? ovitalUrl,
}) {
  final ua = kIsWeb ? '' : 'com.explorejournal.app';

  // Retain more off-screen / previous-zoom tiles so panning and pinch-zoom
  // don't expose blank blocks before the new tiles arrive. `keepBuffer`
  // holds tiles after they scroll out (and old-zoom tiles during a zoom);
  // `panBuffer` pre-loads a ring of tiles around the viewport.
  TileLayer make(String url, {List<String> subdomains = const []}) =>
      TileLayer(
        urlTemplate: url,
        subdomains: subdomains,
        userAgentPackageName: ua,
        // cached_network_image's web path throws "source image cannot be
        // decoded" (EncodingError) for tiles, so on web use flutter_map's
        // plain NetworkTileProvider (the browser HTTP-caches anyway). Native
        // keeps the persistent on-disk CachedTileProvider.
        tileProvider: kIsWeb ? NetworkTileProvider() : CachedTileProvider(),
        // Native pre-loads/keeps a generous ring of tiles for buttery panning.
        // On web every extra tile is another canvaskit composite op per frame,
        // so keep the working set small — much smoother zoom/pan in a browser.
        keepBuffer: kIsWeb ? 1 : 5,
        panBuffer: kIsWeb ? 0 : 3,
        // A tile that failed (subdomain hiccup, brief offline) must be
        // re-requested when it scrolls back in — the default keeps the error
        // placeholder alive for the whole session, a permanent "hole" that
        // reads as an unloaded block under the fog veil.
        evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
        // 瓦片加载失败一律打日志——不然"整页灰"只能靠猜（问题排查用，
        // 每瓦片一行，正常时零输出，保留无成本）。
        errorTileCallback: (tile, error, _) =>
            debugPrint('[TILE] ${tile.coordinates} failed: $error'),
      );

  const amapSubs = ['1', '2', '3', '4'];

  switch (provider) {
    case MapProvider.amap:
      switch (style) {
        case MapStyle.standard:
          return make(
            'https://wprd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&style=7&x={x}&y={y}&z={z}',
            subdomains: amapSubs,
          );
        case MapStyle.satellite:
          return make(
            'https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}',
            subdomains: amapSubs,
          );
        case MapStyle.hybrid:
          return make(
            'https://webst0{s}.is.autonavi.com/appmaptile?style=8&x={x}&y={y}&z={z}',
            subdomains: amapSubs,
          );
      }
    case MapProvider.google:
      final t = switch (style) {
        MapStyle.standard => 'm',
        MapStyle.satellite => 's',
        MapStyle.hybrid => 'y',
      };
      return make(
        'https://mt{s}.google.com/vt/lyrs=$t&x={x}&y={y}&z={z}',
        subdomains: const ['0', '1', '2', '3'],
      );
    case MapProvider.osm:
      final url = normalizeTileTemplate(customOsmUrl) ??
          switch (style) {
            MapStyle.standard => _kOsmStandardUrl,
            MapStyle.satellite =>
              'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
            MapStyle.hybrid =>
              'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
          };
      return make(url);
    case MapProvider.ovital:
      // One template serves every style: which Ovital map it shows is the
      // `getomap_<mapId>` segment the user put in the URL.
      final url = normalizeTileTemplate(ovitalUrl);
      if (url == null) return make(_kOsmStandardUrl);
      // Ovital's `{s}` (if any) is the user's own server list; we can only
      // hand it one host, so keep a single-element pool.
      return make(url, subdomains: url.contains('{s}') ? const ['a'] : const []);
  }
}
