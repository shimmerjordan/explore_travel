import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import '../../models/models.dart';
import 'sample_buffer.dart';

/// Cross-isolate, persisted flag: were we recording when the process last
/// went away? Set true on start / false on stop. An OS-restarted service
/// (boot, app update, low-memory kill) reads it in [onStart] to decide
/// whether to resume or shut itself back down.
const String _kRecordingFlagKey = 'recording_active';

/// Foreground service entry point. The OS keeps this isolate alive while a
/// persistent notification is shown. We stream GPS samples and forward them
/// back to the UI isolate using the foreground_task `sendDataToMain` channel.
@pragma('vm:entry-point')
void backgroundCallback() {
  FlutterForegroundTask.setTaskHandler(_LocationTaskHandler());
}

/// 通知上「停止记录」按钮的 id。按下时后台 isolate 先给主 isolate 发一条
/// [kStoppedFromNotification] 命令再停服，好让 UI 走与手动停止完全相同的收尾。
const String kStopRecordingButtonId = 'stop_recording';

/// 后台 → 主 isolate 的控制命令（与位置样本走同一条 sendDataToMain 通道，
/// 靠 `cmd` 键区分：样本没有 `cmd`，命令没有 lat/lng）。
const String kStoppedFromNotification = 'stopped_from_notification';

class _LocationTaskHandler extends TaskHandler {
  StreamSubscription<Position>? _sub;
  RecordingMode _mode = RecordingMode.balanced;

  /// When we last forwarded a fix. The repeat-event watchdog uses this to
  /// notice a stalled stream (common after a Doze cycle or an OEM "freeze")
  /// and recover with an active fetch + resubscribe.
  DateTime _lastFixAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Guards against overlapping active polls (a slow fix + the next
  /// repeat tick) and against resubscribing while one is already pending.
  bool _polling = false;

  /// Consecutive active-poll failures (both fused fix AND last-known came
  /// back empty). At 3+ we assume the fused provider itself is wedged on
  /// this ROM (classic MIUI deep-doze symptom: 高德 has fixes, we don't —
  /// their SDK talks to its own network locator, we sit on a dead fused
  /// stream) and flip the stream over to the raw LocationManager.
  int _stallPolls = 0;
  bool _forceLm = false;

  /// Rate-limits stall-triggered resubscribes so a long GPS outage doesn't
  /// churn cancel/subscribe every 9 s heartbeat.
  DateTime _lastResub = DateTime.fromMillisecondsSinceEpoch(0);

  /// Last time we refreshed the notification line (最后定位 HH:mm).
  DateTime _lastNotifUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  /// Stationary detection. `distanceFilter` silences the passive stream
  /// when the user stops moving, which the stall watchdog then read as a
  /// dead stream and answered with an active fix every 10–60 s — standing
  /// still cost MORE battery than walking. Track the last fix that actually
  /// moved; after [_kStationaryAfter] without movement the watchdog backs
  /// off to [_kStationaryPoll].
  Position? _lastMovedPos;
  DateTime _lastMovedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const double _kMoveMeters = 25;
  static const Duration _kStationaryAfter = Duration(minutes: 3);
  static const Duration _kStationaryPoll = Duration(minutes: 2);

  bool get _stationary =>
      _lastMovedAt.millisecondsSinceEpoch != 0 &&
      DateTime.now().difference(_lastMovedAt) >= _kStationaryAfter;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // If the OS auto-restarted us (boot / app-update / low-memory) but the
    // user wasn't actually recording when the process died, shut back down
    // instead of silently draining battery and showing a notification.
    final wasRecording =
        await FlutterForegroundTask.getData<bool>(key: _kRecordingFlagKey) ??
            false;
    if (starter != TaskStarter.developer && !wasRecording) {
      await FlutterForegroundTask.stopService();
      return;
    }
    // Recover the mode the UI last pushed, so a service auto-restarted by
    // the OS keeps the user's chosen accuracy.
    final saved = await FlutterForegroundTask.getData<int>(key: 'rec_mode');
    if (saved != null && saved >= 0 && saved < RecordingMode.values.length) {
      _mode = RecordingMode.values[saved];
    }
    await _startStream();
  }

