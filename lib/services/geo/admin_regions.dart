import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'learned_regions.dart';
import '../security/http_guard.dart';

/// Administrative-region boundaries + lit-region matching for the
/// "点亮地图" tab.
///
/// Boundaries come from Alibaba's DataV GeoAtlas (GCJ-02, same datum as the
/// Amap base tiles, so polygons sit exactly on the map):
///   https://geo.datav.aliyun.com/areas_v3/bound/{adcode}_full.json
///
/// A region is LIT when any fog block centre (i.e. 足迹/路径经过的地方) falls
/// inside its polygon — geometric matching against the actual explored fog,
/// NOT just the geocoder's confirmed visits (which only cover places visited
/// while online with geocoding enabled; that's why only Shanghai lit up
/// before). Geocoder-learned regions still union in as a fallback.
///
/// Storage (documents/admin_regions/): index.json with the name→adcode
/// tables and the lit set, plus one {adcode}.json boundary per LIT region
/// only — "没有去过的国家、地区不存数据". [update] re-downloads the index,
/// re-matches the fog, and fetches any missing boundaries.
class LitRegion {
  final String name;
  final int adcode;
  final List<List<LatLng>> rings;
  final LatLng center;

  /// Rough bbox area (deg²) — label declutter shows big regions first.
  final double areaScore;
  const LitRegion({
    required this.name,
    required this.adcode,
    required this.rings,
    required this.center,
    required this.areaScore,
  });
}

class AdminMapData {
  final List<LitRegion> lit;
  final int countryCount;
  final int provinceCount;
  final int cityCount;
  final DateTime? updatedAt;
  const AdminMapData({
    required this.lit,
    required this.countryCount,
    required this.provinceCount,
    required this.cityCount,
    required this.updatedAt,
  });

  bool get hasIndex => updatedAt != null;
}

