import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import '../../data/db/database.dart';
import '../fog/fog_engine.dart';

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
  /// Parse a file, dispatching on its extension and falling back to sniffing
  /// the leading bytes when the extension is missing or wrong.
  static Future<ImportedTrack> parseFile(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    final base = p.basenameWithoutExtension(file.path);
    switch (ext) {
      case '.gpx':
        return ImportedTrack(base, _parseGpx(await file.readAsString()));
      case '.kml':
        return ImportedTrack(base, _parseKml(await file.readAsString()));
      case '.kmz':
        return ImportedTrack(base, _parseKmz(await file.readAsBytes()));
      case '.geojson':
      case '.json':
        return ImportedTrack(base, _parseGeoJson(await file.readAsString()));
    }
    // Unknown extension — sniff. KMZ is a zip (starts with "PK").
    final bytes = await file.readAsBytes();
    if (bytes.length > 1 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
      return ImportedTrack(base, _parseKmz(bytes));
    }
    final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
    if (text.startsWith('{') || text.startsWith('[')) {
      return ImportedTrack(base, _parseGeoJson(text));
    }
    if (text.contains('<gpx')) return ImportedTrack(base, _parseGpx(text));
    if (text.contains('<kml')) return ImportedTrack(base, _parseKml(text));
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
  static List<List<ImportedPoint>> _parseKmz(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes is Uint8List
        ? bytes
        : Uint8List.fromList(List<int>.from(bytes)));
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
  /// still breaks the visible line between runs. Returns points inserted.
  static Future<int> ingest({
    required ImportedTrack track,
    required int layerId,
    required AppDb db,
    required FogEngine fog,
    required double pointWidth,
    required double penRadius,
    void Function(double progress)? onProgress,
  }) async {
    // 1) Insert all points (batched in one transaction for speed).
    var synth = DateTime.now()
        .subtract(Duration(seconds: track.pointCount + track.segments.length));
    final rows = <TrackPointsCompanion>[];
    for (final seg in track.segments) {
      for (final pt in seg) {
        final t = pt.time ?? synth;
        synth = synth.add(const Duration(seconds: 1));
        rows.add(TrackPointsCompanion.insert(
          lat: pt.lat,
          lng: pt.lng,
          time: t,
          layerId: layerId,
          altitude: Value(pt.altitude),
          width: Value(pointWidth),
        ));
      }
      synth = synth.add(const Duration(seconds: 60)); // gap between runs
    }
    if (rows.isEmpty) return 0;
    await db.insertPoints(rows);

    // 2) Reveal fog. Within a run, chain consecutive points with a swept
    //    corridor; bridge only gaps small enough to be a real walk (mirrors
    //    RecordingController's distance gate so a sparse track's big jumps
    //    don't paint a giant fake corridor).
    final maxGap = (penRadius * 5).clamp(50.0, double.infinity);
    final total = track.pointCount;
    var done = 0;
    for (final seg in track.segments) {
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
          final gap = _haversine(prev.lat, prev.lng, cur.lat, cur.lng);
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
    return rows.length;
  }

  static double _haversine(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    const deg = math.pi / 180;
    final dLat = (lat2 - lat1) * deg;
    final dLng = (lng2 - lng1) * deg;
    final a = (1 - math.cos(dLat)) / 2 +
        math.cos(lat1 * deg) * math.cos(lat2 * deg) * (1 - math.cos(dLng)) / 2;
    return 2 * r * math.asin(math.sqrt(a));
  }
}
