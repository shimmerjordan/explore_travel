import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../../data/iso_countries.dart';

/// Coarse offline lat/lng → (continent, country) lookup.
///
/// Uses the bundled `assets/boundaries/countries.json` (~6KB, axis-aligned
/// bounding boxes per Chinese-named country). We pick the smallest-area
/// bbox that contains the point, which gives decent results for big land
/// masses but is unreliable for islands and shared borders. Good enough for
/// path categorisation; not good enough for a serious geocoder.
class CountryLookup {
  static CountryLookup? _instance;
  static Future<CountryLookup> get instance async =>
      _instance ??= await _load();

  final List<_Box> _boxes;
  CountryLookup._(this._boxes);

  static Future<CountryLookup> _load() async {
    final raw = await rootBundle.loadString('assets/boundaries/countries.json');
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final countries = (j['countries'] as Map).cast<String, dynamic>();
    // Build a Chinese-name → continent map from iso_countries.dart so we
    // don't have to ship a second table.
    final nameToContinent = <String, String>{};
    for (final entry in kContinents.entries) {
      for (final c in entry.value) {
        nameToContinent[c.name] = entry.key;
        for (final a in c.aliases) {
          nameToContinent[a] = entry.key;
        }
      }
    }
    final boxes = <_Box>[];
    for (final e in countries.entries) {
      final m = e.value as Map<String, dynamic>;
      final bbox = (m['bbox'] as List).cast<num>();
      if (bbox.length < 4) continue;
      boxes.add(_Box(
        country: e.key,
        continent: nameToContinent[e.key] ?? '其它',
        minLat: bbox[0].toDouble(),
        minLng: bbox[1].toDouble(),
        maxLat: bbox[2].toDouble(),
        maxLng: bbox[3].toDouble(),
      ));
    }
    return CountryLookup._(boxes);
  }

  /// Returns (continent, country) for the given coordinate. Falls back to
  /// `('未知', '未知')` if no bbox matches.
  ({String continent, String country}) lookup(double lat, double lng) {
    _Box? best;
    double bestArea = double.infinity;
    for (final b in _boxes) {
      if (lat < b.minLat || lat > b.maxLat) continue;
      if (lng < b.minLng || lng > b.maxLng) continue;
      final area = (b.maxLat - b.minLat) * (b.maxLng - b.minLng);
      if (area < bestArea) {
        bestArea = area;
        best = b;
      }
    }
    if (best == null) return (continent: '未知', country: '未知');
    return (continent: best.continent, country: best.country);
  }
}

/// Continent lookup by country name — used when a geocoder returned a
/// country but we still need to bucket it into a continent for the
/// upload-path hierarchy and explore screen rollup.
class CountryLookupExt {
  static Map<String, String>? _nameToContinent;
  static Future<String?> continentFor(String country) async {
    _nameToContinent ??= _build();
    return _nameToContinent![country];
  }

  static Map<String, String> _build() {
    final m = <String, String>{};
    for (final entry in kContinents.entries) {
      for (final c in entry.value) {
        m[c.name] = entry.key;
        for (final a in c.aliases) {
          m[a] = entry.key;
        }
      }
    }
    return m;
  }
}

class _Box {
  final String country;
  final String continent;
  final double minLat, minLng, maxLat, maxLng;
  _Box({
    required this.country,
    required this.continent,
    required this.minLat,
    required this.minLng,
    required this.maxLat,
    required this.maxLng,
  });
}
