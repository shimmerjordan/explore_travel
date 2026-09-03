import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart' as gc;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/prefs.dart';
import 'country_lookup.dart';
import 'learned_regions.dart';
import '../security/http_guard.dart';

/// Layered reverse-geocoding with a persistent cell cache + a learned
/// regions table. Resolution order:
///
///   1. 0.01° cell cache (instant, offline once warmed)
///   2. Amap reverse geocoding (if amapApiKey is set) — best for China
///   3. System geocoder (geocoding package) — uses iOS CLGeocoder /
///      Android Geocoder; best outside China when device is online
///   4. Bundled bbox table — last-resort coarse country guess, offline
///
/// Steps 2 and 3 cache the result in step 1's table, and also call into
/// [LearnedRegionsStore] so the explore screen can show finer regions
/// than what's bundled.
class GeocodeResult {
  final String country;
  final String province;
  final String city;
  final String source; // 'cache' | 'amap' | 'system' | 'bbox'
  const GeocodeResult({
    required this.country,
    required this.province,
    required this.city,
    required this.source,
  });

  bool get isEmpty => country.isEmpty;

  Map<String, dynamic> toJson() => {
        'country': country,
        'province': province,
        'city': city,
        'source': source,
      };
  static GeocodeResult fromJson(Map<String, dynamic> j) => GeocodeResult(
        country: j['country']?.toString() ?? '',
        province: j['province']?.toString() ?? '',
        city: j['city']?.toString() ?? '',
        source: j['source']?.toString() ?? 'cache',
      );
}

class GeocodingService {
  static const _cellPrefsKey = 'geocode_cell_cache_v1';
  static const _grid = 0.01; // ~1.1 km on a side at the equator

  /// 格缓存写回的合并窗口。预热 / 到访检测里网络反查常成串到来，每格都整包
  /// jsonEncode + 落盘一次太浪费，攒一会儿一起写。
  static const cacheWriteDelay = Duration(seconds: 2);

  final LearnedRegionsStore learned;
  final Dio _dio = guardedDio();
  AppSettings _settings;

  // 格缓存的内存权威副本：首次用到时才从 prefs 解码一次，之后只改内存、延迟
  // 写回。原先每次 resolve() 都 getString + 整包 jsonDecode，_persist 再解一次
  // 编一次，缓存几千格后每个点都要付这笔钱。
  Map<String, GeocodeResult>? _cells;
  // 上次解码 / 写出的 prefs 原文。备份恢复、「清除地理编码缓存」按钮都绕过本类
  // 直接改 prefs，靠它察觉外部改写：getString 返回的是同一个 String 对象，
  // 比较走 identical 快路径，不用真的逐字符比。
  String? _cellsRaw;
  // 还没落盘的新格。外部改写触发重解时要叠回去，别把它们丢了。
  final Map<String, GeocodeResult> _pending = {};
  Timer? _flushTimer;

  GeocodingService(AppSettings settings, this.learned) : _settings = settings;

  void updateSettings(AppSettings s) {
    _settings = s;
  }

  // ─── Cache ─────────────────────────────────────────────────────────────

  String _cellKey(double lat, double lng) {
    final qLat = (lat / _grid).floor();
    final qLng = (lng / _grid).floor();
    return '$qLat,$qLng';
  }