/// Isolate entry: match [points] (lat,lng pairs) against every feature in
/// every GeoJSON document, returning the features containing ≥[minHits]
/// points (default 1). bbox pre-filter first, exact ray-casting on the
/// survivors, early-stop at minHits. Country-level callers pass minHits > 1
/// so a single stray fog block (FOW imports carry the odd bogus cell — a
/// lone block in Brazil) can't light a whole country and trigger a
/// multi-megabyte boundary download.
Map<String, List<Map<String, Object>>> matchLitRegions(
    Map<String, Object> args) {
  final pts = args['points'] as Float64List;
  final docs = (args['docs'] as Map).cast<String, String>();
  final minHits = (args['minHits'] as int?) ?? 1;
  final out = <String, List<Map<String, Object>>>{};

  bool inRing(double lat, double lng, List ring) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final pi = ring[i] as List, pj = ring[j] as List;
      final xi = (pi[0] as num).toDouble(), yi = (pi[1] as num).toDouble();
      final xj = (pj[0] as num).toDouble(), yj = (pj[1] as num).toDouble();
      if ((yi > lat) != (yj > lat) &&
          lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  for (final entry in docs.entries) {
    final lit = <Map<String, Object>>[];
    final geo = jsonDecode(entry.value) as Map<String, dynamic>;
    for (final f in (geo['features'] as List? ?? const [])) {
      final props = ((f as Map)['properties'] as Map?) ?? const {};
      // Attribute compatibility: DataV uses name; GADM uses NAME_2/NAME_1;
      // world-countries GeoJSON uses name + a string feature.id (ISO3).
      final name = (props['name'] ??
              props['NAME_2'] ??
              props['NAME_1'] ??
              props['shapeName'])
          ?.toString() ??
          '';
      // DataV features carry a numeric properties.adcode (plus one aggregate
      // feature whose adcode is the STRING "100000_JD" — a hard `as num?`
      // cast on it crashed the whole update); GADM carries GID_2/GID_1.
      final ac = props['adcode'];
      final id = ac is num
          ? '${ac.toInt()}'
          : (props['GID_2'] ?? props['GID_1'] ?? f['id'])?.toString() ?? '';
      final geom = f['geometry'] as Map?;
      if (name.isEmpty || id.isEmpty || geom == null) continue;

      // Outer rings only (holes are negligible at city granularity).
      final rings = <List>[];
      final coords = geom['coordinates'] as List? ?? const [];
      if (geom['type'] == 'Polygon') {
        if (coords.isNotEmpty) rings.add(coords.first as List);
      } else if (geom['type'] == 'MultiPolygon') {
        for (final poly in coords) {
          if ((poly as List).isNotEmpty) rings.add(poly.first as List);
        }
      }
      if (rings.isEmpty) continue;

      var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
      for (final ring in rings) {
        for (final p in ring) {
          final lng = ((p as List)[0] as num).toDouble();
          final lat = (p[1] as num).toDouble();
          if (lat < minLat) minLat = lat;
          if (lat > maxLat) maxLat = lat;
          if (lng < minLng) minLng = lng;
          if (lng > maxLng) maxLng = lng;
        }
      }

      var hits = 0;
      for (var i = 0; i < pts.length && hits < minHits; i += 2) {
        final lat = pts[i], lng = pts[i + 1];
        if (lat < minLat || lat > maxLat || lng < minLng || lng > maxLng) {
          continue;
        }
        for (final ring in rings) {
          if (inRing(lat, lng, ring)) {
            hits++;
            break;
          }
        }
      }
      if (hits >= minHits) lit.add({'name': name, 'id': id});
    }
    out[entry.key] = lit;
  }
  return out;
}

class AdminRegionStore {
  static const _base = 'https://geo.datav.aliyun.com/areas_v3/bound';

  /// World country outlines (WGS-84) — DataV only covers China, so foreign
  /// footprints light up at COUNTRY granularity from this set. jsDelivr
  /// mirror: reachable from mainland China without a proxy.
  static const _worldUrl =
      'https://cdn.jsdelivr.net/gh/johan/world.geo.json@master/countries.geo.json';
  static const _municipalityAdcodes = {110000, 120000, 310000, 500000};
  final Dio _dio = guardedDio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
  ));

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/admin_regions');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<String?> _readRaw(String name) async {
    try {
      final f = File('${(await _dir()).path}/$name');
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeRaw(String name, String data) async {
    await File('${(await _dir()).path}/$name').writeAsString(data);
  }

  Future<String> _fetchRaw(String path) async {
    final r = await _dio.get<String>(
        path.startsWith('http') ? path : '$_base/$path',
        options: Options(responseType: ResponseType.plain));
    return r.data!;
  }

  /// Fuzzy CN admin-name match (geocoder spellings vs DataV names).
  int? _match(String name, Map<String, int> table) {
    if (name.isEmpty) return null;
    final hit = table[name];
    if (hit != null) return hit;
    String strip(String s) => s.replaceAll(
        RegExp(r'(市|省|自治区|自治州|特别行政区|地区|盟|区|县)$'), '');
    final ns = strip(name);
    if (ns.isEmpty) return null;
    for (final e in table.entries) {
      if (strip(e.key) == ns) return e.value;
    }
    for (final e in table.entries) {
      if (e.key.startsWith(ns) || ns.startsWith(strip(e.key))) return e.value;
    }
    return null;
  }

  /// Extract feature [adcode] from a `_full` document and store it as that
  /// region's standalone boundary file.
  Future<bool> _storeFeature(String rawFull, int adcode) async {
    try {
      final geo = jsonDecode(rawFull) as Map<String, dynamic>;
      for (final f in (geo['features'] as List? ?? const [])) {
        final props = ((f as Map)['properties'] as Map?) ?? const {};
        final ac = props['adcode'];
        if (ac is! num || ac.toInt() != adcode) continue;
        await _writeRaw('$adcode.json',
            jsonEncode({'type': 'FeatureCollection', 'features': [f]}));
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Re-download the index, geometrically match the fog against province and
  /// city polygons, union the geocoder-learned regions, and store the lit
  /// set + boundaries. [fogPoints] is (lat,lng) pairs of explored fog block
  /// centres — the "足迹经过" ground truth.
  Future<String> update({
    required List<LearnedRegion> learned,
    required Float64List fogPoints,
    void Function(String phase)? onPhase,
  }) async {
    onPhase?.call('下载省级边界…');
    final provRaw = await _fetchRaw('100000_full.json');
    final provinceTable = <String, int>{};
    {
      final geo = jsonDecode(provRaw) as Map<String, dynamic>;
      for (final f in (geo['features'] as List? ?? const [])) {
        final p = ((f as Map)['properties'] as Map?) ?? const {};
        final n = p['name']?.toString() ?? '';
        final a = p['adcode'];
        if (n.isNotEmpty && a is num) provinceTable[n] = a.toInt();
      }
    }

    onPhase?.call('按足迹匹配省份…');
    final provMatch = await compute(
        matchLitRegions, {'points': fogPoints, 'docs': {'p': provRaw}});
    final litProvinces = <int, String>{
      for (final m in provMatch['p'] ?? const [])
        int.parse('${m['id']}'): m['name'] as String,
    };
    // Geocoder-learned provinces union in (visited but fog too sparse).
    for (final r in learned) {
      if (r.province.isEmpty) continue;
      final a = _match(r.province, provinceTable);
      if (a != null) {
        litProvinces.putIfAbsent(
            a, () => provinceTable.entries.firstWhere((e) => e.value == a).key);
      }
    }

    // Cities: one _full fetch per lit province, matched in one isolate run.
    final cityTable = <String, int>{};
    final cityDocs = <String, String>{};
    for (final e in litProvinces.entries) {
      if (_municipalityAdcodes.contains(e.key)) continue; // city == itself
      onPhase?.call('下载 ${e.value} 城市边界…');
      try {
        final raw = await _fetchRaw('${e.key}_full.json');
        cityDocs['${e.key}'] = raw;
        final geo = jsonDecode(raw) as Map<String, dynamic>;
        for (final f in (geo['features'] as List? ?? const [])) {
          final p = ((f as Map)['properties'] as Map?) ?? const {};
          final n = p['name']?.toString() ?? '';
          final a = p['adcode'];
          if (n.isNotEmpty && a is num) cityTable[n] = a.toInt();
        }
      } catch (_) {}
    }

    onPhase?.call('按足迹匹配城市…');
    final litCities = <int, String>{};
    if (cityDocs.isNotEmpty) {
      final cityMatch = await compute(
          matchLitRegions, {'points': fogPoints, 'docs': cityDocs});
      for (final list in cityMatch.values) {
        for (final m in list) {
          litCities[int.parse('${m['id']}')] = m['name'] as String;
        }
      }
    }
    // Municipalities are lit as "cities" via their province polygon.
    for (final e in litProvinces.entries) {
      if (_municipalityAdcodes.contains(e.key)) litCities[e.key] = e.value;
    }
    // Geocoder-learned cities union in.
    for (final r in learned) {
      if (r.city.isEmpty) continue;
      final a = _match(r.city, cityTable);
      if (a != null && !litCities.containsKey(a)) {
        litCities[a] =
            cityTable.entries.firstWhere((e) => e.value == a).key;
      }
    }

    // Store each lit city's boundary (from the already-fetched province
    // docs — no extra requests). Municipalities extract from the country doc.
    onPhase?.call('保存点亮区域边界…');
    var stored = 0;
    for (final e in litCities.entries) {
      if (_municipalityAdcodes.contains(e.key)) {
        if (await _storeFeature(provRaw, e.key)) stored++;
        continue;
      }
      final provKey = '${(e.key ~/ 10000) * 10000}';
      final raw = cityDocs[provKey];
      if (raw != null && await _storeFeature(raw, e.key)) stored++;
    }

    // Foreign footprints (DataV has no data outside China): the coarse world
    // set only SELECTS which countries to inspect; the actual lighting is
    // city-level (GADM ADM2, falling back to ADM1, then to the coarse
    // country outline) — visiting one city must NOT light the whole country.
    final litCountries = <String, String>{};
    final litForeign = <String, String>{};
    try {
      onPhase?.call('下载世界国家边界…');
      final worldRaw = await _fetchRaw(_worldUrl);
      onPhase?.call('按足迹匹配国家…');
      // minHits 3: a country must contain ≥3 explored blocks to count —
      // FOW imports can carry a lone bogus cell on another continent.
      final worldMatch = await compute(matchLitRegions,
          {'points': fogPoints, 'docs': {'w': worldRaw}, 'minHits': 3});
      for (final m in worldMatch['w'] ?? const []) {
        final id = '${m['id']}';
        if (id == 'CHN') continue;
        litCountries[id] = m['name'] as String;
      }

      for (final e in litCountries.entries) {
        final iso3 = e.key;
        var stored = false;
        for (final level in const [2, 1]) {
          try {
            // The phone reaches the GADM host at ~15-50 KB/s — cache the
            // per-country file forever so only the FIRST update pays for it.
            final cacheName = 'gadm_${iso3}_$level.json';
            var raw = await _readRaw(cacheName);
            if (raw == null) {
              onPhase?.call('下载 ${e.value} 行政区（级别 $level）…');
              final url =
                  'https://geodata.ucdavis.edu/gadm/gadm4.1/json/gadm41_${iso3}_$level.json';
              // Size guard: at these speeds anything past a few MB feels
              // like a hang (and huge files would OOM the JSON parse
              // anyway) — drop a level instead.
              final head = await _dio.head(url);
              final len = int.tryParse(
                      head.headers.value('content-length') ?? '') ??
                  0;
              if (len > 6 * 1024 * 1024) continue;
              final resp = await _dio.get<String>(
                url,
                options: Options(
                  responseType: ResponseType.plain,
                  receiveTimeout: const Duration(minutes: 4),
                ),
                onReceiveProgress: (got, total) {
                  if (total > 0) {
                    onPhase?.call('下载 ${e.value} 行政区（级别 $level）'
                        ' ${(got * 100 / total).round()}%');
                  }
                },
              );
              raw = resp.data!;
              await _writeRaw(cacheName, raw);
            }
            onPhase?.call('按足迹匹配 ${e.value} 的城市…');
            final match = await compute(
                matchLitRegions, {'points': fogPoints, 'docs': {'g': raw}});
            final hits = match['g'] ?? const [];
            if (hits.isEmpty) break; // country matched but no subdivision —
            // coastline mismatch; fall through to the outline below.
            final geo = jsonDecode(raw) as Map<String, dynamic>;
            final wanted = {for (final m in hits) '${m['id']}': m['name']};
            for (final f in (geo['features'] as List? ?? const [])) {
              final props = ((f as Map)['properties'] as Map?) ?? const {};
              final gid =
                  (props['GID_2'] ?? props['GID_1'])?.toString() ?? '';
              final hitName = wanted[gid];
              if (hitName == null) continue;
              final key = gid.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
              await _writeRaw('foreign_$key.json',
                  jsonEncode({'type': 'FeatureCollection', 'features': [f]}));
              litForeign[key] = '$hitName';
            }
            stored = true;
            break;
          } catch (_) {
            // 404 (no such level) / timeout — try the next fallback.
          }
        }
        if (!stored) {
          // Last resort: the coarse country outline, so the visit still shows.
          final worldGeo = jsonDecode(worldRaw) as Map<String, dynamic>;
          for (final f in (worldGeo['features'] as List? ?? const [])) {
            if ((f as Map)['id']?.toString() != iso3) continue;
            await _writeRaw('foreign_$iso3.json',
                jsonEncode({'type': 'FeatureCollection', 'features': [f]}));
            litForeign[iso3] = e.value;
          }
        }
      }
    } catch (_) {
      // Offline / mirror down — keep whatever the previous run stored.
    }

    await _writeRaw(
        'index.json',
        jsonEncode({
          'updated': DateTime.now().toIso8601String(),
          'provinces': provinceTable,
          'cities': cityTable,
          'litProvinces':
              litProvinces.map((k, v) => MapEntry('$k', v)),
          'litCities': litCities.map((k, v) => MapEntry('$k', v)),
          'litCountries': litCountries,
          'litForeign': litForeign,
        }));
    return '行政区已更新：足迹点亮 ${litProvinces.length} 省 · '
        '${litCities.length} 市 · 境外 ${litCountries.length} 国 '
        '${litForeign.length} 个行政区（$stored 个边界已缓存）';
  }

  /// Assemble the lit map purely from local files (no network).
  Future<AdminMapData> load(List<LearnedRegion> learned) async {
    final countries = <String>{
      for (final r in learned)
        if (r.country.isNotEmpty) r.country,
    };

    final indexRaw = await _readRaw('index.json');
    if (indexRaw == null) {
      return AdminMapData(
        lit: const [],
        countryCount: countries.length,
        provinceCount: 0,
        cityCount: 0,
        updatedAt: null,
      );
    }
    final index = jsonDecode(indexRaw) as Map<String, dynamic>;
    final litCities = ((index['litCities'] as Map?) ?? const {})
        .map((k, v) => MapEntry(int.parse(k.toString()), v.toString()));
    final litCountries = ((index['litCountries'] as Map?) ?? const {})
        .map((k, v) => MapEntry(k.toString(), v.toString()));
    final litForeign = ((index['litForeign'] as Map?) ?? const {})
        .map((k, v) => MapEntry(k.toString(), v.toString()));
    final litProvinceCount =
        ((index['litProvinces'] as Map?) ?? const {}).length;
    // Any lit fog inside China implies the country is visited even when the
    // geocoder never confirmed it.
    if (litCities.isNotEmpty) countries.add('中国');
    countries.addAll(litCountries.values);

    final lit = <LitRegion>[];
    for (final e in litCities.entries) {
      final raw = await _readRaw('${e.key}.json');
      if (raw == null) continue;
      final region = _parseOutline(
          e.value, e.key, jsonDecode(raw) as Map<String, dynamic>);
      if (region != null) lit.add(region);
    }
    // Foreign lit subdivisions (GADM city/state level, or the coarse
    // country outline when GADM had nothing).
    for (final e in litForeign.entries) {
      final raw = await _readRaw('foreign_${e.key}.json');
      if (raw == null) continue;
      final region = _parseOutline(
          e.value, 0, jsonDecode(raw) as Map<String, dynamic>);
      if (region != null) lit.add(region);
    }
    return AdminMapData(
      lit: lit,
      countryCount: countries.length,
      provinceCount: litProvinceCount,
      cityCount: litCities.length + litForeign.length,
      updatedAt: DateTime.tryParse(index['updated']?.toString() ?? ''),
    );
  }

  /// Parse a boundary document into simplified rings + a label point.
  LitRegion? _parseOutline(String name, int adcode, Map<String, dynamic> geo) {
    final features = geo['features'] as List? ?? const [];
    if (features.isEmpty) return null;
    final f = features.first as Map;
    final props = (f['properties'] as Map?) ?? const {};
    final geom = f['geometry'] as Map?;
    if (geom == null) return null;

    List<List<LatLng>> rings;
    final type = geom['type'];
    final coords = geom['coordinates'] as List? ?? const [];
    if (type == 'Polygon') {
      rings = [_ring(coords.isEmpty ? const [] : coords.first as List)];
    } else if (type == 'MultiPolygon') {
      rings = [
        for (final poly in coords)
          _ring((poly as List).isEmpty ? const [] : poly.first as List),
      ];
    } else {
      return null;
    }
    rings = [
      for (final r in rings)
        if (r.length >= 4) r
    ];
    if (rings.isEmpty) return null;

    LatLng center;
    final c = props['center'] ?? props['centroid'];
    if (c is List && c.length >= 2) {
      center = LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
    } else {
      var lat = 0.0, lng = 0.0, n = 0;
      for (final p in rings.first) {
        lat += p.latitude;
        lng += p.longitude;
        n++;
      }
      center = LatLng(lat / n, lng / n);
    }

    var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
    for (final ring in rings) {
      for (final p in ring) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
    }
    return LitRegion(
      name: name,
      adcode: adcode,
      rings: rings,
      center: center,
      areaScore: (maxLat - minLat) * (maxLng - minLng),
    );
  }

  /// GeoJSON ring → LatLng list. Points are snapped to a ~110 m grid and
  /// consecutive duplicates dropped. Quantisation is the ONLY reduction that
  /// keeps neighbouring regions' SHARED borders vertex-identical — the old
  /// every-Nth decimation thinned each ring on its own phase, so adjacent
  /// cities showed slivers of overlap and gaps along their common edge.
  List<LatLng> _ring(List raw) {
    const q = 0.001; // ° — ~110 m, invisible at city scale
    final out = <LatLng>[];
    double? plat, plng;
    for (final p in raw) {
      if (p is! List || p.length < 2) continue;
      final lat = ((p[1] as num) / q).round() * q;
      final lng = ((p[0] as num) / q).round() * q;
      if (lat == plat && lng == plng) continue;
      out.add(LatLng(lat, lng));
      plat = lat;
      plng = lng;
    }
    return out;
  }
}
