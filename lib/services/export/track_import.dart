import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import '../../core/geo_math.dart' show haversineMeters;
import '../../data/db/database.dart';
import '../fog/fog_engine.dart';
import '../location/point_filter.dart';

/// What [TrackImport.ingest] did: rows written, exact duplicates of points
/// already on the layer skipped, fixes the noise gate refused outright.
class IngestResult {
  final int inserted;
  final int duplicates;
  final int dropped;

  /// Time span of the written points (null when nothing was written) — the
  /// window stay detection should re-run over.
  final DateTime? from;
  final DateTime? to;
  const IngestResult({
    required this.inserted,
    required this.duplicates,
    required this.dropped,
    this.from,
    this.to,
  });
}

/// A single imported coordinate. [time] is null when the source format
/// carries no per-point timestamp (most KML LineStrings / GeoJSON);
/// [ingest] synthesises a monotonic clock for those.
class ImportedPoint {
  final double lat;
  final double lng;
  final double? altitude;
  final DateTime? time;
  const ImportedPoint(this.lat, this.lng, {this.altitude, this.time});
}

/// A parsed track file. [segments] preserves the source's continuous runs
/// (GPX `<trkseg>`, KML `<LineString>`, GeoJSON LineString, …) so fog reveal
/// connects points *within* a run but never bridges the gap between runs.
class ImportedTrack {
  final String name;
  final List<List<ImportedPoint>> segments;
  const ImportedTrack(this.name, this.segments);

  int get pointCount => segments.fold(0, (a, s) => a + s.length);
  bool get isEmpty => pointCount == 0;
}

/// Reads mainstream track files (GPX / KML / KMZ / GeoJSON) — including the
/// GPX/KML that Fog of World, Strava, Garmin, 两步路, OSM tools, etc. export —
/// into the app's own track points + fog. The companion exporter lives in
/// [TrackExport]; the Fog-of-World *fog-tile* format (not a track file) is
/// handled separately in `services/fog/fow_compat.dart`.
class TrackImport {
  /// 文件小于这个体积就在当前 isolate 解析：几十 KB 的 XML 一两毫秒就完，
  /// isolate 的启动 + 把整段字节拷过去的固定成本反而是大头。
  static const int kIsolateParseThreshold = 64 << 10;

  /// Parse a file, dispatching on its extension and falling back to sniffing
  /// the leading bytes when the extension is missing or wrong.
  static Future<ImportedTrack> parseFile(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    final base = p.basenameWithoutExtension(file.path);
    return parseBytes(base, ext, await file.readAsBytes());
  }

  /// Parse in-memory contents. [ext] is the lower-cased, dotted extension
  /// used for dispatch (`''` forces sniffing). XML / JSON parsing of a big
  /// track is the one CPU-heavy step of an import, so it runs in `compute()`
  /// — the DB insert + fog reveal in [ingest] stay on the caller's isolate.
  static Future<ImportedTrack> parseBytes(
      String name, String ext, Uint8List bytes) async {
    final segs = (!kIsWeb && bytes.length > kIsolateParseThreshold)
        ? await compute(parseTrackSegments, <Object>[ext, bytes])
        : parseTrackSegments(<Object>[ext, bytes]);
    return ImportedTrack(name, segs);
  }

  /// `compute()` entry: `[ext, bytes]` in, segments out. Public only so the
  /// isolate can reach it and tests can call it directly; use [parseBytes].
  /// 返回值只含 double / DateTime 这种原语字段的小对象，可直接跨 isolate 送回。
  static List<List<ImportedPoint>> parseTrackSegments(List<Object> args) {
    final ext = args[0] as String;
    final bytes = args[1] as Uint8List;
    switch (ext) {
      case '.gpx':
        return _parseGpx(utf8.decode(bytes));
      case '.kml':
        return _parseKml(utf8.decode(bytes));
      case '.kmz':
        return _parseKmz(bytes);
      case '.geojson':
      case '.json':
        return _parseGeoJson(utf8.decode(bytes));
    }
    // Unknown extension — sniff. KMZ is a zip (starts with "PK").
    if (bytes.length > 1 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
      return _parseKmz(bytes);
    }
    final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
    if (text.startsWith('{') || text.startsWith('[')) {
      return _parseGeoJson(text);
    }
    if (text.contains('<gpx')) return _parseGpx(text);
    if (text.contains('<kml')) return _parseKml(text);
    throw const FormatException('无法识别的轨迹文件格式（支持 GPX / KML / KMZ / GeoJSON）');
  }

