/// 语义状态色：成功 / 警告 / 危险 / 中性。
///
/// 为什么不用 `Colors.green` / `Colors.orange` / `Colors.red` / `Colors.grey`：
/// 它们是为 Material 的白底设计的中间调，在本应用两套主题的面上过不了
/// WCAG AA 的 4.5:1（`Colors.green` 压在亮色卡片上约 2.3:1，`Colors.grey`
/// 在暗色面上约 3.4:1）。状态色恰恰是「看错了会做错事」的那类信息，
/// 不能靠猜。
///
/// 危险色直接用 M3 的 `error` 角色——它本来就按明暗各调过一版。成功与警告
/// M3 没有对应角色，这里显式给两套值，并由 `test/ui/contrast_test.dart`
/// 对 scaffold / surface / card / 两级 container 面逐一断言。
library;

import 'package:flutter/material.dart';

@immutable
class StatusPalette {
  /// 成功 / 已完成 / 已上传。
  final Color success;

  /// 待处理 / 需注意 / 已关闭某项自动行为。
  final Color warning;

  /// 失败 / 删除 / 不可逆操作。
  final Color danger;

  /// 未启用 / 无数据 / 不适用。
  final Color neutral;

  const StatusPalette({
    required this.success,
    required this.warning,
    required this.danger,
    required this.neutral,
  });

  /// 暗色：面在 `#14212C`–`#2A3B46` 之间，用高亮度低饱和的一族。
  static const _dark = StatusPalette(
    success: Color(0xFF7BD88F),
    warning: Color(0xFFF2B457), // 与主题的琥珀 secondary 同一枚
    danger: Color(0xFFFF8A80),
    neutral: Color(0xFFA8BAC6),
  );

  /// 亮色：面在 `#F3FAF8` 附近，用深色一族。
  static const _light = StatusPalette(
    success: Color(0xFF1B6B3A),
    warning: Color(0xFF875200), // 与主题的亮色 secondary 同一枚
    danger: Color(0xFFB3261E),
    neutral: Color(0xFF4A5C68),
  );

  /// 按配色方案取当前应生效的一套。危险色跟随 M3 的 `error` 角色。
  static StatusPalette of(ColorScheme cs) {
    final base = cs.brightness == Brightness.dark ? _dark : _light;
    return StatusPalette(
      success: base.success,
      warning: base.warning,
      danger: cs.error,
      neutral: base.neutral,
    );
  }
}

/// 用法：`Theme.of(context).status.success`。
extension StatusPaletteX on ThemeData {
  StatusPalette get status => StatusPalette.of(colorScheme);
}
