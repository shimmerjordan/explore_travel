import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../app/providers.dart';
import '../../services/geo/coord_converter.dart';
import '../../services/map/tile_providers.dart';
import '../../services/security/http_guard.dart';

/// 全屏地图选点：拖动地图把中心针对准位置，或搜索地名跳过去。
/// 返回 **WGS-84** 坐标（内部按底图 provider 做 GCJ-02 换算），取消返回 null。
///
/// 搜索源：配了高德 Key 走高德 place/text（国内 POI 全）；没配走 OSM
/// Nominatim（免费，无需 Key，海外覆盖好）。
Future<({double lat, double lng})?> showLocationPicker(
  BuildContext context, {
  double? initialLat,
  double? initialLng,
}) {
  return Navigator.of(context, rootNavigator: true)
      .push<({double lat, double lng})>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _LocationPickerScreen(
        initialLat: initialLat,
        initialLng: initialLng,
      ),
    ),
  );
}

class _LocationPickerScreen extends ConsumerStatefulWidget {
  final double? initialLat;
  final double? initialLng;
  const _LocationPickerScreen({this.initialLat, this.initialLng});

  @override
  ConsumerState<_LocationPickerScreen> createState() =>
      _LocationPickerScreenState();
}

class _SearchHit {
  final String name;
  final String detail;
  final double lat; // WGS-84
  final double lng;
  _SearchHit(this.name, this.detail, this.lat, this.lng);
}

class _LocationPickerScreenState extends ConsumerState<_LocationPickerScreen> {
  final _mapCtrl = MapController();
  final _searchCtrl = TextEditingController();
  final _dio = guardedDio();

  // 地图中心（display 坐标系）。用 ValueNotifier 而不是 setState —— 拖动
  // 时每帧 setState 会重建 FlutterMap 子树、重置 TileLayer 的加载状态，
  // 瓦片永远出不来（轮15 在点亮地图上踩过一模一样的坑）。
  final _centerVN = ValueNotifier<LatLng?>(null);
  bool _searching = false;
  String? _searchError;
  List<_SearchHit> _hits = const [];

  /// 固定的地图实例：任何 setState（搜索结果、加载态）都不许重建它。
  /// 初始视角直接写进 MapOptions（有初始点 → 街区级；没有 → 全国级），
  /// 不走 postFrame move —— 避免与 TileLayer 首次订阅赛跑。
  late final Widget _map = () {
    final s = ref.read(settingsProvider);
    final hasInit = widget.initialLat != null && widget.initialLng != null;
    return FlutterMap(
      mapController: _mapCtrl,
      options: MapOptions(
        initialCenter: hasInit
            ? _toDisplay(widget.initialLat!, widget.initialLng!)
            : const LatLng(34.5, 104.0),
        initialZoom: hasInit ? 15.5 : 3.6,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onPositionChanged: (pos, _) => _centerVN.value = pos.center,
      ),
      children: [
        buildTileLayer(
          provider: s.mapProvider,
          style: s.mapStyle,
          amapKey: s.amapApiKey,
          googleKey: s.googleMapKey,
          customOsmUrl: s.customOsmTileUrl,
          ovitalUrl: s.ovitalTileUrl,
        ),
      ],
    );
  }();

  bool get _gcj => CoordConverter.needsGcj02(
      ref.read(settingsProvider).mapProvider);

  LatLng _toDisplay(double lat, double lng) {
    if (_gcj) {
      final g = CoordConverter.wgs84ToGcj02(lat, lng);
      return LatLng(g.lat, g.lng);
    }
    return LatLng(lat, lng);
  }

