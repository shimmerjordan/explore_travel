import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import '../../app/providers.dart';
import '../../services/map/tile_providers.dart';

/// Structured trip plan we extract from the model's trailing JSON block.
/// Drives the mini route map + energy/steps summary in the planner screen.
class TripPlan {
  final String destination;
  final TripPoi? origin;
  final List<TripDay> days;
  /// Total trip distance (km), straight-line + roads, model-estimated.
  final double totalKm;
  /// Walking subset of [totalKm].
  final double walkingKm;

  TripPlan({
    required this.destination,
    required this.origin,
    required this.days,
    required this.totalKm,
    required this.walkingKm,
  });

  /// Try to pull a ```json ... ``` block out of the message and parse it.
  /// Returns null if not found / malformed.
  static TripPlan? tryParse(String markdown) {
    final m = RegExp(
      r'```(?:json)?\s*\n([\s\S]*?)\n```',
      multiLine: true,
    ).firstMatch(markdown);
    if (m == null) return null;
    final raw = m.group(1)!;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return TripPlan(
        destination: j['destination']?.toString() ?? '',
        origin: _poi(j['origin'] as Map<String, dynamic>?),
        days: ((j['days'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TripDay.fromJson)
            .toList(),
        totalKm: (j['totalKm'] as num?)?.toDouble() ?? 0,
        walkingKm: (j['walkingKm'] as num?)?.toDouble() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static TripPoi? _poi(Map<String, dynamic>? j) {
    if (j == null) return null;
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return TripPoi(
      name: j['name']?.toString() ?? '',
      lat: lat,
      lng: lng,
      type: j['type']?.toString() ?? '出发地',
    );
  }

  /// Flattened ordered list including origin (if set).
  List<TripPoi> get allPois => [
        if (origin != null) origin!,
        for (final d in days) ...d.pois,
      ];

  /// All distinct positions for fitBounds.
  LatLngBounds? get bounds {
    final pts = allPois.map((p) => LatLng(p.lat, p.lng)).toList();
    if (pts.isEmpty) return null;
    return LatLngBounds.fromPoints(pts);
  }
}

class TripDay {
  final int day;
  final List<TripPoi> pois;
  TripDay({required this.day, required this.pois});
  factory TripDay.fromJson(Map<String, dynamic> j) => TripDay(
        day: (j['day'] as num?)?.toInt() ?? 0,
        pois: ((j['pois'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TripPoi.fromJson)
            .toList(),
      );
}

class TripPoi {
  final String name;
  final double lat;
  final double lng;
  final String type; // 景点 / 餐饮 / 住宿 / 交通 / 出发地
  TripPoi({
    required this.name,
    required this.lat,
    required this.lng,
    required this.type,
  });
  factory TripPoi.fromJson(Map<String, dynamic> j) => TripPoi(
        name: j['name']?.toString() ?? '',
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        lng: (j['lng'] as num?)?.toDouble() ?? 0,
        type: j['type']?.toString() ?? '景点',
      );
}

/// Rough physiological estimate. Inputs are weight (default 65 kg) and
/// total walking distance in km.
class EnergyEstimate {
  final double kcal;
  final int steps;
  final Duration walkingTime;
  EnergyEstimate(
      {required this.kcal,
      required this.steps,
      required this.walkingTime});

  /// MET ≈ 3.5 for moderate walking. kcal/min = MET × 3.5 × weight / 200
  /// Walking pace ≈ 5 km/h, step length ≈ 0.76 m → 1316 steps/km.
  factory EnergyEstimate.forWalking(double walkingKm, {double weight = 65}) {
    final hours = walkingKm / 5.0;
    final minutes = hours * 60;
    final kcal = 3.5 * 3.5 * weight / 200 * minutes;
    final steps = (walkingKm * 1316).round();
    return EnergyEstimate(
      kcal: kcal,
      steps: steps,
      walkingTime: Duration(minutes: minutes.round()),
    );
  }
}

Color _typeColor(String type) {
  return switch (type) {
    '景点' => const Color(0xFF26A69A),
    '餐饮' => const Color(0xFFFFA726),
    '住宿' => const Color(0xFFAB47BC),
    '交通' => const Color(0xFF42A5F5),
    '出发地' => const Color(0xFFEF5350),
    _ => const Color(0xFF78909C),
  };
}

IconData _typeIcon(String type) {
  return switch (type) {
    '景点' => Icons.place,
    '餐饮' => Icons.restaurant,
    '住宿' => Icons.hotel,
    '交通' => Icons.directions_bus,
    '出发地' => Icons.flag,
    _ => Icons.location_on,
  };
}

class TripMiniMapCard extends ConsumerWidget {
  final TripPlan plan;
  const TripMiniMapCard({super.key, required this.plan});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final pois = plan.allPois;
    final bounds = plan.bounds;
    final energy = EnergyEstimate.forWalking(plan.walkingKm);
    final s = ref.watch(settingsProvider);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 220,
            child: bounds == null
                ? Container(
                    color: cs.surfaceContainerHigh,
                    alignment: Alignment.center,
                    child: Text('未生成可视化路线',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  )
                : FlutterMap(
                    options: MapOptions(
                      initialCameraFit: CameraFit.bounds(
                        bounds: bounds,
                        padding: const EdgeInsets.all(32),
                      ),
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.pinchZoom |
                            InteractiveFlag.drag |
                            InteractiveFlag.doubleTapZoom,
                      ),
                    ),
                    children: [
                      buildTileLayer(
                        provider: s.mapProvider,
                        style: s.mapStyle,
                        amapKey: s.amapApiKey,
                        googleKey: s.googleMapKey,
                        customOsmUrl: s.customOsmTileUrl,
                      ),
                      PolylineLayer(polylines: [
                        Polyline(
                          points: pois
                              .map((p) => LatLng(p.lat, p.lng))
                              .toList(),
                          color: cs.primary,
                          strokeWidth: 3,
                        ),
                      ]),
                      MarkerLayer(
                        markers: pois
                            .asMap()
                            .entries
                            .map((e) => Marker(
                                  point:
                                      LatLng(e.value.lat, e.value.lng),
                                  width: 36,
                                  height: 36,
                                  child: _PoiMarker(
                                    index: e.key + 1,
                                    poi: e.value,
                                  ),
                                ))
                            .toList(),
                      ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.flag_rounded, size: 16, color: cs.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        plan.destination,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    _stat(context, Icons.straighten_rounded,
                        '${plan.totalKm.toStringAsFixed(1)} km',
                        '总距离'),
                    _stat(context, Icons.directions_walk_rounded,
                        '${plan.walkingKm.toStringAsFixed(1)} km',
                        '步行段'),
                    _stat(context, Icons.local_fire_department_rounded,
                        '${energy.kcal.toStringAsFixed(0)} kcal',
                        '步行消耗'),
                    _stat(context, Icons.directions_run_rounded,
                        '${energy.steps}',
                        '步数估算'),
                    _stat(
                        context,
                        Icons.timer_outlined,
                        '${energy.walkingTime.inMinutes} 分',
                        '步行耗时'),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _legend(context, '景点'),
                    _legend(context, '餐饮'),
                    _legend(context, '住宿'),
                    _legend(context, '交通'),
                    _legend(context, '出发地'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, IconData icon, String value,
      String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Theme.of(context).hintColor),
        const SizedBox(width: 4),
        Text(value,
            style:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).hintColor)),
      ],
    );
  }

  Widget _legend(BuildContext context, String type) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: _typeColor(type),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(type,
            style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).hintColor)),
      ],
    );
  }
}

class _PoiMarker extends StatelessWidget {
  final int index;
  final TripPoi poi;
  const _PoiMarker({required this.index, required this.poi});
  @override
  Widget build(BuildContext context) {
    final c = _typeColor(poi.type);
    return Tooltip(
      message: '${poi.name} · ${poi.type}',
      child: Container(
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 4),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(_typeIcon(poi.type), color: Colors.white, size: 18),
      ),
    );
  }
}