  // ─── GPX ───
  static List<List<ImportedPoint>> _parseGpx(String xmlStr) {
    final doc = XmlDocument.parse(xmlStr);
    final segs = <List<ImportedPoint>>[];
    List<ImportedPoint> readPts(Iterable<XmlElement> pts) {
      final seg = <ImportedPoint>[];
      for (final pt in pts) {
        final lat = double.tryParse(pt.getAttribute('lat') ?? '');
        final lon = double.tryParse(pt.getAttribute('lon') ?? '');
        if (lat == null || lon == null) continue;
        final ele =
            double.tryParse(pt.getElement('ele')?.innerText.trim() ?? '');
        final t =
            DateTime.tryParse(pt.getElement('time')?.innerText.trim() ?? '');
        seg.add(ImportedPoint(lat, lon, altitude: ele, time: t));
      }
      return seg;
    }

    // Recorded tracks: <trk><trkseg><trkpt>. Each trkseg is one run.
    for (final seg in doc.findAllElements('trkseg')) {
      final pts = readPts(seg.findElements('trkpt'));
      if (pts.isNotEmpty) segs.add(pts);
    }
    // Planned routes: <rte><rtept>.
    for (final rte in doc.findAllElements('rte')) {
      final pts = readPts(rte.findElements('rtept'));
      if (pts.isNotEmpty) segs.add(pts);
    }
    return segs;
  }

