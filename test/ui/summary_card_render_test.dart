import 'dart:ui' as ui;

import 'package:explore_journal/services/stats/summary_card_data.dart';
import 'package:explore_journal/ui/common/app_theme.dart';
import 'package:explore_journal/ui/stats/summary_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 总结卡的渲染冒烟：它要被抓成 PNG 发出去，所以最起码得能布局、能画、
/// 抓出来的图非空且尺寸对得上。没做 golden——像素级比对在字体回退不同的
/// 机器上必然漂，维护成本高于收益。
void main() {
  SummaryCardData card({
    bool empty = false,
    bool withShape = true,
    List<SummaryPlace> places = const [],
  }) =>
      SummaryCardData(
        range: SummaryRange.year(2026),
        totalMeters: empty ? 0 : 1234567,
        recordedDays: empty ? 0 : 128,
        longestStreakDays: empty ? 0 : 17,
        countries: empty ? const [] : const ['中国', '日本', '泰国'],
        hourly: empty
            ? List.filled(24, 0)
            : [for (var i = 0; i < 24; i++) (i % 7) / 6],
        places: places,
        shape: (empty || !withShape)
            ? const []
            : [
                for (var i = 0; i < 200; i++)
                  SummaryShapePoint(
                    0.5 + 0.4 * (i % 20) / 20 - 0.2,
                    i / 200,
                    connected: i % 50 != 0, // 每 50 个点断一次
                  ),
              ],
      );

  Widget host(SummaryCardData d) => MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: const ValueKey('card'),
              child: SummaryCard(data: d),
            ),
          ),
        ),
      );

  /// `toImage` 要等引擎真的光栅化，在 widget test 里必须放进 `runAsync`，
  /// 否则 fake async 时钟下这个 Future 永远不完成（会一路挂到超时）。
  Future<ui.Image?> capture(WidgetTester tester) => tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('card')));
        return boundary.toImage(pixelRatio: 1080 / kSummaryCardSize.width);
      });

  testWidgets('有数据的卡片画得出来，抓成 1080 宽的图', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(card(places: const [
      SummaryPlace('家', 3600 * 40),
      SummaryPlace('公司', 3600 * 22),
      SummaryPlace('一个名字特别长的地方用来测省略号会不会撑破布局', 1800),
    ])));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final img = await capture(tester);
    expect(img, isNotNull);
    addTearDown(img!.dispose);
    expect(img.width, 1080);
    expect(img.height,
        (1080 * kSummaryCardSize.height / kSummaryCardSize.width).round());

    final bytes = await tester
        .runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
    expect(bytes, isNotNull);
    expect(bytes!.lengthInBytes, greaterThan(1000), reason: '不该是一张空图');
  });

  testWidgets('没有轨迹点时说清楚，而不是画一张空画布', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(card(withShape: false)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('没有轨迹'), findsOneWidget);
  });

  testWidgets('空范围显示「还没有记录」，不摆一排 0', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(card(empty: true)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('这段时间还没有记录'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('卡片尺寸固定，不随外部约束变形', (tester) async {
    tester.view.physicalSize = const Size(2000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(card()));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SummaryCard)), kSummaryCardSize);
  });
}
