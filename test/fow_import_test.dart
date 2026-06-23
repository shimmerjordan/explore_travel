import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';
import 'package:explore_journal/services/fog/fow_compat.dart';

/// Verifies the Fog of World import pipeline: filename decode → zlib parse →
/// batched [FogEngine.importBlocks]. The round-trip test is self-contained;
/// the second test runs against a real extracted "Sync" folder when present
/// (it's skipped in CI where the fixture is absent).
void main() {
  late AppDb db;
  late FogEngine fog;

  setUp(() {
    db = AppDb.forTesting(NativeDatabase.memory());
    fog = FogEngine(db);
  });
  tearDown(() => db.close());

  Future<int> newLayer(String name) => db.insertLayer(
        TrackLayersCompanion.insert(
          name: name,
          colorValue: 0xFF00BCD4,
          createdAt: DateTime.now(),
        ),
      );

  test('export → parse → batched import round-trips fog exactly', () async {
    final a = await newLayer('A');
    // Reveal a handful of pixels in different FoW tiles (Beijing, Shanghai,
    // Chengdu) so the export spans multiple tiles/blocks.
    await fog.revealSinglePixel(lat: 39.9042, lng: 116.4074, layerId: a);
    await fog.revealSinglePixel(lat: 31.2304, lng: 121.4737, layerId: a);
    await fog.revealSinglePixel(lat: 30.5728, lng: 104.0668, layerId: a);

    final zip = await exportFowArchive(engine: fog, layerIds: [a]);
    expect(zip, isNotEmpty, reason: 'export should produce a non-empty zip');

    final blocks = fowBlocksFromArchive(zip);
    expect(blocks, isNotEmpty, reason: 'archive should parse into blocks');

    final b = await newLayer('B');
    final written = await fog.importBlocks(layerId: b, blocks: blocks);
    expect(written, greaterThan(0));

    // Layer B's fog must be byte-identical to layer A's (same tile keys + bitmaps).
    Future<Map<(int, int), String>> snapshot(int layer) async {
      final tiles = await db.fogTilesForLayers([layer], FogEngine.tileZoom);
      return {for (final t in tiles) (t.tileX, t.tileY): t.bitmap.join(',')};
    }

    final sa = await snapshot(a);
    final sb = await snapshot(b);
    expect(sb.keys.toSet(), equals(sa.keys.toSet()),
        reason: 'imported tiles must cover the same DB cells');
    for (final k in sa.keys) {
      expect(sb[k], equals(sa[k]), reason: 'bitmap mismatch at $k');
    }
  });

  test('importing the same FoW data twice is idempotent (OR-merge)', () async {
    final a = await newLayer('A');
    await fog.revealSinglePixel(lat: 39.9042, lng: 116.4074, layerId: a);
    final zip = await exportFowArchive(engine: fog, layerIds: [a]);
    final blocks = fowBlocksFromArchive(zip);

    final b = await newLayer('B');
    final first = await fog.importBlocks(layerId: b, blocks: blocks);
    final after1 = await db.fogTilesForLayers([b], FogEngine.tileZoom);
    final second = await fog.importBlocks(layerId: b, blocks: blocks);
    final after2 = await db.fogTilesForLayers([b], FogEngine.tileZoom);

    expect(second, equals(first), reason: 'same blocks touched both times');
    expect(after2.length, equals(after1.length),
        reason: 're-import must not create extra tiles');
  });

  test('progress parser matches the sync parser and reports completion',
      () async {
    final a = await newLayer('A');
    await fog.revealSinglePixel(lat: 39.9042, lng: 116.4074, layerId: a);
    await fog.revealSinglePixel(lat: 31.2304, lng: 121.4737, layerId: a);
    final zip = await exportFowArchive(engine: fog, layerIds: [a]);

    final sync = fowBlocksFromArchive(zip);
    var lastDone = 0;
    var lastTotal = 0;
    final progressive = await fowBlocksFromArchiveProgress(
      zip,
      onProgress: (done, total) {
        lastDone = done;
        lastTotal = total;
      },
    );
    expect(progressive.length, equals(sync.length));
    expect(lastTotal, greaterThan(0));
    expect(lastDone, equals(lastTotal),
        reason: 'final progress callback should report completion');
  });

  test('fogTilesInRange returns only tiles inside the window', () async {
    final a = await newLayer('A');
    await fog.revealSinglePixel(lat: 39.9042, lng: 116.4074, layerId: a);
    final all = await db.fogTilesForLayers([a], FogEngine.tileZoom);
    expect(all, isNotEmpty);
    final t = all.first;

    final inWindow = await db.fogTilesInRange(
        [a], FogEngine.tileZoom, t.tileX - 1, t.tileX + 1, t.tileY - 1, t.tileY + 1);
    expect(inWindow.map((e) => (e.tileX, e.tileY)), contains((t.tileX, t.tileY)));

    final outOfWindow = await db.fogTilesInRange([a], FogEngine.tileZoom,
        t.tileX + 1000, t.tileX + 1001, t.tileY, t.tileY);
    expect(outOfWindow, isEmpty);
  });

  test('parseFowInputs (isolate entrypoint) matches direct parsing', () async {
    final a = await newLayer('A');
    await fog.revealSinglePixel(lat: 39.9042, lng: 116.4074, layerId: a);
    await fog.revealSinglePixel(lat: 31.2304, lng: 121.4737, layerId: a);
    final zip = await exportFowArchive(engine: fog, layerIds: [a]);
    final viaInputs = parseFowInputs([(name: 'Sync.zip', bytes: zip)]);
    final direct = fowBlocksFromArchive(zip);
    expect(viaInputs.length, equals(direct.length));
    expect(viaInputs, isNotEmpty);
  });

  test('imports a real Fog of World Sync folder when one is provided',
      () async {
    // Point this at an extracted FoW "Sync" folder to exercise real data:
    //   FOW_SYNC_DIR=/path/to/Sync flutter test test/fow_import_test.dart
    // Skipped (no-op) when unset, so CI and other machines stay green.
    final fixture = Platform.environment['FOW_SYNC_DIR'];
    if (fixture == null || fixture.isEmpty) return;
    final dir = Directory(fixture);
    if (!dir.existsSync()) return;

    final layer = await newLayer('FOW');
    final blocks = <FowBlockImport>[];
    var files = 0;
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      final parsed = fowBlocksFromFile(name, f.readAsBytesSync());
      if (parsed.isNotEmpty) {
        files++;
        blocks.addAll(parsed);
      }
    }
    expect(files, greaterThan(100), reason: 'should parse the ~220 Sync files');
    expect(blocks.length, greaterThan(10000),
        reason: 'should decode tens of thousands of blocks');

    final written = await fog.importBlocks(layerId: layer, blocks: blocks);
    expect(written, greaterThan(1000));
    final tiles = await db.fogTilesForLayers([layer], FogEngine.tileZoom);
    expect(tiles, isNotEmpty);
    // ignore: avoid_print
    print('REAL FoW: $files files → ${blocks.length} blocks → '
        '$written tile rows written');
  });
}
