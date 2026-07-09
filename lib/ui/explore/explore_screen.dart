import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../data/iso_countries.dart';
import '../../data/iso_country_areas.dart';
import '../../services/fog/fog_engine.dart';
import '../../services/geo/learned_regions.dart';

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
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadAndCompute();
  }

  Future<void> _loadAndCompute() async {
    setState(() => _loading = true);
    Map<String, dynamic>? data;
    try {
      final raw =
          await rootBundle.loadString('assets/boundaries/countries.json');
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}

    final fog = ref.read(fogEngineProvider);
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    final layerIds =
        layers.where((l) => l.visible).map((l) => l.id).toList();

    // Same calc as home stats card — both go through
    // [FogEngine.globalExplorationPercent] which is revealed km² / Earth
    // surface (510 072 000 km²). Keeps the two numbers consistent.
    _globalPercent = await fog.globalExplorationPercent(layerIds);
    _pct.clear();
    _regionPct.clear();

    // Build ONE flat (country|province → bbox) map and let the engine
    // attribute each revealed pixel to the SMALLEST containing bbox —
    // that's what avoids "Shanghai also counts for Jiangsu/Zhejiang"
    // when bundled rects overlap.
    if (data != null) {
      final countries = data['countries'] as Map<String, dynamic>;
      final regionBboxes =
          <String, ({double minLat, double minLng, double maxLat, double maxLng})>{};
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
      final countryOnly = <String, ({double minLat, double minLng, double maxLat, double maxLng})>{
        for (final e in regionBboxes.entries)
          if (e.key.startsWith('country|')) e.key: e.value,
      };
      final provOnly = <String, ({double minLat, double minLng, double maxLat, double maxLng})>{
        for (final e in regionBboxes.entries)
          if (e.key.startsWith('prov|')) e.key: e.value,
      };
      final countryKm2 = await fog.revealedAreaByRegionsKm2(layerIds,
          regions: countryOnly);
      final provKm2 = await fog.revealedAreaByRegionsKm2(layerIds,
          regions: provOnly);

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

    // Learned regions override bundled. Use each learned bbox as both
    // numerator scope AND denominator — the bbox grows as the user visits
    // more places, so % is "fraction of your personal bbox covered". For a
    // single-point visit, bbox ≈ a point ≈ near-zero area, giving a tiny
    // non-zero number rather than a fake 100%.
    _learned = await ref.read(learnedRegionsProvider).all();
    for (final r in _learned) {
      if (r.province.isEmpty || r.city.isNotEmpty) continue; // province only
      final revealedKm2 = await fog.revealedAreaInBboxKm2(
        layerIds,
        minLat: r.minLat,
        minLng: r.minLng,
        maxLat: r.maxLat,
        maxLng: r.maxLng,
      );
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

    setState(() => _loading = false);
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
    final totalCountries = kContinents.values
        .fold<int>(0, (a, list) => a + list.length);
    final visitedCountries = kContinents.values
        .expand((l) => l)
        .where((e) => _lookupPct(e) > 0)
        .length;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('探索进度',
                style: TextStyle(fontWeight: FontWeight.w700)),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _loadAndCompute,
              ),
            ],
          ),
          if (_loading)
            const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()))
          else ...[
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
        ],
      ),
    );
  }
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
        // Stacked instead of single-row: 10-decimal % is ~13 chars wide
        // at 18pt bold — combined with the label and icon it overflowed
        // narrow screens by a few px. Putting % on its own line removes
        // the squeeze entirely and reads cleaner anyway.
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
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('${(pct * 100).toStringAsFixed(10)}%',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 5,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF26A69A), Color(0xFF00897B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row('全球（含海洋）', globalPercent, Icons.public),
            const SizedBox(height: 14),
            _row('陆地（按国家面积加权）', landPercent, Icons.landscape_outlined),
            const SizedBox(height: 12),
            Text(
              '已涉足 $visited / $total 个国家/地区',
              style:
                  const TextStyle(color: Colors.white70, fontSize: 13),
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
    final byCountry = <String, ({Set<String> provinces, Set<String> cities, int points})>{};
    for (final r in learned) {
      final cur = byCountry.putIfAbsent(
          r.country, () => (provinces: <String>{}, cities: <String>{}, points: 0));
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
      ..sort((a, b) =>
          byCountry[b]!.points.compareTo(byCountry[a]!.points));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
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
                          style: const TextStyle(
                              fontWeight: FontWeight.w600))),
                  Text(
                      '${v.provinces.length} 省 · ${v.cities.length} 市 · ${v.points} 次',
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurfaceVariant)),
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
        : countries.fold<double>(0, (a, c) => a + pctOf(c)) /
            countries.length;

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
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Text(
                  '$visited / ${countries.length} · ${(avg * 100).toStringAsFixed(10)}%',
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant),
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
                    style: const TextStyle(fontSize: 32)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      Text(
                        '${(pct * 100).toStringAsFixed(10)}%',
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).hintColor),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 6,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHigh,
              ),
            ),
            const SizedBox(height: 16),
            if (regions == null || regions.isEmpty)
              Text(
                pct == 0
                    ? '尚未涉足。boundary 资源中也可能没有此国家的精细网格 —— 显示为 0% 不一定代表完全没去过。'
                    : '暂无行政区划数据',
                style: TextStyle(
                    color: Theme.of(context).hintColor, fontSize: 12),
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
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
                    style: const TextStyle(fontSize: 32, height: 1),
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
