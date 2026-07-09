import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/data/db/database.dart';

/// Pins the layer self-heal: content referencing a layerId with no matching
/// track_layers row must get a layer recreated for it, or the layer-driven
/// map/trail/journal render pipeline shows a blank screen despite holding all
/// its data (the exact "0 layers, 462710 fog rows, nothing renders" report).
void main() {
  late AppDb db;

  setUp(() => db = AppDb.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> wipeLayers() async {
    await db.customStatement('DELETE FROM track_layers');
  }

  test('a wiped layer table with orphaned content recreates the layer',
      () async {
    // Fresh DB has the default layer (id 1). Put content on it, then wipe
    // the layer table to simulate the corrupted state.
    await db.insertPoint(TrackPointsCompanion.insert(
      lat: 30, lng: 104, time: DateTime(2026, 6, 1), layerId: 1,
    ));
    await db.batchUpsertFogTiles([
      FogTilesCompanion.insert(
        tileX: 10, tileY: 20, zoom: 100, layerId: 1,
        bitmap: Uint8List(512)..[0] = 1, updatedAt: DateTime(2026, 6, 1),
      ),
    ]);
    await wipeLayers();
    expect(await db.allLayers(), isEmpty);

    final healed = await db.ensureLayersForContent();
    expect(healed, 1);
    final layers = await db.allLayers();
    expect(layers, hasLength(1));
    expect(layers.single.id, 1, reason: 'reuses the referenced id → content re-homes');
    expect(layers.single.visible, isTrue);
    expect(layers.single.uuid, 'default-layer',
        reason: 'id 1 recovers to the stable default uuid so devices converge');
  });

  test('recreates one layer per distinct orphaned id', () async {
    await db.insertPoint(TrackPointsCompanion.insert(
      lat: 30, lng: 104, time: DateTime(2026, 6, 1), layerId: 3,
    ));
    await db.insertPoint(TrackPointsCompanion.insert(
      lat: 31, lng: 105, time: DateTime(2026, 6, 2), layerId: 7,
    ));
    await wipeLayers();

    final healed = await db.ensureLayersForContent();
    expect(healed, 2);
    expect((await db.allLayers()).map((l) => l.id).toSet(), {3, 7});
  });

  test('a healthy DB (layers cover content) is left untouched', () async {
    // Default layer id 1 exists; content references it.
    await db.insertPoint(TrackPointsCompanion.insert(
      lat: 30, lng: 104, time: DateTime(2026, 6, 1), layerId: 1,
    ));
    final before = (await db.allLayers()).length;
    expect(await db.ensureLayersForContent(), 0);
    expect((await db.allLayers()).length, before);
  });

  test('layer-less AND content-less DB reseeds a default', () async {
    await wipeLayers();
    expect(await db.ensureLayersForContent(), 1);
    final layers = await db.allLayers();
    expect(layers.single.name, '默认图层');
    expect(layers.single.uuid, 'default-layer');
  });

  test('recovery clears a stale tombstone for the layer it restores — '
      'breaks the delete→recreate→delete churn', () async {
    await db.insertPoint(TrackPointsCompanion.insert(
      lat: 30, lng: 104, time: DateTime(2026, 6, 1), layerId: 5,
    ));
    await wipeLayers();
    // Simulate a stale cloud tombstone for the uuid recovery will use.
    await db.recordTombstones('track_layers', ['recovered-layer-5']);
    expect(await db.tombstonedUuids('track_layers'), contains('recovered-layer-5'));

    expect(await db.ensureLayersForContent(), 1);
    // The tombstone must be gone, or the next sync would delete the layer
    // again and recovery would recreate it forever.
    expect(await db.tombstonedUuids('track_layers'),
        isNot(contains('recovered-layer-5')));
    expect((await db.allLayers()).single.uuid, 'recovered-layer-5');
  });

  test('idempotent — a second run creates nothing more', () async {
    await db.insertPoint(TrackPointsCompanion.insert(
      lat: 30, lng: 104, time: DateTime(2026, 6, 1), layerId: 5,
    ));
    await wipeLayers();
    expect(await db.ensureLayersForContent(), 1);
    expect(await db.ensureLayersForContent(), 0);
    expect(await db.allLayers(), hasLength(1));
  });
}
