import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db/database.dart';
import 'geocoding_service.dart';
import 'region_stats.dart';

/// Loads the 区域点云: track points → ~5 km cells → named administrative
/// regions, offline-first.
///
/// The naming is the expensive part, so it is cached forever under
/// [_prefsKey] (grid-aligned, so it survives new points landing in a cell
/// that is already named) and runs in two passes:
///
///  * **offline** — cache plus the bundled country bboxes, drawn immediately;
///  * **network** — only the still-unnamed cells, busiest first, gently
///    rate-limited, refreshing the view every few results. A cell that the
///    system geocoder can name abroad is what gets us city-level labels
///    outside China, per the user's choice; with no network the cell keeps
///    its country-level name.
///
/// Cancel by calling [dispose] — the network pass checks between cells.
class RegionCloudSource extends ChangeNotifier {
  static const _prefsKey = 'region_cell_names_v1';

  /// Cells to name over the network in one visit to the screen.
  static const _networkBudget = 180;
  static const _networkGap = Duration(milliseconds: 140);

  final AppDb db;
  final GeocodingService geocoder;

  RegionCloudSource({required this.db, required this.geocoder});

  List<CellAgg> _cells = const [];
  List<RegionStat> _regions = const [];
  Map<String, String> _names = {};
  bool _loading = false;
  bool _naming = false;
  int _pending = 0;
  bool _disposed = false;

  List<CellAgg> get cells => _cells;
  List<RegionStat> get regions => _regions;
  bool get loading => _loading;

  /// True while the background naming pass is still running.
  bool get naming => _naming;

  /// Cells still waiting for a name (shown as a progress hint).
  int get pending => _pending;

  /// Busiest region's day count — the scale every label size is relative to.
  int get maxDayCount => _regions.isEmpty ? 0 : _regions.first.dayCount;

  Future<void> load({
    required List<int> layerIds,
    DateTime? from,
    DateTime? to,
    bool allowNetwork = true,
  }) async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      final pts = await db.cleanPoints(layerIds, from: from, to: to);
      final lats = Float64List(pts.length);
      final lngs = Float64List(pts.length);
      final times = Int64List(pts.length);
      for (var i = 0; i < pts.length; i++) {
        lats[i] = pts[i].lat;
        lngs[i] = pts[i].lng;
        times[i] = pts[i].time.millisecondsSinceEpoch;
      }
      final tz = DateTime.now().timeZoneOffset.inMilliseconds;
      _cells = await compute(_aggregate, (lats: lats, lngs: lngs, times: times, tz: tz));
      _names = await _loadNames();
      _refold();
      if (_disposed) return;
      _loading = false;
      notifyListeners();
      if (allowNetwork) unawaited(_nameMissing());
    } finally {
      _loading = false;
    }
  }

  void _refold() {
    _regions = foldRegions(_cells, _names);
    _pending = _cells.where((c) => !_names.containsKey(c.key)).length;
  }

  Future<void> _nameMissing() async {
    if (_naming) return;
    final todo = _cells.where((c) => !_names.containsKey(c.key)).toList();
    if (todo.isEmpty) return;
    _naming = true;
    notifyListeners();
    var done = 0, dirty = 0;
    try {
      for (final c in todo.take(_networkBudget)) {
        if (_disposed) return;
        try {
          final r = await geocoder.resolve(c.lat, c.lng);
          final name = '${r.country}|${r.province}|${r.city}';
          if (name != '||') {
            _names[c.key] = name;
            dirty++;
          }
        } catch (e) {
          debugPrint('[RegionCloud] geocode ${c.key} failed: $e');
        }
        done++;
        // Refresh often enough to feel alive, rarely enough to stay cheap.
        if (dirty > 0 && done % 8 == 0) {
          _refold();
          if (_disposed) return;
          notifyListeners();
        }
        await Future<void>.delayed(_networkGap);
      }
    } finally {
      _naming = false;
      if (!_disposed) {
        if (dirty > 0) {
          _refold();
          await _saveNames();
        }
        notifyListeners();
      }
    }
  }

  Future<Map<String, String>> _loadNames() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveNames() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(_names));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

List<CellAgg> _aggregate(
        ({Float64List lats, Float64List lngs, Int64List times, int tz}) a) =>
    aggregateCells(
      lats: a.lats,
      lngs: a.lngs,
      times: a.times,
      tzOffsetMs: a.tz,
    );
