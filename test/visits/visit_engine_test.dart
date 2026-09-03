import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/geo/geocoding_service.dart';
import 'package:explore_journal/services/visits/stay_detector.dart' show StayParams;
import 'package:explore_journal/services/visits/visit_engine.dart';

void main() {
  late AppDb db;
  late VisitEngine engine;
  var geocodeCalls = 0;

  setUp(() {
    db = AppDb.forTesting(NativeDatabase.memory());
    geocodeCalls = 0;
    engine = VisitEngine(db, geocoder: (lat, lng) async {
      geocodeCalls++;
      return const GeocodeResult(
          country: '中国', province: '四川省', city: '成都市', source: 'test');
    });
  });
  tearDown(() async {
    engine.dispose();
    await db.close();
  });

  final day = DateTime(2026, 8, 20);
  Future<void> dwell(double lat, double lng, DateTime from, int minutes,
      {int layer = 1}) async {
    final rows = <TrackPointsCompanion>[];
    for (var m = 0; m <= minutes; m += 5) {
      rows.add(TrackPointsCompanion.insert(
        lat: lat + (m.isEven ? 0.00005 : -0.00005),
        lng: lng,
        time: from.add(Duration(minutes: m)),
        layerId: layer,
        accuracy: const Value(12),
      ));
    }
    await db.insertPoints(rows);
  }

  test('detects stays, mints a place per spot, geocodes once per place',
      () async {
    await dwell(30.0, 104.0, day.add(const Duration(hours: 8)), 120); // home
    await dwell(30.05, 104.05, day.add(const Duration(hours: 11)), 300); // work
    final n = await engine.detectRange(day, day.add(const Duration(days: 1)));
    expect(n, 2);
    final visits = await db.visitsBetween(day, day.add(const Duration(days: 1)));
    expect(visits.length, 2);
    expect(visits.every((v) => v.status == 0), isTrue);
    expect(visits.every((v) => v.confidence > 0), isTrue);
    final places = await db.allPlaces();
    expect(places.length, 2);
    expect(places.first.name, '成都市 · 未命名地点');
    expect(places.first.city, '成都市');
    expect(geocodeCalls, 2);
  });

  test('re-running is idempotent: no duplicate visits or places', () async {
    await dwell(30.0, 104.0, day.add(const Duration(hours: 8)), 120);
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    expect((await db.visitsBetween(day, day.add(const Duration(days: 1)))).length, 1);
    expect((await db.allPlaces()).length, 1);
    expect(geocodeCalls, 1);
  });

  test('a returning stay is attributed to the existing place', () async {
    await dwell(30.0, 104.0, day.add(const Duration(hours: 8)), 60); // home
    await dwell(30.05, 104.05, day.add(const Duration(hours: 12)), 60); // away
    await dwell(30.0001, 104.0001, day.add(const Duration(hours: 20)), 60);
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    final visits = await db.visitsBetween(day, day.add(const Duration(days: 1)));
    expect(visits.length, 3);
    expect(visits[0].placeId, visits[2].placeId);
    expect(visits[1].placeId, isNot(visits[0].placeId));
    expect((await db.allPlaces()).length, 2);
  });

  test('same spot before and after a silence is ONE bridged stay', () async {
    await dwell(30.0, 104.0, day.add(const Duration(hours: 8)), 60);
    await dwell(30.0001, 104.0001, day.add(const Duration(hours: 20)), 60);
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    final visits = await db.visitsBetween(day, day.add(const Duration(days: 1)));
    expect(visits.length, 1);
    expect(visits.single.bridgedSec, greaterThan(10 * 3600));
  });

  test('a confirmed visit is an anchor: re-detection keeps it, adds no twin',
      () async {
    await dwell(30.0, 104.0, day.add(const Duration(hours: 8)), 120);
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    final v = (await db.visitsBetween(day, day.add(const Duration(days: 1)))).single;
    await engine.confirm(v.id);
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    final after = await db.visitsBetween(day, day.add(const Duration(days: 1)));
    expect(after.length, 1);
    expect(after.single.id, v.id);
    expect(after.single.status, 1);
  });

  test('a deleted visit leaves a tombstone and is never re-suggested',
      () async {
    await dwell(30.0, 104.0, day.add(const Duration(hours: 8)), 120);
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    final v = (await db.visitsBetween(day, day.add(const Duration(days: 1)))).single;
    await engine.remove(v.id);
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    final live = await db.visitsBetween(day, day.add(const Duration(days: 1)));
    expect(live, isEmpty);
    final all = await db.visitsBetween(day, day.add(const Duration(days: 1)),
        includeDeleted: true);
    expect(all.length, 1);
    expect(all.single.deletedAt, isNotNull);
  });

  test('rename locks the place as manual; assign drops orphaned auto place',
      () async {
    await dwell(30.0, 104.0, day.add(const Duration(hours: 8)), 60);
    await dwell(30.05, 104.05, day.add(const Duration(hours: 12)), 60);
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    final places = await db.allPlaces();
    final home = places[0], other = places[1];
    await engine.renamePlace(home.id, ' 家 ');
    final renamed = (await db.allPlaces()).firstWhere((p) => p.id == home.id);
    expect(renamed.name, '家');
    expect(renamed.source, 1);

    final visits = await db.visitsBetween(day, day.add(const Duration(days: 1)));
    final atOther = visits.firstWhere((v) => v.placeId == other.id);
    await engine.assignPlace(atOther.id, home.id);
    final left = await db.allPlaces();
    expect(left.map((p) => p.id), [home.id]); // orphaned auto place gone
    final moved = (await db.visitsBetween(day, day.add(const Duration(days: 1))))
        .firstWhere((v) => v.id == atOther.id);
    expect(moved.placeId, home.id);
    expect(moved.status, 1);
  });

  test('detectAll (isolate path) finds exactly what detectRange (inline) does',
      () async {
    // Three stays across two months, two of them at the same spot and one of
    // them bridged across a silence — every branch of the detector in play.
    Future<void> seed(AppDb d) async {
      Future<void> dw(double lat, double lng, DateTime from, int minutes) async {
        final rows = <TrackPointsCompanion>[];
        for (var m = 0; m <= minutes; m += 5) {
          rows.add(TrackPointsCompanion.insert(
            lat: lat + (m.isEven ? 0.00005 : -0.00005),
            lng: lng,
            time: from.add(Duration(minutes: m)),
            layerId: 1,
            accuracy: Value(8.0 + m % 3),
          ));
        }
        await d.insertPoints(rows);
      }

      await dw(30.0, 104.0, DateTime(2026, 6, 3, 8), 90);
      await dw(30.0001, 104.0001, DateTime(2026, 6, 3, 20), 60); // bridged
      await dw(30.05, 104.05, DateTime(2026, 8, 20, 11), 240);
    }

    await seed(db);
    final viaAll = await engine.detectAll(); // bulk → every month in compute()

    final db2 = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    final engine2 = VisitEngine(db2,
        geocoder: (lat, lng) async => const GeocodeResult(
            country: '中国', province: '四川省', city: '成都市', source: 'test'));
    addTearDown(engine2.dispose);
    await seed(db2);
    var viaRange = 0;
    for (final m in [6, 8]) {
      viaRange += await engine2.detectRange(
          DateTime(2026, m), DateTime(2026, m + 1)); // < 2000 pts → inline
    }
    expect(viaAll, 2);
    expect(viaRange, viaAll);

    String key(Visit v) =>
        '${v.startedAt}|${v.endedAt}|${v.pointCount}|${v.bridgedSec}|'
        '${v.lat.toStringAsFixed(6)}|${v.lng.toStringAsFixed(6)}|'
        '${v.radius.toStringAsFixed(3)}|${v.confidence}';
    final a = (await db.visitsBetween(DateTime(2026), DateTime(2027)))
        .map(key)
        .toList()
      ..sort();
    final b = (await db2.visitsBetween(DateTime(2026), DateTime(2027)))
        .map(key)
        .toList()
      ..sort();
    expect(a, b);
    expect((await db.allPlaces()).length, (await db2.allPlaces()).length);
  });

  test('custom StayParams are honoured on the isolate path too', () async {
    // minPoints 30 — a 13-fix dwell must NOT become a stay, whichever path.
    final strict = VisitEngine(db,
        geocoder: (lat, lng) async => null,
        params: const StayParams(minPoints: 30));
    addTearDown(strict.dispose);
    await dwell(30.0, 104.0, DateTime(2026, 6, 3, 9), 60);
    expect(await strict.detectAll(), 0); // isolate
    expect(await strict.detectRange(DateTime(2026, 6), DateTime(2026, 7)), 0);
    await dwell(30.0, 104.0, DateTime(2026, 6, 4, 9), 200); // 41 fixes
    expect(await strict.detectAll(), 1);
  });

  test('concurrent runs are serialised, in order, and all complete', () async {
    await dwell(30.0, 104.0, day.add(const Duration(hours: 8)), 120);
    // Fire three overlapping runs without awaiting between them: the second
    // and third must wait for the first (no interleaved rebuild of the same
    // window) and every future must complete.
    final results = await Future.wait([
      engine.detectAll(),
      engine.detectRange(day, day.add(const Duration(days: 1))),
      engine.detectRecent(lookback: const Duration(days: 365 * 5)),
    ]);
    expect(results, [1, 1, 1]);
    expect((await db.visitsBetween(day, day.add(const Duration(days: 1)))).length, 1);
    expect((await db.allPlaces()).length, 1);
    expect(geocodeCalls, 1);
  });

  test('detectAll walks months and covers every stay', () async {
    await dwell(30.0, 104.0, DateTime(2026, 6, 3, 9), 60);
    await dwell(30.0, 104.0, DateTime(2026, 8, 20, 9), 60);
    final n = await engine.detectAll();
    expect(n, 2);
    expect((await db.allPlaces()).length, 1);
  });

  test('anomaly-flagged points are ignored', () async {
    await dwell(30.0, 104.0, day.add(const Duration(hours: 8)), 60);
    await db.insertPoint(TrackPointsCompanion.insert(
        lat: 45,
        lng: 120,
        time: day.add(const Duration(hours: 8, minutes: 30)),
        layerId: 1,
        flags: const Value(1)));
    await engine.detectRange(day, day.add(const Duration(days: 1)));
    final visits = await db.visitsBetween(day, day.add(const Duration(days: 1)));
    expect(visits.length, 1);
    expect(visits.single.lat, closeTo(30.0, 0.001));
  });
}
