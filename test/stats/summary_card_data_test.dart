import 'package:explore_journal/services/stats/summary_card_data.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Pt = ({double lat, double lng, DateTime time});

Pt p(double lat, double lng, DateTime t) => (lat: lat, lng: lng, time: t);

void main() {
  final t0 = DateTime(2026, 7, 9, 10);

  group('SummaryRange.year', () {
    test('覆盖整年，不多一微秒也不少一微秒', () {
      final r = SummaryRange.year(2026);
      expect(r.title, '2026 年');
      expect(r.contains(DateTime(2026)), isTrue);
      expect(r.contains(DateTime(2026, 12, 31, 23, 59, 59)), isTrue);
      expect(r.contains(DateTime(2025, 12, 31, 23, 59, 59)), isFalse);
      expect(r.contains(DateTime(2027)), isFalse);
    });
  });

  group('buildShape', () {
    test('少于两个点没有形状', () {
      expect(SummaryCardData.buildShape([]), isEmpty);
      expect(SummaryCardData.buildShape([p(31, 121, t0)]), isEmpty);
    });

    test('原地不动没有形状（避免画出一个点当作旅程）', () {
      final pts = [
        for (var i = 0; i < 10; i++)
          p(31.0, 121.0, t0.add(Duration(minutes: i)))
      ];
      expect(SummaryCardData.buildShape(pts), isEmpty);
    });

    test('归一化进 0..1，且等比不变形', () {
      // 一条正南北的线：x 应该全在中线上，y 铺满 0..1。
      final pts = [
        for (var i = 0; i < 5; i++)
          p(31.0 + i * 0.01, 121.0, t0.add(Duration(minutes: i)))
      ];
      final shape = SummaryCardData.buildShape(pts);
      expect(shape.length, 5);
      for (final s in shape) {
        expect(s.x, closeTo(0.5, 1e-9), reason: '经度没变，x 该在中线');
        expect(s.y, inInclusiveRange(0, 1));
      }
      // 上北：纬度最大的点 y 最小。
      expect(shape.last.y, lessThan(shape.first.y));
      expect(shape.first.y, closeTo(1.0, 1e-9));
      expect(shape.last.y, closeTo(0.0, 1e-9));
    });

    test('高纬度不会被横向拉扁：同样的经纬跨度，形状仍等比', () {
      List<SummaryShapePoint> at(double lat) => SummaryCardData.buildShape([
            p(lat, 0.0, t0),
            p(lat + 0.02, 0.0, t0.add(const Duration(minutes: 1))),
            p(lat, 0.02, t0.add(const Duration(minutes: 2))),
          ]);
      // 赤道附近经度不收缩，高纬度收缩——收缩后 x 跨度应当明显更小。
      final eq = at(0.0), north = at(60.0);
      double xSpan(List<SummaryShapePoint> s) =>
          s.map((e) => e.x).reduce((a, b) => a > b ? a : b) -
          s.map((e) => e.x).reduce((a, b) => a < b ? a : b);
      expect(xSpan(north), lessThan(xSpan(eq)));
      // 但两者都仍落在 0..1 内。
      for (final s in [...eq, ...north]) {
        expect(s.x, inInclusiveRange(0, 1));
        expect(s.y, inInclusiveRange(0, 1));
      }
    });

    test('间隔超过阈值的相邻点断开，不连成跨城直线', () {
      final pts = [
        p(31.0, 121.0, t0),
        p(31.01, 121.01, t0.add(const Duration(minutes: 5))),
        // 三小时后出现在另一座城市：不该与上一点连线
        p(39.9, 116.4, t0.add(const Duration(hours: 3))),
        p(39.91, 116.41, t0.add(const Duration(hours: 3, minutes: 5))),
      ];
      final shape = SummaryCardData.buildShape(pts);
      expect(shape[0].connected, isFalse, reason: '第一个点没有前驱');
      expect(shape[1].connected, isTrue);
      expect(shape[2].connected, isFalse, reason: '跨了 3 小时，必须断开');
      expect(shape[3].connected, isTrue);
    });

    test('点太多时抽稀，但首尾都保留', () {
      final pts = [
        for (var i = 0; i < 9000; i++)
          p(31.0 + i * 0.0001, 121.0 + i * 0.0001, t0.add(Duration(seconds: i)))
      ];
      final shape = SummaryCardData.buildShape(pts, maxPoints: 100);
      expect(shape.length, lessThanOrEqualTo(102));
      expect(shape.first.y, closeTo(1.0, 1e-6), reason: '起点（最南）应保留');
      expect(shape.last.y, closeTo(0.0, 1e-6), reason: '终点（最北）应保留');
    });
  });

  group('pathMeters', () {
    test('按相邻点累加', () {
      final pts = [
        p(31.0, 121.0, t0),
        p(31.001, 121.0, t0.add(const Duration(minutes: 2))),
      ];
      // 0.001° 纬度 ≈ 111 m
      expect(SummaryCardData.pathMeters(pts), closeTo(111, 3));
    });

    test('跨越长间隔的段不计（与足迹统计同口径）', () {
      final pts = [
        p(31.0, 121.0, t0),
        p(31.001, 121.0, t0.add(const Duration(hours: 2))),
      ];
      expect(SummaryCardData.pathMeters(pts), 0);
    });

    test('隐含速度超过 300 km/h 的段不计', () {
      final pts = [
        p(31.0, 121.0, t0),
        p(39.9, 116.4, t0.add(const Duration(minutes: 10))), // 上海→北京 10 分钟
      ];
      expect(SummaryCardData.pathMeters(pts), 0);
    });
  });

  group('normalizeHourly', () {
    test('按峰值归一', () {
      final n = SummaryCardData.normalizeHourly(
          [for (var i = 0; i < 24; i++) i == 8 ? 50 : 10]);
      expect(n[8], 1.0);
      expect(n[0], closeTo(0.2, 1e-9));
    });

    test('全零与长度不对都返回 24 个零，不会除零', () {
      expect(SummaryCardData.normalizeHourly(List.filled(24, 0)),
          List.filled(24, 0.0));
      expect(SummaryCardData.normalizeHourly(const []), List.filled(24, 0.0));
    });
  });

  group('isEmpty', () {
    SummaryCardData make({double meters = 0, int days = 0, List<SummaryShapePoint> shape = const []}) =>
        SummaryCardData(
          range: SummaryRange.year(2026),
          totalMeters: meters,
          recordedDays: days,
          longestStreakDays: 0,
          countries: const [],
          hourly: List.filled(24, 0),
          places: const [],
          shape: shape,
        );

    test('这段范围什么都没有时说得出来', () {
      expect(make().isEmpty, isTrue);
      expect(make(meters: 1200).isEmpty, isFalse);
      expect(make(days: 3).isEmpty, isFalse);
    });

    test('只有一个点也不算有形状', () {
      expect(make(shape: const [SummaryShapePoint(0.5, 0.5, connected: false)]).hasShape,
          isFalse);
    });
  });
}