  ({double lat, double lng}) _fromDisplay(LatLng p) {
    if (_gcj) {
      final w = CoordConverter.gcj02ToWgs84(p.latitude, p.longitude);
      return (lat: w.lat, lng: w.lng);
    }
    return (lat: p.latitude, lng: p.longitude);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _centerVN.value = _mapCtrl.camera.center;
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _centerVN.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searchError = null;
      _hits = const [];
    });
    try {
      final amapKey = (ref.read(settingsProvider).amapApiKey ?? '').trim();
      List<_SearchHit> hits;
      if (amapKey.isNotEmpty) {
        final resp = await _dio.get<Map<String, dynamic>>(
          'https://restapi.amap.com/v3/place/text',
          queryParameters: {
            'keywords': query,
            'key': amapKey,
            'offset': 10,
            'page': 1,
          },
          options: Options(receiveTimeout: const Duration(seconds: 10)),
        );
        final pois = (resp.data?['pois'] as List?) ?? const [];
        hits = [
          for (final p in pois.whereType<Map>())
            if ((p['location'] ?? '').toString().contains(','))
              () {
                final loc = (p['location'] as String).split(',');
                // 高德返回 GCJ-02 → 统一归一成 WGS-84 存储。
                final w = CoordConverter.gcj02ToWgs84(
                    double.parse(loc[1]), double.parse(loc[0]));
                return _SearchHit(
                  (p['name'] ?? '').toString(),
                  [p['pname'], p['cityname'], p['adname'], p['address']]
                      .whereType<String>()
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  w.lat,
                  w.lng,
                );
              }(),
        ];
        if (hits.isEmpty &&
            (resp.data?['status']?.toString() ?? '1') != '1') {
          throw '高德搜索失败：${resp.data?['info'] ?? resp.data}';
        }
      } else {
        final resp = await _dio.get<List<dynamic>>(
          'https://nominatim.openstreetmap.org/search',
          queryParameters: {
            'q': query,
            'format': 'jsonv2',
            'limit': 10,
            'accept-language': 'zh-CN,zh',
          },
          options: Options(
            headers: {'User-Agent': 'explore_journal/0.1 (personal app)'},
            receiveTimeout: const Duration(seconds: 12),
          ),
        );
        hits = [
          for (final p in (resp.data ?? const []).whereType<Map>())
            _SearchHit(
              (p['name'] ?? p['display_name'] ?? '').toString(),
              (p['display_name'] ?? '').toString(),
              double.parse(p['lat'].toString()),
              double.parse(p['lon'].toString()),
            ),
        ];
      }
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searching = false;
        if (hits.isEmpty) _searchError = '没搜到「$query」，换个关键词试试';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = '搜索失败：$e';
      });
    }
  }

  void _jumpTo(_SearchHit h) {
    FocusScope.of(context).unfocus();
    _mapCtrl.move(_toDisplay(h.lat, h.lng), 16);
    _centerVN.value = _mapCtrl.camera.center;
    setState(() => _hits = const []);
  }

  Future<void> _jumpToMyLocation() async {
    final pin = ref.read(currentDisplayPositionProvider);
    ({double lat, double lng})? wgs = pin;
    if (wgs == null) {
      final pos = await ref.read(locationServiceProvider).currentOnce();
      if (pos != null) wgs = (lat: pos.latitude, lng: pos.longitude);
    }
    if (wgs == null || !mounted) return;
    _mapCtrl.move(_toDisplay(wgs.lat, wgs.lng), 15.5);
    _centerVN.value = _mapCtrl.camera.center;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          _map,
          // 中心固定针：针尖精确落在地图中心（图标底部对中心 → 整体上移一半高）。
          IgnorePointer(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_pin,
                      size: 44,
                      color: cs.primary,
                      shadows: const [
                        Shadow(color: Colors.black45, blurRadius: 6)
                      ]),
                  const SizedBox(height: 44), // 把针尖顶到 Center 点
                ],
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: cs.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
          ),
          // ── 顶部：返回 + 搜索栏 ──
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            right: 8,
            child: Column(
              children: [
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: cs.surface,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '取消',
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          textInputAction: TextInputAction.search,
                          onSubmitted: _search,
                          decoration: const InputDecoration(
                            hintText: '搜地名 / POI，回车跳转',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      if (_searching)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2)),
                        )
                      else
                        IconButton(
                          tooltip: '搜索',
                          icon: const Icon(Icons.search_rounded),
                          onPressed: () => _search(_searchCtrl.text),
                        ),
                    ],
                  ),
                ),
                if (_searchError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Material(
                      borderRadius: BorderRadius.circular(6),
                      color: cs.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Text(_searchError!,
                            style: TextStyle(
                                fontSize: 12, color: cs.onErrorContainer)),
                      ),
                    ),
                  ),
                if (_hits.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      color: cs.surface,
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 320),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _hits.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final h = _hits[i];
                            return ListTile(
                              dense: true,
                              leading: Icon(Icons.place_outlined,
                                  size: 20, color: cs.primary),
                              title: Text(h.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: h.detail.isEmpty
                                  ? null
                                  : Text(h.detail,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11)),
                              onTap: () => _jumpTo(h),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // ── 底部：坐标 + 确认 ──
          Positioned(
            left: 8,
            right: 8,
            bottom: MediaQuery.of(context).padding.bottom + 12,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(10),
              color: cs.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '回到我的位置',
                      icon: Icon(Icons.my_location_rounded,
                          color: cs.primary),
                      onPressed: _jumpToMyLocation,
                    ),
                    Expanded(
                      child: ValueListenableBuilder<LatLng?>(
                        valueListenable: _centerVN,
                        builder: (_, c, __) {
                          final wgs = c == null ? null : _fromDisplay(c);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('拖动地图，针尖对准要关联的位置',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600)),
                              Text(
                                wgs == null
                                    ? '…'
                                    : '${wgs.lat.toStringAsFixed(5)}, ${wgs.lng.toStringAsFixed(5)}',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: cs.onSurfaceVariant),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('就选这里'),
                      onPressed: () {
                        final c = _centerVN.value;
                        if (c == null) return;
                        Navigator.pop(context, _fromDisplay(c));
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
