import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../../models/models.dart';

class LocationService {
  StreamSubscription<Position>? _sub;
  final _controller = StreamController<Position>.broadcast();
  Stream<Position> get stream => _controller.stream;
  RecordingMode _mode = RecordingMode.balanced;
  bool _running = false;
  bool get running => _running;
  String? lastError;

  /// Requests permission and verifies location services are enabled.
  /// Returns true on success. Sets [lastError] with a human-readable message
  /// when it fails so the UI can surface it.
  Future<bool> ensurePermission() async {
    lastError = null;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        lastError = '定位权限被拒绝';
        return false;
      }
      if (permission == LocationPermission.deniedForever) {
        lastError = '定位权限被永久拒绝，请到系统设置开启';
        return false;
      }
      if (!kIsWeb) {
        // Web browsers don't expose this and may throw — only check on native.
        final enabled = await Geolocator.isLocationServiceEnabled();
        if (!enabled) {
          lastError = '系统定位服务未开启';
          return false;
        }
      }
      return true;
    } catch (e) {
      lastError = '定位不可用：$e';
      return false;
    }
  }

  /// Best-effort one-shot fix. Strategy:
  ///   1. Return the OS's last-known fix immediately if we have one
  ///      AND it's recent enough that it's still useful (≤ 5 min)
  ///   2. Race a high-accuracy GPS fix against a 6 s timeout
  ///   3. Fall back to a low-accuracy (network/Wi-Fi/cell) fix —
  ///      indoors with no sky view, low-accuracy is often the only
  ///      thing that succeeds. Better a 200 m fix than nothing
  ///
  /// Used by:
  ///   • the map's initial centring (returns ASAP so UI feels snappy)
  ///   • the journal "create at my current position" flow
  ///   • the AI planner's locality keyword extraction
  Future<Position?> currentOnce() async {
    if (!await ensurePermission()) return null;
    // 1. Last-known. `getLastKnownPosition` returns whatever the OS
    //    cached during a previous fix, instantly — no GPS warm-up.
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        final age = DateTime.now().difference(last.timestamp);
        if (age < const Duration(minutes: 5)) return last;
      }
    } catch (_) {}
    // 2. Fast fix FIRST, at balanced-power accuracy. This maps to Android's
    //    PRIORITY_BALANCED_POWER (Wi-Fi / cell / fused), which is exactly
    //    what returns in ~1-2 s indoors — the same path 高德 uses. The old
    //    code led with high-accuracy GPS and sat on a 6 s timeout indoors
    //    before ever trying the network, which is why a fix felt slow even
    //    with a perfectly good Wi-Fi position available.
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 5),
        ),
      );
    } on TimeoutException catch (_) {
      // Fall through.
    } catch (e) {
      lastError = '获取位置失败：$e';
    }
    // 3. Last resort: low accuracy (cell), longer timeout — better a coarse
    //    fix than none.
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } catch (e) {
      lastError = '获取位置失败：$e';
      return null;
    }
  }

  Future<bool> start(RecordingMode mode) async {
    if (_running) await stop();
    if (!await ensurePermission()) return false;
    _mode = mode;
    final settings = LocationSettings(
      accuracy: switch (mode) {
        RecordingMode.highPerformance => LocationAccuracy.best,
        RecordingMode.balanced => LocationAccuracy.high,
        RecordingMode.batterySaver => LocationAccuracy.medium,
      },
      distanceFilter: mode.distanceFilter.toInt(),
    );
    try {
      _subscribe(settings);
      _running = true;
      return true;
    } catch (e) {
      lastError = '无法启动位置流：$e';
      return false;
    }
  }

  void _subscribe(LocationSettings settings) {
    _sub?.cancel();
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _controller.add,
      // 断流自愈：provider 抖一下不该杀掉整个流（3s 后重订，仍在运行时）。
      onError: (e) {
        lastError = '位置流错误：$e';
        _sub = null;
        Future.delayed(const Duration(seconds: 3), () {
          if (_running && _sub == null) _subscribe(settings);
        });
      },
      onDone: () {
        _sub = null;
        Future.delayed(const Duration(seconds: 3), () {
          if (_running && _sub == null) _subscribe(settings);
        });
      },
      cancelOnError: true,
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _running = false;
  }

  RecordingMode get mode => _mode;
}
