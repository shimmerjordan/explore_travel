import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart' as gc;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/prefs.dart';
import 'country_lookup.dart';
import 'learned_regions.dart';

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

  final LearnedRegionsStore learned;
  final Dio _dio = Dio();
  AppSettings _settings;

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

  Future<Map<String, GeocodeResult>> _loadCache() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_cellPrefsKey);
    if (raw == null) return {};
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) =>
        MapEntry(k, GeocodeResult.fromJson(v as Map<String, dynamic>)));
  }

  Future<void> _saveCache(Map<String, GeocodeResult> m) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_cellPrefsKey,
        jsonEncode(m.map((k, v) => MapEntry(k, v.toJson()))));
  }

  Future<int> cachedCellCount() async => (await _loadCache()).length;

  Future<void> clearCache() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_cellPrefsKey);
  }

  // ─── Main resolve ──────────────────────────────────────────────────────

  /// [allowNetwork] = false short-circuits to cache + bbox only. Used by
  /// background passes that don't want to spend the user's data plan.
  Future<GeocodeResult> resolve(double lat, double lng,
      {bool allowNetwork = true}) async {
    final cache = await _loadCache();
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
      // 2. Amap if configured.
      if ((_settings.amapApiKey ?? '').isNotEmpty) {
        try {
          final r = await _amap(lat, lng);
          if (!r.isEmpty) {
            await _persist(lat, lng, r);
            return r;
          }
        } catch (e) {
          debugPrint('[Geocoding] Amap failed: $e');
        }
      }
      // 3. System geocoder.
      try {
        final r = await _system(lat, lng);
        if (!r.isEmpty) {
          await _persist(lat, lng, r);
          return r;
        }
      } catch (e) {
        debugPrint('[Geocoding] system geocoder failed: $e');
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

  Future<void> _persist(double lat, double lng, GeocodeResult r) async {
    final cache = await _loadCache();
    cache[_cellKey(lat, lng)] = r;
    await _saveCache(cache);
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
