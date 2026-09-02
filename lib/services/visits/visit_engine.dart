import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/db/database.dart';
import '../geo/geocoding_service.dart' show GeocodeResult;
import '../location/point_filter.dart';
import 'confidence_scorer.dart';
import 'stay_detector.dart';

/// Reverse-geocoder seam: (lat, lng) → region or null. Injected so the engine
/// is testable without SharedPreferences / network.
typedef PlaceGeocoder = Future<GeocodeResult?> Function(double lat, double lng);

/// Runs stay detection over track points and keeps the `visits` / `places`
/// tables in sync — the persistence half of Dawarich's pipeline:
///
///  * **Idempotent rebuild.** Machine rows (status 0, no tombstone) inside the
///    detected window are deleted and rewritten; rows the user touched
///    (confirmed / declined / soft-deleted / hand-made) are *anchors*: a new
///    stay overlapping an anchor by more than half its length is dropped, so
///    a deleted visit never comes back and a confirmed one is never doubled.
///  * **No churn.** If the fresh stays are tuple-identical to what's stored,
///    nothing is written (keeps sync/backup quiet).
///  * **Places.** A stay is attributed to the nearest place within 50 m
///    (manual > most-visited > closest); otherwise a new auto place is minted,
///    named from the geocoder's city when it knows one.
///  * **Incremental.** Callers pass a window; [detectAll] walks the whole
///    history in month chunks, in `compute()`, once (see [ensureInitial]).
class VisitEngine {
  final AppDb db;
  final PlaceGeocoder geocoder;
  final StayParams params;

  /// Detection algorithm version stored on each machine row.
  static const int detectionVersion = 1;

  /// Padding around a requested window so a stay straddling the edge is
  /// detected whole (bridged overnight stays can span a lot more, but 12 h
  /// covers the common "recording stopped at midnight" case).
  static const Duration windowPad = Duration(hours: 12);

  static const double attributionRadiusM = 50;

  VisitEngine(this.db, {required this.geocoder, this.params = StayParams.defaults});

  Timer? _debounce;
  bool _running = false;
  final _changes = StreamController<void>.broadcast();

  /// Fires after every run that wrote something.
  Stream<void> get changes => _changes.stream;

