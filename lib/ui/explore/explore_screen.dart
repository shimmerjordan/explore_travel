import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app/providers.dart';
import '../../data/iso_countries.dart';
import '../../data/iso_country_areas.dart';
import '../../models/models.dart';
import '../../services/fog/fog_engine.dart';
import '../../services/geo/admin_regions.dart';
import '../../services/geo/learned_regions.dart';
import '../../services/map/tile_providers.dart';
import '../common/atmosphere.dart';
import '../common/pixel.dart';

/// Exploration progress, organised by continent → country pixel grid.
///
/// Compared to the previous flat list, this version:
///   - lists every ISO-3166 country (via [kContinents]), not just the ones
///     present in the boundary asset. Countries with no boundary data show
///     as 0% but still appear in their continent's grid;
///   - groups by 7 continents with a header showing visited / total + an
///     aggregate progress bar;
///   - renders countries as small pixel-style colored squares (one per
///     country) — tap to expand details.
class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});
  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  // countryNameOrCode → percent in [0,1]
  final Map<String, double> _pct = {};
  // countryNameOrCode → optional region map for the country detail sheet
  final Map<String, Map<String, double>> _regionPct = {};
  double _globalPercent = 0;

  /// Weighted average per-country progress, weighted by real country area
  /// (km², from [kCountryAreasKm2]). Approximates "how much of Earth's
  /// actual land have I covered" without needing per-cell geocoding.
  double _landPercent = 0;

  /// Regions the geocoder has confirmed during real visits. Merged in
  /// "learned overrides bundled" semantics: if a region appears in both
  /// the bundled file and here, [_pct] is replaced by a learned-bbox
  /// progress estimate.
  List<LearnedRegion> _learned = const [];
  Map<String, double> _learnedRevealedKm2 = const {};
  bool _loading = true;

  /// Persisted result of the last full aggregation. Loading + aggregating
  /// ~46k fog rows takes the better part of a second — on every open, that
  /// was a full-screen spinner ("首次点击旅人很卡"). Now the last snapshot
  /// renders instantly and the fresh numbers replace it silently.
  static const _snapshotKey = 'explore_snapshot_v2';

  @override
  void initState() {
    super.initState();
    _restoreSnapshot().then((hit) => _loadAndCompute(silent: hit));
  }

  Future<bool> _restoreSnapshot() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_snapshotKey);
      if (raw == null) return false;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _pct
        ..clear()
        ..addAll((j['pct'] as Map).map(
            (k, v) => MapEntry(k.toString(), (v as num).toDouble())));
      _regionPct
        ..clear()
        ..addAll((j['regionPct'] as Map).map((k, v) => MapEntry(
            k.toString(),
            (v as Map).map(
                (k2, v2) => MapEntry(k2.toString(), (v2 as num).toDouble())))));
      _globalPercent = (j['global'] as num?)?.toDouble() ?? 0;
      _landPercent = (j['land'] as num?)?.toDouble() ?? 0;
      _learned = [
        for (final e in (j['learned'] as List? ?? const []))
          LearnedRegion.fromJson(e as Map<String, dynamic>)
      ];
      if (mounted) setState(() => _loading = false);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveSnapshot() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _snapshotKey,
          jsonEncode({
            'pct': _pct,
            'regionPct': _regionPct,
            'global': _globalPercent,
            'land': _landPercent,
            'learned': [for (final r in _learned) r.toJson()],
          }));
    } catch (_) {}
  }

  Future<void> _loadAndCompute({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    Map<String, dynamic>? data;
    try {
      final raw =
          await rootBundle.loadString('assets/boundaries/countries.json');
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}

    final fog = ref.read(fogEngineProvider);
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    final layerIds = layers.where((l) => l.visible).map((l) => l.id).toList();

    _pct.clear();
    _regionPct.clear();

    // Learned regions are needed up-front now: their bboxes ride along in
    // the same aggregate call instead of one full fog walk per province.
    _learned = await ref.read(learnedRegionsProvider).all();
    final learnedBboxes = <String,
        ({double minLat, double minLng, double maxLat, double maxLng})>{
      for (final r in _learned)
        if (r.province.isNotEmpty && r.city.isEmpty)
          'learned|${r.country}|${r.province}': (
            minLat: r.minLat,
            minLng: r.minLng,
            maxLat: r.maxLat,
            maxLng: r.maxLng,
          ),
    };

    // Build ONE flat (country|province → bbox) map and let the engine
    // attribute each revealed pixel to the SMALLEST containing bbox —
    // that's what avoids "Shanghai also counts for Jiangsu/Zhejiang"
    // when bundled rects overlap.
    if (data != null) {
      final countries = data['countries'] as Map<String, dynamic>;
      final regionBboxes = <String,
          ({double minLat, double minLng, double maxLat, double maxLng})>{};
      // For each country, register both the country-level bbox and each
      // of its sub-regions. Keys include a "kind|name" prefix so we can
      // tell them apart when reading back.
      for (final entry in countries.entries) {
        final country = entry.key;
        final payload = entry.value;
        final cbbox = (payload['bbox'] as List).cast<num>();
        regionBboxes['country|$country'] = (
          minLat: cbbox[0].toDouble(),
          minLng: cbbox[1].toDouble(),
          maxLat: cbbox[2].toDouble(),
          maxLng: cbbox[3].toDouble(),
        );
        final regions = payload['regions'] as Map<String, dynamic>? ?? {};
        for (final r in regions.entries) {
          final rb = (r.value['bbox'] as List).cast<num>();
          regionBboxes['prov|$country|${r.key}'] = (
            minLat: rb[0].toDouble(),
            minLng: rb[1].toDouble(),
            maxLat: rb[2].toDouble(),
            maxLng: rb[3].toDouble(),
          );
        }
      }

      // ONE DB walk for everything. Cell-level smallest-bbox dedup means
      // each revealed cell counts in at most one province AND at most one
      // country (which may differ! a cell at the border picks the
      // smallest province but its own country denominator is separate).
      // To get correct country totals we run the engine twice — once with
      // only country-level bboxes, once with only province-level. Province
      // dedup keeps adjacent provinces honest; country dedup is a no-op
      // for non-overlapping countries but still safe.
      final countryOnly = <String,
          ({double minLat, double minLng, double maxLat, double maxLng})>{
        for (final e in regionBboxes.entries)
          if (e.key.startsWith('country|')) e.key: e.value,
      };
      final provOnly = <String,
          ({double minLat, double minLng, double maxLat, double maxLng})>{
        for (final e in regionBboxes.entries)
          if (e.key.startsWith('prov|')) e.key: e.value,
      };
      // ONE aggregate call: country attribution + province attribution are
      // independent passes computed in the same isolate run over one fetch;
      // learned bboxes + the global number ride along too.
      const earthSurfaceKm2 = 510072000.0;
      final agg = await fog.computeAggregates(layerIds,
          regions: countryOnly, regions2: provOnly, bboxes: learnedBboxes);
      _globalPercent = (agg.globalKm2 / earthSurfaceKm2).clamp(0.0, 1.0);
      final countryKm2 = agg.regions;
      final provKm2 = agg.regions2;
      _learnedRevealedKm2 = agg.bboxes;

      for (final entry in countries.entries) {
        final country = entry.key;
        final payload = entry.value;
        final cbbox = (payload['bbox'] as List).cast<num>();
        final realArea = kCountryAreasKm2[country] ??
            FogEngine.bboxAreaKm2(cbbox[0].toDouble(), cbbox[1].toDouble(),
                cbbox[2].toDouble(), cbbox[3].toDouble());
        final got = countryKm2['country|$country'] ?? 0;
        _pct[country] = realArea <= 0 ? 0 : (got / realArea).clamp(0.0, 1.0);

        final regions = payload['regions'] as Map<String, dynamic>? ?? {};
        final regionMap = <String, double>{};
        for (final r in regions.entries) {
          final rb = (r.value['bbox'] as List).cast<num>();
          final rArea = FogEngine.bboxAreaKm2(rb[0].toDouble(),
              rb[1].toDouble(), rb[2].toDouble(), rb[3].toDouble());
          final pgot = provKm2['prov|$country|${r.key}'] ?? 0;
          regionMap[r.key] = rArea <= 0 ? 0 : (pgot / rArea).clamp(0.0, 1.0);
        }
        _regionPct[country] = regionMap;
      }
    }

    // No boundary asset? Still compute the global number + learned bboxes
    // in one aggregate pass.
    if (data == null) {
      const earthSurfaceKm2 = 510072000.0;
      final agg =
          await fog.computeAggregates(layerIds, bboxes: learnedBboxes);
      _globalPercent = (agg.globalKm2 / earthSurfaceKm2).clamp(0.0, 1.0);
      _learnedRevealedKm2 = agg.bboxes;
    }

    // Learned regions override bundled. Use each learned bbox as both
    // numerator scope AND denominator — the bbox grows as the user visits
    // more places, so % is "fraction of your personal bbox covered". For a
    // single-point visit, bbox ≈ a point ≈ near-zero area, giving a tiny
    // non-zero number rather than a fake 100%. Revealed km² per bbox was
    // already computed in the aggregate call above.
    for (final r in _learned) {
      if (r.province.isEmpty || r.city.isNotEmpty) continue; // province only
      final revealedKm2 =
          _learnedRevealedKm2['learned|${r.country}|${r.province}'] ?? 0;
      final bboxKm2 =
          FogEngine.bboxAreaKm2(r.minLat, r.minLng, r.maxLat, r.maxLng);
      final pct = bboxKm2 <= 0 ? 0.0 : (revealedKm2 / bboxKm2).clamp(0.0, 1.0);
      final m = _regionPct.putIfAbsent(r.country, () => {});
      m[r.province] = pct;
    }

    // Aggregate land progress: total revealed land km² / total known land
    // km². Honest, not weighted by per-country pct.
    double revealedSum = 0, knownArea = 0;
    for (final entry in kContinents.entries) {
      for (final c in entry.value) {
        final area = kCountryAreasKm2[c.name];
        if (area == null) continue;
        revealedSum += _lookupPct(c) * area;
        knownArea += area;
      }
    }
    _landPercent = knownArea > 0 ? revealedSum / knownArea : 0;

    if (mounted) setState(() => _loading = false);
    await _saveSnapshot();
  }

  double _lookupPct(CountryEntry e) {
    final byName = _pct[e.name];
    if (byName != null) return byName;
    for (final a in e.aliases) {
      final v = _pct[a];
      if (v != null) return v;
    }
    final byCode = _pct[e.code];
    if (byCode != null) return byCode;
    return 0;
  }

  Map<String, double>? _lookupRegions(CountryEntry e) {
    final byName = _regionPct[e.name];
    if (byName != null && byName.isNotEmpty) return byName;
    for (final a in e.aliases) {
      final v = _regionPct[a];
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final totalCountries =
        kContinents.values.fold<int>(0, (a, list) => a + list.length);
    final visitedCountries = kContinents.values
        .expand((l) => l)
        .where((e) => _lookupPct(e) > 0)
        .length;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('探索进度',
              style: PixelText.headline
                  .copyWith(color: Theme.of(context).colorScheme.onSurface)),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              // Silent: the page already shows the previous numbers —
              // refresh in place instead of blanking to a spinner.
              onPressed: () => _loadAndCompute(silent: true),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: '总览'),
            Tab(text: '点亮地图'),
          ]),
        ),
        body: TabBarView(
          children: [
            _buildOverview(visitedCountries, totalCountries),
            _LitMapTab(learned: _learned),
          ],
        ),
      ),
    );
  }

  Widget _buildOverview(int visitedCountries, int totalCountries) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(
          child: _GlobalCard(
            globalPercent: _globalPercent,
            landPercent: _landPercent,
            visited: visitedCountries,
            total: totalCountries,
          ),
        ),
        if (_learned.isNotEmpty)
          SliverToBoxAdapter(child: _LearnedRegionsCard(learned: _learned)),
        for (final entry in kContinents.entries)
          SliverToBoxAdapter(
            child: _ContinentSection(
              name: entry.key,
              countries: entry.value,
              pctOf: _lookupPct,
              regionsOf: _lookupRegions,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }
}

