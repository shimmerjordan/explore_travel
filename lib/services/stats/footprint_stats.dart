import '../../data/db/database.dart';
import '../location/point_filter.dart';

/// Distance rules shared by the timeline legs and the stats page — the
/// Dawarich `Stats::DailyDistanceQuery` conventions:
///  * consecutive fixes more than [kMaxGapMs] apart are NOT joined (a stopped
///    recording that resumes the next morning is not a 30 km straight line);
///  * an implied speed over [kMaxSpeedKmh] is a GPS jump, not travel.
const int kMaxGapMs = 30 * 60 * 1000;
const double kMaxSpeedKmh = 300;

/// Sum of segment lengths in [pts] (ONE layer, time-ascending), in metres.
double pathDistanceMeters(List<TrackPoint> pts) {
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    if (a.layerId != b.layerId) continue;
    final dtMs = b.time.millisecondsSinceEpoch - a.time.millisecondsSinceEpoch;
    if (dtMs <= 0 || dtMs > kMaxGapMs) continue;
    final d = PointFilter.haversineMeters(a.lat, a.lng, b.lat, b.lng);
    final kmh = d / 1000 / (dtMs / 3600000);
    if (kmh > kMaxSpeedKmh) continue;
    total += d;
  }
  return total;
}

/// Coarse travel mode from average speed (km/h). Display only — this is the
/// user's own trip, they know whether it was a bus or a bike.
String travelModeLabel(double kmh) {
  if (kmh < 7) return '步行';
  if (kmh < 25) return '骑行';
  if (kmh < 150) return '驾车';
  return '火车 / 飞行';
}

String formatKm(double meters) => meters >= 10000
    ? '${(meters / 1000).toStringAsFixed(0)} km'
    : meters >= 1000
        ? '${(meters / 1000).toStringAsFixed(1)} km'
        : '${meters.round()} m';

String formatDuration(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} 秒';
  if (d.inHours < 1) return '${d.inMinutes} 分';
  final h = d.inHours, m = d.inMinutes % 60;
  return m == 0 ? '$h 小时' : '$h 小时 $m 分';
}
