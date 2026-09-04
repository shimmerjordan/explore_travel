/// 地图浮层（chrome）的配色。**故意不跟随明暗主题**，只有这一处例外。
///
/// 为什么：地图页的背景是**地图影像**，不是应用表面。它的明暗由迷雾幕
/// （`AppSettings.fogColor` / `fogOpacity`）与「暗色地图」开关决定，与
/// `themePref` 无关——亮色主题下也可以是一张压暗的夜色地图，暗色主题下也可以
/// 是一张雪地卫星图。所以浮层若跟着主题走，就会在一半情形下变成浅底浅字，
/// 正好违反 PRODUCT.md「地图浮层文字必须有足够对比或半透明底衬（强光下可读）」。
///
/// 取而代之的契约是：**深色玻璃 + 白字，在最亮与最暗两种底图上都过 WCAG AA**。
/// `test/ui/contrast_test.dart` 对纯白与 `#05070A` 两端都做断言，改这里的任何
/// 数值都会被它挡住。
///
/// 三级层次（原先散落着 5 个各不相同的"深色半透明"，同一个角色 5 个值）：
///   * [glass] —— 贴在影像上的小标签（信号、指北、个人卡）。半透明，让地图透出来。
///   * [panel] —— 可点的控件面（圆形按钮、图层选择器）。不透明，点得准、读得清。
///   * [bar]   —— 屏幕边缘的大块 chrome（底部导航栏）。近乎不透明。
library;

import 'package:flutter/material.dart';

abstract final class MapChrome {
  /// 半透明深色玻璃：小标签贴在影像上，既压住底图明暗差又不挡视线。
  /// 0.55 是能让白字在纯白底图上过 4.5:1 的下限（见对比度测试）。
  static const Color glass = Color(0x8C000000); // black @ 0.55

  /// 不透明控件面。带一点青绿倾向的深蓝黑，与主题的深色面同族，
  /// 这样浮层和抽屉/卡片并置时不像两个应用。
  static const Color panel = Color(0xFF1A2733);

  /// 屏幕边缘 chrome。比 [panel] 更沉，跟系统导航条接得上。
  static const Color bar = Color(0xF20F1923); // #0F1923 @ 0.95

  /// 读数用的深玻璃：信号强度、指北针这类**靠颜色传递数值**的胶囊。
  /// 0.55 的 [glass] 只够白字（4.5:1），但压不住彩色刻度——弱信号红在
  /// 「玻璃盖白色雪地」上只有 1.59:1。0.78 让整条色阶都过 3:1，而这个数字
  /// 正是应用默认迷雾幕的不透明度，视觉上与地图是一家。
  static const Color readout = Color(0xC7000000); // black @ 0.78

  /// 信号强度四档（强→弱）。刻意保留绿→黄绿→琥珀→红的语义色相，靠加厚
  /// 底衬而不是把红色淡成粉色来满足对比度。条数与白色文字本身也是冗余通道。
  static const List<Color> signalRamp = [
    Color(0xFFE57373), // 1 格：弱
    Color(0xFFFFB74D), // 2 格：一般
    Color(0xFFAED581), // 3 格：良好
    Color(0xFF66BB6A), // 4 格：强
  ];

  /// 指北针的红色针尖。
  static const Color compassNeedle = Color(0xFFFF5252);

  /// 浮在影像上、**承载白色正文**的实色告警条底：[TopToast] 的背景，以及
  /// 「点击地图擦除…」这条模式提示横幅。
  ///
  /// 为什么不能直接用 Material 的 redAccent / orange.shade700：`TopToast` 的
  /// 前景固定是白色，而白字压在 `#FF5252` 上只有 3.19:1（提示条还带 0.9 不
  /// 透明度盖在雪地底图上，掉到 2.90:1），远不到正文要求的 4.5:1。这里各压深
  /// 到 6.5:1，色相不变——红仍是红、琥珀仍是琥珀。
  static const Color toastDanger = Color(0xFFB3261E);

  /// 同一族里的品牌青绿版：给「新增手账」这类**品牌色承载白色正文**的横幅。
  /// [brand] 那枚 `#26A69A` 是标记点与 FAB 的填充色（图形，3:1 即可），
  /// 拿来当白字的底只有 2.67:1；压深到 teal 800 后是 5.32:1，仍是同一枝青绿。
  static const Color brandDeep = Color(0xFF00695C);

  /// 同上，警示/无数据类提示条的琥珀底。
  static const Color toastWarning = Color(0xFF8A5000);

  /// 玻璃/面板上的描边。白色低透明，像素风的"道具面板"轮廓。
  static const Color chromeBorder = Color(0x3DFFFFFF); // white @ 0.24

  /// 浮层上的正文与图标。
  static const Color onChrome = Color(0xFFFFFFFF);

  /// 浮层上的次要文字（单位、副标题）。仍需过大字/图标的 3:1。
  static const Color onChromeMuted = Color(0xBFFFFFFF); // white @ 0.75

  /// 品牌青绿。浮层上的品牌色刻意用固定值而不是 `cs.primary`：
  /// 亮色主题的 primary 是一枚为浅底调过的浅色调，压在深色玻璃上会发灰。
  static const Color brand = Color(0xFF26A69A);

  /// 手账图钉的珊瑚色（同理，固定值）。
  static const Color journalPin = Color(0xFFFF8A65);

  /// 「对方在线」小绿点。用 Material green 600 而不是 500：这个点是靠一圈
  /// 1.5px 白环从背景里分出来的，green 500 与白色只有 2.78:1，过不了 WCAG
  /// 1.4.11 的 3:1（对比度测试会挡）。600 是 3.30:1，肉眼几乎无差。
  static const Color online = Color(0xFF43A047);

  /// 模拟行走（仅调试）用紫色，一眼区别于真实定位。
  static const Color simulated = Color(0xFF7E57C2);

  /// 定位精度圈与标记环用的纯白描边（有物理含义，不是主题色）。
  static const Color markerRing = Color(0xFFFFFFFF);

  /// 浮层投影。
  static const Color shadow = Color(0x59000000); // black @ 0.35
}
