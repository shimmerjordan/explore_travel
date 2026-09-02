import 'dart:convert';

import 'replay_model.dart';

/// The referential half of a 合并记录 (see `MergedTrips` in database.dart):
/// which time windows of which layers belong to the bundle, and how those
/// windows are matched back to live [ReplaySession]s.
///
/// Layers are referenced by **uuid**, not local id — ids differ per device
/// and get remapped on sync/restore; uuids are the stable identity.
class TripSegment {
  final String layerUuid;
  final int startMs;
  final int endMs;
  const TripSegment(this.layerUuid, this.startMs, this.endMs);

  Map<String, Object> toJson() =>
      {'layer': layerUuid, 'startMs': startMs, 'endMs': endMs};

  static TripSegment? fromJson(Object? j) {
    if (j is! Map) return null;
    final layer = j['layer']?.toString() ?? '';
    final s = (j['startMs'] as num?)?.toInt();
    final e = (j['endMs'] as num?)?.toInt();
    if (layer.isEmpty || s == null || e == null || e < s) return null;
    return TripSegment(layer, s, e);
  }
}

String encodeTripSegments(Iterable<TripSegment> segs) =>
    jsonEncode([for (final s in segs) s.toJson()]);

List<TripSegment> decodeTripSegments(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! List) return const [];
    return [
      for (final e in j)
        if (TripSegment.fromJson(e) case final s?) s,
    ];
  } catch (_) {
    return const [];
  }
}

/// Segments for a set of picked sessions. A hair of tolerance is baked into
/// the WINDOW (±1 min) so a later re-derivation whose session boundaries
/// moved a few seconds (a new point at the edge, a tightened noise gate)
/// still matches.
List<TripSegment> segmentsForSessions(
    Iterable<ReplaySession> sessions, Map<int, String> layerUuidById) {
  const pad = 60 * 1000;
  return [
    for (final s in sessions)
      if ((layerUuidById[s.layerId] ?? '').isNotEmpty)
        TripSegment(
          layerUuidById[s.layerId]!,
          s.start.millisecondsSinceEpoch - pad,
          s.end.millisecondsSinceEpoch + pad,
        ),
  ];
}

/// The live sessions a trip covers: same layer (by uuid) and the session
/// STARTS inside one of the trip's windows. Matching on the start alone
/// keeps a session that grew longer since the trip was saved.
List<ReplaySession> resolveTripSessions(
  List<TripSegment> segments,
  List<ReplaySession> all,
  Map<int, String> layerUuidById,
) {
  final out = <ReplaySession>[];
  for (final s in all) {
    final uuid = layerUuidById[s.layerId] ?? '';
    if (uuid.isEmpty) continue;
    final startMs = s.start.millisecondsSinceEpoch;
    for (final seg in segments) {
      if (seg.layerUuid == uuid &&
          startMs >= seg.startMs &&
          startMs <= seg.endMs) {
        out.add(s);
        break;
      }
    }
  }
  return out;
}