  /// Debounced (5 min, Dawarich's realtime debouncer) re-detection of the
  /// last [lookback] — call when recording stops or on a burst of new points.
  void scheduleRecent({Duration lookback = const Duration(hours: 6)}) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(minutes: 5), () {
      final now = DateTime.now();
      detectRange(now.subtract(lookback), now);
    });
  }

  /// Immediate re-detection of the last [lookback] (recording stop).
  Future<int> detectRecent({Duration lookback = const Duration(hours: 6)}) {
    _debounce?.cancel();
    final now = DateTime.now();
    return detectRange(now.subtract(lookback), now);
  }

  /// Walk the whole history month by month. Returns total machine visits.
  Future<int> detectAll({void Function(double progress)? onProgress}) async {
    final span = await db.pointTimeSpan();
    if (span == null) return 0;
    var (lo, hi) = span;
    lo = DateTime(lo.year, lo.month);
    var total = 0;
    var cursor = lo;
    final months = (hi.year - lo.year) * 12 + hi.month - lo.month + 1;
    var done = 0;
    while (!cursor.isAfter(hi)) {
      final next = DateTime(cursor.year, cursor.month + 1);
      total += await detectRange(cursor, next.subtract(const Duration(milliseconds: 1)));
      cursor = next;
      done++;
      onProgress?.call((done / months).clamp(0.0, 1.0));
    }
    return total;
  }

  /// Detect + persist for every layer with points in [from, to]. Returns the
  /// number of machine visits now stored for the window.
  Future<int> detectRange(DateTime from, DateTime to) async {
    if (_running) {
      // Serialise: a second caller waits for the first to finish.
      while (_running) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    _running = true;
    try {
      return await _detectRange(from, to);
    } catch (e, st) {
      debugPrint('[VISITS] detect failed: $e\n$st');
      return 0;
    } finally {
      _running = false;
    }
  }

  Future<int> _detectRange(DateTime from, DateTime to) async {
    final pFrom = from.subtract(windowPad), pTo = to.add(windowPad);
    final layers = await db.allLayers();
    final pts = await db.cleanPoints(layers.map((l) => l.id).toList(),
        from: pFrom, to: pTo);
    if (pts.isEmpty) return 0;

    // Group by layer (cleanPoints is ordered by layer, time already).
    final byLayer = <int, List<StayPoint>>{};
    for (final p in pts) {
      (byLayer[p.layerId] ??= []).add(StayPoint(
          p.lat, p.lng, p.time.millisecondsSinceEpoch,
          accuracy: p.accuracy));
    }

    final existing = await db.visitsBetween(pFrom, pTo, includeDeleted: true);
    final places = await db.allPlaces();
    final counts = await db.visitCountsByPlace();
    var written = 0;
    var changed = false;

    for (final e in byLayer.entries) {
      final layerId = e.key;
      final stays = await _detect(e.value);
      final anchors = existing
          .where((v) => v.layerId == layerId &&
              (v.status != 0 || v.deletedAt != null))
          .toList();
      final machine = existing
          .where((v) => v.layerId == layerId && v.status == 0 && v.deletedAt == null)
          .toList();

      final fresh = <_Candidate>[];
      for (final s in stays) {
        if (_overlapsAnchor(s, anchors)) continue;
        final place = await _attribute(s, places, counts);
        final conf = ConfidenceScorer.score(
          durationS: s.durationS,
          count: s.count,
          radiusM: s.radiusM,
          stayRadiusM: params.radiusM,
          medianAccM: s.medianAccM,
          bridgedFraction: s.bridgedFraction,
          placeMatch: place == null
              ? PlaceMatch.none
              : (place.source == 1 ? PlaceMatch.manual : PlaceMatch.auto),
          minPoints: params.minPoints,
        );
        fresh.add(_Candidate(s, place?.id, conf));
        if (place != null) counts[place.id] = (counts[place.id] ?? 0) + 1;
      }

      // Unchanged? Compare (start, end, placeId, count) tuples.
      final oldKeys = {for (final v in machine) _key(v.startedAt, v.endedAt, v.placeId, v.pointCount)};
      final newKeys = {for (final c in fresh) _key(DateTime.fromMillisecondsSinceEpoch(c.stay.startMs), DateTime.fromMillisecondsSinceEpoch(c.stay.endMs), c.placeId, c.stay.count)};
      written += fresh.length;
      if (oldKeys.length == newKeys.length && oldKeys.containsAll(newKeys)) {
        continue;
      }
      changed = true;
      final now = DateTime.now();
      await db.transaction(() async {
        await db.deleteMachineVisits(machine.map((v) => v.id).toList());
        await db.insertVisits([
          for (final c in fresh)
            VisitsCompanion.insert(
              placeId: Value(c.placeId),
              layerId: layerId,
              startedAt: DateTime.fromMillisecondsSinceEpoch(c.stay.startMs),
              endedAt: DateTime.fromMillisecondsSinceEpoch(c.stay.endMs),
              lat: c.stay.lat,
              lng: c.stay.lng,
              radius: c.stay.radiusM,
              pointCount: c.stay.count,
              bridgedSec: Value(c.stay.bridgedS),
              status: const Value(0),
              confidence: Value(c.conf.score),
              confidenceJson: Value(c.conf.toJson()),
              detectionVersion: const Value(detectionVersion),
              createdAt: now,
            ),
        ]);
      });
    }
    if (changed && _changes.hasListener) _changes.add(null);
    debugPrint('[VISITS] $from → $to: ${pts.length} pts, $written machine visits'
        '${changed ? '' : ' (unchanged)'}');
    return written;
  }

  Future<List<Stay>> _detect(List<StayPoint> pts) async {
    if (kIsWeb || pts.length < 2000) return detectStays(pts, params: params);
    final packed = await compute(detectStaysPacked, <String, Object>{
      'lat': [for (final p in pts) p.lat],
      'lng': [for (final p in pts) p.lng],
      'tMs': [for (final p in pts) p.tMs],
      'acc': [for (final p in pts) p.accuracy ?? double.nan],
    });
    return unpackStays(packed);
  }

  static String _key(DateTime a, DateTime b, int? place, int count) =>
      '${a.millisecondsSinceEpoch}|${b.millisecondsSinceEpoch}|$place|$count';

  static bool _overlapsAnchor(Stay s, List<Visit> anchors) {
    final dur = s.endMs - s.startMs;
    if (dur <= 0) return true;
    for (final a in anchors) {
      final lo = a.startedAt.millisecondsSinceEpoch;
      final hi = a.endedAt.millisecondsSinceEpoch;
      final overlap = (s.endMs < hi ? s.endMs : hi) - (s.startMs > lo ? s.startMs : lo);
      if (overlap > dur * 0.5) return true;
    }
    return false;
  }

  /// Nearest place within 50 m — manual first, then most visited, then
  /// closest. Mints an auto place when there is none.
  Future<Place?> _attribute(
      Stay s, List<Place> places, Map<int, int> counts) async {
    Place? best;
    var bestScore = -1.0;
    for (final p in places) {
      final d = PointFilter.haversineMeters(s.lat, s.lng, p.lat, p.lng);
      final r = p.radius > attributionRadiusM ? p.radius : attributionRadiusM;
      if (d > r) continue;
      final score = (p.source == 1 ? 1e6 : 0) + (counts[p.id] ?? 0) * 1e3 + (r - d);
      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }
    if (best != null) return best;

    // Mint. Name from the geocoder's city when it knows one, else generic.
    String name = '未命名地点';
    String? country, province, city;
    try {
      final g = await geocoder(s.lat, s.lng);
      if (g != null && !g.isEmpty) {
        country = g.country;
        province = g.province.isEmpty ? null : g.province;
        city = g.city.isEmpty ? null : g.city;
        if (city != null) name = '$city · 未命名地点';
      }
    } catch (_) {}
    final now = DateTime.now();
    final id = await db.insertPlace(PlacesCompanion.insert(
      name: name,
      lat: s.lat,
      lng: s.lng,
      radius: Value(s.radiusM < attributionRadiusM ? attributionRadiusM : s.radiusM),
      source: const Value(0),
      country: Value(country),
      province: Value(province),
      city: Value(city),
      createdAt: now,
      updatedAt: Value(now),
    ));
    final row = Place(
      id: id,
      uuid: '',
      name: name,
      lat: s.lat,
      lng: s.lng,
      radius: s.radiusM < attributionRadiusM ? attributionRadiusM : s.radiusM,
      source: 0,
      country: country,
      province: province,
      city: city,
      createdAt: now,
      updatedAt: now,
    );
    places.add(row);
    return row;
  }

  // ─── User actions ───

  Future<void> confirm(int visitId) =>
      db.updateVisit(visitId, const VisitsCompanion(status: Value(1)));

  /// Soft-delete: stays gone, never re-suggested.
  Future<void> remove(int visitId) => db.softDeleteVisit(visitId);

  /// Rename a place (locks it as manual so the geocoder never renames it).
  Future<void> renamePlace(int placeId, String name) => db.updatePlace(
      placeId, PlacesCompanion(name: Value(name.trim()), source: const Value(1)));

  /// Move a visit to [placeId]; if its old auto place is now unreferenced,
  /// drop it so the place list doesn't fill with orphans.
  Future<void> assignPlace(int visitId, int placeId) async {
    final v = await (db.select(db.visits)..where((t) => t.id.equals(visitId)))
        .getSingleOrNull();
    if (v == null) return;
    await db.updateVisit(
        visitId, VisitsCompanion(placeId: Value(placeId), status: const Value(1)));
    final old = v.placeId;
    if (old != null && old != placeId) {
      final counts = await db.visitCountsByPlace();
      final oldPlace = (await db.allPlaces()).where((p) => p.id == old).firstOrNull;
      if (oldPlace != null && oldPlace.source == 0 && (counts[old] ?? 0) == 0) {
        await db.deletePlace(old);
      }
    }
    if (_changes.hasListener) _changes.add(null);
  }

  void dispose() {
    _debounce?.cancel();
    _changes.close();
  }
}

class _Candidate {
  final Stay stay;
  final int? placeId;
  final ConfidenceResult conf;
  const _Candidate(this.stay, this.placeId, this.conf);
}