/// "点亮地图" — a map preview where every geocoder-confirmed city renders as
/// a lit administrative polygon (à la Fog of World's 点亮记录). Boundaries
/// are downloaded on demand for VISITED regions only and cached on disk;
/// the 更新 button re-syncs both the index and any missing boundaries.
class _LitMapTab extends ConsumerStatefulWidget {
  final List<LearnedRegion> learned;
  const _LitMapTab({required this.learned});
  @override
  ConsumerState<_LitMapTab> createState() => _LitMapTabState();
}

class _LitMapTabState extends ConsumerState<_LitMapTab>
    with AutomaticKeepAliveClientMixin {
  final _store = AdminRegionStore();
  AdminMapData? _data;
  bool _busy = false;
  String? _phase;

  /// Base-map override for THIS tab only. Amap has no useful rendering
  /// outside China, so foreign lit countries need Google / OSM.
  MapProvider? _providerOverride;

  // Keep the map alive across tab flips — reloading tiles on every switch
  // reads as jank.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _LitMapTab old) {
    super.didUpdateWidget(old);
    if (!identical(old.learned, widget.learned)) _load();
  }

  Future<List<LearnedRegion>> _learnedNow() async =>
      widget.learned.isNotEmpty
          ? widget.learned
          : await ref.read(learnedRegionsProvider).all();

  Future<void> _load() async {
    final learned = await _learnedNow();
    final d = await _store.load(learned);
    if (mounted) setState(() => _data = d);
  }

  /// Explored fog block centres (lat,lng pairs) — the "足迹经过" ground
  /// truth that lights regions up, whether or not the geocoder ever ran.
  Future<Float64List> _fogPoints() async {
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    final ids = layers.where((l) => l.visible).map((l) => l.id).toList();
    if (ids.isEmpty) return Float64List(0);
    final rows = await db.customSelect(
      'SELECT DISTINCT tile_x, tile_y FROM fog_tiles '
      'WHERE zoom = ${FogEngine.tileZoom} AND layer_id IN (${ids.join(",")})',
    ).get();
    const bw = FogEngine.bitmapWidth;
    final pts = Float64List(rows.length * 2);
    for (var i = 0; i < rows.length; i++) {
      final x = rows[i].read<int>('tile_x');
      final y = rows[i].read<int>('tile_y');
      pts[i * 2] = FogEngine.globalYToLat(y * bw + bw ~/ 2);
      pts[i * 2 + 1] = FogEngine.globalXToLng(x * bw + bw ~/ 2);
    }
    return pts;
  }

  Future<void> _update() async {
    setState(() {
      _busy = true;
      _phase = '统计足迹…';
    });
    String msg;
    try {
      msg = await _store.update(
          learned: await _learnedNow(),
          fogPoints: await _fogPoints(),
          onPhase: (p) {
        if (mounted) setState(() => _phase = p);
      });
    } catch (e) {
      msg = '更新失败：$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _phase = null;
    });
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(settingsProvider);
    final d = _data;
    if (d == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!d.hasIndex) {
      // First run: nothing downloaded yet.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 48, color: cs.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                '还没有行政区数据。\n下载后，真实走过的城市会在地图上点亮\n'
                '（只下载去过的地区，之后可随时更新）。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _update,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_rounded),
                label: Text(_busy ? (_phase ?? '下载中…') : '下载行政区数据'),
              ),
            ],
          ),
        ),
      );
    }

    const lit = Color(0xFF4DD0E1); // FOW-style lit cyan
    final provider = _providerOverride ?? s.mapProvider;
    final center = d.lit.isEmpty
        ? const LatLng(34.5, 108.0)
        : d.lit.first.center;
    // Major regions label first; the rest appear as you zoom in.
    final byArea = [...d.lit]
      ..sort((a, b) => b.areaScore.compareTo(a.areaScore));
    final major = byArea.take((byArea.length / 3).ceil()).toSet();
    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: d.lit.isEmpty ? 3.6 : 5.2,
            minZoom: 2.5,
            maxZoom: 12,
            backgroundColor: const Color(0xFF0B1620),
            interactionOptions: const InteractionOptions(
              // A stats-preview map: pinch/pan only, no rotation.
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            // Dark blue-grey base: dim enough that lit polygons glow, but
            // bright enough that coastlines/roads/labels stay readable
            // (the previous pass was near-black, "看不清底色").
            ColorFiltered(
              colorFilter: const ColorFilter.matrix([
                0.066, 0.222, 0.022, 0, 16, //
                0.066, 0.222, 0.022, 0, 22, //
                0.066, 0.222, 0.022, 0, 34, //
                0, 0, 0, 1, 0,
              ]),
              child: buildTileLayer(
                provider: provider,
                style: s.mapStyle,
                amapKey: s.amapApiKey,
                googleKey: s.googleMapKey,
                customOsmUrl: s.customOsmTileUrl,
              ),
            ),
            PolygonLayer(
              // NO runtime simplification: it runs per polygon, so two
              // neighbours' shared border simplifies differently and shows
              // gaps/overlap slivers. Rings are already grid-quantised in
              // the store (which preserves shared edges exactly), and the
              // zoom-jank fix is _ZoomGated below.
              simplificationTolerance: 0,
              polygons: [
                for (final r in d.lit)
                  for (final ring in r.rings)
                    Polygon(
                      points: ring,
                      color: lit.withValues(alpha: 0.34),
                      borderColor: lit,
                      borderStrokeWidth: 1.4,
                    ),
              ],
            ),
            // Labels rebuild ONLY when the 0.5-zoom bucket flips — the old
            // per-move setState rebuilt every polygon each frame (缩放特别卡).
            _ZoomGated(
              builder: (zoom) => zoom < 6.0
                  ? const SizedBox.shrink()
                  : MarkerLayer(
                      markers: [
                        for (final r in d.lit)
                          if (zoom >= 7.5 || major.contains(r))
                            Marker(
                              point: r.center,
                              width: 96,
                              height: 16,
                              child: IgnorePointer(
                                child: Text(
                                  r.name,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white70,
                                    shadows: [
                                      Shadow(
                                          blurRadius: 3, color: Colors.black),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                      ],
                    ),
            ),
          ],
        ),
        // Base-map switcher + update button — top row, above the map.
        Positioned(
          top: 10,
          right: 10,
          child: Row(
            children: [
              FilledButton.tonal(
                onPressed: () => setState(() {
                  _providerOverride = switch (provider) {
                    MapProvider.amap => MapProvider.google,
                    MapProvider.google => MapProvider.osm,
                    MapProvider.osm => MapProvider.amap,
                  };
                }),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12)),
                child: Text(
                    switch (provider) {
                      MapProvider.amap => '高德',
                      MapProvider.google => 'Google',
                      MapProvider.osm => 'OSM',
                    },
                    style: const TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _update,
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync_rounded, size: 16),
                label: Text(_busy ? (_phase ?? '更新中…') : '更新行政区',
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        // Stats bar — FOW-style counts along the bottom.
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xE0121E28),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: lit.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                _Stat(label: '国家/地区', value: d.countryCount),
                _Stat(label: '省份', value: d.provinceCount),
                _Stat(label: '城市', value: d.cityCount),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Rebuild-limiter for zoom-dependent layers inside a FlutterMap: its own
/// build runs per camera frame (MapCamera.of subscribes it), but [builder]
/// only re-runs when the zoom crosses a 0.5 step — pan and sub-step zoom
/// return the cached subtree untouched. Same pattern as the map screen's
/// pin scaler; a plain setState-per-move here rebuilt every marker each
/// frame and made pinch-zoom stutter.
class _ZoomGated extends StatefulWidget {
  final Widget Function(double zoomBucket) builder;
  const _ZoomGated({required this.builder});

  @override
  State<_ZoomGated> createState() => _ZoomGatedState();
}

class _ZoomGatedState extends State<_ZoomGated> {
  double? _bucket;
  Widget? _cached;

  @override
  Widget build(BuildContext context) {
    final z = MapCamera.of(context).zoom;
    final b = (z * 2).round() / 2;
    if (b != _bucket || _cached == null) {
      _bucket = b;
      _cached = widget.builder(b);
    }
    return _cached!;
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final int value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$value',
                style: PixelText.headline.copyWith(
                    fontSize: 22, color: const Color(0xFF4DD0E1))),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(fontSize: 10, color: Colors.white70)),
          ],
        ),
      );
}

class _GlobalCard extends StatelessWidget {
  final double globalPercent;
  final double landPercent;
  final int visited;
  final int total;
  const _GlobalCard({
    required this.globalPercent,
    required this.landPercent,
    required this.visited,
    required this.total,
  });

  Widget _row(String label, double pct, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1)),
          ),
        ]),
        const SizedBox(height: 4),
        // The collection stat IS the celebration — pixel display face.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('${(pct * 100).toStringAsFixed(10)}%',
              style: PixelText.headline.copyWith(color: Colors.white)),
        ),
        const SizedBox(height: 6),
        // 8-bit health bar: progress as discrete blocks.
        PixelBlockBar(
          value: pct,
          cells: 24,
          cellHeight: 7,
          color: Colors.white,
          emptyColor: Colors.white24,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: PixelPanel(
        color: const Color(0xFF00897B),
        borderColor: const Color(0xFF26A69A),
        step: 4,
        steps: 2,
        clipChild: true,
        child: Stack(
          children: [
            // Dither fade toward the foot of the card — the pixel answer to
            // the old gradient, gives the panel weight without banding.
            const Positioned.fill(
              child: PixelDitherFade(color: Color(0xFF00695C), cell: 4),
            ),
            // Drifting pixel clouds + square motes — the "clearing the fog"
            // motif in 8-bit. Drag across the card to part the motes.
            const Positioned.fill(
              child: Atmosphere(intensity: 0.9),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('全球（含海洋）', globalPercent, Icons.public),
                  const SizedBox(height: 14),
                  _row('陆地（按国家面积加权）', landPercent, Icons.landscape_outlined),
                  const SizedBox(height: 12),
                  Text(
                    '已涉足 $visited / $total 个国家/地区',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact bottom card listing every region the geocoder has confirmed
/// during real visits. This is the "we learned this exists" complement to
/// the bundled country grid above.
class _LearnedRegionsCard extends StatelessWidget {
  final List<LearnedRegion> learned;
  const _LearnedRegionsCard({required this.learned});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Group by country → unique provinces and unique cities.
    final byCountry =
        <String, ({Set<String> provinces, Set<String> cities, int points})>{};
    for (final r in learned) {
      final cur = byCountry.putIfAbsent(r.country,
          () => (provinces: <String>{}, cities: <String>{}, points: 0));
      if (r.province.isNotEmpty) cur.provinces.add(r.province);
      if (r.city.isNotEmpty) cur.cities.add(r.city);
      final cur2 = byCountry[r.country]!;
      byCountry[r.country] = (
        provinces: cur2.provinces,
        cities: cur2.cities,
        points: cur2.points + r.pointCount,
      );
    }
    final countries = byCountry.keys.toList()
      ..sort((a, b) => byCountry[b]!.points.compareTo(byCountry[a]!.points));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.history_edu_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              const Text('真实走过的地方（geocoder 确认）',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            Text(
              '由 Amap / 系统反向地理编码即时确认，覆盖 bundled bbox。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const Divider(height: 16),
            ...countries.map((c) {
              final v = byCountry[c]!;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(
                      child: Text(c,
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  Text(
                      '${v.provinces.length} 省 · ${v.cities.length} 市 · ${v.points} 次',
                      style:
                          TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ]),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _ContinentSection extends StatelessWidget {
  final String name;
  final List<CountryEntry> countries;
  final double Function(CountryEntry) pctOf;
  final Map<String, double>? Function(CountryEntry) regionsOf;

  const _ContinentSection({
    required this.name,
    required this.countries,
    required this.pctOf,
    required this.regionsOf,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final visited = countries.where((c) => pctOf(c) > 0).length;
    final avg = countries.isEmpty
        ? 0.0
        : countries.fold<double>(0, (a, c) => a + pctOf(c)) / countries.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Text(
                  '$visited / ${countries.length} · ${(avg * 100).toStringAsFixed(10)}%',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          // Pixel grid. Each country = one ~40dp colored square. Auto-wraps
          // based on available width so it looks dense on any screen.
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: countries
                .map((c) => _CountryPixel(
                      entry: c,
                      pct: pctOf(c),
                      onTap: () => _showDetail(context, c),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context, CountryEntry c) {
    final pct = pctOf(c);
    final regions = regionsOf(c);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Row(
              children: [
                Text(_codeToFlagEmoji(c.code),
                    style:
                        const TextStyle(fontSize: 32, fontFamily: 'Roboto')),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      Text(
                        '${(pct * 100).toStringAsFixed(10)}%',
                        style: TextStyle(
                            fontSize: 13, color: Theme.of(context).hintColor),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            PixelBlockBar(
              value: pct,
              cells: 24,
              cellHeight: 8,
              color: const Color(0xFF26A69A),
              emptyColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            ),
            const SizedBox(height: 16),
            if (regions == null || regions.isEmpty)
              Text(
                pct == 0
                    ? '尚未涉足。boundary 资源中也可能没有此国家的精细网格 —— 显示为 0% 不一定代表完全没去过。'
                    : '暂无行政区划数据',
                style:
                    TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
              )
            else ...[
              const Text('行政区进度',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              ...(regions.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value)))
                  .map((r) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(child: Text(r.key)),
                            Text(
                              '${(r.value * 100).toStringAsFixed(10)}%',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: r.value > 0
                                      ? const Color(0xFF26A69A)
                                      : Theme.of(context).hintColor),
                            ),
                          ],
                        ),
                      )),
            ],
          ],
        ),
      ),
    );
  }
}

class _CountryPixel extends StatelessWidget {
  final CountryEntry entry;
  final double pct;
  final VoidCallback onTap;
  const _CountryPixel({
    required this.entry,
    required this.pct,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final flag = _codeToFlagEmoji(entry.code);
    return Tooltip(
      message: '${entry.name} · ${(pct * 100).toStringAsFixed(10)}%',
      child: GestureDetector(
        onTap: onTap,
        child: ClipRect(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              border: Border.all(
                  color: pct > 0
                      ? const Color(0xFF26A69A).withValues(alpha: 0.7)
                      : Colors.white.withValues(alpha: 0.08),
                  width: pct > 0 ? 1.5 : 1),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Flag emoji centered as background.
                Center(
                  child: Text(
                    flag,
                    // Explicit system face: the global PixelZh font renders
                    // regional-indicator pairs as letter tiles instead of
                    // falling back to the color-emoji font.
                    style: const TextStyle(
                        fontSize: 32, height: 1, fontFamily: 'Roboto'),
                  ),
                ),
                // Greyscale veil for unvisited; transparent for fully
                // visited — flag shows more vividly the more you've been
                // there.
                Container(
                  color: Colors.black.withValues(
                      alpha: (0.55 * (1 - pct.clamp(0, 1))).clamp(0.0, 0.55)),
                ),
                // Tiny progress bar at the bottom.
                if (pct > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height: 3,
                      color: Colors.black54,
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: pct.clamp(0.0, 1.0),
                        child: Container(color: const Color(0xFF26A69A)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Convert an ISO 3166-1 alpha-2 code to the corresponding regional-
/// indicator emoji pair (e.g. "CN" → 🇨🇳). For codes that don't map to a
/// real flag emoji on this device (rare territories), falls back to 🏳️.
String _codeToFlagEmoji(String code) {
  if (code.length != 2) return '🏳️';
  const base = 0x1F1E6; // regional indicator A
  final cu = code.toUpperCase();
  try {
    final a = cu.codeUnitAt(0) - 'A'.codeUnitAt(0) + base;
    final b = cu.codeUnitAt(1) - 'A'.codeUnitAt(0) + base;
    if (a < base || b < base) return '🏳️';
    return String.fromCharCodes([a, b]);
  } catch (_) {
    return '🏳️';
  }
}
