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

  Future<Position?> currentOnce() async {
    if (!await ensurePermission()) return null;
    try {
      return await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high));
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
      _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
        _controller.add,
        onError: (e) {
          lastError = '位置流错误：$e';
        },
      );
      _running = true;
      return true;
    } catch (e) {
      lastError = '无法启动位置流：$e';
      return false;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _running = false;
  }

  RecordingMode get mode => _mode;
}
