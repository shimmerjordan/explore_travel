import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:explore_journal/main.dart';
import 'package:explore_journal/ui/map/map_screen.dart';

/// 地图页的定位流要在「被整页路由盖住」时停、露出来时起。MapScreen 是常驻
/// 首页（push 出去不 dispose），这条链路靠 GoRouter.observers → RouteObserver
/// → RouteAware 三段接起来，任何一段断了都只会静默地让 GPS 在别的页面下面
/// 一直开着——所以这里走真实的 GoRouter 栈，而不是单测 RouteAware 回调。
/// 观测点是 MapScreen 在 kDebugMode 下打的固定日志行（logcat 里也用它验）。
void main() {
  const suspended = '[MAP] location stream suspended (route covered)';
  const resumed = '[MAP] location stream resumed (route covered)';

  testWidgets(
      'MapScreen suspends location sources while a page route covers it',
      (tester) async {
    final log = <String>[];
    // debugPrint 是 foundation 的调试变量，flutter_test 在测试体一结束就检查
    // 它必须已还原（早于 tearDown），所以用 try/finally 而不是 addTearDown。
    final prevPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) log.add(message);
    };
    try {
      await tester.pumpWidget(const ProviderScope(child: ExploreJournalApp()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MapScreen), findsOneWidget);
      expect(log.where((l) => l.startsWith('[MAP] location stream')), isEmpty,
          reason: '首页刚起来、没人盖着，不该有起停日志');

      // 与底栏「更多 / 歌单 / 组队」走的是同一条 context.push 路径；挑 /splash
      // 是因为它没有任何平台通道副作用。
      final mapCtx = tester.element(find.byType(MapScreen));
      GoRouter.of(mapCtx).push('/splash');
      // push 经 Router 解析（微任务）→ 下一帧重建 Navigator → 同步通知
      // observer → didPushNext；两次 pump 保证那一帧一定跑到。
      await tester.pump();
      await tester.pump();
      expect(log.where((l) => l == suspended).length, 1);
      expect(log.where((l) => l == resumed), isEmpty);
      await tester.pump(const Duration(milliseconds: 400)); // 走完转场

      // 第二层路由压在 /splash 上不该再通知地图页（它已经被盖着了）。
      GoRouter.of(mapCtx).push('/splash');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(log.where((l) => l == suspended).length, 1);

      GoRouter.of(mapCtx).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(log.where((l) => l == resumed), isEmpty,
          reason: '上面还压着一层，地图页仍被盖着');

      GoRouter.of(mapCtx).pop();
      await tester.pump(); // 顶层出栈 → didPop(route, previous=map) → didPopNext
      expect(log.where((l) => l == resumed).length, 1);
      await tester.pump(const Duration(milliseconds: 400));

      // MapScreen 还在（常驻首页），而且没有异常。
      expect(find.byType(MapScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugPrint = prevPrint;
    }
  });
}
