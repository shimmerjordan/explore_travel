import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import '../../models/models.dart';

/// Foreground service entry point. The OS keeps this isolate alive while a
/// persistent notification is shown. We stream GPS samples and forward them
/// back to the UI isolate using the foreground_task `sendDataToMain` channel.
@pragma('vm:entry-point')
void backgroundCallback() {
  FlutterForegroundTask.setTaskHandler(_LocationTaskHandler());
}

class _LocationTaskHandler extends TaskHandler {
  StreamSubscription<Position>? _sub;
  RecordingMode _mode = RecordingMode.balanced;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _startStream();
  }

  Future<void> _startStream() async {
    await _sub?.cancel();
    final settings = LocationSettings(
      accuracy: switch (_mode) {
        RecordingMode.highPerformance => LocationAccuracy.best,
        RecordingMode.balanced => LocationAccuracy.high,
        RecordingMode.batterySaver => LocationAccuracy.medium,
      },
      distanceFilter: _mode.distanceFilter.toInt(),
    );
    _sub = Geolocator.getPositionStream(locationSettings: settings)
        .listen((pos) {
      FlutterForegroundTask.sendDataToMain({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'accuracy': pos.accuracy,
        'altitude': pos.altitude,
        'speed': pos.speed,
        'timeMs': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _sub?.cancel();
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map && data['cmd'] == 'setMode') {
      final idx = data['mode'] as int?;
      if (idx != null) {
        _mode = RecordingMode.values[idx];
        _startStream();
      }
    }
  }

  @override
  void onNotificationButtonPressed(String id) {}
  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/map');
  }
  @override
  void onNotificationDismissed() {}
}

/// UI-side helper that manages the foreground service lifecycle.
class BackgroundLocation {
  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'explore_journal_loc',
        channelName: '轨迹记录',
        channelDescription: '在后台记录你的位置以点亮地图迷雾',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  static Future<bool> requestPermissions() async {
    final notif = await FlutterForegroundTask.checkNotificationPermission();
    if (notif != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
    return true;
  }

  static Future<void> start(RecordingMode mode) async {
    init();
    await requestPermissions();
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask(
          {'cmd': 'setMode', 'mode': mode.index});
      return;
    }
    await FlutterForegroundTask.startService(
      notificationTitle: 'Explore Journal 正在记录',
      notificationText: '${mode.label} 模式 · 点击返回应用',
      callback: backgroundCallback,
    );
    // After start, push initial mode.
    FlutterForegroundTask.sendDataToTask(
        {'cmd': 'setMode', 'mode': mode.index});
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Subscribes to GPS samples coming from the background isolate.
  static StreamSubscription<Map<String, dynamic>> listen(
      void Function(Map<String, dynamic>) onSample) {
    final port = ReceivePort();
    FlutterForegroundTask.addTaskDataCallback((Object data) {
      if (data is Map) {
        // Force a fully-modifiable copy. Some Flutter plugin Maps land here
        // as `_ConstMap` or platform-channel-derived unmodifiable views.
        port.sendPort.send(<String, dynamic>{
          for (final entry in data.entries) entry.key.toString(): entry.value,
        });
      }
    });
    return port
        .cast<Map<String, dynamic>>()
        .map((m) => <String, dynamic>{...m})
        .listen(onSample);
  }
}
