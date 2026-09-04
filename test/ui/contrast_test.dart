import 'dart:math' as math;

import 'package:explore_journal/ui/common/app_theme.dart';
import 'package:explore_journal/ui/common/map_chrome.dart';
import 'package:explore_journal/ui/common/status_palette.dart';
import 'package:explore_journal/ui/leaderboard/leaderboard_screen.dart'
    show medalColor;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.1 相对亮度。
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

/// 前景压在背景上之后的对比度。前景带 alpha 时先按 [over] 合成——地图浮层
/// 大量使用半透明白字，不合成算出来的数字是假的。
double contrast(Color fg, Color bg) {
  final composited = Color.from(
    alpha: 1,
    red: fg.r * fg.a + bg.r * (1 - fg.a),
    green: fg.g * fg.a + bg.g * (1 - fg.a),
    blue: fg.b * fg.a + bg.b * (1 - fg.a),
  );
  final a = _luminance(composited), b = _luminance(bg);
  final hi = math.max(a, b), lo = math.min(a, b);
  return (hi + 0.05) / (lo + 0.05);
}

Color _over(Color fg, Color bg) => Color.from(
      alpha: 1,
      red: fg.r * fg.a + bg.r * (1 - fg.a),
      green: fg.g * fg.a + bg.g * (1 - fg.a),
      blue: fg.b * fg.a + bg.b * (1 - fg.a),
    );

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void main() {
  /// 正文 4.5:1；大字与图标 3:1（WCAG 1.4.3 / 1.4.11）。
  const body = 4.5;
  const large = 3.0;

  void expectContrast(Color fg, Color bg, double min, String what) {
    final r = contrast(fg, bg);
    expect(r, greaterThanOrEqualTo(min),
        reason: '$what: ${_hex(fg)} on ${_hex(bg)} = '
            '${r.toStringAsFixed(2)}:1，需 ≥ $min:1');
  }

  group('地图浮层（故意与主题无关：深色玻璃盖在影像上）', () {
    // 地图影像本身的明暗由迷雾幕与 darkMap 设置决定，不跟随主题，所以浮层
    // 必须在「最亮的可能底图」和「最暗的可能底图」两端都可读。
    const brightest = Color(0xFFFFFFFF); // 雪地 / 高德日间空白区
    const darkest = Color(0xFF05070A); // darkMap 迷雾幕
    for (final imagery in [brightest, darkest]) {
      final tag = imagery == brightest ? '亮底图' : '暗底图';

      test('$tag：玻璃胶囊上的文字与图标', () {
        final glass = _over(MapChrome.glass, imagery);
        expectContrast(MapChrome.onChrome, glass, body, '$tag 玻璃正文');
        expectContrast(MapChrome.onChromeMuted, glass, large, '$tag 玻璃次要文字');
      });

      test('$tag：不透明面板上的文字与图标', () {
        final panel = _over(MapChrome.panel, imagery);
        expectContrast(MapChrome.onChrome, panel, body, '$tag 面板正文');
        expectContrast(MapChrome.onChromeMuted, panel, large, '$tag 面板次要文字');
      });

      test('$tag：底栏上的文字与图标', () {
        final bar = _over(MapChrome.bar, imagery);
        expectContrast(MapChrome.onChrome, bar, body, '$tag 底栏正文');
        expectContrast(MapChrome.onChromeMuted, bar, large, '$tag 底栏次要文字');
      });

      test('$tag：品牌色在浮层上仍可辨', () {
        final panel = _over(MapChrome.panel, imagery);
        expectContrast(MapChrome.brand, panel, large, '$tag 面板上的品牌青绿');
      });

      test('$tag：承载白色正文的实色底（告警条 / 模式横幅）', () {
        // 这三枚是**白字压在上面**的实色底，按正文算 4.5:1。横幅带 0.9
        // 不透明度盖在影像上，所以要连合成一起验。
        for (final entry in {
          'toastDanger': MapChrome.toastDanger,
          'toastWarning': MapChrome.toastWarning,
          'brandDeep': MapChrome.brandDeep,
        }.entries) {
          expectContrast(MapChrome.onChrome, entry.value, body,
              '$tag ${entry.key} 实色');
          final at90 = _over(entry.value.withValues(alpha: 0.9), imagery);
          expectContrast(
              MapChrome.onChrome, at90, body, '$tag ${entry.key} @0.9');
        }
      });

      test('$tag：读数胶囊上的信号色阶与指北针针尖', () {
        // 信号格与指北针针尖是**靠颜色本身传递数值**的图形，按 WCAG 1.4.11
        // 需要 3:1。它们坐在更厚的 readout 玻璃上，正因为 0.55 的普通玻璃
        // 压不住彩色刻度。
        final readout = _over(MapChrome.readout, imagery);
        for (var i = 0; i < MapChrome.signalRamp.length; i++) {
          expectContrast(
              MapChrome.signalRamp[i], readout, large, '$tag 信号第 ${i + 1} 档');
        }
        expectContrast(
            MapChrome.compassNeedle, readout, large, '$tag 指北针针尖');
        expectContrast(MapChrome.onChrome, readout, body, '$tag 读数文字');
      });
    }

    test('告警条底色：TopToast 的白色前景在上面过正文 4.5:1', () {
      // TopToast 的 foreground 默认写死 Colors.white（见 widgets/top_toast.dart），
      // 所以这两枚底色是否达标只取决于「白字压在它上面」。它们是实色，不透明，
      // 与底图无关；但擦除模式提示条会带 0.9 不透明度盖在影像上，所以两端底图
      // 也各验一次。
      const white = MapChrome.onChrome;
      expectContrast(white, MapChrome.toastDanger, body, '危险告警条白字');
      expectContrast(white, MapChrome.toastWarning, body, '警示告警条白字');
      for (final imagery in [brightest, darkest]) {
        final tag = imagery == brightest ? '亮底图' : '暗底图';
        expectContrast(white, _over(MapChrome.toastDanger.withValues(alpha: 0.9), imagery),
            body, '$tag 上 0.9 不透明度的危险提示条白字');
        expectContrast(white, _over(MapChrome.toastWarning.withValues(alpha: 0.9), imagery),
            body, '$tag 上 0.9 不透明度的警示提示条白字');
      }
    });

    test('Material 直出的 redAccent 当告警条底色确实不够', () {
      // 把换掉它的理由钉在测试里：白字压在 #FF5252 上过不了正文 4.5:1。
      expect(contrast(MapChrome.onChrome, const Color(0xFFFF5252)),
          lessThan(body));
    });

    test('在线小绿点靠白环分隔，不靠与玻璃的对比', () {
      // WCAG 1.4.11 要求图形与**相邻**颜色有 3:1。绿点填充压在玻璃上只有
      // 1.7:1，真正把它从背景里分出来的是那圈 1.5px 白环——所以断言环与
      // 填充的对比，而不是填充与玻璃的对比。
      expectContrast(MapChrome.markerRing, MapChrome.online, large, '绿点白环');
    });

    test('玻璃与面板足够厚，能压住底图明暗差', () {
      // 同一套白字要在两端都过 4.5:1，玻璃就必须有足够不透明度；这条断言
      // 把「以后有人把 alpha 调薄」挡住。
      expect(MapChrome.glass.a, greaterThanOrEqualTo(0.5));
      expect(MapChrome.bar.a, greaterThanOrEqualTo(0.9));
      expect(MapChrome.panel.a, 1.0);
      // 读数玻璃必须比普通玻璃厚，否则彩色刻度过不了 3:1。
      expect(MapChrome.readout.a, greaterThan(MapChrome.glass.a));
    });
  });

  group('语义状态色（跟随主题，两套都要过）', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final theme = buildAppTheme(brightness);
      final cs = theme.colorScheme;
      final tag = brightness == Brightness.light ? '亮色' : '暗色';

      // 状态色出现在卡片、脚手架与两级容器面上，全都要过。
      final surfaces = <String, Color>{
        'scaffold': theme.scaffoldBackgroundColor,
        'surface': cs.surface,
        'card': theme.cardTheme.color ?? cs.surface,
        'containerHigh': cs.surfaceContainerHigh,
        'containerHighest': cs.surfaceContainerHighest,
      };

      test('$tag：成功 / 警告 / 危险 / 中性在每种面上都可读', () {
        final palette = StatusPalette.of(cs);
        for (final s in surfaces.entries) {
          expectContrast(palette.success, s.value, body, '$tag ${s.key} 成功');
          expectContrast(palette.warning, s.value, body, '$tag ${s.key} 警告');
          expectContrast(palette.danger, s.value, body, '$tag ${s.key} 危险');
          expectContrast(palette.neutral, s.value, body, '$tag ${s.key} 中性');
        }
      });

      test('$tag：正文与次要文字在每种面上都可读', () {
        for (final s in surfaces.entries) {
          expectContrast(cs.onSurface, s.value, body, '$tag ${s.key} 正文');
          expectContrast(
              cs.onSurfaceVariant, s.value, body, '$tag ${s.key} 次要文字');
        }
      });

      test('$tag：前三名奖牌色当文字用，普通行与「这是我」那行都要可读', () {
        // 奖牌色不是状态色，但它被 PixelText.label 当 14sp 文字色用，所以按
        // 正文 4.5:1 要求。「这是我」那一行底上还压了一层 primaryContainer
        // 0.45，比普通行更浅/更亮，是更难的一面——两面都验。
        final selfRow = _over(
            cs.primaryContainer.withValues(alpha: 0.45),
            theme.scaffoldBackgroundColor);
        for (var rank = 1; rank <= 3; rank++) {
          final medal = medalColor(rank, cs);
          expectContrast(
              medal, theme.scaffoldBackgroundColor, body, '$tag 第 $rank 名奖牌');
          expectContrast(medal, selfRow, body, '$tag 第 $rank 名奖牌（自己那行）');
        }
      });

      test('$tag：Material 直出的红/绿/橙/灰确实不够——所以才要这套色板', () {
        // 这条不是为了断言"要用调色板"，而是把当初换掉 Colors.green 之类的
        // 理由钉在测试里：它们在至少一套主题上过不了 4.5:1。
        final offenders = <String, Color>{
          'Colors.green': Colors.green,
          'Colors.orange': Colors.orange,
          'Colors.grey': Colors.grey,
        };
        final failures = <String>[];
        for (final o in offenders.entries) {
          for (final s in surfaces.entries) {
            if (contrast(o.value, s.value) < body) {
              failures.add('${o.key}/${s.key}');
            }
          }
        }
        expect(failures, isNotEmpty,
            reason: '若 Material 直出色也都达标，这套调色板就没必要了');
      });
    }
  });
}
