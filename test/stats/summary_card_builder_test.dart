import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/stats/footprint_summary.dart';
import 'package:explore_journal/services/stats/summary_card_builder.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Pt = ({double lat, double lng, DateTime time});

Pt pt(double lat, double lng, DateTime t) => (lat: lat, lng: lng, time: t);

void main() {
  group('year()', () {
    final summary = FootprintSummary(
      dailyMeters: {
        '2025-12-31': 5000, // 上一年，不该算进来
        '2026-01-01': 1000,
        '2026-01-02': 2000,
        '2026-01-03': 3000, // 连续三天
        '2026-05-01': 4000,
      },
      hourly: [for (var i = 0; i < 24; i++) i == 9 ? 100 : 10],
      pointCount: 500,
      first: DateTime(2025, 12, 31),
      last: DateTime(2026, 5, 1),
      dayCountries: {
        '2025-12-31': ['日本'],
        '2026-01-01': ['中国'],
        '2026-05-01': ['中国', '泰国'],
      },
    );

    test('只统计目标年份的天数、里程与国家', () {
      final card = SummaryCardBuilder.year(
        year: 2026,
        summary: summary,
        pointsInYear: const [],
        places: const [],
      );
      expect(card.range.title, '2026 年');
      expect(card.recordedDays, 4, reason: '2025-12-31 不该算进来');
      expect(card.totalMeters, 10000);
      expect(card.countries, ['中国', '泰国'], reason: '日本只在 2025 年出现');
    });

    test('最长连续天数只在该年内计算', () {
      final card = SummaryCardBuilder.year(
        year: 2026,
        summary: summary,
        pointsInYear: const [],
        places: const [],
      );
      // 01-01/02/03 连续三天；05-01 独立。跨年的 12-31→01-01 不该接上。
      expect(card.longestStreakDays, 3);
    });

    test('没有轨迹点时不画形状，但数据仍在（FOW 导入的历史就是这样）', () {
      final card = SummaryCardBuilder.year(
        year: 2026,
        summary: summary,
        pointsInYear: const [],
        places: const [],
      );
      expect(card.hasShape, isFalse);
      expect(card.isEmpty, isFalse, reason: '有里程有天数，不是空卡');
    });

    test('里程与足迹页同源，不重算', () {
      final card = SummaryCardBuilder.year(
        year: 2026, summary: summary, pointsInYear: const [], places: const []);
      expect(card.totalMeters, summary.metersInYear(2026));
    });
  });

  group('trip()', () {
    final t0 = DateTime(2026, 7, 9, 8);
    test('就地算里程、作息与天数', () {
      final points = [
        pt(31.0, 121.0, t0),
        pt(31.001, 121.0, t0.add(const Duration(minutes: 2))),
        pt(31.002, 121.0, t0.add(const Duration(minutes: 4))),
      ];
      final card = SummaryCardBuilder.trip(
        title: '7 月 9 日的旅程',
        from: t0,
        to: t0.add(const Duration(hours: 1)),
        points: points,
        places: const [],
      );
      expect(card.totalMeters, closeTo(222, 6)); // 两段各 ~111 m
      expect(card.recordedDays, 1);
      expect(card.hourly[8], 1.0, reason: '全在 8 点这一格');
      expect(card.hasShape, isTrue);
      expect(card.countries, isEmpty, reason: '单段旅程不做国家归属');
    });

    test('空旅程是空卡，而不是一排 0', () {
      final card = SummaryCardBuilder.trip(
        title: 'x',
        from: t0,
        to: t0,
        points: const [],
        places: const [],
      );
      expect(card.isEmpty, isTrue);
    });
  });

  group('placesFrom()', () {
    late AppDb db;
    setUp(() => db = AppDb.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<int> place(String name) => db.into(db.places).insert(
        PlacesCompanion.insert(
            name: name, lat: 31, lng: 121, createdAt: DateTime(2026)));

    Future<void> visit(int? placeId, DateTime from, Duration d,
            {int status = 0}) =>
        db.into(db.visits).insert(VisitsCompanion.insert(
              placeId: Value(placeId),
              layerId: 1,
              startedAt: from,
              endedAt: from.add(d),
              lat: 31,
              lng: 121,
              radius: 50,
              pointCount: 5,
              status: Value(status),
              createdAt: DateTime(2026),
            ));

    test('按停留时长排序并截断', () async {
      final a = await place('家'), b = await place('公司'), c = await place('公园');
      final base = DateTime(2026, 7, 9, 8);
      await visit(a, base, const Duration(hours: 2));
      await visit(b, base, const Duration(hours: 5));
      await visit(c, base, const Duration(minutes: 30));
      final out = SummaryCardBuilder.placesFrom(
        await db.select(db.visits).get(),
        await db.allPlaces(),
        from: DateTime(2026),
        to: DateTime(2027),
        limit: 2,
      );
      expect(out.map((e) => e.name).toList(), ['公司', '家']);
      expect(out.first.dwellSeconds, 5 * 3600);
    });

    test('同一地点的多次到访累加', () async {
      final a = await place('家');
      final base = DateTime(2026, 7, 9, 8);
      await visit(a, base, const Duration(hours: 1));
      await visit(a, base.add(const Duration(days: 1)), const Duration(hours: 2));
      final out = SummaryCardBuilder.placesFrom(
          await db.select(db.visits).get(), await db.allPlaces(),
          from: DateTime(2026), to: DateTime(2027));
      expect(out.single.dwellSeconds, 3 * 3600);
    });

    test('用户否掉的到访（status=2）不算，范围外的也不算', () async {
      final a = await place('家'), b = await place('机场');
      await visit(a, DateTime(2026, 7, 9), const Duration(hours: 3), status: 2);
      await visit(b, DateTime(2025, 7, 9), const Duration(hours: 4));
      final out = SummaryCardBuilder.placesFrom(
          await db.select(db.visits).get(), await db.allPlaces(),
          from: DateTime(2026), to: DateTime(2027));
      expect(out, isEmpty);
    });

    test('反查不到名字的地点不上卡（未命名地点 / 城市 · 未命名地点）', () async {
      final a = await place('未命名地点');
      final b = await place('上海市 · 未命名地点');
      final c = await place('外滩');
      await visit(a, DateTime(2026, 7, 9), const Duration(hours: 9));
      await visit(b, DateTime(2026, 7, 9), const Duration(hours: 8));
      await visit(c, DateTime(2026, 7, 9), const Duration(hours: 1));
      final out = SummaryCardBuilder.placesFrom(
          await db.select(db.visits).get(), await db.allPlaces(),
          from: DateTime(2026), to: DateTime(2027));
      expect(out.map((e) => e.name).toList(), ['外滩'],
          reason: '待得更久但没名字的两处不该顶掉真正有名字的');
    });

    test('没有名字的地点不上卡', () async {
      final a = await place('   ');
      await visit(a, DateTime(2026, 7, 9), const Duration(hours: 3));
      final out = SummaryCardBuilder.placesFrom(
          await db.select(db.visits).get(), await db.allPlaces(),
          from: DateTime(2026), to: DateTime(2027));
      expect(out, isEmpty);
    });
  });
}