  // ─── KML / KMZ ───
  static List<List<ImportedPoint>> _parseKmz(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? kml;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final n = f.name.toLowerCase();
      if (n.endsWith('.kml')) {
        kml = f;
        if (n == 'doc.kml' || n.endsWith('/doc.kml')) break;
      }
    }
    if (kml == null) throw const FormatException('KMZ 压缩包中找不到 .kml 文件');
    return _parseKml(utf8.decode(kml.content as List<int>, allowMalformed: true));
  }

  static List<List<ImportedPoint>> _parseKml(String xmlStr) {
    final doc = XmlDocument.parse(xmlStr);
    final root = doc.rootElement;
    final segs = <List<ImportedPoint>>[];

    Iterable<XmlElement> byLocal(XmlElement e, String local) =>
        e.descendantElements.where((d) => d.name.local == local);

    // <LineString><coordinates>lng,lat,ele lng,lat,ele …</coordinates>
    for (final ls in byLocal(root, 'LineString')) {
      XmlElement? coords;
      for (final c in ls.descendantElements) {
        if (c.name.local == 'coordinates') {
          coords = c;
          break;
        }
      }
      final seg = _parseKmlCoords(coords?.innerText ?? '');
      if (seg.isNotEmpty) segs.add(seg);
    }

    // gx:Track / Track: parallel <when> and gx:coord ("lng lat ele").
    for (final tr in byLocal(root, 'Track')) {
      final whens = byLocal(tr, 'when')
          .map((e) => DateTime.tryParse(e.innerText.trim()))
          .toList();
      final coordEls = byLocal(tr, 'coord').toList();
      final seg = <ImportedPoint>[];
      for (var i = 0; i < coordEls.length; i++) {
        final parts = coordEls[i].innerText.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        final lng = double.tryParse(parts[0]);
        final lat = double.tryParse(parts[1]);
        if (lat == null || lng == null) continue;
        seg.add(ImportedPoint(lat, lng,
            altitude: parts.length > 2 ? double.tryParse(parts[2]) : null,
            time: i < whens.length ? whens[i] : null));
      }
      if (seg.isNotEmpty) segs.add(seg);
    }

    // Standalone <Point> placemarks → isolated single-point segments.
    for (final pt in byLocal(root, 'Point')) {
      XmlElement? coords;
      for (final c in pt.descendantElements) {
        if (c.name.local == 'coordinates') {
          coords = c;
          break;
        }
      }
      final seg = _parseKmlCoords(coords?.innerText ?? '');
      if (seg.isNotEmpty) segs.add(seg);
    }
    return segs;
  }

  static List<ImportedPoint> _parseKmlCoords(String raw) {
    final seg = <ImportedPoint>[];
    for (final tok in raw.trim().split(RegExp(r'\s+'))) {
      if (tok.isEmpty) continue;
      final parts = tok.split(',');
      if (parts.length < 2) continue;
      final lng = double.tryParse(parts[0]);
      final lat = double.tryParse(parts[1]);
      if (lat == null || lng == null) continue;
      seg.add(ImportedPoint(lat, lng,
          altitude: parts.length > 2 ? double.tryParse(parts[2]) : null));
    }
    return seg;
  }

  // ─── GeoJSON ───
  static List<List<ImportedPoint>> _parseGeoJson(String jsonStr) {
    final data = jsonDecode(jsonStr);
    final segs = <List<ImportedPoint>>[];

    void handleGeom(Map g) {
      switch (g['type']) {
        case 'LineString':
          final s = _geoCoords(g['coordinates']);
          if (s.isNotEmpty) segs.add(s);
          break;
        case 'MultiLineString':
          for (final line in (g['coordinates'] as List? ?? const [])) {
            final s = _geoCoords(line);
            if (s.isNotEmpty) segs.add(s);
          }
          break;
        case 'Point':
          final s = _geoCoords([g['coordinates']]);
          if (s.isNotEmpty) segs.add(s);
          break;
        case 'MultiPoint':
          final s = _geoCoords(g['coordinates']);
          if (s.isNotEmpty) segs.add(s);
          break;
        case 'GeometryCollection':
          for (final sub in (g['geometries'] as List? ?? const [])) {
            if (sub is Map) handleGeom(sub);
          }
          break;
      }
    }

    if (data is Map) {
      switch (data['type']) {
        case 'FeatureCollection':
          for (final f in (data['features'] as List? ?? const [])) {
            if (f is Map && f['geometry'] is Map) {
              handleGeom(f['geometry'] as Map);
            }
          }
          break;
        case 'Feature':
          if (data['geometry'] is Map) handleGeom(data['geometry'] as Map);
          break;
        default:
          handleGeom(data); // bare geometry object
      }
    }
    return segs;
  }

  static List<ImportedPoint> _geoCoords(dynamic coords) {
    final seg = <ImportedPoint>[];
    if (coords is! List) return seg;
    for (final c in coords) {
      if (c is! List || c.length < 2) continue;
      final lng = (c[0] as num?)?.toDouble();
      final lat = (c[1] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      seg.add(ImportedPoint(lat, lng,
          altitude: c.length > 2 ? (c[2] as num?)?.toDouble() : null));
    }
    return seg;
  }

  /// Write [track] into [layerId] and reveal fog along each segment. Points
  /// without a source timestamp get a synthesised monotonic clock (1 s apart
  /// within a run, 60 s between runs) so the renderer keeps them ordered and
  /// still breaks the visible line between runs.
  ///
  /// Two gates run first: exact duplicates of points already on the layer
  /// (same ms + same 1e-6° coords — re-importing a GPX, or a GPX that
  /// overlaps a recorded session) are skipped, and the GPS noise gate drops /
  /// flags bad fixes exactly as live recording does. Fog is revealed only
  /// along clean, newly written points.
  static Future<IngestResult> ingest({
    required ImportedTrack track,
    required int layerId,
    required AppDb db,
    required FogEngine fog,
    required double pointWidth,
    required double penRadius,
    void Function(double progress)? onProgress,
  }) async {
    // 1) Assign times, dedup against what the layer already holds, gate.
    var synth = DateTime.now()
        .subtract(Duration(seconds: track.pointCount + track.segments.length));
    final timed = <List<({ImportedPoint p, DateTime t})>>[];
    DateTime? lo, hi;
    for (final seg in track.segments) {
      final run = <({ImportedPoint p, DateTime t})>[];
      for (final pt in seg) {
        final t = pt.time ?? synth;
        synth = synth.add(const Duration(seconds: 1));
        run.add((p: pt, t: t));
        if (lo == null || t.isBefore(lo)) lo = t;
        if (hi == null || t.isAfter(hi)) hi = t;
      }
      synth = synth.add(const Duration(seconds: 60)); // gap between runs
      timed.add(run);
    }
    if (lo == null || hi == null) {
      return const IngestResult(inserted: 0, duplicates: 0, dropped: 0);
    }
    final existing = await db.pointDedupKeys(layerId, lo, hi);

    final rows = <TrackPointsCompanion>[];
    // Clean points per run, for the fog pass (anomalies and dupes excluded).
    final cleanRuns = <List<ImportedPoint>>[];
    var duplicates = 0, dropped = 0;
    for (final run in timed) {
      final clean = <ImportedPoint>[];
      PointSample? prev;
      for (final e in run) {
        final key = AppDb.pointDedupKey(e.t, e.p.lat, e.p.lng);
        if (existing.contains(key)) {
          duplicates++;
          continue;
        }
        existing.add(key); // a file can repeat its own points too
        final sample =
            PointSample(e.p.lat, e.p.lng, e.t.millisecondsSinceEpoch);
        final verdict = PointFilter.judge(sample, prev: prev);
        if (verdict == PointVerdict.drop) {
          dropped++;
          continue;
        }
        final anomaly = verdict == PointVerdict.anomaly;
        if (!anomaly) prev = sample;
        rows.add(TrackPointsCompanion.insert(
          lat: e.p.lat,
          lng: e.p.lng,
          time: e.t,
          layerId: layerId,
          altitude: Value(e.p.altitude),
          width: Value(pointWidth),
          flags: Value(anomaly ? PointFlags.anomaly : 0),
        ));
        if (!anomaly) clean.add(e.p);
      }
      if (clean.isNotEmpty) cleanRuns.add(clean);
    }
    if (rows.isEmpty) {
      onProgress?.call(1.0);
      return IngestResult(inserted: 0, duplicates: duplicates, dropped: dropped);
    }
    await db.insertPoints(rows);

    // 2) Reveal fog. Within a run, chain consecutive points with a swept
    //    corridor; bridge only gaps small enough to be a real walk (mirrors
    //    RecordingController's distance gate so a sparse track's big jumps
    //    don't paint a giant fake corridor).
    final maxGap = (penRadius * 5).clamp(50.0, double.infinity);
    final total = cleanRuns.fold<int>(0, (a, s) => a + s.length);
    var done = 0;
    for (final seg in cleanRuns) {
      for (var i = 0; i < seg.length; i++) {
        final cur = seg[i];
        if (i == 0) {
          await fog.revealPoint(
              lat: cur.lat,
              lng: cur.lng,
              radiusMeters: penRadius,
              layerId: layerId);
        } else {
          final prev = seg[i - 1];
          final gap = haversineMeters(prev.lat, prev.lng, cur.lat, cur.lng);
          if (gap <= maxGap) {
            await fog.revealLine(
              lat0: prev.lat,
              lng0: prev.lng,
              lat1: cur.lat,
              lng1: cur.lng,
              layerId: layerId,
              radiusMeters: penRadius,
            );
          } else {
            await fog.revealPoint(
                lat: cur.lat,
                lng: cur.lng,
                radiusMeters: penRadius,
                layerId: layerId);
          }
        }
        done++;
        if (onProgress != null && (done & 0x1F) == 0) {
          onProgress(done / total);
        }
      }
    }
    onProgress?.call(1.0);
    return IngestResult(
      inserted: rows.length,
      duplicates: duplicates,
      dropped: dropped,
      from: lo,
      to: hi,
    );
  }
}
