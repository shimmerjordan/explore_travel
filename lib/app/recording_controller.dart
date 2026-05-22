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
class RecordingController {
  final Ref ref;
  StreamSubscription<Map<String, dynamic>>? _bgSub;
  StreamSubscription? _fgSub;
  RecordingController(this.ref);

  /// Last sample (lat, lng) we wrote to the fog, per layer id. Used to
  /// connect successive GPS samples with a line of revealed pixels when
  /// they're close enough (<= 2.5 × pen radius). Without this you get a
  /// dotted constellation instead of a continuous trail.
  final Map<int, ({double lat, double lng, DateTime t})> _lastSample = {};

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
    _bgSub = BackgroundLocation.listen(_handleSample);

    _fgSub = loc.stream.listen((pos) => _handleSample({
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

  Future<void> _handleSample(Map<String, dynamic> s) async {
    final db = ref.read(dbProvider);
    final fog = ref.read(fogEngineProvider);
    final layerId = ref.read(effectiveActiveLayerIdProvider);
    final lat = (s['lat'] as num).toDouble();
    final lng = (s['lng'] as num).toDouble();
    // If user has joined a group, broadcast our location so peers can render
    // our colored trail on their map.
    final settings = ref.read(settingsProvider);
    if (settings.groupId != null && settings.groupId!.isNotEmpty) {
      try {
        await ref.read(groupServiceProvider).broadcastLocation(
              lat: lat,
              lng: lng,
              heading: (s['heading'] as num?)?.toDouble(),
            );
      } catch (_) {}
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

      // Connect to previous sample if they're close enough — matches the
      // user's "圆心距离 ≤ 2.5×直径" intent (= 5×radius). 50m pen radius →
      // up to 250m gap fills in as a line. Beyond that, treat it as a
      // teleport (GPS lost lock / app suspended) and just drop a single
      // point.
      final last = _lastSample[layerId];
      final penR = ref.read(settingsProvider).fogPenRadius;
      final maxGap = penR * 5; // 2.5 × diameter = 5 × radius
      if (last != null) {
        final gap = _haversineMeters(last.lat, last.lng, lat, lng);
        final age = DateTime.now().difference(last.t);
        if (gap > 0.5 && gap <= maxGap && age < const Duration(minutes: 2)) {
          await fog.revealLine(
            lat0: last.lat,
            lng0: last.lng,
            lat1: lat,
            lng1: lng,
            layerId: layerId,
          );
        } else {
          await fog.revealSinglePixel(
              lat: lat, lng: lng, layerId: layerId);
        }
      } else {
        await fog.revealSinglePixel(lat: lat, lng: lng, layerId: layerId);
      }
      _lastSample[layerId] = (lat: lat, lng: lng, t: DateTime.now());
      ref.read(fogRefreshProvider.notifier).state++;
    } catch (e, st) {
      debugPrint('[Recording] write failed at ($lat,$lng) layer=$layerId: $e\n$st');
      rethrow;
    }
  }

  /// Called by the debug simulation panel to inject a fake GPS sample.
  void handleSimulatedSample(double lat, double lng) {
    _handleSample({
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
    await BackgroundLocation.stop();
    await ref.read(locationServiceProvider).stop();
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