  LocationSettings _settings() {
    final accuracy = switch (_mode) {
      RecordingMode.highPerformance => LocationAccuracy.best,
      RecordingMode.balanced => LocationAccuracy.high,
      RecordingMode.batterySaver => LocationAccuracy.medium,
    };
    final distanceFilter = _mode.distanceFilter.toInt();
    // On Android, an explicit interval tells the fused provider the cadence
    // we want even while dozing under a foreground service. We deliberately
    // do NOT set `foregroundNotificationConfig` — flutter_foreground_task
    // already owns the persistent notification + service; a second one
    // would conflict.
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        intervalDuration: _mode.interval,
        // Escalation: after repeated total stalls we bypass the fused
        // provider and read GPS via the platform LocationManager directly.
        // Slightly more battery, but immune to the fused-provider freezes
        // that some ROMs develop in deep doze. Sticky until service restart.
        forceLocationManager: _forceLm,
      );
    }
    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }

  /// CRITICAL: use the GPS fix's own timestamp, NOT `DateTime.now()`. When
  /// Android suspends the app or buffers samples during a Doze cycle,
  /// several positions can arrive in a rapid burst minutes after capture.
  /// Stamping with `now()` collapses their times together and defeats both
  /// the line-stitching gate in RecordingController and the session-split
  /// logic in FogLayer — that's how far-apart points got joined by a long
  /// false line.
  void _emit(Position pos) {
    _lastFixAt = DateTime.now();
    _stallPolls = 0;
    final prev = _lastMovedPos;
    if (prev == null ||
        Geolocator.distanceBetween(prev.latitude, prev.longitude,
                pos.latitude, pos.longitude) >=
            _kMoveMeters) {
      _lastMovedPos = pos;
      _lastMovedAt = _lastFixAt;
    }
    final sample = <String, dynamic>{
      'lat': pos.latitude,
      'lng': pos.longitude,
      'accuracy': pos.accuracy,
      'altitude': pos.altitude,
      'speed': pos.speed,
      'timeMs': pos.timestamp.millisecondsSinceEpoch,
    };
    // Live update for the UI when the app is open…
    FlutterForegroundTask.sendDataToMain(sample);
    // …and a durable copy so a fix taken while the main isolate is
    // suspended (screen off) or absent (boot-resumed service) survives to
    // be ingested into the DB next time the app runs.
    SampleBuffer.append(sample);
  }

  Future<void> _startStream() async {
    await _sub?.cancel();
    _sub = Geolocator.getPositionStream(locationSettings: _settings()).listen(
      _emit,
      // A stream error (provider hiccup, transient GMS failure) used to
      // kill recording permanently because nothing resubscribed. Now we
      // tear down and let the next repeat-event watchdog bring it back.
      onError: (Object e) {
        _sub?.cancel();
        _sub = null;
      },
      // Some OEM ROMs end the stream outright when the screen sleeps;
      // treat completion the same as an error so the watchdog revives it.
      onDone: () {
        _sub = null;
      },
      cancelOnError: true,
    );
  }

  /// Fires on the foreground service's repeat timer (see [ForegroundTaskOptions]).
  /// This is the keep-alive heartbeat: it runs under the service's wakelock
  /// even while the device dozes, so it's our reliable chance to (a) revive
  /// a dead/cancelled stream and (b) actively pull a fresh fix when the
  /// passive stream has gone quiet for too long.
  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_sub == null) _startStream();
    // Stall threshold: a couple of expected intervals, with a floor so we
    // don't hammer GPS in high-performance mode. If the stream is healthy
    // and the user is moving, this never fires (the stream keeps _lastFixAt
    // fresh); it only kicks in when updates have actually stopped.
    final now = DateTime.now();
    final stationary = _stationary;
    final stallFor = stationary
        ? _kStationaryPoll
        : Duration(
            milliseconds:
                math.max(_mode.interval.inMilliseconds * 2, 10000));
    if (now.difference(_lastFixAt) >= stallFor) {
      _activePoll();
      // 流"假活"（订阅在、回调停）也要治：stall 期间每 30s 重订一次。
      // 静止时流本来就该沉默，不算假活，不重订。
      if (!stationary &&
          now.difference(_lastResub) >= const Duration(seconds: 30)) {
        _lastResub = now;
        _startStream();
      }
    }
    // 通知行显示最后定位时间 —— 锁屏丢定位从"玄学"变成一眼可诊断：
    // 下拉通知就知道后台最后一次定位是什么时候。每分钟刷一次。
    if (now.difference(_lastNotifUpdate) >= const Duration(minutes: 1)) {
      _lastNotifUpdate = now;
      final fix = _lastFixAt.millisecondsSinceEpoch == 0
          ? '等待定位…'
          : '最后定位 ${_lastFixAt.hour.toString().padLeft(2, '0')}:'
              '${_lastFixAt.minute.toString().padLeft(2, '0')}';
      FlutterForegroundTask.updateService(
        notificationTitle: 'Explore Journal 正在记录',
        notificationText:
            '${_mode.label} 模式 · $fix${_forceLm ? ' · GPS 直连' : ''}'
            '${stationary ? ' · 静止省电' : ''}',
      );
    }
  }

  /// 通知上的按钮。**跑在后台 isolate 里**——这里拿不到 Riverpod 容器，
  /// 所以不能直接调 `RecordingController.stop()`。做法是：先把标志位清掉
  /// （万一进程随后就被杀，下次冷启动的 `wasRecording()` 才不会误恢复），
  /// 再给主 isolate 发一条命令让它走正常收尾，最后停服。
  ///
  /// 发命令必须在 `stopService()` 之前：停服会拆掉这条通道。
  @override
  void onNotificationButtonPressed(String id) {
    if (id != kStopRecordingButtonId) return;
    _stopFromNotification();
  }

  Future<void> _stopFromNotification() async {
    await FlutterForegroundTask.saveData(
        key: _kRecordingFlagKey, value: false);
    FlutterForegroundTask.sendDataToMain({'cmd': kStoppedFromNotification});
    await _sub?.cancel();
    _sub = null;
    await FlutterForegroundTask.stopService();
  }

  Future<void> _activePoll() async {
    if (_polling) return;
    _polling = true;
    try {
      // Use balanced-power accuracy for the recovery poll, NOT the (often
      // GPS-only) recording accuracy. When the stream has stalled — which
      // indoors usually means no GPS sky view — a Wi-Fi / cell / fused fix
      // is what actually comes back, and quickly. The live stream still
      // uses the higher recording accuracy for quality while moving.
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 15));
      _emit(pos);
    } catch (_) {
      // Still nothing — fall back to the OS's last-known fix so the trail
      // keeps a heartbeat. It carries its own (older) timestamp, so the
      // session-split logic won't draw a false line, and an unchanged fix
      // dedups away in RecordingController.
      var gotAny = false;
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          _emit(last);
          gotAny = true;
        }
      } catch (_) {}
      if (!gotAny) {
        _stallPolls++;
        // Fused provider 连 last-known 都掏不出来，连续三次 → 切
        // LocationManager 直连重订（见 _settings 注释）。
        if (_stallPolls >= 3 &&
            !_forceLm &&
            defaultTargetPlatform == TargetPlatform.android) {
          _forceLm = true;
          await _startStream();
        }
      }
    } finally {
      _polling = false;
    }
  }

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
        // Persist so an OS-restarted service recovers the right mode.
        FlutterForegroundTask.saveData(key: 'rec_mode', value: idx);
        _startStream();
      }
    }
  }

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

  /// flutter_foreground_task ships plugin implementations for Android and iOS
  /// ONLY. On desktop (this repo also targets Linux) every one of its calls
  /// hits a MethodChannel with no registered handler and throws
  /// MissingPluginException — which used to escape [start] and kill recording
  /// outright. Gate the whole surface so desktop degrades cleanly to the
  /// foreground geolocator stream instead. (Web never gets here: it compiles
  /// against background_task_stub.dart.)
  static bool get supported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static void init() {
    if (_initialized || !supported) return;
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
        // Heartbeat for the keep-alive watchdog in onRepeatEvent. 9 s is
        // frequent enough to revive a stalled stream / pull a fresh fix
        // soon after a Doze cycle, without waking GPS too often itself.
        eventAction: ForegroundTaskEventAction.repeat(9000),
        // Restart the service after a reboot. onStart re-checks the
        // persisted recording flag and stops itself if we weren't actually
        // recording, so this never starts an unwanted background drain.
        autoRunOnBoot: true,
        // If the OS replaces the process on an app update, bring the
        // recording service back automatically.
        autoRunOnMyPackageReplaced: true,
        // Hold a partial wakelock so onRepeatEvent + the GPS callbacks keep
        // firing while the screen is off — without this the foreground
        // service stays alive but its CPU work is deferred during Doze.
        allowWakeLock: true,
        // No Wi-Fi lock: GPS recording needs no network, and holding the
        // radio out of its power-save state all night was pure drain.
        allowWifiLock: false,
      ),
    );
  }

  static Future<bool> requestPermissions() async {
    if (!supported) return false;
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
    if (!supported) return;
    init();
    await requestPermissions();
    // Persist BEFORE startService so the service's onStart sees a true flag
    // (and so a later OS restart knows to resume).
    await FlutterForegroundTask.saveData(
        key: _kRecordingFlagKey, value: true);
    await FlutterForegroundTask.saveData(key: 'rec_mode', value: mode.index);
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask(
          {'cmd': 'setMode', 'mode': mode.index});
      // 服务已在跑（开机自恢复、应用被替换后自恢复，或本次是改录制模式）——
      // 那次是 OS 拉起的，走的不是下面的 startService，通知上没有按钮。
      // update 路径对按钮是条件写入，所以这里正是把它补齐的钩子；不补的话
      // 那整段会话都只能开应用才停得下来。
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Explore Journal 正在记录',
        notificationText: '${mode.label} 模式 · 点击返回应用',
        notificationButtons: _notificationButtons,
      );
      return;
    }
    await FlutterForegroundTask.startService(
      notificationTitle: 'Explore Journal 正在记录',
      notificationText: '${mode.label} 模式 · 点击返回应用',
      notificationButtons: _notificationButtons,
      callback: backgroundCallback,
    );
    // After start, push initial mode.
    FlutterForegroundTask.sendDataToTask(
        {'cmd': 'setMode', 'mode': mode.index});
  }

  /// 通知上的操作按钮。不加它，停止记录就必须先打开应用。
  ///
  /// 注：每分钟刷新文案的那处 `updateService` **不必**重传——Android 侧的
  /// 更新路径对按钮字段是条件写入（省略即保留原按钮）。但**服务已在跑**的
  /// 那条早退路径必须显式补一次，见 [start]。
  static const List<NotificationButton> _notificationButtons = [
    NotificationButton(id: kStopRecordingButtonId, text: '停止记录'),
  ];

  static Future<void> stop() async {
    if (!supported) return;
    // Clear the flag first so an OS restart racing with our stop won't
    // resume a recording the user just ended.
    await FlutterForegroundTask.saveData(
        key: _kRecordingFlagKey, value: false);
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Whether the user was recording when the process last went away — used
  /// on cold launch to decide whether to auto-resume.
  static Future<bool> wasRecording() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    return await FlutterForegroundTask.getData<bool>(
            key: _kRecordingFlagKey) ??
        false;
  }

  /// Whether the foreground service is currently alive.
  static Future<bool> isServiceRunning() async =>
      supported && await FlutterForegroundTask.isRunningService;

  /// Subscribes to GPS samples coming from the background isolate. The
  /// task-data callback is REMOVED again when the returned subscription is
  /// cancelled — it used to be registered and never unregistered, so every
  /// record start/stop cycle leaked one callback. (The old ReceivePort
  /// round-trip is also gone: the callback already fires on the main
  /// isolate, so a controller forwards directly.)
  /// [onCommand] 收后台发来的控制命令（`{'cmd': ...}`）。位置样本与命令共用
  /// 同一条通道，但 `_enqueueSample` 会静默丢掉没有 lat/lng 的 Map，所以命令
  /// 必须在这里就分流出去，不能混在样本回调里。
  static StreamSubscription<Map<String, dynamic>> listen(
      void Function(Map<String, dynamic>) onSample,
      {void Function(String cmd)? onCommand}) {
    late final StreamController<Map<String, dynamic>> ctrl;
    void forward(Object data) {
      if (data is Map) {
        // Force a fully-modifiable copy. Some Flutter plugin Maps land here
        // as `_ConstMap` or platform-channel-derived unmodifiable views.
        ctrl.add(<String, dynamic>{
          for (final entry in data.entries) entry.key.toString(): entry.value,
        });
      }
    }

    ctrl = StreamController<Map<String, dynamic>>(
      onListen: () => FlutterForegroundTask.addTaskDataCallback(forward),
      onCancel: () => FlutterForegroundTask.removeTaskDataCallback(forward),
    );
    return ctrl.stream.listen((m) {
      final cmd = m['cmd'];
      if (cmd is String) {
        onCommand?.call(cmd);
        return;
      }
      onSample(m);
    });
  }
}