  /// 当前格表（内存副本）。prefs 原文若被别处改了，就以 prefs 为准重解，再叠上
  /// 本实例尚未落盘的格。
  Future<Map<String, GeocodeResult>> _cache() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_cellPrefsKey);
    final cells = _cells;
    if (cells != null && raw == _cellsRaw) return cells;
    final fresh =
        raw == null ? <String, GeocodeResult>{} : decodeCellCache(raw);
    fresh.addAll(_pending);
    _cells = fresh;
    _cellsRaw = raw;
    return fresh;
  }

  /// prefs 原文 → 格表。单独拆出来是给测试数解码次数用的。
  @protected
  Map<String, GeocodeResult> decodeCellCache(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) =>
        MapEntry(k, GeocodeResult.fromJson(v as Map<String, dynamic>)));
  }

  /// 把内存里的格表立刻写回 prefs。平时由 [cacheWriteDelay] 的定时器触发；
  /// 显式调用用于收尾 / 测试。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty) return;
    final cells = await _cache();
    final wrote = Map.of(_pending);
    final raw = jsonEncode(cells.map((k, v) => MapEntry(k, v.toJson())));
    try {
      final p = await SharedPreferences.getInstance();
      // 先记原文再写：setString 会同步更新 prefs 的内存表，之后 _cache() 比对
      // 就认得出这是自己写的。
      _cellsRaw = raw;
      await p.setString(_cellPrefsKey, raw);
    } catch (e) {
      debugPrint('[Geocoding] cache write failed: $e');
      return; // 留在 _pending 里，下次再试
    }
    // 只清掉本次确实写进去的；写的当口又进来的新格留给下一轮。
    for (final e in wrote.entries) {
      if (identical(_pending[e.key], e.value)) _pending.remove(e.key);
    }
  }

  /// 服务随 app 存活（provider 不销毁），这里只是给显式收尾一个口子。
  Future<void> dispose() => flush();

  Future<int> cachedCellCount() async => (await _cache()).length;

  Future<void> clearCache() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    final p = await SharedPreferences.getInstance();
    // remove 同步清掉 prefs 内存表里的键，之后 getString 是 null，与 _cellsRaw
    // 一致，内存副本继续作数。
    _cells = {};
    _cellsRaw = null;
    await p.remove(_cellPrefsKey);
  }

  // ─── Main resolve ──────────────────────────────────────────────────────

  /// [allowNetwork] = false short-circuits to cache + bbox only. Used by
  /// background passes that don't want to spend the user's data plan.
  Future<GeocodeResult> resolve(double lat, double lng,
      {bool allowNetwork = true}) async {
    final cache = await _cache();
    final k = _cellKey(lat, lng);
    final cached = cache[k];
    if (cached != null && !cached.isEmpty) {
      return GeocodeResult(
        country: cached.country,
        province: cached.province,
        city: cached.city,
        source: 'cache',
      );
    }

    if (allowNetwork) {
      final r = await lookupOnline(lat, lng);
      if (r != null) {
        try {
          await _persist(lat, lng, r);
        } catch (e) {
          debugPrint('[Geocoding] cache/learned write failed: $e');
        }
        return r;
      }
    }

    // 4. Bbox fallback.
    try {
      final lk = await CountryLookup.instance;
      final res = lk.lookup(lat, lng);
      final r = GeocodeResult(
        country: res.country,
        province: '',
        city: '',
        source: 'bbox',
      );
      // Don't pollute the cache with bbox guesses — they have lower trust
      // and we want a fresh online attempt next time.
      return r;
    } catch (_) {
      return const GeocodeResult(
          country: '未知', province: '', city: '', source: 'bbox');
    }
  }

  /// 在线反查：高德（配了 key 时）→ 系统地理编码器，返回第一个非空结果，都没有
  /// 就 null。拆成可覆写的方法是给测试一个不走网络的口子。
  @protected
  Future<GeocodeResult?> lookupOnline(double lat, double lng) async {
    // 2. Amap if configured.
    if ((_settings.amapApiKey ?? '').isNotEmpty) {
      try {
        final r = await _amap(lat, lng);
        if (!r.isEmpty) return r;
      } catch (e) {
        debugPrint('[Geocoding] Amap failed: $e');
      }
    }
    // 3. System geocoder.
    try {
      final r = await _system(lat, lng);
      if (!r.isEmpty) return r;
    } catch (e) {
      debugPrint('[Geocoding] system geocoder failed: $e');
    }
    return null;
  }

  Future<void> _persist(double lat, double lng, GeocodeResult r) async {
    final cells = await _cache();
    final k = _cellKey(lat, lng);
    cells[k] = r;
    _pending[k] = r;
    // 只改内存，落盘攒到一起（见 cacheWriteDelay）。
    _flushTimer ??= Timer(cacheWriteDelay, () => unawaited(flush()));
    await learned.upsert(
      country: r.country,
      province: r.province,
      city: r.city,
      lat: lat,
      lng: lng,
    );
  }

  // ─── Amap (国内最准) ──────────────────────────────────────────────────

  Future<GeocodeResult> _amap(double lat, double lng) async {
    // Amap docs: https://restapi.amap.com/v3/geocode/regeo
    // Coordinates must be GCJ-02. Geolocator gives WGS-84, so we relay
    // straight through and accept ~50m offset rather than depend on
    // CoordConverter here (callers can do better).
    final resp = await _dio.get(
      'https://restapi.amap.com/v3/geocode/regeo',
      queryParameters: {
        'key': _settings.amapApiKey,
        'location': '$lng,$lat',
        'extensions': 'base',
        'output': 'json',
      },
      options: Options(
        receiveTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 8),
      ),
    );
    final data = resp.data;
    if (data is! Map || data['status'] != '1') {
      return const GeocodeResult(
          country: '', province: '', city: '', source: 'amap');
    }
    final ac =
        (data['regeocode']?['addressComponent'] as Map?)?.cast<String, dynamic>();
    if (ac == null) {
      return const GeocodeResult(
          country: '', province: '', city: '', source: 'amap');
    }
    final country = ac['country']?.toString() ?? '中国';
    final province = ac['province']?.toString() ?? '';
    String city = '';
    final cityRaw = ac['city'];
    if (cityRaw is String && cityRaw.isNotEmpty) {
      city = cityRaw;
    } else if (cityRaw is List && cityRaw.isNotEmpty) {
      city = cityRaw.first?.toString() ?? '';
    }
    return GeocodeResult(
      country: country,
      province: province,
      city: city,
      source: 'amap',
    );
  }

  // ─── System geocoder (CLGeocoder / Android Geocoder) ──────────────────

  Future<GeocodeResult> _system(double lat, double lng) async {
    final list = await gc.placemarkFromCoordinates(lat, lng);
    if (list.isEmpty) {
      return const GeocodeResult(
          country: '', province: '', city: '', source: 'system');
    }
    final p = list.first;
    return GeocodeResult(
      country: p.country ?? '',
      province: p.administrativeArea ?? '',
      city: p.locality ?? p.subAdministrativeArea ?? '',
      source: 'system',
    );
  }
}
