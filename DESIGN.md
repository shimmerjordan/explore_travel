---
name: Explore Journal
description: 走过的地方会点亮迷雾的旅行探索 App —— 重新点亮的地图
colors:
  # ── 品牌（Primary，青绿）────────────────────────────────────────────
  seed-teal: "#26A69A"
  primary-light: "#006A62"
  primary-dark: "#81D5CA"
  on-primary-light: "#FFFFFF"
  on-primary-dark: "#003732"
  # ── 次色（Secondary，琥珀"金币/火把"）──────────────────────────────
  amber-light: "#875200"
  amber-dark: "#F2B457"
  amber-container-light: "#FFE0B0"
  amber-container-dark: "#5C4014"
  # ── 第三色（Tertiary，珊瑚"红心/旗标"）────────────────────────────
  coral-light: "#B13B22"
  coral-dark: "#FF8A70"
  # ── 面（Neutral，带青绿偏色）──────────────────────────────────────
  scaffold-light: "#F3FAF8"
  scaffold-dark: "#14212C"
  card-light: "#EEFCF9"
  card-dark: "#1B2D38"
  container-high-light: "#DDEBE8"
  container-high-dark: "#24343F"
  container-highest-light: "#D7E6E2"
  container-highest-dark: "#2A3B46"
  ink-light: "#111E1C"
  ink-dark: "#DDE4E2"
  ink-muted-light: "#394A47"
  ink-muted-dark: "#BEC9C6"
  outline-light: "#B8CAC7"
  outline-dark: "#3F4947"
  # ── 语义状态（明暗各一套，全部过 4.5:1）──────────────────────────
  success-light: "#1B6B3A"
  success-dark: "#7BD88F"
  warning-light: "#875200"
  warning-dark: "#F2B457"
  danger-light: "#BA1A1A"
  danger-dark: "#FFB4AB"
  neutral-light: "#4A5C68"
  neutral-dark: "#A8BAC6"
  # ── 地图浮层（不跟随主题；见 Colors 一节的理由）────────────────────
  chrome-glass: "#0000008C"
  chrome-readout: "#000000C7"
  chrome-panel: "#1A2733"
  chrome-bar: "#0F1923F2"
  chrome-border: "#FFFFFF3D"
  on-chrome: "#FFFFFF"
  on-chrome-muted: "#FFFFFFBF"
  chrome-brand: "#26A69A"
  chrome-brand-deep: "#00695C"
  chrome-toast-danger: "#B3261E"
  chrome-toast-warning: "#8A5000"
  chrome-journal-pin: "#FF8A65"
  chrome-online: "#43A047"
  chrome-simulated: "#7E57C2"
  # ── 迷雾（数据可视化，用户可调）────────────────────────────────────
  fog-veil-default: "#101820"
  fog-veil-dark-map: "#05070A"
  tile-backdrop: "#EAE6DE"
typography:
  display:
    fontFamily: "PixelZh, Roboto, sans-serif"
    fontSize: "36sp"
    lineHeight: 1.15
    letterSpacing: "0"
  headline:
    fontFamily: "PixelZh, Roboto, sans-serif"
    fontSize: "24sp"
    lineHeight: 1.2
    letterSpacing: "0"
  title:
    fontFamily: "PixelZh, Roboto, sans-serif"
    fontSize: "16sp"
  body:
    fontFamily: "PixelZh, Roboto, sans-serif"
    fontSize: "14sp"
  label:
    fontFamily: "PixelZh, Roboto, sans-serif"
    fontSize: "12sp"
  mono:
    fontFamily: "monospace"
    fontSize: "12sp"
rounded:
  chip: "6px"
  surface: "8px"
  button: "10px"
  fab: "12px"
  dialog: "14px"
  sheet: "16px"
components:
  button-primary:
    backgroundColor: "{colors.primary-light}"
    textColor: "{colors.on-primary-light}"
    rounded: "{rounded.button}"
  button-destructive:
    backgroundColor: "{colors.danger-light}"
    textColor: "#FFFFFF"
    rounded: "{rounded.button}"
  card:
    backgroundColor: "{colors.card-dark}"
    textColor: "{colors.ink-dark}"
    rounded: "{rounded.surface}"
  chip:
    backgroundColor: "{colors.container-high-dark}"
    textColor: "{colors.ink-dark}"
    rounded: "{rounded.chip}"
  menu-panel:
    backgroundColor: "{colors.container-high-dark}"
    textColor: "{colors.ink-dark}"
    rounded: "{rounded.surface}"
  fab-record:
    backgroundColor: "{colors.chrome-brand}"
    textColor: "{colors.on-chrome}"
    rounded: "{rounded.fab}"
    size: "72px"
  map-chip:
    backgroundColor: "{colors.chrome-glass}"
    textColor: "{colors.on-chrome}"
    rounded: "{rounded.chip}"
  map-readout:
    backgroundColor: "{colors.chrome-readout}"
    textColor: "{colors.on-chrome}"
    rounded: "{rounded.chip}"
  map-fab:
    backgroundColor: "{colors.chrome-panel}"
    textColor: "{colors.on-chrome}"
    rounded: "{rounded.surface}"
    size: "48px"
  bottom-nav:
    backgroundColor: "{colors.chrome-bar}"
    textColor: "{colors.on-chrome}"
    height: "64px"
