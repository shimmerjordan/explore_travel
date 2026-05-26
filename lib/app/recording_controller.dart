import 'dart:async';
import 'dart:math' as math;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/db/database.dart';
import '../services/location/background_task.dart'
    if (dart.library.js_interop) '../services/location/background_task_stub.dart';
import 'providers.dart';
// providers exports groupServiceProvider

final recordingActiveProvider = StateProvider<bool>((ref) => false);

/// Drives recording: foreground (LocationService) when app is open, plus a
/// persistent foreground service so screen lock keeps GPS flowing. Both feed
/// the same DB insert + fog reveal pipeline.
///
/// Concurrency contract:
///   * Two subscriptions (foreground + background) can fire `_handleSample`
///     concurrently. Each sample does a drift insert + 1-N fog-tile
///     read/write + an in-mesh broadcast — racing them stalls the main
///     isolate and double-paints the fog. We serialise through a single
///     `Future` chain (`_inflight`) so only one sample is in flight at
///     a time; the rest queue.
///   * Identical samples (same lat/lng/timestamp) from the two streams
///     are deduped by `_lastHandledKey`. Without this every sample
///     ended up being processed twice on Android.
///   * `fogRefreshProvider` is bumped at most once per 250 ms via a
///     coalescing timer instead of once per sample, so a flurry of
///     points doesn't trigger a frame-storm in the fog painter.
class RecordingController {
  final Ref ref;
  StreamSubscription<Map<String, dynamic>>? _bgSub;
  StreamSubscription? _fgSub;
  RecordingController(this.ref);

  /// Last sample (lat, lng, time) per layer — used for the line-stitching
  /// gate.
  final Map<int, ({double lat, double lng, DateTime t})> _lastSample = {};

  /// Serialises samples. New samples await whatever's already in flight
  /// before their own work begins. If the queue ever exceeds [_maxQueue]
  /// we drop the new sample on the floor (better to skip a point than
  /// pile up a 30-sample backlog that locks the UI for seconds).
  Future<void> _inflight = Future.value();
  int _queued = 0;
  static const _maxQueue = 6;

  /// "lat|lng|timeMs" of the most recently handled sample — used to
  /// drop the duplicate that the *other* stream is about to emit.
  String? _lastHandledKey;

  /// Coalescing timer for the UI fog refresh counter. We collect any
  /// number of writes into a single notifier bump.
  Timer? _refreshDebounce;
  bool _refreshPending = false;

  /// Returns null on success, or a user-facing error string on failure.
  Future<String?> start() async {
    final settings = ref.read(settingsProvider);
    final loc = ref.read(locationServiceProvider);
    final ok = await loc.start(settings.recordingMode);
    if (!ok) {
      return loc.lastError ?? '无法启动定位';
    }

    // Background service only available on native platforms; safe to call on web (stub no-ops).
    await BackgroundLocation.start(settings.recordingMode);
    _bgSub = BackgroundLocation.listen(_enqueueSample);

    _fgSub = loc.stream.listen((pos) => _enqueueSample({
          'lat': pos.latitude,
          'lng': pos.longitude,
          'accuracy': pos.accuracy,
          'altitude': pos.altitude,
          'speed': pos.speed,
          'timeMs': DateTime.now().millisecondsSinceEpoch,
        }));

    ref.read(recordingActiveProvider.notifier).state = true;
    return null;
  }

  /// Public entry point — every sample (fg / bg / sim) goes through here.
  /// Enqueues onto [_inflight] so the writes are strictly sequential.
  void _enqueueSample(Map<String, dynamic> s) {
    if (_queued >= _maxQueue) {
      // Drop. The fog has plenty of points; one missed sample is
      // invisible. Worse than dropping would be a 5-second main-thread
      // lag while we catch up.
      if (kDebugMode) debugPrint('[Recording] queue full — dropping sample');
      return;
    }
    final lat = (s['lat'] as num?)?.toDouble();
    final lng = (s['lng'] as num?)?.toDouble();
    final timeMs = (s['timeMs'] as num?)?.toInt();
    if (lat == null || lng == null) return;
    // Dedup the bg/fg double-emit. Round time to nearest 200 ms so
    // micro-jitter between the two streams still folds together.
    final key = '${lat.toStringAsFixed(6)}|${lng.toStringAsFixed(6)}|'
        '${(timeMs ?? 0) ~/ 200}';
    if (key == _lastHandledKey) return;
    _lastHandledKey = key;

    _queued++;
    _inflight = _inflight.then((_) async {
      try {
        await _handleSample(s);
      } finally {
        _queued--;
      }
    });
  }

