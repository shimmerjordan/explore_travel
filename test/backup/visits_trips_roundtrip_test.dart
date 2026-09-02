import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/playback/merged_trip_model.dart';

/// Real export → import round trips for the new 'visits' and 'trips'
/// modules: user rows travel with UUID-based references (layer / place),
/// machine rows stay home, places converge instead of duplicating, and
/// deletions propagate (soft-delete rows for visits, tombstones for trips).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDb a, b;
  late BackupService svcA, svcB;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    a = AppDb.forTesting(NativeDatabase.memory());
    b = AppDb.forTesting(NativeDatabase.memory());
    svcA = BackupService(a);
    svcB = BackupService(b);
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  final t0 = DateTime(2026, 8, 20, 8);

  Future<int> layer(AppDb db, String uuid, String name) =>
      db.insertLayer(TrackLayersCompanion.insert(
        uuid: Value(uuid),
        name: name,
        colorValue: 0xFF00BCD4,
        createdAt: t0,
        updatedAt: Value(t0),
      ));

  Future<int> place(AppDb db, String uuid,
          {String name = '家',
          double lat = 30,
          double lng = 104,
          int source = 1,
          DateTime? updatedAt}) =>
      db.insertPlace(PlacesCompanion.insert(
        uuid: Value(uuid),
        name: name,
        lat: lat,
        lng: lng,
        source: Value(source),
        createdAt: t0,
        updatedAt: Value(updatedAt ?? t0),
      ));

  Future<void> visit(AppDb db,
          {required String uuid,
          required int layerId,
          int? placeId,
          int status = 1,
          DateTime? deletedAt,
          DateTime? updatedAt}) =>
      db.insertVisits([
        VisitsCompanion.insert(
          uuid: Value(uuid),
          placeId: Value(placeId),
          layerId: layerId,
          startedAt: t0,
          endedAt: t0.add(const Duration(hours: 2)),
          lat: 30,
          lng: 104,
          radius: 40,
          pointCount: 20,
          status: Value(status),
          confidence: const Value(85),
          deletedAt: Value(deletedAt),
          createdAt: t0,
          updatedAt: Value(updatedAt ?? t0),
        ),
      ]);

  test('user visits travel with remapped layer/place; machine rows stay home',
      () async {
    final layerA = await layer(a, 'layer-1', '旅行');
    final placeA = await place(a, 'place-home');
    await visit(a, uuid: 'v-confirmed', layerId: layerA, placeId: placeA);
    await visit(a, uuid: 'v-machine', layerId: layerA, status: 0);
    await visit(a,
        uuid: 'v-deleted',
        layerId: layerA,
        placeId: placeA,
        deletedAt: DateTime(2026, 8, 21));

    final bytes = await svcA
        .exportToArchive({'layers', 'visits', 'tombstones', 'leaderboard'});
    // B has its own layer ids: seed an unrelated layer first so ids shift.
    await layer(b, 'layer-other', '别的');
    final summary = await svcB.importFromArchive(bytes,
        modules: BackupService.allModules.toSet());
    expect(summary.errors, isEmpty);

    final layersB = await b.allLayers();
    final layer1B = layersB.firstWhere((l) => l.uuid == 'layer-1');
    final placesB = await b.allPlaces();
    expect(placesB.map((p) => p.uuid), contains('place-home'));
    final visitsB = await b.select(b.visits).get();
    expect(visitsB.map((v) => v.uuid).toSet(), {'v-confirmed', 'v-deleted'},
        reason: 'machine rows must not travel');
    final confirmed = visitsB.firstWhere((v) => v.uuid == 'v-confirmed');
    expect(confirmed.layerId, layer1B.id, reason: 'layer remapped by uuid');
    expect(confirmed.placeId,
        placesB.firstWhere((p) => p.uuid == 'place-home').id);
    expect(confirmed.status, 1);
    final deleted = visitsB.firstWhere((v) => v.uuid == 'v-deleted');
    expect(deleted.deletedAt, isNotNull,
        reason: 'a soft-deleted visit travels as a tombstone row');

    // Idempotent: importing the same archive again changes nothing.
    await svcB.importFromArchive(bytes,
        modules: BackupService.allModules.toSet());
    expect((await b.select(b.visits).get()).length, 2);
    expect((await b.allPlaces()).length, 1);
  });

  test('an incoming place folds onto a local one within 30 m', () async {
    final layerA = await layer(a, 'layer-1', '旅行');
    final placeA = await place(a, 'place-a', name: '公司', lat: 30.0001);
    await visit(a, uuid: 'v-1', layerId: layerA, placeId: placeA);
    final bytes = await svcA
        .exportToArchive({'layers', 'visits', 'tombstones', 'leaderboard'});

    // B auto-minted its own place ~11 m away for the same spot.
    await layer(b, 'layer-1', '旅行');
    final localPlace = await place(b, 'place-b-auto',
        name: '未命名地点', lat: 30.0002, source: 0, updatedAt: DateTime(2026, 1, 1));
    await svcB.importFromArchive(bytes,
        modules: BackupService.allModules.toSet());

    final placesB = await b.allPlaces();
    expect(placesB.length, 1, reason: 'no duplicate place for the same spot');
    expect(placesB.single.id, localPlace);
    expect(placesB.single.uuid, 'place-a',
        reason: 'local row re-stamped so future pulls match by uuid');
    expect(placesB.single.name, '公司', reason: 'newer incoming name wins');
    final v = (await b.select(b.visits).get()).single;
    expect(v.placeId, localPlace);
  });

  test('trips round-trip, rename wins by LWW, dissolve propagates', () async {
    await layer(a, 'layer-1', '旅行');
    await a.insertMergedTrip(MergedTripsCompanion.insert(
      uuid: const Value('trip-1'),
      name: '川西环线',
      segmentsJson: encodeTripSegments(
          [TripSegment('layer-1', t0.millisecondsSinceEpoch, t0.add(const Duration(days: 2)).millisecondsSinceEpoch)]),
      createdAt: t0,
      updatedAt: Value(t0),
    ));
    final bytes = await svcA
        .exportToArchive({'layers', 'trips', 'tombstones', 'leaderboard'});
    await svcB.importFromArchive(bytes,
        modules: BackupService.allModules.toSet());
    final tripB = (await b.allMergedTrips()).single;
    expect(tripB.name, '川西环线');
    expect(decodeTripSegments(tripB.segmentsJson).single.layerUuid, 'layer-1');

    // B renames later → re-importing the OLDER archive must not undo it.
    await b.renameMergedTrip(tripB.id, '川西 2026');
    await svcB.importFromArchive(bytes,
        modules: BackupService.allModules.toSet());
    expect((await b.allMergedTrips()).single.name, '川西 2026');

    // A dissolves the trip → the tombstone rides the next export and removes
    // B's copy (B's rename is younger than nothing — deletes always win).
    final tripA = (await a.allMergedTrips()).single;
    await a.deleteMergedTrip(tripA.id);
    final bytes2 = await svcA
        .exportToArchive({'layers', 'trips', 'tombstones', 'leaderboard'});
    await svcB.importFromArchive(bytes2,
        modules: BackupService.allModules.toSet());
    expect(await b.allMergedTrips(), isEmpty);
  });

  test('a visit whose layer is absent locally is skipped, not misfiled',
      () async {
    final layerA = await layer(a, 'layer-x', 'X');
    await visit(a, uuid: 'v-x', layerId: layerA);
    // Export WITHOUT the layers module: B never learns layer-x.
    final bytes =
        await svcA.exportToArchive({'visits', 'tombstones', 'leaderboard'});
    final summary = await svcB.importFromArchive(bytes,
        modules: BackupService.allModules.toSet());
    expect(summary.errors, isEmpty);
    expect(await b.select(b.visits).get(), isEmpty);
  });
}
