import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/services/group/group_service.dart';
import 'package:explore_journal/ui/chat/chat_screen.dart';
import 'package:explore_journal/ui/common/app_theme.dart';
import 'package:explore_journal/ui/common/empty_state.dart';
import 'package:explore_journal/ui/music/music_sources_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 空状态 / 加载态里最容易回归的那几条：**「还在找」和「找不到」不能长一个样**。
///
/// 组队成员发现要跑十几秒（多播 + 子网扫描），在这段时间里屏幕上写
/// 「没有其他成员在线」，用户会当成结论直接去改配置。这里把两种情况分别钉住。
///
/// 只挑不需要数据库的屏：足迹页的空状态得先起 Drift + 跑一次 compute()，
/// 那要造的假太重，留给真机验。
void main() {
  setUp(() {
    // settingsProvider 一构造就读盘；测试里给它一份空的 prefs，免得平台通道缺失
    // 变成未捕获的异步异常。
    SharedPreferences.setMockInitialValues({});
  });

  Widget host(Widget child, {required List<Override> overrides}) =>
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: child,
        ),
      );

  group('群组「成员」页', () {
    // 刻意不用 pumpAndSettle：加载态里的 CircularProgressIndicator 永远在转，
    // 等它「停下来」就是等超时。定量 pump 走完 TabBar 的 300ms 转场即可。
    Future<void> openMembers(WidgetTester tester) async {
      await tester.tap(find.text('成员'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('在线但还没发现队友 → 说「正在找」，不说「没有」', (tester) async {
      await tester.pumpWidget(host(
        const ChatScreen(),
        overrides: [
          groupRunningProvider.overrideWith((ref) => true),
          groupPeersProvider.overrideWith((ref) => const <GroupPeer>[]),
        ],
      ));
      await tester.pump();
      await openMembers(tester);

      expect(find.byType(LoadingState), findsOneWidget);
      expect(find.text('正在找附近的队友…'), findsOneWidget);
      expect(find.byType(EmptyState), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没连上 → 空状态，并指到「群组 ID」那一格', (tester) async {
      await tester.pumpWidget(host(
        const ChatScreen(),
        overrides: [
          groupRunningProvider.overrideWith((ref) => false),
          groupPeersProvider.overrideWith((ref) => const <GroupPeer>[]),
        ],
      ));
      await tester.pump();
      await openMembers(tester);

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('还没有连上群组'), findsOneWidget);
      // 引导语必须点到真实控件的名字，否则用户不知道去哪儿填。
      expect(
          find.textContaining('群组 ID', findRichText: true), findsWidgets);
      expect(find.byType(LoadingState), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('音乐平台配置：一份凭证都没存时说清「不登录也能听」', (tester) async {
    await tester.pumpWidget(host(const MusicSourcesScreen(), overrides: []));
    await tester.pump();
    // 这条空状态排在四张平台卡之后，测试视口里要滚下去才会被 ListView 建出来。
    await tester.scrollUntilVisible(find.byType(EmptyState), 400);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('还没有保存任何平台凭证'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
