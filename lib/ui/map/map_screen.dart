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
import '../../app/providers.dart';
import '../../core/prefs.dart' show PeerOverrideX;
import '../../app/recording_controller.dart';
import '../../data/db/database.dart' as db_t show JournalEntry, TrackLayer;
import '../../models/models.dart';
import '../../services/geo/coord_converter.dart';
import '../../services/fog/fog_engine.dart';
import '../../services/group/group_service.dart';
import '../../services/group/group_sync_controller.dart';
import 'native_file_image_io.dart';
import '../../services/map/fog_layer.dart';
import '../../services/map/tile_providers.dart';
import '../journal/journal_screen.dart' as journal_ui;
import '../widgets/top_toast.dart';

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

  // Raw WGS-84 position — always stored in WGS-84
  double? _wgsLat;
  double? _wgsLng;
  /// Heading in degrees (0 = north, clockwise). Sourced from Geolocator
  /// when moving > a small threshold; null when stationary so the arrow
  /// collapses back to a plain dot.
  double? _heading;
  StreamSubscription<Position>? _posSub;

  // ─── Debug simulation ───
  bool _simActive = false;
  double _simLat = 30.6586;
  double _simLng = 104.0648;
  double _simBearing = 0; // degrees, 0=north
  Timer? _simTimer;
  static const _simStepMeters = 9.5; // ~1 FOW pixel per tick

  StreamSubscription<GroupMessage>? _groupMsgSub;

  // Cached journal-pin future: rebuilt only when entries change, so we don't
  // hit the DB on every map frame.
  Future<List<db_t.JournalEntry>>? _journalPinsFuture;
  int _journalPinsRev = 0;
  // Per-session hide state for journal pins. Not persisted — re-opens reset
  // to "all visible" so users don't lose track of where journals live.
  final Set<int> _hiddenJournalIds = {};
  bool _allPinsHidden = false;
  void _reloadJournalPins() {
    _journalPinsFuture =
        ref.read(dbProvider).recentJournal(limit: 100);
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
          _peerRefreshTimer =
              Timer.periodic(const Duration(seconds: 10), (_) {
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
        }
        _startLocationStream();
      } catch (_) {
        // GPS not available (e.g. web without permission) — use default center
        if (mounted) {
          setState(() {
            _wgsLat = _simLat;
            _wgsLng = _simLng;
          });
        }
      }
    });
  }

  void _startLocationStream() {
    try {
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3,
        ),
      ).listen(
        (pos) {
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
          });
          _publishDisplayPos();
        },
        onError: (_) {},
      );
    } catch (_) {
      // Geolocator stream not available on this platform
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _simTimer?.cancel();
    _groupMsgSub?.cancel();
    _groupPeerSub?.cancel();
    _peerRefreshTimer?.cancel();
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
    final cell =
        '${(_wgsLat! / 0.01).floor()},${(_wgsLng! / 0.01).floor()}';
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
    _feedSimToRecording(lat, lng);
  }

  void _simStep() {
    final dLat = _simStepMeters / 111320.0 * math.cos(_simBearing * math.pi / 180);
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
    // Use the EFFECTIVE active id so manual reveals also go to a visible
    // layer — see provider docs for the why.
    final activeLayerId = ref.watch(effectiveActiveLayerIdProvider);
    final visibleLayerIds = layersAsync.maybeWhen(
      data: (rows) => rows.where((l) => l.visible).map((l) => l.id).toList(),
      orElse: () => <int>[],
    );

    final LatLng? displayPos = (_wgsLat != null && _wgsLng != null)
        ? _toDisplay(_wgsLat!, _wgsLng!)
        : null;

    return Scaffold(
      extendBody: true,
      floatingActionButtonLocation:
          FloatingActionButtonLocation.centerDocked,
      floatingActionButton: _CenterRecFab(
        recording: recording,
        onTap: () async {
          final ctrl = ref.read(recordingControllerProvider);
          if (recording) {
            await ctrl.stop();
            if (mounted) TopToast.show(context, '已停止记录');
          } else {
            final err = await ctrl.start();
            if (mounted) {
              TopToast.show(
                context,
                err ?? '已开始记录，走动几步看看迷雾',
                background: err == null ? null : Colors.red.shade700,
              );
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
          FlutterMap(
            mapController: _mapCtrl,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 13,
              initialRotation: 0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onTap: (tapPos, latlng) => _onMapTap(latlng, activeLayerId),
              onLongPress: (kDebugMode || ref.read(settingsProvider).debugMode)
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
              buildTileLayer(
                provider: settings.mapProvider,
                style: settings.mapStyle,
                amapKey: settings.amapApiKey,
                googleKey: settings.googleMapKey,
                customOsmUrl: settings.customOsmTileUrl,
              ),
              if (visibleLayerIds.isNotEmpty)
                FogLayer(
                  engine: ref.read(fogEngineProvider),
                  db: ref.read(dbProvider),
                  layerIds: visibleLayerIds,
                  fogColor: Color(settings.fogColor),
                  fogOpacity: settings.fogOpacity,
                  trailRadiusMeters: settings.fogPenRadius,
                  refreshKey: fogRefresh,
                  mapProvider: settings.mapProvider,
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
                  builder: (_, snap) {
                    final list = (snap.data ?? const <db_t.JournalEntry>[])
                        .where((j) => !_hiddenJournalIds.contains(j.id))
                        .toList();
                    if (list.isEmpty) return const SizedBox.shrink();
                    return MarkerLayer(
                      markers: list.map((j) {
                        final p = _toDisplay(j.lat, j.lng);
                        return Marker(
                          point: p,
                          width: 48,
                          height: 58,
                          alignment: Alignment.bottomCenter,
                          child: GestureDetector(
                            onTap: () async {
                              final changed = await journal_ui
                                  .showJournalViewer(context, ref, j);
                              if (changed && mounted) {
                                setState(_reloadJournalPins);
                              }
                            },
                            onLongPress: () => _showPinHideMenu(j),
                            child: _JournalPin(entry: j),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
            ],
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
                  borderRadius: BorderRadius.circular(12),
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
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 8),
                        overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14),
                        activeTrackColor: Colors.white,
                        inactiveTrackColor:
                            Colors.white.withValues(alpha: 0.3),
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
          Positioned(
            right: 16,
            bottom: 110,
            child: Column(
              children: [
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
                _MapFab(
                  icon: Icons.my_location_rounded,
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
                  icon: _satellite
                      ? Icons.satellite_alt
                      : Icons.map_outlined,
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
                    final next = providers[(settings.mapProvider.index + 1) %
                        providers.length];
                    ref
                        .read(settingsProvider.notifier)
                        .update((p) => p.copyWith(mapProvider: next));
                  },
                ),
              ],
            ),
          ),
          // ── Top-center: REC pill when recording ──
          if (recording)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 0,
              right: 0,
              child: const Center(
                child: IgnorePointer(
                  child: _RecPill(),
                ),
              ),
            ),
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
                await ref.read(dbProvider).updateLayer(db_t.TrackLayer(
                      id: l.id,
                      uuid: l.uuid,
                      name: l.name,
                      colorValue: l.colorValue,
                      visible: !l.visible,
                      tag: l.tag,
                      createdAt: l.createdAt,
                    ));
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
          if ((kDebugMode || ref.watch(settingsProvider).debugMode) && _simActive)
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
          if ((kDebugMode || ref.watch(settingsProvider).debugMode) && !_simActive)
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
        ],
      ),
    );
  }

  Future<void> _gotoCurrent() async {
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('还没有位置')));
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
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.5,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('附近 ~5km 的旅行手账',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
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
                    ? const Center(
                        child: Text('附近还没有手账，点右上角"新建"立即创建'))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        itemCount: near.length,
                        itemBuilder: (_, i) {
                          final j = near[i];
                          final distance = _distanceMeters(
                              lat, lng, j.lat, j.lng);
                          return _JournalCard(
                            entry: j,
                            distanceMeters: distance,
                            onTap: () async {
                              Navigator.pop(context);
                              _mapCtrl.move(_toDisplay(j.lat, j.lng), 16);
                              final changed = await journal_ui
                                  .showJournalViewer(context, ref, j);
                              if (changed && mounted) {
                                setState(_reloadJournalPins);
                              }
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

  Future<void> _showStatsSheet(BuildContext context) async {
    final db = ref.read(dbProvider);
    final fog = ref.read(fogEngineProvider);
    final layers = await db.allLayers();
    final layerIds = layers.where((l) => l.visible).map((l) => l.id).toList();
    final pct = await fog.globalExplorationPercent(layerIds);
    final tiles = await db.fogTilesForLayers(layerIds, FogEngine.tileZoom);
    final journalCount = (await db.recentJournal(limit: 1000)).length;
    if (!context.mounted) return;
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      backgroundColor: const Color(0xFF1A2733),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        // Wrap in Consumer so the avatar + name update live when the
        // user taps "更换" inside this very sheet — without a rebuild
        // it would only flip after the user closes & reopens.
        child: Consumer(builder: (sheetCtx, sheetRef, _) {
          final settings = sheetRef.watch(settingsProvider);
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
                            onTap: () =>
                                _editDisplayName(sheetCtx, sheetRef),
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
                            '等级 ${(pct * 100000).toInt().clamp(1, 999)}',
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 12),
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
                const SizedBox(height: 20),
                const Text('已探索',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
                Text(
                  '${(pct * 100).toStringAsFixed(10)} %',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                        child: _StatTile('${tiles.length}', '迷雾区块')),
                    Expanded(child: _StatTile('$journalCount', '手账数')),
                    Expanded(
                        child: _StatTile('${layers.length}', '图层数')),
                  ],
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  icon: const Icon(Icons.public),
                  label: const Text('查看国家/行政区详情'),
                  onPressed: () {
                    Navigator.pop(context);
                    context.push('/explore');
                  },
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    backgroundColor: const Color(0xFF26A69A),
                  ),
                ),
              ],
            ),
          );
        }),
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
          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
              content: Text('图片过大，请选择更小或更低质量的照片')));
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
    final ctrl = TextEditingController(
        text: ref.read(settingsProvider).displayName);
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

  Future<void> _onMapTap(LatLng latlng, int layerId) async {
    final fog = ref.read(fogEngineProvider);
    final wgs = _fromDisplay(latlng.latitude, latlng.longitude);
    final radius = ref.read(settingsProvider).fogPenRadius;
    if (_editMode == _EditMode.add) {
      await fog.revealPoint(
        lat: wgs.latitude,
        lng: wgs.longitude,
        radiusMeters: radius,
        layerId: layerId,
      );
      ref.read(fogRefreshProvider.notifier).state++;
    } else if (_editMode == _EditMode.erase) {
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
        borderRadius: BorderRadius.circular(16),
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
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
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
    return Material(
      elevation: 3,
      shape: const CircleBorder(),
      color: active ? (activeColor ?? Colors.blue) : const Color(0xFF1A2733),
      child: InkWell(
        customBorder: const CircleBorder(),
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
    final paths = entry.mediaPaths
        .split('\n')
        .where((p) => p.isNotEmpty)
        .toList();
    final preview = _previewText(entry.richContent);
    final distLabel = distanceMeters < 1000
        ? '${distanceMeters.toStringAsFixed(0)} m'
        : '${(distanceMeters / 1000).toStringAsFixed(1)} km';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
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
                  borderRadius: BorderRadius.circular(8),
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
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.book_outlined, size: 28),
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
                          decoration: BoxDecoration(
                            color: const Color(0xFF26A69A).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
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
      shape: const CircularNotchedRectangle(),
      notchMargin: 8,
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
    return InkResponse(
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
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: Color(0xFF4CAF50),
                      shape: BoxShape.circle,
                    ),
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
    final color = widget.recording ? Colors.red.shade700 : const Color(0xFF26A69A);
    return SizedBox(
      width: 64,
      height: 64,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) {
          final t = widget.recording ? _pulse.value : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (widget.recording)
                Container(
                  width: 64 + t * 16,
                  height: 64 + t * 16,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18 * (1 - t)),
                    shape: BoxShape.circle,
                  ),
                ),
              child!,
            ],
          );
        },
        child: Material(
          shape: const CircleBorder(),
          color: color,
          elevation: 6,
          shadowColor: color.withValues(alpha: 0.5),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: widget.onTap,
            child: SizedBox(
              width: 60,
              height: 60,
              child: Icon(
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
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: Colors.white60, fontSize: 11)),
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
              border: Border.all(
                  color: stale ? Colors.grey : shown, width: 3),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 6),
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

class _RecPill extends StatelessWidget {
  const _RecPill();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.red.shade700.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.red.withValues(alpha: 0.4),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, color: Colors.white, size: 10),
          SizedBox(width: 6),
          Text('REC',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5)),
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
    final firstImage = entry.mediaPaths
        .split('\n')
        .where((p) => p.isNotEmpty)
        .where((p) {
      final l = p.toLowerCase();
      return !(l.endsWith(".mp4") ||
          l.endsWith(".mov") ||
          l.endsWith(".mkv"));
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
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 4),
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
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _showMenu(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Color(active.colorValue),
                  shape: BoxShape.circle,
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
      builder: (sheetCtx) => SafeArea(
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
            ...layers.map((l) => ListTile(
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
                          fontWeight: l.id == activeId
                              ? FontWeight.w700
                              : FontWeight.w500)),
                  subtitle: Text(l.id == activeId ? '★ 当前活动图层' : ''),
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
                )),
          ],
        ),
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
