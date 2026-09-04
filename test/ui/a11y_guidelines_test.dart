import 'dart:typed_data';
import 'dart:ui' show SemanticsAction, SemanticsFlag;

import 'package:drift/native.dart';
import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/main.dart';
import 'package:explore_journal/services/heat/heat3d_camera.dart';
import 'package:explore_journal/services/heat/heat_source.dart';
import 'package:explore_journal/ui/common/empty_state.dart';
import 'package:explore_journal/ui/common/app_theme.dart';
import 'package:explore_journal/ui/common/pixel.dart';
import 'package:explore_journal/ui/heat/heat_tilt_screen.dart';
import 'package:explore_journal/ui/home/home_screen.dart';
import 'package:explore_journal/ui/map/map_screen.dart';
import 'package:explore_journal/ui/playback/playback_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flutter 自带的无障碍准则检查，当门禁用。
///
/// 分两层：
///   * **可复用组件**（下半部分最早的几条）—— 跑得快，挡住"新写的控件忘了标签 /
///     点击区太小"这类最常见的回归。
///   * **整屏**（地图首页、更多页、回放、3D 热图）—— 地图页那些浮层控件是
///     `part of map_screen.dart` 的库私有类，测试拿不到、没法单独 pump；但整屏
///     是可以起来的（见 map_screen_route_aware_test.dart 也这么干），所以标签
///     门禁就架在整屏上。为了测试把私有部件改成公开是不值得的。
///
/// 三条准则的含义：
///   * `androidTapTargetGuideline` —— 触控目标 ≥ 48×48 dp（Material 无障碍下限，
///     也是 PRODUCT.md 写明的目标）。
///   * `labeledTapTargetGuideline` —— 每个可点区域都有语义标签，TalkBack 读得出。
///   * `textContrastGuideline` —— 文字对背景的对比度达 WCAG AA。
///
/// 地图首页**只**架标签准则、不架触控目标：顶部那排 `_MapChip` 是刻意做小的
/// 地图浮层（34×30），改成 48 会把顶栏整体撑高、还要连带挪图层胶囊——那是一次
/// 设计改动，不该混在这次「补语义」里；另外左下角的 `CompanionAvatarButton`
/// (44×44) 属于 lib/ui/companion/，不在本次改动范围内。两者见交付说明。
void main() {
  Widget wrap(Widget child, {Brightness brightness = Brightness.dark}) =>
      MaterialApp(
        theme: buildAppTheme(brightness),
        home: Scaffold(body: Center(child: child)),
      );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final tag = brightness == Brightness.light ? '亮色' : '暗色';

    testWidgets('$tag：空状态（带行动按钮）过三条准则', (tester) async {
      await tester.pumpWidget(wrap(
        EmptyState(
          title: '还没有旅行手账',
          hint: '在地图上长按底栏的「附近手账」，就能就地记下一条。',
          sprite: PixelSprites.book,
          actionLabel: '写第一条',
          onAction: () {},
        ),
        brightness: brightness,
      ));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });

    testWidgets('$tag：加载态文字对比达标', (tester) async {
      await tester.pumpWidget(
          wrap(const LoadingState(label: '统计中…'), brightness: brightness));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });

    testWidgets('$tag：像素面板与进度条上的文字对比达标', (tester) async {
      final cs = buildAppTheme(brightness).colorScheme;
      await tester.pumpWidget(wrap(
        SizedBox(
          width: 300,
          child: PixelPanel(
            color: cs.surfaceContainerHigh,
            child: Column(children: [
              Text('探索进度', style: TextStyle(color: cs.onSurface)),
              const SizedBox(height: 8),
              PixelBlockBar(
                  value: 0.42,
                  cells: 12,
                  color: cs.primary,
                  emptyColor: cs.surfaceContainerHighest),
            ]),
          ),
        ),
        brightness: brightness,
      ));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  }

  // ══════════════════════════════════════════════════════════════════════
  // 整屏：纯图标控件的语义标签
  // ══════════════════════════════════════════════════════════════════════

  /// 播放器 / 回放列表要真数据才有行，用内存库喂 20 个点（一段记录）。
  Future<AppDb> seededDb() async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final layerId = await db.insertLayer(TrackLayersCompanion.insert(
        name: '默认图层', colorValue: 1, createdAt: DateTime(2026, 1, 1)));
    final t0 = DateTime(2026, 8, 1, 8, 0);
    await db.insertPoints([
      for (var i = 0; i < 20; i++)
        TrackPointsCompanion.insert(
          lat: 30.0 + i * 0.001,
          lng: 104.0,
          time: t0.add(Duration(seconds: i * 5)),
          layerId: layerId,
        ),
    ]);
    return db;
  }

  testWidgets('地图首页：每个纯图标控件都有中文标签', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ExploreJournalApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(MapScreen), findsOneWidget);

    final handle = tester.ensureSemantics();
    // 底栏 4 个目标、中央录制 FAB、右侧按钮列（放大/缩小/擦除/加点/照片/回中）、
    // 顶部胶囊、图层胶囊、GPS 读数、AI 旅伴、调试按钮，以及地图本体自己那个
    // 全屏手势节点，全都要有标签。
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

    // 抽查几句，确认读出来的是「这颗按钮做什么」而不是图标名。
    for (final label in [
      '开始记录', // 中央 FAB（按状态在 开始/停止 之间切）
      '附近手账',
      '组队',
      '歌单',
      '更多',
      '放大',
      '缩小',
      '擦除迷雾',
      '添加记录点',
      '从照片定位点亮记录点',
      '回到我的位置',
      '隐藏全部手账气泡',
      '进入 3D 热力图',
      '地图', // flutter_map 那个全屏手势节点
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    // 隐藏动作（长按底栏「附近手账」就地新建）必须有 hint，否则读屏用户根本
    // 不知道它存在。
    expect(
      tester.getSemantics(find.bySemanticsLabel('附近手账')).hintOverrides,
      isNotNull,
    );
    handle.dispose();
  });

  testWidgets('地图首页：GPS 读数读的是信号质量，不是四根格子', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ExploreJournalApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final handle = tester.ensureSemantics();
    // 测试环境里没有定位回报 → 「无定位」。有定位时的措辞由下面的纯函数覆盖。
    expect(find.bySemanticsLabel('GPS 无定位'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('更多页：过标签 + 触控目标两条准则', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: HomeScreen()),
    ));
    await tester.pump();
    final handle = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    // 右上角头像原来只念得出首字母。
    expect(find.bySemanticsLabel(RegExp('个人资料')), findsOneWidget);
    // 版本号那行在页面最底下，滚到它才建；原来它完全听不出可点。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pump();
    final version =
        find.bySemanticsLabel(RegExp('连续点按十次可开启调试模式'));
    expect(version, findsOneWidget);
    // 一行 11px 的字本身只有 ~14dp 高，靠外面那个透明框撑到 48dp。整屏的
    // androidTapTargetGuideline 不能在滚动之后再跑一遍（半个滚出视口的入口片
    // 会被裁成十几 dp 高而误报），所以这里单点这一处。
    expect(tester.getSemantics(version).rect.height,
        greaterThanOrEqualTo(48.0));
    handle.dispose();
  });

  testWidgets('回放列表与播放器：过标签 + 触控目标两条准则', (tester) async {
    final db = await seededDb();
    addTearDown(db.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [dbProvider.overrideWithValue(db)],
      child: const MaterialApp(home: PlaybackScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final handle = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

    // 进播放器：传输栏（播放/暂停、倍率、进度条）与导出按钮。
    await tester.tap(find.byType(ListTile).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    expect(find.bySemanticsLabel('播放回放'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^播放速度 ')), findsOneWidget);
    // 顶栏那几颗按钮走 IconButton 的 tooltip（读屏也读 tooltip），不是 label。
    expect(find.byTooltip('导出视频'), findsOneWidget);
    expect(find.byTooltip('停止跟随'), findsOneWidget); // 进来默认就在跟随
    handle.dispose();
  });

  // ══════════════════════════════════════════════════════════════════════
  // 3D 热力图：标签 + 系统「移除动画」
  // ══════════════════════════════════════════════════════════════════════

  /// 一份空快照就够撑起这一屏（瓦片在测试里本来也拉不到）。
  Heat3DView heatView(Heat3DCamera cam) => Heat3DView(
        initialCamera: cam,
        heat: HeatSnapshot(
          index: HeatIndex.empty,
          lut: Uint32List(256),
          exposure: 1,
          width: 1,
          generation: 0,
        ),
        onExit: (_, __, ___) {},
      );

  Heat3DCamera heatCam() => Heat3DCamera(
      centerX01: 0.5,
      centerY01: 0.5,
      zoom: 14,
      viewport: const Size(400, 800));

  Widget heatHost(Widget child, {bool disableAnimations = false}) =>
      ProviderScope(
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: child,
          ),
        ),
      );

  testWidgets('3D 热力图顶栏：模式段与时间范围都读得出当前状态', (tester) async {
    await tester.pumpWidget(heatHost(heatView(heatCam())));
    await tester.pump();
    final handle = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(find.bySemanticsLabel('山脊视图'), findsOneWidget);
    expect(find.bySemanticsLabel('区域视图'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^时间范围：')), findsOneWidget);
    // 二选一开关：选中态不能只靠底色，读屏要能听出来。
    expect(
        tester
            .getSemantics(find.bySemanticsLabel('山脊视图'))
            .hasFlag(SemanticsFlag.isSelected),
        isTrue);
    // 段是可点的：ExcludeSemantics 若包住了 GestureDetector，tap 动作会一起
    // 被排除掉——那时读屏能读不能点，而两条准则都发现不了。
    expect(
        tester
            .getSemantics(find.bySemanticsLabel('区域视图'))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue);
    handle.dispose();
  });

  testWidgets('3D 热力图：系统「移除动画」时直接落到最终俯仰角', (tester) async {
    final cam = heatCam();
    await tester
        .pumpWidget(heatHost(heatView(cam), disableAnimations: true));
    await tester.pump();
    // 700 ms 的入场倾斜整段跳过：第一帧就已经是最终角度。
    expect(cam.pitchDeg, 52.0);
  });

  testWidgets('3D 热力图：默认仍走入场动画（上一条的对照）', (tester) async {
    final cam = heatCam();
    await tester.pumpWidget(heatHost(heatView(cam)));
    await tester.pump();
    // 动画刚起步，还平躺着（0°）——证明上一条测的确实是"被跳过"。
    expect(cam.pitchDeg, lessThan(52.0));
    await tester.pump(const Duration(milliseconds: 350));
    expect(cam.pitchDeg, greaterThan(0.0));
  });

  // ══════════════════════════════════════════════════════════════════════
  // 语义标签的措辞：地图页的部件是库私有的，但拼标签的纯函数是公开的
  // ══════════════════════════════════════════════════════════════════════

  group('语义标签措辞', () {
    test('组队入口：人数不能只报一个数字', () {
      expect(
          groupNavSemanticLabel(
              inGroup: false, memberCount: 1, peersOnline: false),
          '组队');
      expect(
          groupNavSemanticLabel(
              inGroup: true, memberCount: 3, peersOnline: false),
          '组队，当前 3 人');
      expect(
          groupNavSemanticLabel(
              inGroup: true, memberCount: 3, peersOnline: true),
          '组队，当前 3 人，有队友在线');
    });

    test('GPS 读数：说质量与精度，不说「几格」', () {
      final now = DateTime(2026, 9, 4, 12);
      expect(gpsSignalSemanticLabel(accuracyMeters: 12, reportedAt: null),
          'GPS 无定位');
      expect(gpsSignalSemanticLabel(accuracyMeters: 8, reportedAt: now),
          'GPS 信号强，精度正负 8 米');
      expect(gpsSignalSemanticLabel(accuracyMeters: 24, reportedAt: now),
          'GPS 信号良好，精度正负 24 米');
      expect(gpsSignalSemanticLabel(accuracyMeters: 50, reportedAt: now),
          'GPS 信号一般，精度正负 50 米');
      expect(gpsSignalSemanticLabel(accuracyMeters: 300, reportedAt: now),
          'GPS 信号弱，精度正负 300 米');
      // 档位与胶囊上亮几根格子共用同一套阈值。
      expect(gpsSignalBars(accuracyMeters: 8, reportedAt: now), 4);
      expect(gpsSignalBars(accuracyMeters: 300, reportedAt: now), 1);
      expect(gpsSignalBars(accuracyMeters: 8, reportedAt: null), 0);
    });

    test('队友标记：带上是谁 + 多久没联系', () {
      expect(peerMarkerSemanticLabel(name: '小明', age: Duration.zero),
          '队友 小明，位置实时');
      expect(
          peerMarkerSemanticLabel(
              name: '小明', age: const Duration(seconds: 45)),
          '队友 小明，45 秒未联系');
      expect(
          peerMarkerSemanticLabel(
              name: '小明', age: const Duration(minutes: 7)),
          '队友 小明，7 分钟未联系');
      expect(
          peerMarkerSemanticLabel(name: '', age: const Duration(hours: 2)),
          '队友，2 小时未联系');
    });

    test('回放进度条：读的是时刻，不是百分比', () {
      final t = DateTime(2026, 8, 1, 9, 8, 7);
      expect(replayProgressSemanticValue(real: t, multiDay: false),
          '已播放到 09:08:07');
      expect(replayProgressSemanticValue(real: t, multiDay: true),
          '已播放到 8 月 1 日 09:08');
    });
  });
}
