import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// One region the user has actually visited. The bbox is the running
/// min/max of every confirmed point that geocoded to this region —
/// starts as a microscopic square at the first point and grows
/// monotonically. Single-visit bboxes are almost meaningless; ~10
/// visits in spread-out parts of a province give a useful shape.
class LearnedRegion {
  final String country;
  /// May be empty when the geocoder only resolved to country level.
  final String province;
  /// May be empty when the geocoder didn't resolve below province.
  final String city;
  double minLat, maxLat, minLng, maxLng;
  int pointCount;
  DateTime lastSeen;

  LearnedRegion({
    required this.country,
    required this.province,
    required this.city,
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
    required this.pointCount,
    required this.lastSeen,
  });

  String get key => '$country|$province|$city';

  void extend(double lat, double lng) {
    if (lat < minLat) minLat = lat;
    if (lat > maxLat) maxLat = lat;
    if (lng < minLng) minLng = lng;
    if (lng > maxLng) maxLng = lng;
    pointCount++;
    lastSeen = DateTime.now();
  }

  Map<String, dynamic> toJson() => {
        'country': country,
        'province': province,
        'city': city,
        'minLat': minLat,
        'maxLat': maxLat,
        'minLng': minLng,
        'maxLng': maxLng,
        'pointCount': pointCount,
        'lastSeen': lastSeen.toIso8601String(),
      };

  static LearnedRegion fromJson(Map<String, dynamic> j) => LearnedRegion(
        country: j['country']?.toString() ?? '',
        province: j['province']?.toString() ?? '',
        city: j['city']?.toString() ?? '',
        minLat: (j['minLat'] as num).toDouble(),
        maxLat: (j['maxLat'] as num).toDouble(),
        minLng: (j['minLng'] as num).toDouble(),
        maxLng: (j['maxLng'] as num).toDouble(),
        pointCount: (j['pointCount'] as num?)?.toInt() ?? 1,
        lastSeen: DateTime.tryParse(j['lastSeen']?.toString() ?? '') ??
            DateTime.now(),
      );
}

/// Persistent table of every learned (country, province, city) the user
/// has ever had a confirmed point in. Stored as JSON in SharedPreferences
/// because the volume is tiny (a heavy traveler in a decade might hit
/// a few thousand entries).
class LearnedRegionsStore {
  static const _prefsKey = 'learned_regions_v1';

  Future<Map<String, LearnedRegion>> _loadAll() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw == null) return {};
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map(
        (k, v) => MapEntry(k, LearnedRegion.fromJson(v as Map<String, dynamic>)));
  }

  Future<void> _saveAll(Map<String, LearnedRegion> all) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey,
        jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))));
  }

  /// Returns the updated region (whether new or extended).
  Future<LearnedRegion> upsert({
    required String country,
    String province = '',
    String city = '',
    required double lat,
    required double lng,
  }) async {
    if (country.isEmpty) {
      return LearnedRegion(
        country: '',
        province: '',
        city: '',
        minLat: lat,
        maxLat: lat,
        minLng: lng,
        maxLng: lng,
        pointCount: 0,
        lastSeen: DateTime.now(),
      );
    }
    final all = await _loadAll();
    // Maintain three rows: country, country+province, country+province+city,
    // so the explore screen can roll up at each level without re-aggregating.
    Future<void> bump(String c, String p, String ci) async {
      final k = '$c|$p|$ci';
      final cur = all[k];
      if (cur == null) {
        all[k] = LearnedRegion(
          country: c,
          province: p,
          city: ci,
          minLat: lat,
          maxLat: lat,
          minLng: lng,
          maxLng: lng,
          pointCount: 1,
          lastSeen: DateTime.now(),
        );
      } else {
        cur.extend(lat, lng);
      }
    }

    await bump(country, '', '');
    if (province.isNotEmpty) await bump(country, province, '');
    if (province.isNotEmpty && city.isNotEmpty) {
      await bump(country, province, city);
    }
    await _saveAll(all);
    final fullKey = '$country|$province|$city';
    return all[fullKey] ?? all['$country||'] ?? all['$country|$province|']!;
  }

  Future<List<LearnedRegion>> all() async => (await _loadAll()).values.toList();

  Future<List<LearnedRegion>> forCountry(String country) async {
    final all = await _loadAll();
    return all.values.where((r) => r.country == country).toList();
  }

  /// True if the user has any confirmed point in [country].
  Future<bool> hasCountry(String country) async {
    final all = await _loadAll();
    return all.containsKey('$country||');
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_prefsKey);
  }
}
