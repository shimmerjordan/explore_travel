import 'package:explore_journal/ui/common/app_theme.dart';
import 'package:explore_journal/ui/common/pixel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 像素字号规则的守卫。
///
/// 这个应用有两条取用显示字号的路径，**故意的**：
///   * `Theme.of(context).textTheme.displaySmall / headlineSmall` —— 写进
///     DESIGN.md frontmatter 的机器可读 token；
///   * `PixelText.display / headline` —— 页面里的常量写法（不需要 context，
///     可以出现在 const 语境里）。
///
/// 两条路径都合法，但它们必须**始终相等**——否则同一个"36 号大字"在两个页面
/// 里会长得不一样。这份测试就是那道锁：改了一边不改另一边就会红。
///
/// 另一条规则来自字体本身：缝合像素字体是 12px 网格的，大字号只有落在 12 的
/// 整数倍上才不发糊。所以断言尺寸是 12 的倍数。
void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    final tt = buildAppTheme(brightness).textTheme;
    final tag = brightness == Brightness.light ? '亮色' : '暗色';

    test('$tag：主题的 display / headline 与 PixelText 常量逐字段相等', () {
      final pairs = <String, (TextStyle?, TextStyle)>{
        'display': (tt.displaySmall, PixelText.display),
        'headline': (tt.headlineSmall, PixelText.headline),
      };
      pairs.forEach((name, p) {
        final themed = p.$1, konst = p.$2;
        expect(themed, isNotNull, reason: '$name 档在主题里必须显式设置');
        expect(themed!.fontSize, konst.fontSize, reason: '$name fontSize');
        expect(themed.height, konst.height, reason: '$name height');
        expect(themed.letterSpacing, konst.letterSpacing,
            reason: '$name letterSpacing');
        expect(themed.fontFamily, konst.fontFamily, reason: '$name fontFamily');
        expect(themed.fontWeight, konst.fontWeight, reason: '$name fontWeight');
      });
    });

    test('$tag：显示字号落在像素字体的 12px 网格上', () {
      for (final st in [tt.displaySmall!, tt.headlineSmall!, PixelText.label]) {
        expect(st.fontSize! % 12, 0,
            reason: '${st.fontSize} 不是 12 的整数倍，像素字面会发糊');
      }
    });

    test('$tag：显示字号一律是像素字面，且不加字距', () {
      // 字距非 0 会让字形推进落在半像素上——像素字体的糊就是这么来的。
      for (final st in [tt.displaySmall!, tt.headlineSmall!, PixelText.label]) {
        expect(st.fontFamily, PixelText.family);
        expect(st.letterSpacing, 0);
      }
    });
  }

  test('PixelText.label 刻意不进 textTheme —— 把理由钉在这里', () {
    // M3 的 labelMedium 在本 Flutter 版本里 fontSize 为 null（尺寸由各
    // Material 组件在构建时自己给），环境默认是 14。把 12px 的
    // PixelText.label 映射过去会让这 6 处文字变大两号；而把 labelMedium
    // 显式钉成 12 又会牵动全应用所有 label。两边都不是"顺手统一"能做的事，
    // 所以 label 档留在常量里，等有人能真机核对再说。
    final tt = buildAppTheme(Brightness.dark).textTheme;
    expect(tt.labelMedium?.fontSize, isNull,
        reason: '若某天它有了显式尺寸，就该重新评估这个决定');
    expect(PixelText.label.fontSize, 12);
  });
}
