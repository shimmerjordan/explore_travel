import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/export/track_import.dart';

/// 解析被搬进 compute() 之后的对等性守卫：同一份 GPX 走「小文件原地解析」和
/// 「大文件 isolate 解析」两条路，点、分段、时间戳必须逐一相同；KML / KMZ /
/// GeoJSON / 嗅探路径也要还在。
void main() {
  const gpx = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>morning</name>
    <trkseg>
      <trkpt lat="30.0001" lon="104.0001"><ele>500.5</ele><time>2026-08-20T01:00:00Z</time></trkpt>
      <trkpt lat="30.0002" lon="104.0002"><ele>501</ele><time>2026-08-20T01:00:10Z</time></trkpt>
      <trkpt lat="bad" lon="104.0003"></trkpt>
    </trkseg>
    <trkseg>
      <trkpt lat="30.1" lon="104.1"><time>2026-08-20T02:00:00Z</time></trkpt>
    </trkseg>
  </trk>
  <rte>
    <rtept lat="31.0" lon="105.0"></rtept>
    <rtept lat="31.1" lon="105.1"></rtept>
  </rte>
</gpx>''';

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

  void expectSamePoints(
      List<List<ImportedPoint>> a, List<List<ImportedPoint>> b) {
    expect(b.length, a.length, reason: 'segment count');
    for (var s = 0; s < a.length; s++) {
      expect(b[s].length, a[s].length, reason: 'segment $s length');
      for (var i = 0; i < a[s].length; i++) {
        expect(b[s][i].lat, a[s][i].lat);
        expect(b[s][i].lng, a[s][i].lng);
        expect(b[s][i].altitude, a[s][i].altitude);
        expect(b[s][i].time, a[s][i].time);
      }
    }
  }

  test('GPX: trkseg runs + rte become segments, bad points skipped', () async {
    final t = await TrackImport.parseBytes('morning', '.gpx', bytesOf(gpx));
    expect(t.name, 'morning');
    expect(t.segments.length, 3);
    expect(t.segments[0].length, 2); // the lat="bad" point is dropped
    expect(t.segments[0][0].lat, 30.0001);
    expect(t.segments[0][0].lng, 104.0001);
    expect(t.segments[0][0].altitude, 500.5);
    expect(t.segments[0][0].time, DateTime.utc(2026, 8, 20, 1));
    expect(t.segments[1].single.time, DateTime.utc(2026, 8, 20, 2));
    expect(t.segments[1].single.altitude, isNull);
    expect(t.segments[2].length, 2);
    expect(t.segments[2][1].time, isNull);
    expect(t.pointCount, 5);
  });

  test('isolate path (big file) parses identically to the inline path',
      () async {
    // Repeat the segment until the file is comfortably past the threshold.
    final sb = StringBuffer(
        '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>');
    var i = 0;
    while (sb.length < TrackImport.kIsolateParseThreshold * 2) {
      final t = DateTime.utc(2026, 8, 20).add(Duration(seconds: i));
      sb.write('<trkpt lat="${30 + i * 1e-5}" lon="${104 + i * 1e-5}">'
          '<ele>${i % 100}</ele><time>${t.toIso8601String()}</time></trkpt>');
      i++;
    }
    sb.write('</trkseg></trk></gpx>');
    final bytes = bytesOf(sb.toString());
    expect(bytes.length, greaterThan(TrackImport.kIsolateParseThreshold));

    final viaIsolate = await TrackImport.parseBytes('big', '.gpx', bytes);
    final inline = TrackImport.parseTrackSegments(<Object>['.gpx', bytes]);
    expect(viaIsolate.pointCount, i);
    expectSamePoints(inline, viaIsolate.segments);
  });

  test('KML LineString / gx:Track / Point', () async {
    const kml = '''<?xml version="1.0"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
<Document>
  <Placemark><LineString><coordinates>
    104.0,30.0,10 104.1,30.1,20
  </coordinates></LineString></Placemark>
  <Placemark><gx:Track>
    <when>2026-08-20T01:00:00Z</when><when>2026-08-20T01:01:00Z</when>
    <gx:coord>105 31 5</gx:coord><gx:coord>105.1 31.1</gx:coord>
  </gx:Track></Placemark>
  <Placemark><Point><coordinates>106,32</coordinates></Point></Placemark>
</Document></kml>''';
    final t = await TrackImport.parseBytes('k', '.kml', bytesOf(kml));
    expect(t.segments.length, 3);
    expect(t.segments[0][0].lat, 30.0);
    expect(t.segments[0][0].lng, 104.0);
    expect(t.segments[0][0].altitude, 10);
    expect(t.segments[1][0].time, DateTime.utc(2026, 8, 20, 1));
    expect(t.segments[1][1].altitude, isNull);
    expect(t.segments[2].single.lat, 32);
  });

  test('KMZ: the doc.kml inside the zip is parsed', () async {
    const kml =
        '<kml><Placemark><LineString><coordinates>104,30 104.1,30.1</coordinates></LineString></Placemark></kml>';
    final archive = Archive()
      ..addFile(ArchiveFile('other.txt', 5, utf8.encode('hello')))
      ..addFile(ArchiveFile('doc.kml', kml.length, utf8.encode(kml)));
    final zip = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final t = await TrackImport.parseBytes('z', '.kmz', zip);
    expect(t.segments.single.length, 2);
    // Sniffed (no extension) too: a zip starts with "PK".
    final sniffed = await TrackImport.parseBytes('z', '', zip);
    expect(sniffed.segments.single.length, 2);
  });

  test('GeoJSON FeatureCollection + sniffing by leading brace', () async {
    const gj = '''{"type":"FeatureCollection","features":[
      {"type":"Feature","geometry":{"type":"LineString","coordinates":[[104,30,1],[104.1,30.1]]}},
      {"type":"Feature","geometry":{"type":"MultiPoint","coordinates":[[105,31]]}}
    ]}''';
    final t = await TrackImport.parseBytes('g', '.geojson', bytesOf(gj));
    expect(t.segments.length, 2);
    expect(t.segments[0][0].altitude, 1);
    expect(t.segments[1].single.lng, 105);
    final sniffed = await TrackImport.parseBytes('g', '', bytesOf(gj));
    expect(sniffed.pointCount, 3);
  });

  test('sniffing finds <gpx> / <kml> without an extension; garbage throws',
      () async {
    expect((await TrackImport.parseBytes('x', '', bytesOf(gpx))).pointCount, 5);
    expect(
        () => TrackImport.parseBytes('x', '', bytesOf('nothing to see here')),
        throwsA(isA<FormatException>()));
  });
}
