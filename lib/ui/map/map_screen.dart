import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app/providers.dart';
import '../../core/geo_math.dart' show haversineMeters;
import '../../core/prefs.dart' show AppSettings, PeerOverrideX;
import '../../app/recording_controller.dart';
import '../../data/db/database.dart' as db_t show JournalEntry, TrackLayer;
import '../../models/models.dart';
import '../../services/geo/coord_converter.dart';
import '../../services/fog/fog_engine.dart';
import '../../services/group/group_service.dart';
import '../../services/group/group_sync_controller.dart';
import 'native_file_image_io.dart';
import '../../services/heat/heat3d_camera.dart';
import '../../services/heat/heat_source.dart';
import '../../services/heat/heat_tile_provider.dart';
import '../../services/map/fog_tile_provider.dart';
import '../../services/map/tile_providers.dart';
import '../common/failure.dart';
import '../common/format.dart' show fmtRelativeTime;
import '../common/pixel.dart';
import '../journal/quill_editor_screen.dart' show quillToPreview;
import '../heat/heat_style_sheet.dart';
import '../heat/heat_tilt_screen.dart';
import '../companion/companion_card.dart';
import '../journal/journal_screen.dart' as journal_ui;
import '../import/track_import_flow.dart';
import '../widgets/top_toast.dart';
import '../common/map_chrome.dart';

part 'map_sim_panel.dart';
part 'map_markers.dart';
part 'map_controls.dart';
part 'map_journal_pins.dart';
part 'map_nav_bar.dart';
part 'map_peers.dart';

/// 地图页订阅的路由观察者，由 main.dart 挂到 GoRouter.observers 上。定义在
/// 这里而不是入口文件，是为了让 map_screen 不必反向 import main.dart。
///
/// 泛型用 PageRoute 而不是 ModalRoute：只有整页路由（设置 / 备份 / 歌单 /
/// 手账详情……）才算「盖住了地图」。底部弹层和对话框虽然也是 ModalRoute，
/// 但地图还露在下面，为它们反复停 / 起 GPS 流只会多几次 provider 请求。
final mapRouteObserver = RouteObserver<PageRoute<void>>();

