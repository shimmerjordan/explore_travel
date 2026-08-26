import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/core/prefs.dart';
import 'package:explore_journal/models/models.dart';
import 'package:explore_journal/services/geo/coord_converter.dart';
import 'package:explore_journal/services/map/tile_providers.dart';

/// 奥维底图接入：奥维没有公开瓦片端点，只能接用户自己奥维实例的 WEB 瓦片
/// 服务 URL 模板。这里钉住：模板归一化、未配置时的回落、GCJ-02 开关、
/// 以及设置持久化对未知枚举值的容错（新增枚举值后降级安装不能清空整份设置）。
void main() {
  group('normalizeTileTemplate', () {
    test("accepts Ovital's {\$z}/{\$x}/{\$y} spelling", () {
      expect(
        normalizeTileTemplate(
            r'http://192.168.1.2:9999/getomap_202_{$z}_{$x}_{$y}_0_0.png'),
        'http://192.168.1.2:9999/getomap_202_{z}_{x}_{y}_0_0.png',
      );
    });

    test('passes flutter_map placeholders through, trimming whitespace', () {
      expect(normalizeTileTemplate('  https://a/{z}/{x}/{y}.png \n'),
          'https://a/{z}/{x}/{y}.png');
    });

    test('maps {\$serverpart} to {s}', () {
      expect(normalizeTileTemplate(r'https://{$serverpart}.t/{$z}/{$x}/{$y}'),
          'https://{s}.t/{z}/{x}/{y}');
    });

    test('rejects empty or placeholder-less input', () {
      expect(normalizeTileTemplate(null), isNull);
      expect(normalizeTileTemplate('   '), isNull);
      expect(normalizeTileTemplate('https://a/tiles.png'), isNull);
      expect(normalizeTileTemplate('https://a/{z}/{x}.png'), isNull);
    });
  });

  group('buildTileLayer(ovital)', () {
    test('uses the configured template for every style', () {
      for (final style in MapStyle.values) {
        final layer = buildTileLayer(
          provider: MapProvider.ovital,
          style: style,
          ovitalUrl: r'http://h:9999/getomap_202_{$z}_{$x}_{$y}_0_0.png',
        );
        expect(layer.urlTemplate,
            'http://h:9999/getomap_202_{z}_{x}_{y}_0_0.png');
      }
    });

    test('falls back to OSM when nothing is configured', () {
      final layer =
          buildTileLayer(provider: MapProvider.ovital, style: MapStyle.standard);
      expect(layer.urlTemplate, contains('openstreetmap.org'));
    });

    test('gives a {s} template a single-host subdomain pool', () {
      final layer = buildTileLayer(
        provider: MapProvider.ovital,
        style: MapStyle.standard,
        ovitalUrl: 'http://{s}.h/{z}/{x}/{y}.png',
      );
      expect(layer.subdomains, hasLength(1));
    });

    test('custom OSM url also accepts the Ovital spelling', () {
      final layer = buildTileLayer(
        provider: MapProvider.osm,
        style: MapStyle.standard,
        customOsmUrl: r'https://mirror/{$z}/{$x}/{$y}.png',
      );
      expect(layer.urlTemplate, 'https://mirror/{z}/{x}/{y}.png');
    });
  });

  group('needsGcj02', () {
    tearDown(() => CoordConverter.ovitalUsesGcj02 = true);

    test('ovital follows the runtime toggle', () {
      CoordConverter.ovitalUsesGcj02 = true;
      expect(CoordConverter.needsGcj02(MapProvider.ovital), isTrue);
      CoordConverter.ovitalUsesGcj02 = false;
      expect(CoordConverter.needsGcj02(MapProvider.ovital), isFalse);
    });

    test('other providers are unaffected by the toggle', () {
      CoordConverter.ovitalUsesGcj02 = false;
      expect(CoordConverter.needsGcj02(MapProvider.amap), isTrue);
      expect(CoordConverter.needsGcj02(MapProvider.google), isTrue);
      expect(CoordConverter.needsGcj02(MapProvider.osm), isFalse);
    });
  });

  group('AppSettings persistence', () {
    test('ovital is appended (index 3) so stored indices keep meaning', () {
      expect(MapProvider.values.indexOf(MapProvider.ovital), 3);
      expect(MapProvider.values.indexOf(MapProvider.amap), 1);
    });

    test('ovital fields round-trip through toJson/fromJson', () {
      const s = AppSettings(
        mapProvider: MapProvider.ovital,
        ovitalTileUrl: 'http://h/{z}/{x}/{y}.png',
        ovitalGcj02: false,
      );
      final back = AppSettings.fromJson(s.toJson());
      expect(back.mapProvider, MapProvider.ovital);
      expect(back.ovitalTileUrl, 'http://h/{z}/{x}/{y}.png');
      expect(back.ovitalGcj02, isFalse);
    });

    test('defaults: no url, GCJ-02 on', () {
      final s = AppSettings.fromJson(const {});
      expect(s.ovitalTileUrl, isNull);
      expect(s.ovitalGcj02, isTrue);
    });

    test('unknown enum index falls back instead of throwing', () {
      // A future build stored provider 7; this build must keep the REST of
      // the blob (fog colour here) rather than resetting everything.
      final s = AppSettings.fromJson(const {
        'mapProvider': 7,
        'mapStyle': -1,
        'recordingMode': 'bogus',
        'fogColor': 0xFF123456,
      });
      expect(s.mapProvider, MapProvider.amap);
      expect(s.mapStyle, MapStyle.standard);
      expect(s.recordingMode, RecordingMode.balanced);
      expect(s.fogColor, 0xFF123456);
    });
  });
}
