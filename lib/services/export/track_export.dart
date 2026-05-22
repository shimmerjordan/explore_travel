import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import '../../data/db/database.dart';

/// Exports tracks to GPX 1.1 and KML 2.2. Both formats are widely accepted by
/// Google Earth, Garmin, Strava, OSM tools, etc.
class TrackExport {
  static Future<File> exportGpx({
    required String name,
    required List<TrackPoint> points,
  }) async {
    final b = XmlBuilder();
    b.processing('xml', 'version="1.0" encoding="UTF-8"');
    b.element('gpx', nest: () {
      b.attribute('version', '1.1');
      b.attribute('creator', 'Explore Journal');
      b.attribute('xmlns', 'http://www.topografix.com/GPX/1/1');
      b.element('trk', nest: () {
        b.element('name', nest: name);
        b.element('trkseg', nest: () {
          for (final pt in points) {
            b.element('trkpt', nest: () {
              b.attribute('lat', pt.lat.toString());
              b.attribute('lon', pt.lng.toString());
              if (pt.altitude != null) {
                b.element('ele', nest: pt.altitude!.toString());
              }
              b.element('time', nest: pt.time.toUtc().toIso8601String());
            });
          }
        });
      });
    });
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(dir.path, 'exports'));
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final file = File(p.join(outDir.path, '${_safe(name)}.gpx'));
    await file.writeAsString(b.buildDocument().toXmlString(pretty: true));
    return file;
  }

  static Future<File> exportKml({
    required String name,
    required List<TrackPoint> points,
    String? colorHex,
  }) async {
    final b = XmlBuilder();
    b.processing('xml', 'version="1.0" encoding="UTF-8"');
    b.element('kml', nest: () {
      b.attribute('xmlns', 'http://www.opengis.net/kml/2.2');
      b.element('Document', nest: () {
        b.element('name', nest: name);
        b.element('Style', nest: () {
          b.attribute('id', 'trk');
          b.element('LineStyle', nest: () {
            b.element('color', nest: colorHex ?? 'ff00bcd4');
            b.element('width', nest: '4');
          });
        });
        b.element('Placemark', nest: () {
          b.element('name', nest: name);
          b.element('styleUrl', nest: '#trk');
          b.element('LineString', nest: () {
            b.element('tessellate', nest: '1');
            b.element('coordinates',
                nest: points.map((p) => '${p.lng},${p.lat}').join(' '));
          });
        });
      });
    });
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(dir.path, 'exports'));
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final file = File(p.join(outDir.path, '${_safe(name)}.kml'));
    await file.writeAsString(b.buildDocument().toXmlString(pretty: true));
    return file;
  }

  /// Parses a GPX file and returns ordered (lat, lng, time, ele) points.
  /// Useful for importing tracks recorded by other apps.
  static Future<List<TrackPointImport>> importGpx(File file) async {
    final doc = XmlDocument.parse(await file.readAsString());
    final out = <TrackPointImport>[];
    for (final pt in doc.findAllElements('trkpt')) {
      final lat = double.tryParse(pt.getAttribute('lat') ?? '');
      final lon = double.tryParse(pt.getAttribute('lon') ?? '');
      if (lat == null || lon == null) continue;
      final ele = double.tryParse(
          pt.getElement('ele')?.innerText.trim() ?? '');
      final t = DateTime.tryParse(
          pt.getElement('time')?.innerText.trim() ?? '');
      out.add(TrackPointImport(
          lat: lat, lng: lon, altitude: ele, time: t ?? DateTime.now()));
    }
    return out;
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^\w一-龥-]'), '_');
}

class TrackPointImport {
  final double lat;
  final double lng;
  final double? altitude;
  final DateTime time;
  TrackPointImport(
      {required this.lat, required this.lng, this.altitude, required this.time});
}