  Future<void> _handleSample(Map<String, dynamic> s) async {
    final db = ref.read(dbProvider);
    final fog = ref.read(fogEngineProvider);
    final layerId = ref.read(effectiveActiveLayerIdProvider);
    final lat = (s['lat'] as num).toDouble();
    final lng = (s['lng'] as num).toDouble();
    final settings = ref.read(settingsProvider);
    // Fire-and-forget the broadcast — it can hit a slow socket and we
    // don't want the fog write to wait for it. The previous code
    // `await`ed it, which is why a flaky LAN peer could stall the
    // record path entirely.
    if (settings.groupId != null && settings.groupId!.isNotEmpty) {
      unawaited(() async {
        try {
          await ref.read(groupServiceProvider).broadcastLocation(
                lat: lat,
                lng: lng,
                heading: (s['heading'] as num?)?.toDouble(),
              );
        } catch (_) {}
      }());
    }
    try {
      await db.insertPoint(TrackPointsCompanion.insert(
        lat: lat,
        lng: lng,
        time: DateTime.fromMillisecondsSinceEpoch(
            (s['timeMs'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch),
        layerId: layerId,
        accuracy: Value((s['accuracy'] as num?)?.toDouble()),
        altitude: Value((s['altitude'] as num?)?.toDouble()),
        speed: Value((s['speed'] as num?)?.toDouble()),
      ));

      // Connect ONLY the immediate predecessor sample when both:
      //   * spatial: centre-to-centre ≤ 2.5 × diameter (= 5 × penR)
      //   * temporal: age ≤ 30 s
      // Either fail → treat as a fresh start, paint a standalone pixel,
      // and reset the predecessor pointer so the *next* sample chains
      // off the right thing.
      // Fog reveal = ambient corridor (wide disk), NOT the visible
      // trail. The visible trail is the vector polyline overlay on the
      // map. Disk radius is `fogPenRadius`; a 50 m default clears a
      // ~10-pixel-wide corridor at FOW's 9.55 m/px storage, which
      // hides the per-sample rasterisation entirely.
      final last = _lastSample[layerId];
      final penR = settings.fogPenRadius;
      final maxGap = math.max(penR * 5, 30.0);
      bool chained = false;
      if (last != null) {
        final gap = _haversineMeters(last.lat, last.lng, lat, lng);
        final age = DateTime.now().difference(last.t);
        if (gap > 0.5 &&
            gap <= maxGap &&
            age <= const Duration(seconds: 30)) {
          await fog.revealLine(
            lat0: last.lat,
            lng0: last.lng,
            lat1: lat,
            lng1: lng,
            layerId: layerId,
            radiusMeters: penR,
          );
          chained = true;
        }
      }
      if (!chained) {
        await fog.revealPoint(
          lat: lat,
          lng: lng,
          radiusMeters: penR,
          layerId: layerId,
        );
      }
      _lastSample[layerId] = (lat: lat, lng: lng, t: DateTime.now());
      _scheduleRefresh();
    } catch (e, st) {
      debugPrint('[Recording] write failed at ($lat,$lng) layer=$layerId: $e\n$st');
      // Don't rethrow — we're inside a queue. Throwing here would break
      // the chain and silently kill recording.
    }
  }

  /// Coalesce N writes-in-a-burst into one provider notify. The fog
  /// layer rebuilds aren't free; bumping the notifier every sample at
  /// 1Hz is borderline, and bumping it during the catch-up burst after
  /// a screen unlock used to drop ~40 frames.
  void _scheduleRefresh() {
    if (_refreshPending) return;
    _refreshPending = true;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 250), () {
      _refreshPending = false;
      ref.read(fogRefreshProvider.notifier).state++;
    });
  }

  /// Called by the debug simulation panel to inject a fake GPS sample.
  void handleSimulatedSample(double lat, double lng) {
    _enqueueSample({
      'lat': lat,
      'lng': lng,
      'accuracy': 5.0,
      'altitude': 0.0,
      'speed': 1.5,
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> stop() async {
    await _bgSub?.cancel();
    await _fgSub?.cancel();
    _bgSub = null;
    _fgSub = null;
    _refreshDebounce?.cancel();
    _refreshDebounce = null;
    _refreshPending = false;
    _lastHandledKey = null;
    await BackgroundLocation.stop();
    await ref.read(locationServiceProvider).stop();
    // Critical: forget the last sample, so when recording resumes —
    // tomorrow, next week — the first new sample doesn't paint a long
    // line back to wherever the user stopped.
    _lastSample.clear();
    ref.read(recordingActiveProvider.notifier).state = false;
  }
}

final recordingControllerProvider =
    Provider((ref) => RecordingController(ref));

double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