---

# Design

## Overview

**重新点亮的地图（The Relit Map）。** 整个系统只服务一件事：用户走过的地方，会从迷雾里亮出来。这个隐喻不是装饰，它是两条最容易被改错的决策的依据——

1. **地图浮层不属于应用，属于地图**（所以它不跟随明暗主题，见 Colors）；
2. **像素是表达层，Material 3 是骨架**（所以正文、控件、语义全走 M3 角色，像素只负责字面与"道具面板"的质感）。

气质是**轻盈 · 游历 · 收集乐趣**：语气亲切、带一点惊喜，从不说教或炫技。要反对的是四件事：SaaS 仪表盘的等大彩色卡片网格、炫技玻璃拟态与满屏渐变、老虎机式的夸张游戏化、以及把"轻盈游历"做成报表工具的冷硬极简。

平台是 Android，Material 3 是规则书；品牌通过 M3 的颜色角色、形状与字体表达，而不是绕过它。使用场景在户外、移动途中、光线多变，常常单手操作、弱网——**离线可靠优先于炫技**，稳定与状态清晰永远高于视觉噱头。

信息层级由**使用频率**决定，不是平铺网格：常用的（记录、看地图、看进度）要大、要近手；低频的（设置、排行榜、组队）退居"更多"页的分组里。

无障碍目标 WCAG 2.1 AA。这不是愿望——`test/ui/contrast_test.dart` 与 `test/ui/a11y_guidelines_test.dart` 把对比度、48dp 触控目标与语义标签做成了 CI 门禁，改动违反就红。

## Colors

种子色 `#26A69A`（青绿）驱动整套 M3 配色，暗色走 `tonalSpot`、亮色走 `vibrant`（亮色是"轻快"模式，彩度更足）。在派生结果之上显式重定义了两个角色族，因为单种子会把一切渲染成同一个蓝灰家族："全是暗色系没有搭配"：

- **Secondary = 琥珀**（金币 / 火把）：`#F2B457` 暗 / `#875200` 亮
- **Tertiary = 珊瑚**（红心 / 旗标）：`#FF8A70` 暗 / `#B13B22` 亮

这么做的杠杆点是 M3 的角色语义：重定义角色族之后，全应用的 tonal 按钮、选中的分段按钮与 chip、徽标自动换装，不需要逐页改。

**两个刻意分开的色域**，这是本系统最容易被"顺手统一"改错的地方：

1. **应用表面跟随主题。** scaffold / card / 两级容器面带轻微青绿偏色（不是中性灰），文字与状态色都有明暗两套，`StatusPalette` 提供 success / warning / danger / neutral（danger 直接用 M3 的 `error` 角色，它本来就按明暗各调过）。绝不用 `Colors.green` / `Colors.orange` / `Colors.red` / `Colors.grey`——它们是为 Material 白底设计的中间调，在本应用至少一套主题上过不了 4.5:1（`Colors.green` 压在亮色卡片上约 2.3:1）。

2. **地图浮层不跟随主题。** `MapChrome` 是深色玻璃 + 白字，两套主题下都一样。理由：地图页的背景是**地图影像**，它的明暗由迷雾幕（`fogColor` / `fogOpacity`）与"暗色地图"开关决定，与 `themePref` 无关——亮色主题下也可以是一张压暗的夜色地图，暗色主题下也可以是一张雪地卫星图。浮层若跟着主题走，就会在一半情形下变成浅底浅字，正好违反"地图浮层文字必须有足够对比或半透明底衬（强光下可读）"。取而代之的契约是：**在最亮（纯白）与最暗（`#05070A`）两种底图上都过 WCAG AA**，由对比度测试对两端同时断言。

玻璃分三级，因为一个厚度盖不住所有内容：`glass` 0.55 够白字（4.5:1）；**`readout` 0.78 给靠颜色传数值的胶囊**（GPS 信号色阶、指北针针尖——0.55 下弱信号红只有 1.59:1）；`panel` 不透明，给可点的控件；`bar` 0.95 给屏幕边缘。浮层上的品牌色用固定值而不是 `cs.primary`：亮色主题的 primary 是为浅底调过的浅色调，压在深色玻璃上会发灰；承载白色正文时还要再压深一档（`brandDeep`）。

有物理含义的颜色不参与主题化：定位点与精度圈的白环、图层的用户自选色、热图色板、迷雾幕。

## Typography

