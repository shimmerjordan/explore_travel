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

  /// Tail of the serial run queue: every run awaits the previous one instead
  /// of polling a `_running` flag every 50 ms (which burned a timer tick per
  /// waiter and woke the UI isolate for nothing while a full-history scan ran).
  Future<void> _tail = Future<void>.value();
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
  ///
  /// Holds the run queue for the WHOLE walk (not per month) so an incremental
  /// [detectRecent] cannot slip in between two months and mint a place the
  /// shared in-memory place list below would never hear about.
  Future<int> detectAll({void Function(double progress)? onProgress}) =>
      _serialised(() async {
        final span = await db.pointTimeSpan();
        if (span == null) return 0;
        var (lo, hi) = span;
        lo = DateTime(lo.year, lo.month);
        // 地点表和每地点到访数只读一次：以前每个月都 allPlaces() +
        // visitCountsByPlace() 各查一遍，几年的历史就是上百次全表查询。
        // _attribute 铸造新地点时 add 进同一个列表、计数在内存里累加，
        // 后面的月份看到的仍是最新状态。
        final places = await db.allPlaces();
        final counts = await db.visitCountsByPlace();
        var total = 0;
        var cursor = lo;
        final months = (hi.year - lo.year) * 12 + hi.month - lo.month + 1;
        var done = 0;
        while (!cursor.isAfter(hi)) {
          final next = DateTime(cursor.year, cursor.month + 1);
          total += await _detectRangeSafe(
              cursor, next.subtract(const Duration(milliseconds: 1)),
              bulk: true, places: places, counts: counts);
          cursor = next;
          done++;
          onProgress?.call((done / months).clamp(0.0, 1.0));
        }
        return total;
      });

  /// Detect + persist for every layer with points in [from, to]. Returns the
  /// number of machine visits now stored for the window.
  Future<int> detectRange(DateTime from, DateTime to) =>
      _serialised(() => _detectRangeSafe(from, to, bulk: false));

  /// Run [body] after every earlier run has finished — one detection at a
  /// time, in call order. The queue never fails: a run's error is handled in
  /// [_detectRangeSafe], so a waiter only ever sees "the previous one is done".
  Future<T> _serialised<T>(Future<T> Function() body) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return () async {
      await prev;
      try {
        return await body();
      } finally {
        done.complete();
      }
    }();
  }

  Future<int> _detectRangeSafe(DateTime from, DateTime to,
      {required bool bulk, List<Place>? places, Map<int, int>? counts}) async {
    try {
      return await _detectRange(from, to,
          bulk: bulk, places: places, counts: counts);
    } catch (e, st) {
      debugPrint('[VISITS] detect failed: $e\n$st');
      return 0;
    }
  }

  /// [places] / [counts] — pass the caller's live copies to reuse them across
  /// windows (see [detectAll]); null loads fresh ones for this window.
  Future<int> _detectRange(DateTime from, DateTime to,
      {required bool bulk, List<Place>? places, Map<int, int>? counts}) async {
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
    places ??= await db.allPlaces();
    counts ??= await db.visitCountsByPlace();
    var written = 0;
    var changed = false;

    for (final e in byLayer.entries) {
      final layerId = e.key;
      final stays = await _detect(e.value, bulk: bulk);
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

  /// [bulk] = part of the full-history walk: always off the UI isolate, even
  /// for a thin month — 几十个月连着算，每月哪怕只卡十几毫秒，加起来就是首启
  /// 时一段肉眼可见的掉帧。录制结束后的增量窗口点很少，原地算比起 isolate
  /// 更快，只有大窗口才进 isolate。
  Future<List<Stay>> _detect(List<StayPoint> pts, {required bool bulk}) async {
    if (kIsWeb || (!bulk && pts.length < 2000)) {
      return detectStays(pts, params: params);
    }
    final n = pts.length;
    final lat = Float64List(n), lng = Float64List(n), acc = Float64List(n);
    final tMs = Int64List(n);
    for (var i = 0; i < n; i++) {
      final p = pts[i];
      lat[i] = p.lat;
      lng[i] = p.lng;
      tMs[i] = p.tMs;
      acc[i] = p.accuracy ?? double.nan;
    }
    final packed = await compute(_detectStaysIsolate, <String, Object>{
      'lat': lat,
      'lng': lng,
      'tMs': tMs,
      'acc': acc,
      'params': Float64List.fromList([
        params.radiusM,
        params.minPoints.toDouble(),
        params.minDurationS.toDouble(),
        params.mergeGapS.toDouble(),
        params.sweepGapS.toDouble(),
        params.bridgeCapS.toDouble(),
        params.driftCapFactor,
        params.minRadiusM,
      ]),
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

/// `compute()` entry for [VisitEngine._detect]: typed columns + the engine's
/// [StayParams] (as an 8-double vector, see `_detect`) in, stays out packed
/// 8 doubles apiece in `detectStaysPacked`'s layout so [unpackStays] reads it.
///
/// 不复用 stay_detector 的 detectStaysPacked，是因为那个入口只认
/// StayParams.defaults —— 引擎带自定义参数时，isolate 路径的结果就会和原地
/// detectStays(params: params) 不一致。
Float64List _detectStaysIsolate(Map<String, Object> m) {
  final lat = m['lat'] as Float64List;
  final lng = m['lng'] as Float64List;
  final tMs = m['tMs'] as Int64List;
  final acc = m['acc'] as Float64List; // NaN = unknown
  final p = m['params'] as Float64List;
  final params = StayParams(
    radiusM: p[0],
    minPoints: p[1].toInt(),
    minDurationS: p[2].toInt(),
    mergeGapS: p[3].toInt(),
    sweepGapS: p[4].toInt(),
    bridgeCapS: p[5].toInt(),
    driftCapFactor: p[6],
    minRadiusM: p[7],
  );
  final pts = <StayPoint>[
    for (var i = 0; i < lat.length; i++)
      StayPoint(lat[i], lng[i], tMs[i],
          accuracy: acc[i].isNaN ? null : acc[i]),
  ];
  final stays = detectStays(pts, params: params);
  final out = Float64List(stays.length * 8);
  for (var i = 0; i < stays.length; i++) {
    final s = stays[i];
    final o = i * 8;
    out[o] = s.startMs.toDouble();
    out[o + 1] = s.endMs.toDouble();
    out[o + 2] = s.lat;
    out[o + 3] = s.lng;
    out[o + 4] = s.radiusM;
    out[o + 5] = s.count.toDouble();
    out[o + 6] = s.bridgedS.toDouble();
    out[o + 7] = s.medianAccM;
  }
  return out;
}
