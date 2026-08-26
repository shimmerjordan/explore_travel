import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../models/models.dart';
import 'cached_tile_provider.dart';

/// Off-screen tile ring shared by the base map AND the fog layers. They must
/// match: when the fog layer kept fewer tiles than the base map, a pinch or
/// fast pan pruned the fog first and the exposed strip showed solid veil over
/// still-visible imagery ("走过的路被雾吞掉又回来").
///
/// 3/2 instead of the old 5/3: that ring made the working set ~6.6× the
/// viewport (≈99 tiles decoded + laid out per layer), which is what panning
/// paid for every frame.
const int kNativeTileKeepBuffer = 3;
const int kNativeTilePanBuffer = 2;

/// Tile updates are driven by MapEvents — one per gesture FRAME by default,
/// each running a full load + prune pass. Throttling (with the trailing event
/// preserved, so the final camera is always served) cuts that to ~12/s with
/// no visible difference.
final _baseTileUpdates =
    TileUpdateTransformers.throttle(const Duration(milliseconds: 80));

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
        // On web every extra tile is another canvaskit composite op per
        // frame, so keep the working set small there.
        keepBuffer: kIsWeb ? 1 : kNativeTileKeepBuffer,
        panBuffer: kIsWeb ? 0 : kNativeTilePanBuffer,
        tileUpdateTransformer: _baseTileUpdates,
        // No fade-in: old-zoom tiles stay underneath until the new ones are
        // decoded anyway, and the 100 ms alpha ramp over the beige backdrop
        // (then multiplied by the dark veil) was the "缩放时底图闪一下". It
        // also delayed pruning by duration+50 ms.
        tileDisplay: const TileDisplay.instantaneous(),
        // Explicit: these sources have no @2x tiles; leaving it unset makes
        // flutter_map warn and guess.
        retinaMode: false,
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