**一套字体，全局像素。** 缝合像素字体（fusion-pixel-font 12px 简中，OFL）注册为 `PixelZh`，通过 `ThemeData.fontFamily` 应用到正文、标签、按钮、标题——这是明确的产品选择，不是只给标题用。缺字自动回落系统字面。**国旗 emoji 必须显式指定 `fontFamily: 'Roboto'`**，否则渲染成字母方块；国行 ROM 常无 regional-indicator 字形，`FlagBadge` 会检测并回退成两字母 ISO 徽章。

像素字体是 **12px 网格**的：大字号只有落在 12 的整数倍上才不发糊。所以 display / headline 两族显式钉在 36 / 24；title / body / label 保持 M3 默认（16 / 14 / 12），它们本来就在可读区间，而动它们等于把全应用的列表、按钮、AppBar 一起改版。经纬度、诊断与调试输出用 `monospace`。

字号一律用 sp（Flutter 的逻辑像素跟随系统字号设置），不写死 px。`test/ui/contrast_test.dart` 有一条断言钉住 12 网格，防止有人顺手改成 34。

## Elevation

**描边分层，阴影只给浮物。** 卡片、AppBar、列表项一律 `elevation: 0`；层次靠色阶（scaffold → card → container-high → container-highest）与 **1.5px `outlineVariant` 描边**表达——菜单、下拉与弹出面板是像素 RPG 的"道具面板"读法，不是漂浮的 Material 卡片。

只有真正浮在内容之上的东西才给阴影：录制 FAB 与弹出菜单 `elevation: 2`，SnackBar 走 floating，地图浮层用深色玻璃 + 低透明黑投影。**嵌套卡片永远是错的**；等大卡片网格也是（见 Do's and Don'ts）。

## Components

形状尺度六档，语义清晰：chip 6 < 面/列表项/SnackBar 8 < 按钮 10 < FAB 12 < 对话框 14 < 底板 16。AppBar 居中标题、`elevation: 0`（亮色滚动后 1）。

- **底部导航**：`BottomAppBar` 高 64，四项（附近手账 / 组队 / 歌单 / 更多）+ 中央 72px 录制 FAB 停靠。**刻意不用 `CircularNotchedRectangle`**：它的裁剪器会在路由转场中读 `Scaffold.geometryOf()`，命中"只能在 paint 阶段"的断言。
- **地图浮层**：左上图层胶囊、顶部状态胶囊排、右侧竖排 48dp 圆形按钮列、右下 FAB。能收起就收起，能半透明就别挡视线。
- **空状态**：`EmptyState` —— **一句现状 + 一句下一步该做什么**，可配像素精灵与行动按钮。写"暂无数据"或让新用户看一屏全零的仪表盘，都算 bug。文案里引用的标签必须是**用户看得见的文字**，不能引用只存在于 `tooltip` 或语义标签里的词。
- **加载态**：`LoadingState` 带说明文字（"统计中…"比孤零零一个转圈有用）。内容区中央转圈是下策但仍胜过一片空白让人以为坏了。
- **失败提示**：`showFailure` —— 「<动作>失败 · <原因>」+ 可重试就给「重试」。异常原文只进 `LogBuffer`，不上屏。
- **交互状态**：M3 角色自带 hover / focus / pressed / disabled / selected。不给非激活态用重色或满饱和强调色。

触控目标 ≥ 48dp、间距 ≥ 8dp。地图顶栏几枚状态胶囊目前小于 48dp——那是"地图是主角"与触控下限之间的已知取舍，放大要连带重排顶栏。

## Do's and Don'ts

**Do**

- 走 M3 颜色角色（`cs.primary` / `cs.error` / `cs.onSurfaceVariant`…）与 `Theme.of(context).status`，让换肤只改一处。
- 地图上的东西用 `MapChrome`；应用表面上的东西用主题。分不清就问：**它背后是地图影像，还是应用的面？**
- 动效克制：150–250ms，只传达状态变化。尊重系统"移除动画"——每个动效都要有淡入或瞬时替代。
- 主操作落在拇指热区（屏幕下半部 / 右侧）。
- 每次探索都值得庆祝，但要恰到好处、不打断。

**Don't**

- 不要写死颜色。特别是不要用 `Colors.green` / `orange` / `red` / `grey` 表达状态——它们过不了对比度门禁。
- 不要让地图浮层跟随明暗主题（会在一半情形下变成浅底浅字）。
- 不要写 inline `fontSize`。用 `textTheme` 的角色；写死字号会让系统字号设置失效。
- 不要用等大彩色卡片网格铺功能入口（层级由使用频率决定）。
- 不要嵌套卡片；不要 `background-clip: text` 式的渐变文字；不要把玻璃拟态当默认。
- 不要把异常原文糊到用户脸上（`'播放失败：$e'`）。
- 不要用 `Semantics(excludeSemantics: true)` 包住 `GestureDetector`——它会把手势动作一起排除，读屏念得出、点不动，而两条无障碍准则都发现不了。
- 不要为了"优雅"用浅灰正文。对比不够时往 ink 端加深。
