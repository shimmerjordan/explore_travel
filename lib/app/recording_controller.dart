import 'dart:async';
import 'dart:math' as math;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/geo_math.dart' show haversineMeters;
import '../data/db/database.dart';
import '../services/location/background_task.dart'
    if (dart.library.js_interop) '../services/location/background_task_stub.dart';
import '../services/location/point_filter.dart';
import '../services/location/sample_buffer.dart';
import '../services/map/live_track_point.dart' show LiveTrackPoint;
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
///   * The map layers update INCREMENTALLY: fog corridor rows flow through
///     [FogEngine.changes] and the coloured trail through [livePoints], so a
///     recording tick no longer bumps `fogRefreshProvider` (which forced a
///     full fog_tiles + track_points re-read every 250 ms — brutal after a
///     ~45k-block FOW import).
class RecordingController with WidgetsBindingObserver {
  final Ref ref;
  StreamSubscription<Map<String, dynamic>>? _bgSub;
  StreamSubscription? _fgSub;
  bool _observing = false;

  /// 正在跑的那次缓冲排空。以前是个 bool 闸门，重入直接 return——但 [stop]
  /// 现在必须**确保**缓冲已经排空才敢清文件，"有人在跑就跳过"会把样本连同
  /// 文件一起删掉。存成 Future 才能等它。
  Future<int>? _ingestJob;
  RecordingController(this.ref);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground: the background service may have
    // captured fixes into the durable buffer while the main isolate was
    // suspended (screen off) — fold them into the DB now.
    if (state == AppLifecycleState.resumed &&
        ref.read(recordingActiveProvider)) {
      _ingestBuffer();
    }
  }

  /// Last sample (lat, lng, time) per layer — used for the line-stitching
  /// gate.
  final Map<int, ({double lat, double lng, DateTime t})> _lastSample = {};

  /// Last sample that passed the noise gate, per layer — the reference for
  /// the implied-speed check. Separate from [_lastSample] (which is about
  /// fog chaining) only in lifetime: this one is reset with it in [stop].
  final Map<int, ({double lat, double lng, int tMs})> _lastClean = {};

  /// Serialises samples. New samples await whatever's already in flight
  /// before their own work begins. If the queue ever exceeds [_maxQueue]
  /// we drop the new sample on the floor (better to skip a point than
  /// pile up a 30-sample backlog that locks the UI for seconds).
  Future<void> _inflight = Future.value();

  /// [stop] 正在跑。见那里的幂等注释。
  bool _stopping = false;

  /// 用户已经要求停止，但当时 [start] / [resumeIfRecording] 的接线还没走完。
  ///
  /// 不能用 `recordingActiveProvider` 当这个判据：它要到接线的最后一步才置位，
  /// 而接线中间有权限申请、服务启动、缓冲排空好几个 await——通知按钮恰好落在
  /// 这个窗口里时，停止请求会被守卫吞掉，接线随后还把状态置成"正在记录"，
  /// 用户就卡在"显示在录、其实服务已停"。
  bool _stopRequested = false;

  /// [start] / [resumeIfRecording] 正在接线。两者都会覆盖 `_bgSub`，没有闸门
  /// 时重入会丢掉前一条订阅（插件里的 task-data 回调从此永不注销）。
  bool _wiring = false;
  int _queued = 0;
  static const _maxQueue = 6;

  /// "lat|lng|timeMs" of the most recently handled sample — used to
  /// drop the duplicate that the *other* stream is about to emit.
  String? _lastHandledKey;

  /// Freshly-inserted points, one event per recorded sample. The map's trail
  /// layer appends these to its loaded sessions — no re-query per tick.
  final _livePoints = StreamController<LiveTrackPoint>.broadcast();
  Stream<LiveTrackPoint> get livePoints => _livePoints.stream;

  /// Returns null on success, or a user-facing error string on failure.
  Future<String?> start() async {
    // Source gate: a read-only (web/回忆) build must never record, even if a
    // record affordance somehow surfaces. Native is viewOnly=false.
    if (ref.read(viewOnlyProvider)) return '展示模式下不可记录轨迹';
    if (_wiring || _stopping) return null; // 接线/收尾进行中，别叠第二次
    _wiring = true;
    _stopRequested = false;
    try {
      final settings = ref.read(settingsProvider);
      final loc = ref.read(locationServiceProvider);
      if (!await loc.ensurePermission()) {
        return loc.lastError ?? '无法启动定位';
      }

      // Background service only available on native platforms; safe to call on web (stub no-ops).
      await BackgroundLocation.start(settings.recordingMode);
      await _bgSub?.cancel(); // 覆盖前先注销，否则插件里的回调永不解绑
      _bgSub = BackgroundLocation.listen(_enqueueSample,
          onCommand: handleBackgroundCommand);
      _startObserving();
      // Fold in anything the background service buffered while we were away
      // (e.g. a previous session the OS suspended, or a boot-resumed run).
      await _ingestBuffer();

      // 功耗：前台服务已在以录制精度持续推流（应用打开时 sendDataToMain 一样
      // 到达主 isolate），这里再开一条前台 geolocator 流等于同时挂两个 GPS
      // 请求、样本全部被 `_lastHandledKey` 去重丢弃。只在没有前台服务的平台
      // （web / 桌面）用前台流兜底。
      if (!await BackgroundLocation.isServiceRunning()) {
        final ok = await loc.start(settings.recordingMode);
        if (!ok) return loc.lastError ?? '无法启动定位';
        _fgSub = loc.stream.listen((pos) => _enqueueSample({
              'lat': pos.latitude,
              'lng': pos.longitude,
              'accuracy': pos.accuracy,
              'altitude': pos.altitude,
              'speed': pos.speed,
              // Use the GPS fix's own capture time, not now(). Same reason
              // as background_task.dart — when the OS buffers samples and
              // delivers them in a burst, stamping with now() collapses
              // their times together and the 30 s split gate stops
              // firing, so far-apart-in-time points end up connected by a
              // long false line on the map.
              'timeMs': pos.timestamp.millisecondsSinceEpoch,
            }));
      }

      // 接线期间用户可能已经在通知上按了停止（见 [_stopRequested]）：那就别把
      // 状态置成"正在记录"，直接走收尾。
      if (_stopRequested) {
        _stopRequested = false;
        _wiring = false;
        await stop();
        return null;
      }
      ref.read(recordingActiveProvider.notifier).state = true;
      return null;
    } finally {
      _wiring = false;
    }
  }

  /// Called once at app startup. If the user was recording when the app was
  /// last killed (or the service was auto-restarted after a reboot), the
  /// foreground service is already streaming + buffering — re-attach the UI
  /// pipeline and drain whatever it captured while we were gone, so the
  /// trail picks up seamlessly without the user having to tap record again.
  Future<void> resumeIfRecording() async {
    if (ref.read(viewOnlyProvider)) return; // read-only build never records
    if (ref.read(recordingActiveProvider)) return; // already wired up
    if (_wiring || _stopping) return;
    if (!await BackgroundLocation.wasRecording()) {
      // 上一段录制可能是在应用不在场时结束的——通知按钮那条路只清了标志位、
      // 停了服务，主 isolate 的收尾（排空缓冲、到访检测）没人做过，命令本身
      // 也随着不存在的端口被静默丢弃。这里补一次；缓冲空时是零成本。
      final ingested = await _ingestBuffer();
      if (ingested > 0) {
        unawaited(ref.read(visitEngineProvider).detectRecent());
      }
      return;
    }
    _wiring = true;
    _stopRequested = false;
    try {
      final loc = ref.read(locationServiceProvider);
      final settings = ref.read(settingsProvider);
      // Make sure the service is actually up (it is after a boot-resume; this
      // also revives it if the OS killed it while the flag stayed set).
      // 再读一次标志位：上一次读到现在之间，用户可能已经在通知上按了停止
      // （那条路会清标志位并停服）。不复查就会把它重新拉起来。
      if (!await BackgroundLocation.wasRecording()) return;
      await BackgroundLocation.start(settings.recordingMode);
      await _bgSub?.cancel(); // 覆盖前先注销，否则插件里的回调永不解绑
      _bgSub = BackgroundLocation.listen(_enqueueSample,
          onCommand: handleBackgroundCommand);
      _startObserving();
      await _ingestBuffer();
      // Foreground-stream fallback only where the service isn't available —
      // same double-GPS-request reasoning as [start].
      if (!await BackgroundLocation.isServiceRunning() &&
          await loc.start(settings.recordingMode)) {
        _fgSub = loc.stream.listen((pos) => _enqueueSample({
              'lat': pos.latitude,
              'lng': pos.longitude,
              'accuracy': pos.accuracy,
              'altitude': pos.altitude,
              'speed': pos.speed,
              'timeMs': pos.timestamp.millisecondsSinceEpoch,
            }));
      }
      if (_stopRequested || !await BackgroundLocation.wasRecording()) {
        _stopRequested = false;
        _wiring = false;
        await stop();
        return;
      }
      ref.read(recordingActiveProvider.notifier).state = true;
    } finally {
      _wiring = false;
    }
  }

  void _startObserving() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void _stopObserving() {
    if (!_observing) return;
    _observing = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Drain the durable background buffer into the DB. Only samples newer
  /// than what's already stored for the active layer are inserted, so fixes
  /// the main isolate already wrote live (via [_enqueueSample]) aren't
  /// duplicated. Runs the same insert + fog-reveal path as live samples so
  /// stitching and stats stay consistent.
  /// 若已有一次排空在跑，等它跑完而不是跳过——见 [_ingestJob]。
  /// 返回真正写进库的样本数（调用方据此决定要不要再跑到访检测）。
  Future<int> _ingestBuffer() {
    final running = _ingestJob;
    if (running != null) return running;
    final job = _runIngest();
    _ingestJob = job;
    return job.whenComplete(() {
      if (_ingestJob == job) _ingestJob = null;
    });
  }

  Future<int> _runIngest() async {
    // 缓冲文件损坏不该拖垮恢复或停止，所以这里照旧吞掉异常——但**不能**吞掉
    // "还没排空"这个事实，那是 [stop] 敢清文件的前提，由 [_ingestJob] 保证。
    try {
      final samples = await SampleBuffer.drain();
      if (samples.isEmpty) return 0;
      samples.sort((a, b) =>
          ((a['timeMs'] as num?) ?? 0).compareTo((b['timeMs'] as num?) ?? 0));
      final layerId = ref.read(effectiveActiveLayerIdProvider);
      final lastT = await ref.read(dbProvider).lastPointTime(layerId);
      final cutoff = lastT?.millisecondsSinceEpoch ?? 0;
      var ingested = 0;
      for (final s in samples) {
        final t = (s['timeMs'] as num?)?.toInt() ?? 0;
        if (t <= cutoff) continue; // already written live — skip the dup
        await _handleSample(s, broadcast: false);
        ingested++;
      }
      if (ingested > 0) {
        if (kDebugMode) {
          debugPrint('[Recording] ingested $ingested buffered bg samples');
        }
        // One full refresh after a catch-up batch — reconciles the layers in
        // a single reload instead of relying on a long burst of deltas.
        ref.read(fogRefreshProvider.notifier).state++;
      }
      return ingested;
    } catch (e) {
      if (kDebugMode) debugPrint('[Recording] buffer ingest failed: $e');
      return 0;
    }
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

  Future<void> _handleSample(Map<String, dynamic> s,
      {bool broadcast = true}) async {
    final db = ref.read(dbProvider);
    final fog = ref.read(fogEngineProvider);
    final layerId = ref.read(effectiveActiveLayerIdProvider);
    final lat = (s['lat'] as num).toDouble();
    final lng = (s['lng'] as num).toDouble();
    final settings = ref.read(settingsProvider);
    // Noise gate. `drop` never reaches the DB (Null Island, ≥500 m accuracy);
    // `anomaly` is stored but flagged so the analytic readers skip it and the
    // fog corridor isn't painted from a teleport. The "previous" reference is
    // the last CLEAN sample on this layer, so one bad fix doesn't make the
    // next good one look like a teleport back.
    final sampleMs =
        (s['timeMs'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final prevClean = _lastClean[layerId];
    final verdict = PointFilter.judge(
      PointSample(lat, lng, sampleMs,
          accuracy: (s['accuracy'] as num?)?.toDouble()),
      prev: prevClean == null
          ? null
          : PointSample(prevClean.lat, prevClean.lng, prevClean.tMs),
    );
    if (verdict == PointVerdict.drop) return;
    final anomaly = verdict == PointVerdict.anomaly;
    if (!anomaly) _lastClean[layerId] = (lat: lat, lng: lng, tMs: sampleMs);
    // Width for NEW points = the active layer's own path width, falling back
    // to the global default when the layer hasn't customised it.
    final activeLayer = ref
        .read(layersProvider)
        .valueOrNull
        ?.where((l) => l.id == layerId)
        .firstOrNull;
    final newPointWidth = activeLayer?.pathWidth ?? settings.trailWidth;
    // Fire-and-forget the broadcast — it can hit a slow socket and we
    // don't want the fog write to wait for it. The previous code
    // `await`ed it, which is why a flaky LAN peer could stall the
    // record path entirely. Skipped when replaying buffered samples
    // (broadcast=false) — those are historical, not live positions.
    if (broadcast && settings.groupId != null && settings.groupId!.isNotEmpty) {
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
        // Freeze the trail size onto this point so later changes to the
        // layer's size only affect points recorded after them.
        width: Value(newPointWidth),
        flags: Value(anomaly ? PointFlags.anomaly : 0),
      ));
      // A teleport must not reveal fog (a 100 km corridor from one bad fix)
      // nor feed the live trail; it's in the DB for the record, nothing else.
      if (anomaly) return;

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
      // Use the SAMPLE's recorded time, not now() — `_inflight` drains
      // the queue in a tight loop after a foreground resume, so several
      // samples may be processed within milliseconds of each other
      // even though their GPS fixes are minutes apart. Comparing
      // `pos.timestamp` deltas is the only way the 30 s gate stays
      // honest.
      final sampleAt = DateTime.fromMillisecondsSinceEpoch(
          (s['timeMs'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch);
      final last = _lastSample[layerId];
      final penR = settings.fogPenRadius;
      final maxGap = math.max(penR * 5, 30.0);
      bool chained = false;
      if (last != null) {
        final gap = haversineMeters(last.lat, last.lng, lat, lng);
        final age = sampleAt.difference(last.t);
        if (gap > 0.5 &&
            gap <= maxGap &&
            age <= const Duration(seconds: 30) &&
            !age.isNegative) {
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
      _lastSample[layerId] = (lat: lat, lng: lng, t: sampleAt);
      // Feed the trail layer's append path. Fog corridor updates travel on
      // FogEngine.changes from inside revealLine/revealPoint themselves.
      if (_livePoints.hasListener) {
        _livePoints.add((
          lat: lat,
          lng: lng,
          time: sampleAt,
          layerId: layerId,
          width: newPointWidth,
          accuracy: (s['accuracy'] as num?)?.toDouble(),
        ));
      }
    } catch (e, st) {
      debugPrint(
          '[Recording] write failed at ($lat,$lng) layer=$layerId: $e\n$st');
      // Don't rethrow — we're inside a queue. Throwing here would break
      // the chain and silently kill recording.
    }
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

  /// 后台 isolate 发来的控制命令。目前只有一条：用户在通知上按了「停止记录」。
  /// 后台那边已经清了标志位并停了服务，这里要做的是主 isolate 的收尾——与手动
  /// 停止走**同一个** [stop]，所以清 `_lastSample`、翻 provider、触发到访检测
  /// 这些都不会漏。
  @visibleForTesting
  void handleBackgroundCommand(String cmd) {
    if (cmd != kStoppedFromNotification) return;
    // 无论此刻在哪个阶段，先把"用户要停"这个意图记下来——接线还没走完时
    // 直接 return 会把请求丢掉（见 [_stopRequested]）。
    _stopRequested = true;
    if (_wiring) return; // 接线的收尾处会看到这个意图并转去 stop()
    if (!ref.read(recordingActiveProvider)) return; // 本来就没在录
    _stopRequested = false;
    unawaited(stop());
  }

  Future<void> stop() async {
    // 幂等：通知按钮与界面按钮可能几乎同时到达，而 detectRecent 会真的去算。
    if (_stopping) return;
    _stopping = true;
    try {
      _stopObserving();
      await _bgSub?.cancel();
      await _fgSub?.cancel();
      _bgSub = null;
      _fgSub = null;
      _lastHandledKey = null;
      await BackgroundLocation.stop();
      // **先排空再清文件**。以前唯一的停止入口是界面按钮，用户按到它必然先把
      // 应用切回前台，`didChangeAppLifecycleState(resumed)` 已经排空过一轮；
      // 通知按钮把这个隐含前置条件拿掉了，直接 clear 会把只存在于缓冲里的
      // 样本（队列闸门丢弃的、写库失败的）连文件一起删掉，永久丢失。
      await _ingestBuffer();
      await SampleBuffer.clear();
      await ref.read(locationServiceProvider).stop();
      // Critical: forget the last sample, so when recording resumes —
      // tomorrow, next week — the first new sample doesn't paint a long
      // line back to wherever the user stopped.
      _lastSample.clear();
      _lastClean.clear();
    } finally {
      // 无论中间哪一步抛（停服、清缓冲、关定位都会走平台通道），录制状态都必须
      // 翻掉、闸门都必须放开——否则用户会卡在「界面显示正在录制、再按也没反应」，
      // 因为 _stopping 永久是 true。
      ref.read(recordingActiveProvider.notifier).state = false;
      _stopping = false;
    }
    // The session just recorded may hold new stays — re-detect the last few
    // hours (fire-and-forget; the timeline refreshes via visitsRefresh).
    unawaited(ref.read(visitEngineProvider).detectRecent());
  }
}

final recordingControllerProvider = Provider((ref) => RecordingController(ref));
