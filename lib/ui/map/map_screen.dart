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
import '../../core/prefs.dart' show AppSettings, PeerOverrideX;
import '../../app/recording_controller.dart';
import '../../data/db/database.dart' as db_t show JournalEntry, TrackLayer;
import '../../models/models.dart';
import '../../services/geo/coord_converter.dart';
import '../../services/fog/fog_engine.dart';
import '../../services/group/group_service.dart';
import '../../services/group/group_sync_controller.dart';
import 'native_file_image_io.dart';
import '../../services/map/fog_tile_provider.dart';
import '../../services/map/tile_providers.dart';
import '../common/pixel.dart';
import '../companion/companion_card.dart';
import '../journal/journal_screen.dart' as journal_ui;
import '../import/track_import_flow.dart';
import '../widgets/top_toast.dart';

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

class _MapScreenState extends ConsumerState<MapScreen> {
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
          // Trigger marker re-render every 10s so "stale > 30s" visuals update
          // even when no new peer message arrives.
          _peerRefreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
            final cur = ref.read(groupPeersProvider);
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

  void _startLocationStream() {
    _posSub?.cancel();
    try {
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3,
        ),
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
    // 常驻看门狗：流“假活”（订阅还在但再无回调）时兜底。90s 无 fix →
    // 重订流 + 主动补一发 currentOnce，让 pin 立刻回来。
    _locWatchdog ??= Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!mounted || _simActive || kIsWeb) return;
      final stale = _accuracyAt == null ||
          DateTime.now().difference(_accuracyAt!) >
              const Duration(seconds: 90);
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
      floatingActionButton: _CenterRecFab(
        recording: recording,
        onTap: () async {
          final ctrl = ref.read(recordingControllerProvider);
          if (recording) {
            await ctrl.stop();
            if (mounted) TopToast.show(context, '已停止记录');
          } else {
            final err = await ctrl.start();
            if (!mounted) return;
            if (err == null) {
              // Each fresh recording starts in centred-follow mode and snaps
              // the camera onto the user, regardless of where they'd panned.
              setState(() => _followCamera = true);
              _recenterOnUser(zoom: 16);
            }
            TopToast.show(
              context,
              err ?? '已开始记录，走动几步看看迷雾',
              background: err == null ? null : Colors.red.shade700,
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
      bottomNavigationBar: _BottomNav(
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
                    setState(() => _mapRotation = e.camera.rotation);
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
          if (_editMode != _EditMode.none)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                decoration: BoxDecoration(
                  color: (_editMode == _EditMode.erase
                          ? Colors.redAccent
                          : const Color(0xFF26A69A))
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
                _MapFab(icon: Icons.add_rounded, onTap: () => _zoomBy(1)),
                const SizedBox(height: 10),
                _MapFab(
                  icon: Icons.remove_rounded,
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
                    active: _editMode == _EditMode.erase,
                    activeColor: Colors.redAccent,
                    onTap: () => setState(() => _editMode =
                        _editMode == _EditMode.erase
                            ? _EditMode.none
                            : _EditMode.erase),
                  ),
                  const SizedBox(height: 10),
                  _MapFab(
                    icon: Icons.add_location_alt_rounded,
                    active: _editMode == _EditMode.add,
                    activeColor: const Color(0xFF26A69A),
                    onTap: () => setState(() => _editMode =
                        _editMode == _EditMode.add
                            ? _EditMode.none
                            : _EditMode.add),
                  ),
                  const SizedBox(height: 10),
                  // Import record points from photos' GPS — lights up the trail
                  // at each picked photo's location. Same flow as the layers
                  // page; lives here so it's reachable from the home map too.
                  Tooltip(
                    message: '从照片定位点亮记录点',
                    child: _MapFab(
                      icon: Icons.add_photo_alternate_rounded,
                      onTap: () => TrackImportFlow.fromPhotos(context, ref),
                    ),
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
                  },
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
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .update((p) => p.copyWith(darkMap: !p.darkMap)),
                ),
                // Rotation lock toggle — lives in the existing top-left chip
                // row so it doesn't cover any other control. Default state
                // (off) shows a "locked" icon; tapping enables two-finger
                // rotation.
                _MapChip(
                  icon: settings.allowMapRotation
                      ? Icons.screen_rotation_rounded
                      : Icons.screen_lock_rotation_rounded,
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
            child: Tooltip(
              message: (_allPinsHidden || _hiddenJournalIds.isNotEmpty)
                  ? '恢复显示手账气泡'
                  : '隐藏全部手账气泡',
              child: _MapFab(
                icon: (_allPinsHidden || _hiddenJournalIds.isNotEmpty)
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
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
      TopToast.show(context, '还没有位置', background: Colors.orange.shade700);
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
                              _distanceMeters(lat, lng, j.lat, j.lng);
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
                    GestureDetector(
                      onTap: () => _pickAvatarOnMap(sheetCtx, sheetRef),
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
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap: () => _editDisplayName(sheetCtx, sheetRef),
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
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx)
            .showSnackBar(SnackBar(content: Text('选择图片失败：$e')));
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
          child: GestureDetector(
            onTap: () async {
              await journal_ui.openJournalDetail(context, ref, j);
              if (mounted) setState(_reloadJournalPins);
            },
            onLongPress: () => _showPinHideMenu(j),
            child: FittedBox(
              fit: BoxFit.contain,
              child: _JournalPin(entry: j),
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

// ─── Simulation control panel (debug only) ───

class _SimPanel extends StatelessWidget {
  final double bearing;
  final bool walking;
  final VoidCallback onStep;
  final ValueChanged<double> onBearingChanged;
  final VoidCallback onToggleWalk;
  final VoidCallback onStop;

  const _SimPanel({
    required this.bearing,
    required this.walking,
    required this.onStep,
    required this.onBearingChanged,
    required this.onToggleWalk,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('SIM',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2)),
          const SizedBox(height: 4),
          // Direction pad
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dirBtn(Icons.north_west, 315),
              _dirBtn(Icons.north, 0),
              _dirBtn(Icons.north_east, 45),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dirBtn(Icons.west, 270),
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: Icon(
                    walking ? Icons.pause : Icons.play_arrow,
                    color: walking ? Colors.amber : Colors.white,
                  ),
                  onPressed: onToggleWalk,
                ),
              ),
              _dirBtn(Icons.east, 90),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dirBtn(Icons.south_west, 225),
              _dirBtn(Icons.south, 180),
              _dirBtn(Icons.south_east, 135),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 24,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onStop,
              child: const Text('关闭',
                  style: TextStyle(color: Colors.white54, fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dirBtn(IconData icon, double dir) {
    final active = (bearing - dir).abs() < 1 || (bearing - dir + 360).abs() < 1;
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: Icon(icon, color: active ? Colors.amber : Colors.white70),
        onPressed: () {
          onBearingChanged(dir);
          onStep();
        },
      ),
    );
  }
}

// ─── UI components ───

class _LocationDot extends StatelessWidget {
  final bool simulated;

  /// Degrees clockwise from north. Null → plain dot, no arrow.
  final double? heading;
  const _LocationDot({this.simulated = false, this.heading});

  @override
  Widget build(BuildContext context) {
    final color = simulated ? Colors.deepPurple : const Color(0xFF26A69A);
    return Stack(
      alignment: Alignment.center,
      children: [
        // Translucent precision halo.
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
        ),
        // Heading arrow — small triangle pointing in motion direction.
        // Sits outside the dot so it's visible against any background.
        if (heading != null)
          Transform.rotate(
            angle: heading! * math.pi / 180,
            // Translate the arrow above center BEFORE rotation so it
            // orbits the dot in the heading direction.
            child: Transform.translate(
              offset: const Offset(0, -16),
              child: CustomPaint(
                size: const Size(14, 10),
                painter: _ArrowPainter(color: color),
              ),
            ),
          ),
        // Solid inner dot.
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 4,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MapChip extends StatelessWidget {
  final IconData icon;
  final String? label;
  final VoidCallback onTap;
  const _MapChip({required this.icon, this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: label != null ? 10 : 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: Colors.white),
                if (label != null) ...[
                  const SizedBox(width: 4),
                  Text(label!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapFab extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color? activeColor;
  final VoidCallback onTap;
  const _MapFab({
    required this.icon,
    this.active = false,
    this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Hard-cornered square stack — the pixel take on map controls (the round
    // dots on the map itself keep their physical meaning; chrome goes 8-bit).
    return Material(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      color: active ? (activeColor ?? Colors.blue) : const Color(0xFF1A2733),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

class _JournalCard extends StatelessWidget {
  final db_t.JournalEntry entry;
  final double distanceMeters;
  final VoidCallback onTap;
  const _JournalCard({
    required this.entry,
    required this.distanceMeters,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final paths =
        entry.mediaPaths.split('\n').where((p) => p.isNotEmpty).toList();
    final preview = _previewText(entry.richContent);
    final distLabel = distanceMeters < 1000
        ? '${distanceMeters.toStringAsFixed(0)} m'
        : '${(distanceMeters / 1000).toStringAsFixed(1)} km';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (paths.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: _Thumb(path: paths.first),
                  ),
                )
              else
                Container(
                  width: 72,
                  height: 72,
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.15),
                  child: Center(
                    child: PixelSprite(
                      rows: PixelSprites.book,
                      color: Theme.of(context).colorScheme.primary,
                      cell: 4,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          color: const Color(0xFF26A69A).withValues(alpha: 0.2),
                          child: Text(distLabel,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF26A69A),
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (preview.isNotEmpty)
                      Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      _formatTime(entry.time),
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.5)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _previewText(String richContent) {
    if (richContent.isEmpty) return '';
    if (richContent.trimLeft().startsWith('[')) {
      // Looks like a Quill delta JSON — extract insert strings.
      try {
        final dynamic d =
            (richContent.contains('"insert"') ? richContent : null);
        if (d != null) {
          final reg = RegExp(r'"insert"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"');
          return reg
              .allMatches(richContent)
              .map((m) => m.group(1) ?? '')
              .join(' ')
              .replaceAll(r'\n', ' ')
              .trim();
        }
      } catch (_) {}
    }
    return richContent;
  }

  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}

class _Thumb extends StatelessWidget {
  final String path;
  const _Thumb({required this.path});
  @override
  Widget build(BuildContext context) {
    final lower = path.toLowerCase();
    final isVideo = lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv');
    if (isVideo) {
      return Container(
        color: Colors.black26,
        alignment: Alignment.center,
        child: const Icon(Icons.play_circle, size: 28),
      );
    }
    if (path.startsWith('http')) {
      return Image.network(path,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image));
    }
    if (kIsWeb) {
      // No filesystem access on web — show generic icon.
      return Container(
        color: Colors.black12,
        alignment: Alignment.center,
        child: const Icon(Icons.image_outlined, size: 28),
      );
    }
    return NativeFileImage(path: path);
  }
}

// ════════════════════════════════════════════════════════════════════════
// FOW-style bottom nav bar with notched center cutout for the REC FAB.
// ════════════════════════════════════════════════════════════════════════

class _BottomNav extends ConsumerWidget {
  final VoidCallback onJournal;
  final VoidCallback onGroup;
  final VoidCallback onMusic;
  final VoidCallback onMenu;
  final VoidCallback onQuickNote;
  const _BottomNav({
    required this.onJournal,
    required this.onGroup,
    required this.onMusic,
    required this.onMenu,
    required this.onQuickNote,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(groupPeersProvider);
    final inGroup = (ref.watch(settingsProvider).groupId ?? '').isNotEmpty;
    return BottomAppBar(
      height: 64,
      // NO notch shape. CircularNotchedRectangle installs a _BottomAppBarClipper
      // that reads Scaffold.geometryOf() while recomputing its clip; during a
      // route transition a pointer hit-test can land between layout-invalidation
      // and the next paint, and that getter asserts "only during the paint
      // phase" → the framework exception seen on back-button transitions. With
      // no shape there is no clipper, so the race can't happen. The centre FAB
      // still docks over the bar; it just floats without the cut-out notch.
      padding: EdgeInsets.zero,
      color: const Color(0xFF0F1923).withValues(alpha: 0.95),
      elevation: 12,
      child: Row(
        children: [
          Expanded(
            child: _NavItem(
              icon: Icons.menu_book_rounded,
              label: '附近手账',
              onTap: onJournal,
              onLongPress: onQuickNote,
            ),
          ),
          Expanded(
            child: _NavItem(
              icon: Icons.groups_rounded,
              label: inGroup ? '${peers.length + 1} 人' : '组队',
              onTap: onGroup,
              badge: peers.isNotEmpty,
            ),
          ),
          const SizedBox(width: 72), // space for center FAB
          Expanded(
            child: _NavItem(
              icon: Icons.music_note_rounded,
              label: '歌单',
              onTap: onMusic,
            ),
          ),
          Expanded(
            child: _NavItem(
              icon: Icons.apps_rounded,
              label: '更多',
              onTap: onMenu,
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool badge;
  const _NavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.badge = false,
  });
  @override
  Widget build(BuildContext context) {
    final core = InkResponse(
      onTap: onTap,
      onLongPress: onLongPress,
      radius: 36,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, color: Colors.white.withValues(alpha: 0.92), size: 22),
              if (badge)
                Positioned(
                  right: -3,
                  top: -3,
                  child: Container(
                    width: 6,
                    height: 6,
                    color: const Color(0xFF4CAF50),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 10,
                fontWeight: FontWeight.w500,
              )),
        ],
      ),
    );
    // Surface the hidden long-press action via a long-press tooltip.
    return onLongPress == null
        ? core
        : Tooltip(message: '长按可快速新建手账', child: core);
  }
}

// ════════════════════════════════════════════════════════════════════════
// Center docked REC FAB with pulsing animation while recording.
// ════════════════════════════════════════════════════════════════════════

class _CenterRecFab extends StatefulWidget {
  final bool recording;
  final VoidCallback onTap;
  const _CenterRecFab({required this.recording, required this.onTap});
  @override
  State<_CenterRecFab> createState() => _CenterRecFabState();
}

class _CenterRecFabState extends State<_CenterRecFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.recording ? Colors.red.shade700 : const Color(0xFF26A69A);
    return SizedBox(
      width: 64,
      height: 64,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) {
          // Pulse steps through 4 discrete sizes — a sprite-sheet blink, not
          // a smooth breath. (0 when idle.)
          final t = widget.recording
              ? (_pulse.value * 4).floorToDouble() / 4
              : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (widget.recording)
                Container(
                  width: 64 + t * 16,
                  height: 64 + t * 16,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18 * (1 - t)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              child!,
            ],
          );
        },
        child: Material(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          color: color,
          elevation: 6,
          shadowColor: color.withValues(alpha: 0.5),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: SizedBox(
              width: 60,
              height: 60,
              child: Icon(
                // Media semantics stay standard: dot = record, square = stop.
                widget.recording
                    ? Icons.stop_rounded
                    : Icons.fiber_manual_record_rounded,
                color: Colors.white,
                size: widget.recording ? 30 : 32,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Profile chip top-right + expanded stats sheet (FOW continent card style)
// ════════════════════════════════════════════════════════════════════════

class _ProfileCard extends ConsumerWidget {
  final VoidCallback onTap;
  const _ProfileCard({required this.onTap});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              _SelfAvatar(
                radius: 16,
                b64: s.avatarBase64,
                seed: s.selfPeerId ?? s.displayName,
              ),
              const SizedBox(width: 8),
              Text(s.displayName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more_rounded,
                  color: Colors.white70, size: 18),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String value;
  final String label;
  const _StatTile(this.value, this.label);
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          // Stats are collection numbers — pixel display face.
          Text(value,
              style: PixelText.label
                  .copyWith(fontSize: 16, color: Colors.white)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: Colors.white60, fontSize: 11)),
        ],
      ),
    );
  }
}

class _PeerTrailsLayer extends ConsumerWidget {
  final LatLng Function(double, double) toDisplay;
  const _PeerTrailsLayer({required this.toDisplay});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(groupPeersProvider);
    final trails = ref.watch(groupTrailsProvider);
    final s = ref.watch(settingsProvider);
    if (peers.isEmpty) return const SizedBox.shrink();
    final dots = <CircleMarker>[];
    final markers = <Marker>[];
    for (final p in peers) {
      if (!s.peerVisible(p.id)) continue;
      final color = Color(s.peerColor(p.id) ?? p.colorValue);
      final name = s.peerName(p.id) ?? p.name;
      // Each historical point becomes its own soft circle. No connecting
      // lines — the user's own track uses the same dot-with-blur look, and
      // straight polylines made GPS noise read as zig-zag teleports.
      // Older points fade towards transparent so the trail still has a
      // visual sense of direction.
      final hist = trails[p.id] ?? const [];
      final n = hist.length;
      for (int i = 0; i < n; i++) {
        final age = 1 - (i / n); // 0 = newest, 1 = oldest
        final c = hist[i];
        dots.add(CircleMarker(
          point: toDisplay(c[0], c[1]),
          radius: 6,
          color: color.withValues(alpha: 0.18 * (1 - age)),
          borderColor: color.withValues(alpha: 0.45 * (1 - age)),
          borderStrokeWidth: 1,
          useRadiusInMeter: false,
        ));
      }
      if (p.lat != null && p.lng != null) {
        // Look up the peer's avatar from the leaderboard — entries are
        // signed snapshots that travel on the same mesh as locations, so
        // by the time a peer is on the map their avatar (if they set
        // one) is already in our local store. Self peers won't be here
        // but they're not rendered as remote markers anyway.
        final lbEntries = ref.read(leaderboardServiceProvider).current;
        final entry = lbEntries.where((e) => e.peerId == p.id).firstOrNull;
        markers.add(Marker(
          point: toDisplay(p.lat!, p.lng!),
          width: 44,
          height: 44,
          child: _PeerMarker(
            peer: p,
            color: color,
            name: name,
            avatarB64: entry?.avatarBase64 ?? '',
          ),
        ));
      }
    }
    return Stack(
      children: [
        if (dots.isNotEmpty) CircleLayer(circles: dots),
        if (markers.isNotEmpty) MarkerLayer(markers: markers),
      ],
    );
  }
}

class _PeerMarker extends StatelessWidget {
  final GroupPeer peer;
  final Color color;
  final String name;
  final String avatarB64;
  const _PeerMarker(
      {required this.peer,
      required this.color,
      required this.name,
      this.avatarB64 = ''});
  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name.characters.first;
    final age = DateTime.now().difference(peer.lastSeen);
    final stale = age > const Duration(seconds: 30);
    final base = color;
    final shown = stale ? base.withValues(alpha: 0.45) : base;
    // Decode the avatar lazily — bad base64 silently falls back to the
    // coloured-initial bubble so a malformed peer entry can't crash the
    // map render path.
    DecorationImage? avatarImg;
    if (avatarB64.isNotEmpty) {
      try {
        avatarImg = DecorationImage(
          image: MemoryImage(base64.decode(avatarB64)),
          fit: BoxFit.cover,
        );
      } catch (_) {}
    }
    return Tooltip(
      message: stale ? '$name · ${age.inSeconds}s 未联系' : name,
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Container(
            decoration: BoxDecoration(
              color: avatarImg == null ? shown : null,
              image: avatarImg,
              shape: BoxShape.circle,
              border: Border.all(color: stale ? Colors.grey : shown, width: 3),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4), blurRadius: 6),
              ],
            ),
            alignment: Alignment.center,
            child: avatarImg != null
                ? null
                : Text(initial,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
          ),
          if (!stale)
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// Map pin for a journal entry: a small thumbnail (first media image if any,
/// otherwise an icon) on top of a teardrop tail. Tapped via the enclosing
/// GestureDetector to open the read-only viewer.
class _JournalPin extends StatelessWidget {
  final db_t.JournalEntry entry;
  const _JournalPin({required this.entry});

  @override
  Widget build(BuildContext context) {
    final firstImage =
        entry.mediaPaths.split('\n').where((p) => p.isNotEmpty).where((p) {
      final l = p.toLowerCase();
      return !(l.endsWith(".mp4") || l.endsWith(".mov") || l.endsWith(".mkv"));
    }).firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35), blurRadius: 4),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: firstImage == null
              ? Container(
                  color: const Color(0xFFFF8A65),
                  alignment: Alignment.center,
                  child: const Icon(Icons.menu_book_rounded,
                      color: Colors.white, size: 20),
                )
              : Image.file(
                  File(firstImage),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFFFF8A65),
                    alignment: Alignment.center,
                    child: const Icon(Icons.menu_book_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
        ),
        // Tail
        CustomPaint(
          size: const Size(12, 8),
          painter: _PinTailPainter(),
        ),
      ],
    );
  }
}

/// Rebuild-limiter for camera-scaled layers: subscribes to the camera (so its
/// own build runs per frame) but only re-runs [builder] — and thus rebuilds
/// the child subtree — when the zoom crosses a 1/[buckets] step. Pan and
/// sub-bucket zoom return the cached child untouched.
class _ZoomBucketed extends StatefulWidget {
  final int buckets;
  final Widget Function(BuildContext, double zoomBucket) builder;
  const _ZoomBucketed({required this.buckets, required this.builder});

  @override
  State<_ZoomBucketed> createState() => _ZoomBucketedState();
}

class _ZoomBucketedState extends State<_ZoomBucketed> {
  double? _bucket;
  Widget? _cached;

  @override
  Widget build(BuildContext context) {
    final z = MapCamera.of(context).zoom;
    final b = (z * widget.buckets).round() / widget.buckets;
    if (b != _bucket || _cached == null) {
      _bucket = b;
      _cached = widget.builder(context, b);
    }
    return _cached!;
  }
}

class _PinTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Removed: _FogDiagBadge corner overlay. Diagnostics now live in the
// debug screen so they don't overlap the map style button. Stub kept to
// silence stale references — if Dart's tree-shaker complains, delete.
// ignore: unused_element
class _FogDiagBadge extends StatelessWidget {
  const _FogDiagBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      child: const Text(
        '',
        style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Small chip on the top-left of the map. Shows the active layer's name
/// and color, and pops a menu of all layers — tap to set active, eye icon
/// to toggle visibility, "管理…" to jump to the layers screen.
class _LayerChip extends StatelessWidget {
  final int activeId;
  final List<db_t.TrackLayer> layers;
  final ValueChanged<int> onSelectActive;
  final ValueChanged<db_t.TrackLayer> onToggleVisible;
  final VoidCallback onManage;
  const _LayerChip({
    required this.activeId,
    required this.layers,
    required this.onSelectActive,
    required this.onToggleVisible,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    // Bail with a neutral placeholder if layers haven't loaded yet.
    if (layers.isEmpty) {
      return const SizedBox.shrink();
    }
    final active = layers.firstWhere(
      (l) => l.id == activeId,
      orElse: () => layers.first,
    );
    return Material(
      elevation: 3,
      color: const Color(0xFF1A2733),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => _showMenu(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 像素方块色标（图层颜色钥匙），与首页分组色标同语言。
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Color(active.colorValue),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                active.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              const Icon(Icons.expand_more_rounded,
                  color: Colors.white, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      // The sheet is a separate route built ONCE; a plain snapshot of `layers`
      // never repaints when the eye toggles the DB. Watch the providers here so
      // the visibility icon (and the ★ active marker) flip live on tap.
      builder: (sheetCtx) => Consumer(
        builder: (ctx, ref, _) {
          final liveLayers = ref.watch(layersProvider).value ?? layers;
          final liveActive = ref.watch(activeLayerIdProvider);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(children: [
                    const Text('图层',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.tune_rounded, size: 16),
                      label: const Text('管理…'),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        onManage();
                      },
                    ),
                  ]),
                ),
                const Divider(height: 1),
                // Scrollable + height-capped: with many layers (e.g. after a
                // multi-layer import / recovery) a plain Column overflowed the
                // sheet ("RenderFlex overflowed by 463 pixels").
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final l in liveLayers)
                        ListTile(
                          leading: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: Color(l.colorValue),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.black12),
                            ),
                          ),
                          title: Text(l.name,
                              style: TextStyle(
                                  fontWeight: l.id == liveActive
                                      ? FontWeight.w700
                                      : FontWeight.w500)),
                          subtitle: Text(l.id == liveActive ? '★ 当前活动图层' : ''),
                          trailing: IconButton(
                            icon: Icon(l.visible
                                ? Icons.visibility
                                : Icons.visibility_off_outlined),
                            onPressed: () {
                              onToggleVisible(l);
                            },
                          ),
                          onTap: () {
                            onSelectActive(l.id);
                            Navigator.pop(sheetCtx);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  _ArrowPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = ui.Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width / 2, size.height * 0.7)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
    final outline = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(path, outline);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) => old.color != color;
}

/// Circular avatar used in the map's profile sheet. Same fallback logic
/// the leaderboard + peer markers use, so the user looks identical
/// everywhere.
class _SelfAvatar extends StatelessWidget {
  final double radius;
  final String b64;
  final String seed;
  const _SelfAvatar(
      {required this.radius, required this.b64, required this.seed});
  @override
  Widget build(BuildContext context) {
    if (b64.isNotEmpty) {
      try {
        return CircleAvatar(
          radius: radius,
          backgroundImage: MemoryImage(base64.decode(b64)),
        );
      } catch (_) {}
    }
    final hue = (seed.hashCode % 360).abs().toDouble();
    return CircleAvatar(
      radius: radius,
      backgroundColor: HSLColor.fromAHSL(1, hue, 0.55, 0.55).toColor(),
      child: Text(
        seed.isEmpty ? '?' : seed.characters.first.toUpperCase(),
        style: TextStyle(
            color: Colors.white,
            fontSize: radius * 0.8,
            fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Vector polyline overlay for the user's own tracks. Reads track points
/// for every visible layer, splits them into "sessions" on long temporal
/// gaps (so today's points don't get joined to last week's), and emits
/// one `Polyline` per session.
///
/// Why this exists: the FOW fog bitmap stores ~9.5 m / pixel which looks
/// blocky and jagged at any zoom above the storage resolution. Drawing
/// the real trail vector on top of it gives the smooth diagonal /
/// curved trace the user wants, without changing the storage schema.
///
/// Re-queried whenever [refreshKey] changes — the recording controller
/// bumps that counter (debounced to 250 ms) every time it writes new
/// samples. The whole result is memoised on (layerIds, refreshKey) via a
/// cached FutureBuilder so panning the map doesn't re-hit the DB.

/// Live GPS signal indicator. Shows fix quality + accuracy distance,
/// or a clear "no fix" state when the OS hasn't reported anything
/// recently. Users would otherwise have no idea why the trail isn't
/// moving — especially indoors where the OS silently stops reporting.
class _SignalChip extends StatefulWidget {
  final double? accuracyMeters;
  final DateTime? reportedAt;
  const _SignalChip({required this.accuracyMeters, required this.reportedAt});
  @override
  State<_SignalChip> createState() => _SignalChipState();
}

class _SignalChipState extends State<_SignalChip> {
  /// Map the LAST KNOWN fix accuracy to "bars" (1-4) + colour.
  ///
  /// Signal strength depends ONLY on whether the GPS can produce a fix and
  /// how accurate that fix is — NOT on how recently the position changed.
  /// A stationary user (or one whose distanceFilter suppresses identical
  /// updates) still has a perfectly good fix, so we no longer downgrade to
  /// "信号弱" just because no fresh sample arrived. "No fix at all" is the
  /// only no-signal state, and that's keyed off [reportedAt] being null.
  ({int bars, Color color, String label}) _classify() {
    if (widget.reportedAt == null) {
      return (bars: 0, color: Colors.grey, label: '无定位');
    }
    final acc = widget.accuracyMeters ?? 9999;
    if (acc <= 10)
      return (
        bars: 4,
        color: const Color(0xFF66BB6A),
        label: '强 · ±${acc.toStringAsFixed(0)} m'
      );
    if (acc <= 30)
      return (
        bars: 3,
        color: const Color(0xFFAED581),
        label: '良好 · ±${acc.toStringAsFixed(0)} m'
      );
    if (acc <= 80)
      return (
        bars: 2,
        color: const Color(0xFFFFB74D),
        label: '一般 · ±${acc.toStringAsFixed(0)} m'
      );
    return (
      bars: 1,
      color: const Color(0xFFE57373),
      label: '弱 · ±${acc.toStringAsFixed(0)} m'
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _classify();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: s.color.withValues(alpha: 0.6), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Four ascending bars; lit ones use the level colour.
          for (int i = 1; i <= 4; i++)
            Container(
              width: 3,
              height: 4.0 + i * 2.5,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: i <= s.bars
                    ? s.color
                    : Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          const SizedBox(width: 8),
          Text(
            s.label,
            style: TextStyle(
                color: s.color, fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Tiny circular compass — only shown when the map's been rotated
/// off-north. Tapping snaps the camera back to north-up.
class _CompassChip extends StatelessWidget {
  final double bearingDeg;
  final VoidCallback onTap;
  const _CompassChip({required this.bearingDeg, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: '回正北',
        child: Material(
          color: Colors.black.withValues(alpha: 0.55),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 32,
              height: 32,
              child: Transform.rotate(
                // flutter_map's `rotation` is degrees CCW; the compass
                // needle should point to true north, which is opposite
                // the camera rotation.
                angle: -bearingDeg * math.pi / 180.0,
                child: const Icon(
                  Icons.navigation_rounded,
                  color: Color(0xFFFF5252),
                  size: 18,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Exploration level derived from the total explored *path area* (km²).
/// Thresholds grow triangularly — reaching level L needs
/// `base · L·(L−1)/2` km² — so early levels come from a walk or two and
/// later ones take real exploring.
const double _kLevelBaseKm2 = 0.5; // km² for the first level-up

class _LevelInfo {
  final int level;
  final double progress; // 0..1 within the current level
  final double remaining; // km² still needed for the next level
  const _LevelInfo(this.level, this.progress, this.remaining);
}

_LevelInfo _levelForArea(double km2) {
  final a = km2 < 0 ? 0.0 : km2;
  double reqToReach(int l) => _kLevelBaseKm2 * l * (l - 1) / 2;
  var level = ((1 + math.sqrt(1 + 8 * a / _kLevelBaseKm2)) / 2).floor();
  if (level < 1) level = 1;
  final reqCur = reqToReach(level);
  final reqNext = reqToReach(level + 1);
  final span = reqNext - reqCur;
  final progress = span <= 0 ? 0.0 : ((a - reqCur) / span).clamp(0.0, 1.0);
  final remaining = (reqNext - a).clamp(0.0, reqNext);
  return _LevelInfo(level, progress.toDouble(), remaining.toDouble());
}

/// Format a km² area for display, dropping to m² when it's tiny so a short
/// trip doesn't read as "0.00 km²".
String _fmtArea(double km2) {
  if (km2 < 0.1) return '${(km2 * 1e6).toStringAsFixed(0)} m²';
  if (km2 < 100) return '${km2.toStringAsFixed(2)} km²';
  return '${km2.toStringAsFixed(0)} km²';
}