/// NOTE on 3D tilt: flutter_map is a 2D raster-tile widget — it has
/// no concept of pitch / tilt / 3D buildings, and the entire camera
/// system is a top-down LatLng + zoom + rotation. Adding "pinch
/// up/down for 3D" would require swapping the whole base map for a
/// real GL engine: either `mapbox_maps_flutter` (Mapbox SDK, paid for
/// any non-trivial usage) or `google_maps_flutter` (Google Maps SDK,
/// requires an API key and forbids screenshot-style fog overlays via
/// `CustomPaint`). Neither is a drop-in replacement; the migration
/// would touch every screen that renders a map (recording, playback,
/// trip plan, journal pins, favorites). We've punted on this until
/// the rest of the app stabilises — if it lands, it's a separate
/// feature branch, not an incremental patch.
///
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});
  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen>
    with WidgetsBindingObserver, RouteAware {
  final _mapCtrl = MapController();
  LatLng _center = const LatLng(30.6586, 104.0648);
  _EditMode _editMode = _EditMode.none;
  bool _satellite = false;

  /// Current camera rotation in degrees, mirrored from `_mapCtrl` via
  /// the `onMapEvent` callback. Reading `_mapCtrl.camera.rotation`
  /// directly during build() throws "FlutterMap not rendered yet" on
  /// the very first frame — keep a local copy and only ever READ
  /// `_mapCtrl.camera` from event callbacks (which only fire after
  /// the map exists).
  double _mapRotation = 0.0;

  /// While recording, the camera auto-follows the user's location, keeping
  /// it centred. Starts on (the default "always centred" behaviour). Any
  /// manual pan/rotate gesture flips it off so the user can look around
  /// without the map yanking back; tapping the locate FAB (or starting a
  /// fresh recording) turns it back on. Outside of recording it has no
  /// effect — the camera only ever moves on explicit user action.
  bool _followCamera = true;

  // Raw WGS-84 position — always stored in WGS-84
  // ── AI 旅伴卡片 ──
  bool _companionOpen = false;
  final _companionKey = GlobalKey<CompanionCardState>();

  double? _wgsLat;
  double? _wgsLng;

  /// Heading in degrees (0 = north, clockwise). Sourced from Geolocator
  /// when moving > a small threshold; null when stationary so the arrow
  /// collapses back to a plain dot.
  double? _heading;
  StreamSubscription<Position>? _posSub;
  // 前台定位流自愈（断流退避重启 + 假活看门狗）。
  Timer? _locWatchdog;
  Timer? _locRestart;
  int _locBackoffMs = 2000;

  /// While recording, the map mirrors the recording pipeline's accepted
  /// points instead of running its own GPS stream (see
  /// [_startLocationStream]); this is that mirror.
  StreamSubscription? _liveSub;
  ProviderSubscription<bool>? _recSub;

  /// App is backgrounded / screen off: every location source on this screen
  /// is torn down until [AppLifecycleState.resumed]. MapScreen is the
  /// resident home route and is never disposed, so without this the
  /// high-accuracy stream + watchdog ran all night behind the lock screen.
  bool _lifecycleSuspended = false;

  /// 另一条整页路由压在地图上面（context.push 进设置 / 备份 / 歌单……）。
  /// MapScreen 是常驻首页、不会 dispose，所以仅靠 [_lifecycleSuspended] 时，
  /// 用户在设置页停留多久，高精度 GPS 流 + 看门狗就在下面开多久。语义与
  /// [_lifecycleSuspended] 相同、来源不同：两者任一为真都不开定位流。
  /// 只由 [didPushNext] / [didPopNext] 翻转——3D 热图、旅伴卡片这类页内
  /// 覆盖层不是路由，不会碰它。
  bool _routeCovered = false;

  /// 已向 [mapRouteObserver] 订阅的路由；didChangeDependencies 会因主题 /
  /// MediaQuery 变化反复进入，靠它避免重复订阅。
  PageRoute<void>? _subscribedRoute;

  /// Last reported fix accuracy in metres. Drives the signal-strength
  /// chip top-center on the map. `null` = we've never received a fix
  /// in this session (cold-start or indoors with no GPS lock).
  double? _accuracyMeters;

  /// When the last accuracy update arrived. Non-null means "we have had at
  /// least one fix this session", which is all the signal chip needs to
  /// distinguish "located" from "无定位". It deliberately does NOT decay
  /// into a "no signal" state over time — a missing update means the user
  /// is stationary, not that GPS reception was lost.
  DateTime? _accuracyAt;

  // ─── Debug simulation ───
  bool _simActive = false;
  double _simLat = 30.6586;
  double _simLng = 104.0648;
  double _simBearing = 0; // degrees, 0=north
  Timer? _simTimer;
  static const _simStepMeters = 9.5; // ~1 FOW pixel per tick

  StreamSubscription<GroupMessage>? _groupMsgSub;

  // ─── "Zoom out 3× past min → 3D globe" gesture ───
  static const double _kMinZoom = 3.0;
  bool _atMinZoom = false;
  int _zoomOutTries = 0; // pinch-in attempts while already fully zoomed out
  Timer? _zoomTriesReset;
  double _prevZoom = 13.0; // last zoom seen in onMapEvent (web wheel detection)
  bool _geoWarnedWeb = false; // one-shot "web location needs https" toast
  final Map<int, Offset> _ptrs = {}; // live pointers for pinch detection
  double? _pinchStartDist; // two-finger distance at the start of a pinch
  bool _pinchCounted = false; // already counted this two-finger gesture?

  void _onPointerDown(PointerDownEvent e) {
    _ptrs[e.pointer] = e.position;
    FogTileLayer.setGestureActive(true);
    if (_ptrs.length == 2) {
      _pinchStartDist = _twoPtrDist();
      _pinchCounted = false;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_ptrs.containsKey(e.pointer)) return;
    _ptrs[e.pointer] = e.position;
    // Only care about a clean two-finger pinch while already at min zoom.
    if (_ptrs.length != 2 || _pinchStartDist == null || _pinchCounted) return;
    if (!_atMinZoom) return;
    final now = _twoPtrDist();
    if (now != null && _pinchStartDist! > 0 && now < _pinchStartDist! * 0.72) {
      _pinchCounted = true; // one count per pinch gesture
      _registerZoomOutTry();
    }
  }

  void _onPointerUp(PointerEvent e) {
    _ptrs.remove(e.pointer);
    if (_ptrs.isEmpty) FogTileLayer.setGestureActive(false);
    if (_ptrs.length < 2) {
      _pinchStartDist = null;
      _pinchCounted = false;
    }
  }

  double? _twoPtrDist() {
    if (_ptrs.length != 2) return null;
    final it = _ptrs.values.toList();
    return (it[0] - it[1]).distance;
  }

  void _registerZoomOutTry() {
    _zoomTriesReset?.cancel();
    setState(() => _zoomOutTries++);
    if (_zoomOutTries >= 3) {
      _zoomOutTries = 0;
      if (mounted) context.push('/globe');
      return;
    }
    // Forget the streak if they pause — avoids accidental accumulation.
    _zoomTriesReset = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _zoomOutTries = 0);
    });
  }

  bool _tiltBusy = false;

  /// Non-null while the map is in 3D heat mode (the live-tile overlay is up).
  HeatSnapshot? _tiltHeat;
  Heat3DCamera? _tiltCam;

  /// 「热图」＝3D 地图模式（Google Maps 式实时瓦片 3D）：加载热度索引，
  /// 用当前 2D 相机初始化 3D 相机，然后把整个地图切给 Heat3DView——
  /// 瓦片在 3D 里按需流式加载，不再抓快照。
  Future<void> _enterHeat3D() async {
    if (_tiltBusy || _tiltHeat != null) return;
    setState(() => _tiltBusy = true);
    try {
      final s = ref.read(settingsProvider);
      final db = ref.read(dbProvider);
      final layerIds = (await db.allLayers())
          .where((l) => l.visible)
          .map((l) => l.id)
          .toList();
      final win = heatTimeWindow(s);
      final snap = await loadHeatSnapshot(
        db: db,
        layerIds: layerIds,
        mapProvider: s.mapProvider,
        style: HeatStyle(
            palette: s.heatPalette,
            exposure: s.heatExposure,
            width: s.heatWidth),
        from: win.$1,
        to: win.$2,
        includeFog: s.heatFogBaseline,
      );
      if (!mounted) return;
      final cam = _mapCtrl.camera;
      final c = cam.center;
      setState(() {
        _tiltHeat = snap;
        _tiltCam = Heat3DCamera(
          centerX01: HeatIndex.lngToWorldX(c.longitude),
          centerY01: HeatIndex.latToWorldY(c.latitude),
          zoom: cam.zoom,
          viewport: Size(cam.nonRotatedSize.x, cam.nonRotatedSize.y),
        );
      });
    } catch (e, st) {
      debugPrint('[HEAT] enter 3D failed: $e\n$st');
      // TopToast 没有动作按钮（它就是为了不挤走 FAB/底栏才存在的），
      // 所以「怎么重试」只能写进话里。
      if (mounted) {
        TopToast.show(context,
            '${failureMessage('打开 3D 热图', e)}。再点一次火苗按钮可重试');
      }
    } finally {
      if (mounted) setState(() => _tiltBusy = false);
    }
  }

  /// Leaving 3D: the 2D map lands exactly where the 3D camera was.
  void _exitHeat3D(double lat, double lng, double zoom) {
    if (!mounted) return;
    setState(() {
      _tiltHeat = null;
      _tiltCam = null;
    });
    try {
      _mapCtrl.move(LatLng(lat, lng), zoom.clamp(3.0, 19.0));
    } catch (_) {}
  }

  /// Zoom by [delta] levels via the +/- buttons (clamped to the map's range).
  void _zoomBy(double delta) {
    final cam = _mapCtrl.camera;
    final z = (cam.zoom + delta).clamp(_kMinZoom, 19.0);
    _mapCtrl.move(cam.center, z);
  }

  /// The "−" button. Deterministic globe path on web (where the wheel gesture
  /// is unreliable): once at the zoom floor, each press counts toward the 3D
  /// globe (3 presses, same as the mobile pinch). Above the floor it just
  /// zooms out one level.
  void _zoomOutOrGlobe() {
    if (_mapCtrl.camera.zoom <= _kMinZoom + 0.05) {
      _registerZoomOutTry();
    } else {
      _zoomBy(-1);
    }
  }

  // Cached journal-pin future: rebuilt only when entries change, so we don't
  // hit the DB on every map frame.
  Future<List<db_t.JournalEntry>>? _journalPinsFuture;
  int _journalPinsRev = 0;
  // Per-session hide state for journal pins. Not persisted — re-opens reset
  // to "all visible" so users don't lose track of where journals live.
  final Set<int> _hiddenJournalIds = {};
  bool _allPinsHidden = false;
  void _reloadJournalPins() {
    _journalPinsFuture = ref.read(dbProvider).recentJournal(limit: 100);
    _journalPinsRev++;
  }

  StreamSubscription<List<GroupPeer>>? _groupPeerSub;
  Timer? _peerRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Recording start/stop swaps the map's position source (own stream ↔
    // pipeline mirror).
    _recSub = ref.listenManual<bool>(
        recordingActiveProvider, (_, __) => _startLocationStream());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(_reloadJournalPins);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // If a FOW import finished while this screen wasn't mounted (the common
      // case — import runs from the backup page), fly to the revealed region
      // now that the map exists.
      if (!mounted) return;
      final focus = ref.read(fogImportFocusProvider);
      if (focus != null) _consumeFogImportFocus(focus);
      final mf = ref.read(mapFocusProvider);
      if (mf != null) _consumeMapFocus(mf);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // If a recording was in progress when the app was last killed (or the
      // service was auto-restarted after a reboot), re-attach the pipeline
      // and fold in whatever the background service buffered while away.
      ref.read(recordingControllerProvider).resumeIfRecording();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Auto-join group if user has set a groupId. This makes the map see
      // peers' colored trails the moment you open the app.
      final s = ref.read(settingsProvider);
      if ((s.groupId ?? '').isNotEmpty) {
        final g = ref.read(groupServiceProvider);
        try {
          await g.start();
          _groupPeerSub = g.peers.listen((peers) {
            ref.read(groupPeersProvider.notifier).state = peers;
          });
          // Re-render peer markers so "stale > 30s" visuals update even when
          // no new peer message arrives. Only when there IS someone to
          // redraw: the old unconditional 10 s tick rebuilt the whole
          // MapScreen forever, peers or not.
          _peerRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
            final cur = ref.read(groupPeersProvider);
            if (cur.isEmpty || !mounted) return;
            ref.read(groupPeersProvider.notifier).state = [...cur];
          });
          // Hook group sync controller (music + voice).
          ref.read(groupSyncControllerProvider).attach(g.messages);
          _groupMsgSub = g.messages.listen((m) {
            if (m.type != 'location') return;
            final trails = {...ref.read(groupTrailsProvider)};
            final lat = (m.data['lat'] as num?)?.toDouble();
            final lng = (m.data['lng'] as num?)?.toDouble();
            if (lat == null || lng == null) return;
            final list = <List<double>>[...(trails[m.fromId] ?? const [])];
            list.add(<double>[lat, lng]);
            if (list.length > 200) list.removeRange(0, list.length - 200);
            trails[m.fromId] = list;
            ref.read(groupTrailsProvider.notifier).state = trails;
          });
        } catch (_) {}
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final pos = await ref.read(locationServiceProvider).currentOnce();
        if (pos != null && mounted) {
          setState(() {
            _wgsLat = pos.latitude;
            _wgsLng = pos.longitude;
            _simLat = pos.latitude;
            _simLng = pos.longitude;
          });
          _publishDisplayPos();
          final display = _toDisplay(pos.latitude, pos.longitude);
          _center = display;
          _mapCtrl.move(_center, 15);
        } else if (mounted && kIsWeb) {
          // No fix on web → almost always an insecure context (http LAN IP)
          // or a denied browser permission. Surface it instead of silently
          // showing the default centre with no marker.
          _warnGeoOnceWeb(ref.read(locationServiceProvider).lastError);
        }
        _startLocationStream();
      } catch (_) {
        // GPS not available (e.g. web without permission) — use default center
        if (mounted) {
          setState(() {
            _wgsLat = _simLat;
            _wgsLng = _simLng;
          });
          if (kIsWeb) {
            _warnGeoOnceWeb(ref.read(locationServiceProvider).lastError);
          }
        }
      }
    });
  }

  /// One-shot web-only toast explaining why there's no location: the browser
  /// Geolocation API only works in a secure context (https or localhost).
  void _warnGeoOnceWeb(String? detail) {
    if (!kIsWeb || _geoWarnedWeb || !mounted) return;
    _geoWarnedWeb = true;
    final extra = (detail != null && detail.isNotEmpty) ? '（$detail）' : '';
    TopToast.show(
      context,
      'Web 定位失败：需用 HTTPS 或 localhost 打开，并允许浏览器定位权限$extra',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_lifecycleSuspended) return;
        _lifecycleSuspended = false;
        _startLocationStream(); // 若仍被路由盖着，它自己会直接返回
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_lifecycleSuspended) return;
        _lifecycleSuspended = true;
        _stopLocationSources();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 只有整页路由才订阅（见 mapRouteObserver）。ModalRoute.of 会让本页依赖
    // 路由状态，每次被盖 / 露出都会再进一次这里——同一路由不重订。
    final route = ModalRoute.of(context);
    if (route is PageRoute<void> && !identical(route, _subscribedRoute)) {
      if (_subscribedRoute != null) mapRouteObserver.unsubscribe(this);
      _subscribedRoute = route;
      mapRouteObserver.subscribe(this, route);
    }
  }

  /// 整页路由压上来（context.push 进设置 / 歌单 / 手账详情……）：只停定位
  /// 相关的东西，队伍 / 迷雾 / 手账等订阅照旧。录制中也一样——录制管线自己
  /// 的 GPS 流不受影响，这里丢的只是地图上的镜像，回来时重新接上。
  @override
  void didPushNext() {
    if (_routeCovered) return;
    _routeCovered = true;
    _stopLocationSources();
    _logRouteCover(on: false);
  }

  @override
  void didPopNext() {
    if (!_routeCovered) return;
    _routeCovered = false;
    _logRouteCover(on: true);
    if (!_lifecycleSuspended) _startLocationStream();
  }

  /// 固定格式，方便在 logcat 里 grep 验证起停配对。
  void _logRouteCover({required bool on}) {
    if (!kDebugMode) return;
    debugPrint(
        '[MAP] location stream ${on ? 'resumed' : 'suspended'} (route covered)');
  }

  /// 撤掉本页所有定位来源：自有 GPS 流、录制镜像、断流退避重启、看门狗。
  /// 后台 / 被路由盖住两条路都走这里；重新开启统一由 [_startLocationStream]。
  void _stopLocationSources() {
    _posSub?.cancel();
    _posSub = null;
    _liveSub?.cancel();
    _liveSub = null;
    _locRestart?.cancel();
    _locRestart = null;
    _locWatchdog?.cancel();
    _locWatchdog = null;
  }

  /// The map's own (not-recording) stream: this only feeds the blue dot the
  /// user is looking at, so it asks the fused provider half as often as the
  /// old hard-coded `high + distanceFilter 3` did (that spelling left the
  /// interval at geolocator's 5 s default — verified on-device as
  /// `ProviderRequest[@+5s0ms]`) and delivers a callback — hence a MapScreen
  /// rebuild — only every 10 m instead of every 3 m.
  LocationSettings _idleLocationSettings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 10),
      );
    }
    return const LocationSettings(
        accuracy: LocationAccuracy.high, distanceFilter: 10);
  }

  void _startLocationStream() {
    _posSub?.cancel();
    _posSub = null;
    _liveSub?.cancel();
    _liveSub = null;
    // 后台 → resumed()、被路由盖住 → didPopNext() 会再叫我们一次。
    if (_lifecycleSuspended || _routeCovered) return;
    if (ref.read(recordingActiveProvider)) {
      // Recording: the pipeline already owns a GPS stream (the foreground
      // service on Android, LocationService elsewhere). Mirror the points
      // it accepts instead of opening a second, hungrier stream alongside
      // — that duplicate was the biggest single drain while recording.
      _liveSub = ref.read(recordingControllerProvider).livePoints.listen((p) {
        if (!mounted || _simActive) return;
        setState(() {
          _wgsLat = p.lat;
          _wgsLng = p.lng;
          _accuracyMeters = p.accuracy ?? _accuracyMeters;
          _accuracyAt = DateTime.now();
        });
        _publishDisplayPos();
        _maybeFollowCamera();
      });
      // The pipeline has its own watchdog; ours would only duplicate polls.
      _locWatchdog?.cancel();
      _locWatchdog = null;
      return;
    }
    try {
      _posSub = Geolocator.getPositionStream(
        locationSettings: _idleLocationSettings(),
      ).listen(
        (pos) {
          _locBackoffMs = 2000; // 有数据 = 健康，重置退避
          if (!mounted || _simActive) return;
          setState(() {
            _wgsLat = pos.latitude;
            _wgsLng = pos.longitude;
            // Geolocator reports heading in degrees, -1 when unavailable.
            // Only update when moving > 0.5 m/s so the arrow doesn't spin
            // randomly when the user is standing still.
            if (pos.heading >= 0 && pos.speed > 0.5) {
              _heading = pos.heading;
            }
            _accuracyMeters = pos.accuracy;
            _accuracyAt = DateTime.now();
          });
          _publishDisplayPos();
          _maybeFollowCamera();
        },
        // 「高德有定位、这个 App 没有」的根因之一：流一断（provider 重启、
        // OEM 熄屏杀流、权限瞬断）就永久死，回前台也不自愈。现在断了就
        // 指数退避重订（后台录制那份 watchdog 早修过，前台这份补齐）。
        onError: (_) {
          _warnGeoOnceWeb(null);
          _scheduleLocRestart();
        },
        onDone: _scheduleLocRestart,
        cancelOnError: true,
      );
    } catch (_) {
      // Geolocator stream not available on this platform
      _warnGeoOnceWeb(null);
      _scheduleLocRestart();
    }
    // 看门狗：流“假活”（订阅还在但再无回调）时兜底。3 分钟无 fix →
    // 重订流 + 主动补一发 currentOnce，让 pin 立刻回来。（只在前台、
    // 非录制时存在；静止 3 分钟内不动作，别把“人没动”当成“流死了”。）
    _locWatchdog ??= Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!mounted ||
          _simActive ||
          kIsWeb ||
          _lifecycleSuspended ||
          _routeCovered) {
        return;
      }
      final stale = _accuracyAt == null ||
          DateTime.now().difference(_accuracyAt!) >
              const Duration(minutes: 3);
      if (!stale) return;
      _startLocationStream();
      final pos = await ref.read(locationServiceProvider).currentOnce();
      if (pos == null || !mounted || _simActive) return;
      setState(() {
        _wgsLat = pos.latitude;
        _wgsLng = pos.longitude;
        _accuracyMeters = pos.accuracy;
        _accuracyAt = DateTime.now();
      });
      _publishDisplayPos();
    });
  }

  void _scheduleLocRestart() {
    if (!mounted) return;
    _posSub?.cancel();
    _posSub = null;
    _locRestart?.cancel();
    _locRestart = Timer(Duration(milliseconds: _locBackoffMs), () {
      if (mounted) _startLocationStream();
    });
    _locBackoffMs = math.min(_locBackoffMs * 2, 30000);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_subscribedRoute != null) mapRouteObserver.unsubscribe(this);
    _recSub?.close();
    _liveSub?.cancel();
    _posSub?.cancel();
    _locWatchdog?.cancel();
    _locRestart?.cancel();
    _simTimer?.cancel();
    _groupMsgSub?.cancel();
    _groupPeerSub?.cancel();
    _peerRefreshTimer?.cancel();
    _zoomTriesReset?.cancel();
    super.dispose();
  }

  /// Push the current real-or-simulated WGS-84 position into the shared
  /// state so other screens (journal editor) can read it as "my current
  /// location" without re-querying the OS. Also opportunistically warms
  /// the geocoder cache when [AppSettings.geocodingPrewarm] is on.
  DateTime? _lastPrewarm;
  String? _lastPrewarmCell;
  void _publishDisplayPos() {
    if (_wgsLat == null || _wgsLng == null) return;
    ref.read(currentDisplayPositionProvider.notifier).state =
        (lat: _wgsLat!, lng: _wgsLng!);
    if (!ref.read(settingsProvider).geocodingPrewarm) return;
    final cell = '${(_wgsLat! / 0.01).floor()},${(_wgsLng! / 0.01).floor()}';
    final now = DateTime.now();
    if (cell == _lastPrewarmCell) return;
    if (_lastPrewarm != null &&
        now.difference(_lastPrewarm!) < const Duration(seconds: 30)) {
      return;
    }
    _lastPrewarm = now;
    _lastPrewarmCell = cell;
    // Fire-and-forget — failures are logged inside the service.
    ref.read(geocodingServiceProvider).resolve(_wgsLat!, _wgsLng!);
  }

  LatLng _toDisplay(double lat, double lng) {
    final provider = ref.read(settingsProvider).mapProvider;
    if (CoordConverter.needsGcj02(provider)) {
      final gc = CoordConverter.wgs84ToGcj02(lat, lng);
      return LatLng(gc.lat, gc.lng);
    }
    return LatLng(lat, lng);
  }

  LatLng _fromDisplay(double lat, double lng) {
    final provider = ref.read(settingsProvider).mapProvider;
    if (CoordConverter.needsGcj02(provider)) {
      final wgs = CoordConverter.gcj02ToWgs84(lat, lng);
      return LatLng(wgs.lat, wgs.lng);
    }
    return LatLng(lat, lng);
  }

  // ─── Simulation helpers ───

  void _simMoveTo(double lat, double lng) {
    setState(() {
      _simLat = lat;
      _simLng = lng;
      _wgsLat = lat;
      _wgsLng = lng;
    });
    _publishDisplayPos();
    _maybeFollowCamera();
    _feedSimToRecording(lat, lng);
  }

  void _simStep() {
    final dLat =
        _simStepMeters / 111320.0 * math.cos(_simBearing * math.pi / 180);
    final dLng = _simStepMeters /
        (111320.0 * math.cos(_simLat * math.pi / 180)) *
        math.sin(_simBearing * math.pi / 180);
    _simMoveTo(_simLat + dLat, _simLng + dLng);
  }

  void _feedSimToRecording(double lat, double lng) {
    final recording = ref.read(recordingActiveProvider);
    if (!recording) return;
    final ctrl = ref.read(recordingControllerProvider);
    ctrl.handleSimulatedSample(lat, lng);
  }

  void _toggleSimWalk() {
    if (_simTimer != null) {
      _simTimer!.cancel();
      _simTimer = null;
      setState(() {});
    } else {
      _simTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _simStep();
      });
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final layersAsync = ref.watch(layersProvider);
    final fogRefresh = ref.watch(fogRefreshProvider);
    final recording = ref.watch(recordingActiveProvider);
    // Re-query journal pins whenever an entry is added/imported/removed from
    // anywhere (the journal list, a backup restore). Without this the map's
    // cached pin future goes stale and imported entries never get pins.
    ref.listen<int>(journalRefreshProvider, (_, __) {
      if (mounted) setState(_reloadJournalPins);
    });
    // After a FOW import, fly to the freshly-revealed region (FoW has no track
    // lines, so cleared fog far from the user is otherwise easy to miss).
    ref.listen<({double lat, double lng, double zoom})?>(mapFocusProvider,
        (_, next) {
      if (next != null) _consumeMapFocus(next);
    });
    ref.listen<LatLng?>(fogImportFocusProvider, (_, next) {
      if (next != null) _consumeFogImportFocus(next);
    });
    // Use the EFFECTIVE active id so manual reveals also go to a visible
    // layer — see provider docs for the why.
    final activeLayerId = ref.watch(effectiveActiveLayerIdProvider);
    final visibleLayers = layersAsync.maybeWhen(
      data: (rows) => rows.where((l) => l.visible).toList(),
      orElse: () => const <db_t.TrackLayer>[],
    );
    final visibleLayerIds = visibleLayers.map((l) => l.id).toList();
    // Single fog veil for everyone. Light mode = the global fog colour /
    // opacity; dark mode = a strong dark scrim. The walked corridors are
    // erased out of it to reveal the map.
    final fogVeil = settings.darkMap
        ? const Color(0xFF05070A)
            .withValues(alpha: math.max(settings.fogOpacity, 0.62))
        : Color(settings.fogColor)
            .withValues(alpha: settings.fogOpacity.clamp(0.0, 1.0));
    // Per-layer corridor tint. pathColor null = plain transparent reveal;
    // set = the SAME corridor geometry rendered in that colour (opacity from
    // pathOpacity). One path style — only the colour differs.
    final fogTints = <int, Color>{
      for (final l in visibleLayers)
        if (l.pathColor != null)
          l.id: Color(l.pathColor!)
              .withValues(alpha: (l.pathOpacity ?? 0.6).clamp(0.0, 1.0)),
    };

    final LatLng? displayPos = (_wgsLat != null && _wgsLng != null)
        ? _toDisplay(_wgsLat!, _wgsLng!)
        : null;

    final viewOnly = ref.watch(viewOnlyProvider);

    return Scaffold(
      // 键盘弹出时不挤压地图（旅伴卡片自己跟随 viewInsets 上移）。
      resizeToAvoidBottomInset: false,
      extendBody: true,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      // Scaffold chrome floats ABOVE the body stack, so the 3D heat overlay
      // can't cover it — hide it outright while the 3D mode is up.
      floatingActionButton: _tiltHeat != null
          ? null
          : _CenterRecFab(
        recording: recording,
        onTap: () async {
          final ctrl = ref.read(recordingControllerProvider);
          if (recording) {
            await ctrl.stop();
            if (context.mounted) TopToast.show(context, '已停止记录');
          } else {
            final err = await ctrl.start();
            if (!context.mounted) return;
            if (err == null) {
              // Each fresh recording starts in centred-follow mode and snaps
              // the camera onto the user, regardless of where they'd panned.
              setState(() => _followCamera = true);
              _recenterOnUser(zoom: 16);
            }
            TopToast.show(
              context,
              err ?? '已开始记录，走动几步看看迷雾',
              // 这条 toast 浮在地图影像上，用固定的浮层色而不是主题色。
              // red.shade700 配白字本来就有 4.98:1（勉强达标），换成 toastDanger
              // 是 6.54:1，且和下面「还没有位置」那条走同一套已断言的 token。
              background: err == null ? null : MapChrome.toastDanger,
            );
            // First-start nudge: if Android, prompt the user to walk
            // through the permission + autostart checklist once.
            // Background recording reliably fails on every major
            // Chinese ROM without this. Gated on a SharedPreferences
            // flag so we only ask once per install.
            if (err == null &&
                defaultTargetPlatform == TargetPlatform.android) {
              _maybeOfferPermissionWalkthrough();
            }
          }
        },
      ),
      bottomNavigationBar: _tiltHeat != null
          ? null
          : _BottomNav(
              onJournal: _showNearbyJournals,
              onGroup: () => context.push('/group'),
              onMusic: () => context.push('/music'),
              onMenu: () => context.push('/menu'),
              onQuickNote: _quickNewJournal,
            ),
      // No AppBar — every top-element is a floating Positioned widget so
      // taps reach the buttons directly instead of being intercepted by the
      // toolbar hit area.
      body: Stack(
        children: [
          // Listener wraps the map purely to OBSERVE pointers (it doesn't
          // absorb them — the map still gets every gesture) so we can detect
          // the "pinch-in while already fully zoomed out" attempts that open
          // the 3D globe.
          Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            // RepaintBoundary: isolates map repaints from the chrome above.
            child: RepaintBoundary(
              // flutter_map 的 RawGestureDetector 会往语义树里挂一个带
              // tap / longPress / scroll 的全屏节点，自己却没有任何标签
              // ——读屏扫到这里只会念一句空白。地图本体就是这个节点，给它一个
              // 名字（编辑模式下 tap 会擦除/加点，所以顺带说清）。
              child: Semantics(
                label: '地图',
                child: FlutterMap(
                mapController: _mapCtrl,
                options: MapOptions(
                  initialCenter: _center,
                  initialZoom: 13,
                  initialRotation: 0,
                  // Floor the zoom so the map always fills the screen — below
                  // this the world is smaller than a tall viewport and the grey
                  // backdrop showed through as a full-white screen. Combined with
                  // the world cameraConstraint below, zoom-out stops at a filled
                  // view (you see most of the world, not blank margins).
                  minZoom: 3,
                  maxZoom: 19,
                  cameraConstraint: CameraConstraint.contain(
                    bounds: LatLngBounds(
                      const LatLng(-85.05, -180),
                      const LatLng(85.05, 180),
                    ),
                  ),
                  // Backdrop for not-yet-fetched tiles. Amap's day-style land
                  // beige, NOT a cool grey: the dark fog veil multiplies over
                  // whatever shows through, and veil-over-beige lands within a
                  // couple of grey levels of veil-over-real-tiles — a cold area
                  // reads as "map still sharpening", not a black hole.
                  backgroundColor: const Color(0xFFEAE6DE),
                  interactionOptions: InteractionOptions(
                    // Rotation is opt-in (default off): most two-finger gestures
                    // are just pinch-zoom, so by default we strip the rotate flag
                    // entirely — no accidental tilt. When the user enables it, a
                    // high rotation threshold still ignores small twists during a
                    // pinch, and the top-right compass snaps back to north.
                    flags: settings.allowMapRotation
                        ? InteractiveFlag.all
                        : InteractiveFlag.all & ~InteractiveFlag.rotate,
                    rotationThreshold: 25.0,
                  ),
                  onPositionChanged: (camera, hasGesture) {
                    // A user-driven pan/zoom/rotate breaks auto-follow so the
                    // map stops yanking back to centre while they look around.
                    // Programmatic moves (our own follow re-centring, the locate
                    // FAB) report hasGesture == false, so they don't disarm it.
                    if (hasGesture && _followCamera) {
                      setState(() => _followCamera = false);
                    }
                  },
                  onMapEvent: (e) {
                    // Mirror the camera's rotation into local state so
                    // build() can render the compass chip without ever
                    // touching `_mapCtrl.camera` (which throws before
                    // the first frame). After the first onMapReady the
                    // camera is safe to read here.
                    if (e is MapEventRotate ||
                        e is MapEventRotateStart ||
                        e is MapEventRotateEnd ||
                        e is MapEventMoveEnd) {
                      if (!mounted) return;
                      // Only when the compass actually needs to turn: with
                      // rotation off this fired a full MapScreen rebuild
                      // (Scaffold, FABs, every map layer) at the end of EVERY
                      // pan and pinch, to redraw an unchanged north arrow.
                      final rot = e.camera.rotation;
                      if (rot != _mapRotation) {
                        setState(() => _mapRotation = rot);
                      }
                    }
                    // Track whether we're pressed against the zoom floor; that's
                    // the only time pinch-in attempts count toward the 3D globe.
                    final atMin = e.camera.zoom <= _kMinZoom + 0.05;
                    if (atMin != _atMinZoom) {
                      if (mounted) setState(() => _atMinZoom = atMin);
                    }
                    // Zooming back in cancels the streak.
                    if (!atMin && _zoomOutTries != 0) {
                      _zoomTriesReset?.cancel();
                      if (mounted) setState(() => _zoomOutTries = 0);
                    }
                    // Web has no two-finger pinch — count mouse-wheel zoom-out
                    // ticks while pressed against the floor as the path into the
                    // 3D globe (parity with the 3× pinch gesture on mobile).
                    if (kIsWeb &&
                        e is MapEventScrollWheelZoom &&
                        atMin &&
                        e.camera.zoom <= _prevZoom + 0.001) {
                      _registerZoomOutTry();
                    }
                    _prevZoom = e.camera.zoom;
                  },
                  onTap: (tapPos, latlng) => _onMapTap(latlng, activeLayerId),
                  onLongPress:
                      (kDebugMode || ref.read(settingsProvider).debugMode)
                          ? (tapPos, latlng) {
                              final wgs =
                                  _fromDisplay(latlng.latitude, latlng.longitude);
                              setState(() {
                                _simActive = true;
                                _simLat = wgs.latitude;
                                _simLng = wgs.longitude;
                                _wgsLat = wgs.latitude;
                                _wgsLng = wgs.longitude;
                              });
                            }
                          : null,
                ),
                children: [
                  // Tile layer — always rendered at full brightness. Dark mode
                  // is no longer a client-side invert of the raster (which
                  // dimmed the explored trail too); instead the fog veil below
                  // turns dark, so walked corridors reveal the bright original
                  // map exactly as in light mode while everything else is
                  // pressed dark. See the FogLayer's dark veil below.
                  buildTileLayer(
                    provider: settings.mapProvider,
                    style: settings.mapStyle,
                    amapKey: settings.amapApiKey,
                    googleKey: settings.googleMapKey,
                    customOsmUrl: settings.customOsmTileUrl,
                    ovitalUrl: settings.ovitalTileUrl,
                  ),
                  // Explored-area fog, baked into real map tiles so it pans/zooms
                  // pixel-for-pixel with the base map (fixed thickness, no custom
                  // per-zoom re-rasterisation). Rendered whenever there are visible
                  // layers OR dark mode is on (empty data → a solid dark scrim).
                  // Gated on settings.loaded: painting with the not-yet-loaded
                  // default veil colour / widths flashed a wrong first frame on
                  // every cold start.
                  if (settings.loaded &&
                      (visibleLayerIds.isNotEmpty || settings.darkMap))
                    FogTileLayer(
                      db: ref.read(dbProvider),
                      layerIds: visibleLayerIds,
                      veil: fogVeil,
                      tints: fogTints,
                      mapProvider: settings.mapProvider,
                      refreshKey: fogRefresh,
                      // Live reveal/erase rows merge into the snapshot in memory;
                      // fogRefresh (imports, layer ops) still forces a full reload.
                      changes: ref.read(fogEngineProvider).changes,
                    ),
                  // Cold-start guard: until prefs AND the layer list are loaded
                  // we can't know the real veil/visible layers, and the frames
                  // in between flashed a bright unfogged map ("闪一下白色地图").
                  // Cover the map with an approximate veil for those first
                  // frames; it's replaced by the real fog tiles the moment the
                  // data is in.
                  if (!settings.loaded || layersAsync.isLoading)
                    IgnorePointer(
                      child: ColoredBox(
                        // Default AppSettings veil (fogColor 0xFF101820 @ 0.78)
                        // for the pre-prefs frames; the real veil once loaded.
                        color: settings.loaded
                            ? fogVeil
                            : const Color(0xC7101820),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  if (displayPos != null)
                    MarkerLayer(markers: [
                      Marker(
                        point: displayPos,
                        width: 36,
                        height: 36,
                        child: _LocationDot(
                            simulated: _simActive, heading: _heading),
                      ),
                    ]),
                  _PeerTrailsLayer(toDisplay: _toDisplay),
                  // Journal pins — tappable thumbnail bubbles for every recent
                  // entry. Loaded once and refreshed on save/delete. Hidden
                  // wholesale (when [_allPinsHidden]) or per-pin (when its id is
                  // in [_hiddenJournalIds]).
                  if (!_allPinsHidden)
                    FutureBuilder<List<db_t.JournalEntry>>(
                      key: ValueKey('journal-pins-$_journalPinsRev'),
                      future: _journalPinsFuture,
                      builder: (ctx, snap) {
                        final list = (snap.data ?? const <db_t.JournalEntry>[])
                            .where((j) => !_hiddenJournalIds.contains(j.id))
                            .toList();
                        if (list.isEmpty) return const SizedBox.shrink();
                        // Pin size. On NATIVE pins scale with zoom; on WEB the
                        // per-frame rebuild of every marker is the main zoom jank,
                        // so pins are a FIXED size there (no camera read at all).
                        // Native reads the camera through a QUANTISED bucket
                        // (0.1 zoom): the builder below re-runs per frame, but it
                        // returns the CACHED MarkerLayer instance until the bucket
                        // actually flips, so the O(entries) marker/pin subtree —
                        // including Image.file thumbnails — is not rebuilt while
                        // panning or during sub-bucket zoom.
                        if (kIsWeb) return _buildPinLayer(list, 1.0);
                        return _ZoomBucketed(
                          buckets: 10, // 0.1-zoom steps
                          builder: (ctx, zoomBucket) {
                            // Proportional with the map (like the fog paths),
                            // but floored so a pin never shrinks past a
                            // recognisable ~12px sprite. The old 0.5 floor
                            // kicked in at z15 already — pins loomed huge over
                            // a zoomed-out city view.
                            final double scale = math
                                .pow(2.0, zoomBucket - 16.0)
                                .toDouble()
                                .clamp(0.28, 3.0);
                            return _buildPinLayer(list, scale);
                          },
                        );
                      },
                    ),
                ],
                ),
              ),
            ),
          ),
          if (_editMode != _EditMode.none)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                decoration: BoxDecoration(
                  // 这条模式提示横幅浮在**地图影像**上，且内含白色正文，所以
                  // 用固定的浮层色而不是主题色。擦除态原先的 redAccent 带
                  // 0.9 不透明度盖在雪地底图上只有 2.90:1。
                  color: (_editMode == _EditMode.erase
                          ? MapChrome.toastDanger
                          : MapChrome.brandDeep)
                      .withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _editMode == _EditMode.erase
                          ? '点击地图擦除 ${settings.fogPenRadius.toInt()}m 半径'
                          : '点击地图新增 ${settings.fogPenRadius.toInt()}m 半径',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w500),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 8),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 14),
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                        thumbColor: Colors.white,
                        overlayColor: Colors.white24,
                      ),
                      child: Slider(
                        // Both the FOW bitmap reveal *and* the
                        // on-screen smooth stroke use this. Bitmap
                        // floor of 1 m rounds to ≥1 storage pixel
                        // (~9.5 m); the stroke uses the value in
                        // METERS via a screen-pixel conversion, so
                        // values below the storage resolution are
                        // still rendered correctly — the trail just
                        // gets thinner on-screen as the user dials
                        // it down.
                        value: settings.fogPenRadius,
                        min: 1,
                        max: 200,
                        divisions: 199,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .update((p) => p.copyWith(fogPenRadius: v)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // (PTT moved to group screen — private chat / call view only.)
          // Right-side floating column: layers, my location, edit modes.
          // Sits above the signal chip now docked at the bottom-right.
          Positioned(
            right: 16,
            bottom: 168,
            child: Column(
              children: [
                // Explicit zoom controls — the only reliable way to zoom on a
                // desktop browser (and the −, at the floor, is the path into
                // the 3D globe where the scroll-wheel gesture is unreliable).
                _MapFab(
                    icon: Icons.add_rounded,
                    semanticLabel: '放大',
                    onTap: () => _zoomBy(1)),
                const SizedBox(height: 10),
                _MapFab(
                  icon: Icons.remove_rounded,
                  // 已经贴着缩放下限时，这颗按钮的意义变成「再按进 3D 地球」，
                  // 读屏得跟着变（视觉上是靠变色提示的）。
                  semanticLabel: _atMinZoom && _zoomOutTries > 0
                      ? '缩小，再按 ${3 - _zoomOutTries} 次进入 3D 地球'
                      : '缩小',
                  active: _atMinZoom && _zoomOutTries > 0,
                  activeColor: const Color(0xFF26A69A),
                  onTap: _zoomOutOrGlobe,
                ),
                const SizedBox(height: 10),
                // Editing tools (modify fog / add points) — hidden in the
                // read-only web viewer.
                if (!viewOnly) ...[
                  _MapFab(
                    icon: Icons.cleaning_services_rounded,
                    semanticLabel: _editMode == _EditMode.erase
                        ? '退出擦除迷雾'
                        : '擦除迷雾',
                    active: _editMode == _EditMode.erase,
                    // _MapFab 的图标是 MapChrome.onChrome（白）。跟它一起亮起来
                    // 的那条提示横幅同色，两个部件读成一组。
                    activeColor: MapChrome.toastDanger,
                    onTap: () => setState(() => _editMode =
                        _editMode == _EditMode.erase
                            ? _EditMode.none
                            : _EditMode.erase),
                  ),
                  const SizedBox(height: 10),
                  _MapFab(
                    icon: Icons.add_location_alt_rounded,
                    semanticLabel: _editMode == _EditMode.add
                        ? '退出添加记录点'
                        : '添加记录点',
                    active: _editMode == _EditMode.add,
                    // 与它点亮的那条横幅同色（见上面 erase 的同款注释）。
                    activeColor: MapChrome.brandDeep,
                    onTap: () => setState(() => _editMode =
                        _editMode == _EditMode.add
                            ? _EditMode.none
                            : _EditMode.add),
                  ),
                  const SizedBox(height: 10),
                  // Import record points from photos' GPS — lights up the trail
                  // at each picked photo's location. Same flow as the layers
                  // page; lives here so it's reachable from the home map too.
                  // Tooltip 不再包在外面：_MapFab 自己就会用 semanticLabel 挂
                  // tooltip（并把它排除在语义外），包两层只会被读两遍。
                  _MapFab(
                    icon: Icons.add_photo_alternate_rounded,
                    semanticLabel: '从照片定位点亮记录点',
                    onTap: () => TrackImportFlow.fromPhotos(context, ref),
                  ),
                  const SizedBox(height: 10),
                ],
                _MapFab(
                  // Highlighted while actively following during a recording.
                  // If you've panned away mid-recording it switches to the
                  // hollow "searching" icon — a cue that one tap re-centres
                  // and resumes following. Unchanged when not recording.
                  icon: (recording && !_followCamera)
                      ? Icons.location_searching_rounded
                      : Icons.my_location_rounded,
                  // 三种状态在视觉上靠图标空心/实心 + 高亮区分，读屏只能靠这句。
                  semanticLabel: recording
                      ? (_followCamera
                          ? '正在跟随我的位置'
                          : '回到我的位置并继续跟随')
                      : '回到我的位置',
                  active: recording && _followCamera,
                  activeColor: const Color(0xFF26A69A),
                  onTap: _gotoCurrent,
                ),
              ],
            ),
          ),
          // ── Top-left: map style + provider toggles ──
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            child: Row(
              children: [
                _MapChip(
                  icon: _satellite ? Icons.satellite_alt : Icons.map_outlined,
                  semanticLabel: _satellite
                      ? '底图：卫星影像，点按切换为标准地图'
                      : '底图：标准地图，点按切换为卫星影像',
                  onTap: () {
                    setState(() => _satellite = !_satellite);
                    ref.read(settingsProvider.notifier).update((p) =>
                        p.copyWith(
                            mapStyle: _satellite
                                ? MapStyle.satellite
                                : MapStyle.standard));
                  },
                ),
                _MapChip(
                  icon: Icons.public,
                  label: switch (settings.mapProvider) {
                    MapProvider.osm => 'OSM',
                    MapProvider.amap => '高德',
                    MapProvider.google => 'G',
                    MapProvider.ovital => '奥维',
                  },
                  // 可见标签是缩写（「G」/「OSM」），语义要说全称 + 这是什么。
                  semanticLabel: '地图源：${switch (settings.mapProvider) {
                    MapProvider.osm => 'OpenStreetMap',
                    MapProvider.amap => '高德地图',
                    MapProvider.google => '谷歌地图',
                    MapProvider.ovital => '奥维地图',
                  }}，点按切换',
                  onTap: () {
                    final providers = MapProvider.values;
                    final next = providers[
                        (settings.mapProvider.index + 1) % providers.length];
                    ref
                        .read(settingsProvider.notifier)
                        .update((p) => p.copyWith(mapProvider: next));
                  },
                ),
                _MapChip(
                  icon: settings.darkMap
                      ? Icons.dark_mode_rounded
                      : Icons.light_mode_outlined,
                  semanticLabel: settings.darkMap
                      ? '地图夜间配色已开，点按关闭'
                      : '地图夜间配色已关，点按开启',
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .update((p) => p.copyWith(darkMap: !p.darkMap)),
                ),
                // 热图＝3D 地图模式：一点就切入 3D 热力山脊（人生点点式），
                // 长按打开样式面板（色板 / 曝光 / 粗细 / 时间范围）。
                _MapChip(
                  icon: _tiltBusy
                      ? Icons.hourglass_top_rounded
                      : Icons.local_fire_department_rounded,
                  label: _tiltBusy ? '热图…' : null,
                  semanticLabel:
                      _tiltBusy ? '正在生成 3D 热力图' : '进入 3D 热力图',
                  longPressHint: '调整热图样式',
                  onTap: _enterHeat3D,
                  onLongPress: () => showHeatStyleSheet(context),
                ),
                // Rotation lock toggle — lives in the existing top-left chip
                // row so it doesn't cover any other control. Default state
                // (off) shows a "locked" icon; tapping enables two-finger
                // rotation.
                _MapChip(
                  icon: settings.allowMapRotation
                      ? Icons.screen_rotation_rounded
                      : Icons.screen_lock_rotation_rounded,
                  semanticLabel: settings.allowMapRotation
                      ? '双指旋转已开启，点按锁定朝北'
                      : '地图已锁定朝北，点按允许双指旋转',
                  onTap: () {
                    final next = !settings.allowMapRotation;
                    ref
                        .read(settingsProvider.notifier)
                        .update((p) => p.copyWith(allowMapRotation: next));
                    // Snap back to north when locking, so we don't leave the
                    // map stuck at an angle the user can no longer correct.
                    if (!next) _mapCtrl.rotate(0);
                  },
                ),
                // Compass — only visible when the map has been rotated
                // off-north. Reads from `_mapRotation` (mirrored from
                // controller via onMapEvent), NOT `_mapCtrl.camera`,
                // because the camera throws before first render.
                if (_mapRotation.abs() > 0.5)
                  _CompassChip(
                    bearingDeg: _mapRotation,
                    onTap: () => _mapCtrl.rotate(0),
                  ),
              ],
            ),
          ),
          // ── Bottom-right: signal-strength chip (always visible) ──
          //    Moved out of the top-center where it sat over the map and
          //    obscured content. Anchored above the 64px bottom nav bar,
          //    below the right-hand FAB column.
          Positioned(
            right: 12,
            bottom: 110,
            child: IgnorePointer(
              child: _SignalChip(
                accuracyMeters: _accuracyMeters,
                reportedAt: _accuracyAt,
              ),
            ),
          ),
          // (REC pill removed — the centre record button already shows the
          // live recording state, so a second top-centre indicator was
          // redundant and covered the map.)
          // ── Top-left: layer selector chip. Sits BELOW the existing
          //    map-style/provider chips at +8 so it doesn't overlap them.
          //    The "active" layer is where new fog reveals get written;
          //    visibility controls which layers FogLayer renders.
          Positioned(
            top: MediaQuery.of(context).padding.top + 56,
            left: 12,
            child: _LayerChip(
              activeId: activeLayerId,
              layers: layersAsync.maybeWhen(
                data: (rows) => rows,
                orElse: () => const <db_t.TrackLayer>[],
              ),
              onSelectActive: (id) =>
                  ref.read(activeLayerIdProvider.notifier).state = id,
              onToggleVisible: (l) async {
                // copyWith preserves the per-layer style columns; building
                // a fresh TrackLayer would null them out.
                await ref
                    .read(dbProvider)
                    .updateLayer(l.copyWith(visible: !l.visible));
                // Force fog re-render after visibility change.
                ref.read(fogRefreshProvider.notifier).state++;
              },
              onManage: () => context.push('/layers'),
            ),
          ),
          // ── Top-right: Profile / stats chip (FOW style) ──
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: _ProfileCard(
              onTap: () => _showStatsSheet(context),
            ),
          ),
          // ── Pin visibility toggle (sits just below the profile chip). ──
          // When any pins are hidden (either everything, or individually),
          // a "show" badge appears so the user can recover. Otherwise it's
          // a single quick-hide button.
          Positioned(
            top: MediaQuery.of(context).padding.top + 64,
            right: 16,
            // Tooltip 交给 _MapFab 自己挂（见那里的注释），这里只给标签。
            child: _MapFab(
              icon: (_allPinsHidden || _hiddenJournalIds.isNotEmpty)
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              semanticLabel: (_allPinsHidden || _hiddenJournalIds.isNotEmpty)
                  ? '恢复显示手账气泡'
                  : '隐藏全部手账气泡',
              onTap: () => setState(() {
                if (_allPinsHidden || _hiddenJournalIds.isNotEmpty) {
                  _allPinsHidden = false;
                  _hiddenJournalIds.clear();
                } else {
                  _allPinsHidden = true;
                }
              }),
            ),
          ),
          // ─── Debug simulation panel ───
          if ((kDebugMode || ref.watch(settingsProvider).debugMode) &&
              _simActive)
            Positioned(
              left: 12,
              bottom: 80,
              child: _SimPanel(
                bearing: _simBearing,
                walking: _simTimer != null,
                onStep: _simStep,
                onBearingChanged: (b) => setState(() => _simBearing = b),
                onToggleWalk: _toggleSimWalk,
                onStop: () {
                  _simTimer?.cancel();
                  _simTimer = null;
                  setState(() => _simActive = false);
                },
              ),
            ),
          if ((kDebugMode || ref.watch(settingsProvider).debugMode) &&
              !_simActive)
            Positioned(
              left: 12,
              bottom: 80,
              child: _MapFab(
                icon: Icons.bug_report_rounded,
                semanticLabel: '打开模拟行走面板',
                onTap: () => setState(() {
                  _simActive = true;
                  if (_wgsLat != null) _simLat = _wgsLat!;
                  if (_wgsLng != null) _simLng = _wgsLng!;
                }),
              ),
            ),
          // ── AI 旅伴：像素头像入口（debug 按钮上方）。通话中呼吸发光，
          //    收起卡片有新回复时亮一颗琥珀像素点。──
          Positioned(
            left: 12,
            bottom: 136,
            // CompanionAvatarButton 是一张像素脸（CustomPaint），自己没有标签；
            // 它不在本次改动范围内，所以在调用点补上语义。
            child: Semantics(
              button: true,
              label: _companionOpen ? 'AI 旅伴，点按收起' : 'AI 旅伴',
              child: CompanionAvatarButton(
                onTap: () {
                  if (_companionOpen) {
                    _companionKey.currentState?.close();
                  } else {
                    setState(() => _companionOpen = true);
                    final c = ref.read(companionProvider);
                    c.setCardOpen(true);
                    c.updatePosition(_wgsLat, _wgsLng);
                  }
                },
              ),
            ),
          ),
          // Read-only badge (web / 展示模式). Enable debug mode to unlock
          // recording — see viewOnlyProvider (the backdoor).
          if (ref.watch(viewOnlyProvider))
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('只读 · 展示模式',
                        style: TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ),
              ),
            ),
          // Hint that appears once the user starts pinching at the zoom
          // floor, guiding them into the 3D globe.
          if (_atMinZoom && _zoomOutTries > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 90,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      kIsWeb
                          ? '🌐 再点「−」缩小 ${3 - _zoomOutTries} 次进入 3D 地球'
                          : '🌐 再捏合缩小 ${3 - _zoomOutTries} 次进入 3D 地球',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
          // ── AI 旅伴侧吸卡片：左缘滑入，悬浮在地图上；键盘弹出时跟随
          //    viewInsets 上移（Scaffold 不再 resize）。──
          if (_companionOpen)
            Positioned(
              // -6 让贴边侧的像素阶梯角滑出屏外，卡片看起来是“吸”在左缘的。
              left: -6,
              bottom: MediaQuery.of(context).viewInsets.bottom > 0
                  ? MediaQuery.of(context).viewInsets.bottom + 8
                  : 136,
              width: math.min(342.0, MediaQuery.of(context).size.width * 0.92),
              height: math.min(
                  470.0,
                  MediaQuery.of(context).size.height -
                      MediaQuery.of(context).padding.top -
                      56 -
                      (MediaQuery.of(context).viewInsets.bottom > 0
                          ? MediaQuery.of(context).viewInsets.bottom + 8
                          : 136)),
              child: CompanionCard(
                key: _companionKey,
                onClosed: () {
                  if (mounted) setState(() => _companionOpen = false);
                  ref.read(companionProvider).setCardOpen(false);
                },
              ),
            ),
          // ── 3D 热图模式：实时瓦片 3D 地图，全屏覆盖（FAB/底栏此时隐藏）。──
          if (_tiltCam != null && _tiltHeat != null)
            Positioned.fill(
              child: Heat3DView(
                initialCamera: _tiltCam!,
                heat: _tiltHeat!,
                onExit: _exitHeat3D,
              ),
            ),
        ],
      ),
    );
  }

  /// First-recording nudge — once per install, on Android only.
  /// Pops a soft dialog explaining the background-recording pitfalls
  /// and offering to take the user to the permission walkthrough.
  /// Skipped silently after the first acknowledgement so it never
  /// becomes nagware.
  Future<void> _maybeOfferPermissionWalkthrough() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('perm_walkthrough_offered_v1') == true) return;
    await prefs.setBool('perm_walkthrough_offered_v1', true);
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        icon: const Icon(Icons.shield_outlined),
        title: const Text('后台记录会被系统杀掉'),
        content: const Text(
          '安卓手机厂商默认会限制后台 App。如果你想锁屏 / 切后台后还能继续记录轨迹，'
          '需要授予「始终允许定位」、加入电池豁免、打开自启动开关。\n\n'
          '这一步只需要做一次。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('稍后')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('去设置')),
        ],
      ),
    );
    if (go == true && mounted) context.push('/permissions');
  }

  /// Read the live camera zoom, falling back to [fallback] before the map
  /// has rendered its first frame (reading `_mapCtrl.camera` then throws).
  double _safeZoom([double fallback = 16]) {
    try {
      return _mapCtrl.camera.zoom;
    } catch (_) {
      return fallback;
    }
  }

  /// Re-centre the camera on the user's current position. Keeps the current
  /// zoom unless [zoom] is given (the locate FAB passes a fixed zoom so a
  /// deliberate tap always frames the user nicely).
  void _recenterOnUser({double? zoom}) {
    if (_wgsLat == null || _wgsLng == null) return;
    _mapCtrl.move(_toDisplay(_wgsLat!, _wgsLng!), zoom ?? _safeZoom());
  }

  /// Fly the camera to the centre of a just-imported FOW region and clear the
  /// one-shot focus provider. Disarms follow so a live fix doesn't immediately
  /// yank the camera back off the imported area.
  void _consumeFogImportFocus(LatLng wgs) {
    _followCamera = false;
    final display = _toDisplay(wgs.latitude, wgs.longitude);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _mapCtrl.move(display, 10);
      } catch (_) {
        // Map controller not attached yet — safe to ignore; the user can
        // still pan there manually.
      }
    });
    ref.read(fogImportFocusProvider.notifier).state = null;
  }

  /// Fly to a place / visit picked on another page (timeline, stats).
  void _consumeMapFocus(({double lat, double lng, double zoom}) f) {
    _followCamera = false;
    final display = _toDisplay(f.lat, f.lng);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _mapCtrl.move(display, f.zoom);
      } catch (_) {}
    });
    ref.read(mapFocusProvider.notifier).state = null;
  }

  /// Called on every position update. While recording and follow is armed,
  /// the camera tracks the user. A no-op otherwise, so panning the map when
  /// not recording (or after a manual gesture) stays put.
  void _maybeFollowCamera() {
    if (!_followCamera) return;
    if (!ref.read(recordingActiveProvider)) return;
    _recenterOnUser();
  }

  Future<void> _gotoCurrent() async {
    // Tapping locate always restores the default centred-follow behaviour.
    if (!_followCamera) setState(() => _followCamera = true);
    if (_wgsLat != null && _wgsLng != null) {
      final display = _toDisplay(_wgsLat!, _wgsLng!);
      _mapCtrl.move(display, 16);
      return;
    }
    final pos = await ref.read(locationServiceProvider).currentOnce();
    if (pos != null) {
      final display = _toDisplay(pos.latitude, pos.longitude);
      _mapCtrl.move(display, 16);
    }
  }

  Future<void> _showNearbyJournals() async {
    if (_wgsLat == null || _wgsLng == null) {
      // Top toast so this doesn't dock to the bottom Scaffold and
      // hide the centred REC button. Same UX as "已开始记录" etc.
      // orange.shade700 配 TopToast 写死的白字只有 2.70:1，是这一轮里最糟的
      // 一处；toastWarning 同色相压深到 6.51:1。
      TopToast.show(context, '还没有位置',
          background: MapChrome.toastWarning);
      return;
    }
    final db = ref.read(dbProvider);
    final all = await db.recentJournal(limit: 200);
    // 5 km approximate filter using lat/lng deltas.
    final lat = _wgsLat!;
    final lng = _wgsLng!;
    const km5 = 0.045; // ~5 km
    final near = all
        .where((j) => (j.lat - lat).abs() < km5 && (j.lng - lng).abs() < km5)
        .toList()
      ..sort((a, b) {
        final da = (a.lat - lat).abs() + (a.lng - lng).abs();
        final db = (b.lat - lat).abs() + (b.lng - lng).abs();
        return da.compareTo(db);
      });
    if (!mounted) return;
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.55,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
                child: Row(
                  children: [
                    Icon(Icons.near_me_rounded,
                        size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('附近的旅行手账',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700)),
                          Text(
                              near.isEmpty
                                  ? '~5km 内暂无'
                                  : '~5km 内 ${near.length} 条',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('新建'),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        _quickNewJournal();
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: near.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('附近 5km 还没有手账'),
                            const SizedBox(height: 12),
                            FilledButton.tonalIcon(
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('在这里写下第一条'),
                              onPressed: () {
                                Navigator.pop(sheetCtx);
                                _quickNewJournal();
                              },
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        itemCount: near.length,
                        itemBuilder: (_, i) {
                          final j = near[i];
                          final distance =
                              haversineMeters(lat, lng, j.lat, j.lng);
                          return _JournalCard(
                            entry: j,
                            distanceMeters: distance,
                            onTap: () async {
                              Navigator.pop(context);
                              _mapCtrl.move(_toDisplay(j.lat, j.lng), 16);
                              await journal_ui.openJournalDetail(
                                  context, ref, j);
                              if (mounted) setState(_reloadJournalPins);
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Last computed profile stats — the sheet opens INSTANTLY with these and
  /// refreshes in place. Static so it survives map-screen rebuilds; the
  /// aggregate itself is additionally cached inside FogEngine.
  static ({double pct, double km2, int blocks, int journals, int layerCount})?
      _profileStatsCache;

  Future<({double pct, double km2, int blocks, int journals, int layerCount})>
      _loadProfileStats() async {
    final db = ref.read(dbProvider);
    final fog = ref.read(fogEngineProvider);
    final layers = await db.allLayers();
    final layerIds = layers.where((l) => l.visible).map((l) => l.id).toList();
    // ONE cached background-isolate aggregate powers both the global % and
    // the level XP (same number, different scale). The old code walked the
    // full fog table three times on the main isolate — seconds of frozen UI
    // after a big FOW import.
    const earthSurfaceKm2 = 510072000.0;
    final agg = await fog.computeAggregates(layerIds);
    // Block count for the stat tile via COUNT(*) — not a 45k-row fetch.
    final tileCountRow = layerIds.isEmpty
        ? null
        : await db.customSelect(
            'SELECT COUNT(*) AS c FROM fog_tiles '
            'WHERE zoom = ${FogEngine.tileZoom} '
            'AND layer_id IN (${layerIds.join(",")})',
          ).getSingle();
    final stats = (
      pct: (agg.globalKm2 / earthSurfaceKm2).clamp(0.0, 1.0),
      km2: agg.globalKm2,
      blocks: tileCountRow?.read<int>('c') ?? 0,
      journals: (await db.recentJournal(limit: 1000)).length,
      layerCount: layers.length,
    );
    _profileStatsCache = stats;
    return stats;
  }

  Future<void> _showStatsSheet(BuildContext context) async {
    // Kick the (possibly slow, first-run) aggregation off and open the sheet
    // IMMEDIATELY — the numbers stream in via the FutureBuilder below. The
    // old code awaited everything up front: first tap after a cold start sat
    // ~2-3 s on a frozen map ("首次点击旅人很卡").
    final statsFuture = _loadProfileStats();
    if (!context.mounted) return;
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      backgroundColor: const Color(0xFF1A2733),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (_) => SafeArea(
        // Wrap in Consumer so the avatar + name update live when the
        // user taps "更换" inside this very sheet — without a rebuild
        // it would only flip after the user closes & reopens.
        child: Consumer(builder: (sheetCtx, sheetRef, _) {
          final settings = sheetRef.watch(settingsProvider);
          return FutureBuilder<
              ({
                double pct,
                double km2,
                int blocks,
                int journals,
                int layerCount
              })>(
              future: statsFuture,
              initialData: _profileStatsCache,
              builder: (statsCtx, statsSnap) {
                final st = statsSnap.data;
                final lvl = _levelForArea(st?.km2 ?? 0);
                return _statsSheetBody(sheetCtx, sheetRef, settings, st, lvl);
              });
        }),
      ),
    );
  }

  Widget _statsSheetBody(
      BuildContext sheetCtx,
      WidgetRef sheetRef,
      AppSettings settings,
      ({double pct, double km2, int blocks, int journals, int layerCount})? st,
      dynamic lvl) {
    return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Semantics(
                      button: true,
                      // 一张头像 + 一枚相机小徽章，没有任何文字。
                      label: '更换头像',
                      child: GestureDetector(
                        onTap: () => _pickAvatarOnMap(sheetCtx, sheetRef),
                        // ExcludeSemantics 只包画面：包住 GestureDetector 会把
                        // tap 动作也排除，读屏就点不动了。
                        child: ExcludeSemantics(
                          child: Stack(
                            alignment: Alignment.bottomRight,
                            children: [
                              _SelfAvatar(
                                radius: 28,
                                b64: settings.avatarBase64,
                                seed: settings.selfPeerId ?? settings.displayName,
                              ),
                              // Tiny camera badge — same affordance pattern
                              // as common chat apps. Tapping anywhere on the
                              // avatar triggers the picker.
                              Container(
                                width: 20,
                                height: 20,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF26A69A),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.photo_camera_outlined,
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            button: true,
                            // 只有一支铅笔图标暗示可改，读屏听不见图标。
                            label: '昵称 ${settings.displayName}，点按修改',
                            child: GestureDetector(
                              onTap: () => _editDisplayName(sheetCtx, sheetRef),
                              // 只包画面，别包住 GestureDetector（见上）。
                              child: ExcludeSemantics(
                                child: Row(
                                  children: [
                                    Flexible(
                                      child: Text(settings.displayName,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 18,
                                              fontWeight: FontWeight.w600)),
                                    ),
                                    const SizedBox(width: 6),
                                    const Icon(Icons.edit_outlined,
                                        color: Colors.white54, size: 14),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Text(
                            st == null ? '探索者 Lv …' : '探索者 Lv ${lvl.level}',
                            style: const TextStyle(
                                color: Color(0xFFFFD54F),
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    if (settings.avatarBase64.isNotEmpty)
                      IconButton(
                        tooltip: '移除头像',
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.white60),
                        onPressed: () => sheetRef
                            .read(settingsProvider.notifier)
                            .update((p) => p.copyWith(avatarBase64: '')),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                // ── Level + progress to next level ──
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF26A69A), Color(0xFF00897B)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(st == null ? 'Lv …' : 'Lv ${lvl.level}',
                                style: PixelText.label.copyWith(
                                    fontSize: 14, color: Colors.white)),
                          ),
                          const Spacer(),
                          Text(
                            st == null
                                ? '计算中…'
                                : (lvl.remaining > 0
                                    ? '再探索 ${_fmtArea(lvl.remaining)} 升到 Lv ${lvl.level + 1}'
                                    : '已满级'),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      PixelBlockBar(
                        value: st == null ? 0.0 : lvl.progress,
                        cells: 20,
                        cellHeight: 8,
                        color: const Color(0xFFFFD54F),
                        emptyColor: Colors.white24,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        st == null
                            ? '正在统计探索面积…'
                            : 'Lv ${lvl.level}  ·  ${(lvl.progress * 100).toStringAsFixed(0)}%  ·  已探索 ${_fmtArea(st.km2)}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Text('已探索',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
                Text(
                  st == null ? '…' : '${(st.pct * 100).toStringAsFixed(10)} %',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                        child: _StatTile(
                            st == null ? '…' : '${st.blocks}', '迷雾区块')),
                    Expanded(
                        child: _StatTile(
                            st == null ? '…' : '${st.journals}', '手账数')),
                    Expanded(
                        child: _StatTile(
                            st == null ? '…' : '${st.layerCount}', '图层数')),
                  ],
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  icon: const Icon(Icons.public),
                  label: const Text('查看国家/行政区详情'),
                  onPressed: () {
                    Navigator.of(sheetCtx).pop();
                    if (mounted) context.push('/explore');
                  },
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    backgroundColor: const Color(0xFF26A69A),
                  ),
                ),
              ],
            ),
          );
  }

  /// Pick an avatar from gallery, downscaled to 256×256 JPEG. Stored as
  /// base64 in [AppSettings.avatarBase64] so it travels with the settings
  /// backup module and inlines into leaderboard entries.
  Future<void> _pickAvatarOnMap(BuildContext ctx, WidgetRef ref) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 70,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final b64 = base64.encode(bytes);
      // ~30 KB cap — anything bigger is going to bloat every leaderboard
      // gossip frame, so refuse rather than chain-degrade everyone.
      if (b64.length > 40000) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
              const SnackBar(content: Text('图片过大，请选择更小或更低质量的照片')));
        }
        return;
      }
      await ref
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(avatarBase64: b64));
    } catch (e, st) {
      // 这里是设置面板里的头像选择，不是地图本体：SnackBar 不会挤到
      // FAB/底栏，所以保持 SnackBar，还能带「重试」。
      if (ctx.mounted) {
        showFailure(ctx,
            action: '选择图片',
            error: e,
            stack: st,
            onRetry: () => _pickAvatarOnMap(ctx, ref));
      }
    }
  }

  Future<void> _editDisplayName(BuildContext ctx, WidgetRef ref) async {
    final ctrl =
        TextEditingController(text: ref.read(settingsProvider).displayName);
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) return;
    await ref
        .read(settingsProvider.notifier)
        .update((p) => p.copyWith(displayName: name));
  }

  void _showPinHideMenu(db_t.JournalEntry j) {
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text('隐藏这条手账气泡（"${j.title}"）'),
              onTap: () {
                Navigator.pop(sheetCtx);
                setState(() => _hiddenJournalIds.add(j.id));
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_rounded),
              title: const Text('隐藏全部手账气泡'),
              onTap: () {
                Navigator.pop(sheetCtx);
                setState(() => _allPinsHidden = true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _quickNewJournal() async {
    // Reuse the same editor as the 旅行手账 page so the user gets one
    // consistent journal-creation flow (title + rich text + media + EXIF
    // GPS) instead of two separate dialogs that go out of sync.
    final changed = await journal_ui.showJournalEditor(context, ref);
    if (changed && mounted) setState(_reloadJournalPins);
  }

  /// The actual journal-pin MarkerLayer at a given pin [scale]. Extracted so
  /// the zoom-bucketed wrapper can cache the whole subtree between bucket
  /// flips (pin thumbnails use Image.file — rebuilding them per frame was
  /// needless decode-cache churn).
  Widget _buildPinLayer(List<db_t.JournalEntry> list, double scale) {
    return MarkerLayer(
      markers: list.map((j) {
        final p = _toDisplay(j.lat, j.lng);
        return Marker(
          point: p,
          width: 44 * scale,
          height: 54 * scale,
          alignment: Alignment.bottomCenter,
          // Counter-rotate so the pin always stays upright
          // (tip pointing down) however the map is rotated.
          rotate: true,
          // 标签在 _JournalPin 里给（「手账：标题」）；这里补上「是颗按钮」与
          // 长按能做什么——长按菜单在视觉上没有任何提示。
          child: Semantics(
            button: true,
            onLongPressHint: '隐藏这条手账气泡',
            child: GestureDetector(
              onTap: () async {
                await journal_ui.openJournalDetail(context, ref, j);
                if (mounted) setState(_reloadJournalPins);
              },
              onLongPress: () => _showPinHideMenu(j),
              // Each pin is a blurred shadow + anti-aliased circular clip +
              // photo: cache its raster so panning only translates the layer
              // instead of re-painting every visible pin per frame.
              child: RepaintBoundary(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: _JournalPin(entry: j),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _onMapTap(LatLng latlng, int layerId) async {
    final fog = ref.read(fogEngineProvider);
    final db = ref.read(dbProvider);
    final wgs = _fromDisplay(latlng.latitude, latlng.longitude);
    final radius = ref.read(settingsProvider).fogPenRadius;
    if (_editMode == _EditMode.add) {
      // The visible trail is drawn from track_points, so a manual dab has
      // to insert a point (not just paint the fog bitmap) to show up. We
      // still reveal the fog bitmap so exploration stats stay correct.
      // Width = brush diameter so the dab renders at the brush radius.
      await db.insertManualPoint(
        lat: wgs.latitude,
        lng: wgs.longitude,
        layerId: layerId,
        width: radius * 2,
      );
      await fog.revealPoint(
        lat: wgs.latitude,
        lng: wgs.longitude,
        radiusMeters: radius,
        layerId: layerId,
      );
      ref.read(fogRefreshProvider.notifier).state++;
    } else if (_editMode == _EditMode.erase) {
      // Delete the actual track points under the brush — that's what the
      // render reads now — then clear the fog bitmap for stats. Without
      // the point delete the trail would just redraw on the next refresh.
      await db.erasePointsAround(wgs.latitude, wgs.longitude, radius);
      await fog.erase(
        lat: wgs.latitude,
        lng: wgs.longitude,
        radiusMeters: radius,
        layerId: layerId,
      );
      ref.read(fogRefreshProvider.notifier).state++;
    }
  }
}

enum _EditMode { none, add, erase }
