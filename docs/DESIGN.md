# Design

> 现有视觉系统的真实快照（从 `lib/main.dart` 的 ThemeData 提取），作为后续 impeccable 优化的基线。平台 Android / Material 3。

## Theme

- **框架**：Flutter + **Material 3**（`useMaterial3: true`），`ColorScheme.fromSeed`。
- **明暗双主题**，跟随系统。深色是户外/夜间一等场景。
- **整体气质**：扁平（elevation 多为 0）、圆角友好、青绿点睛。轻盈通透是目标方向（见 PRODUCT.md 气质）。

## Color

种子色驱动整套 Material 3 配色：

| 角色 | 值 | 说明 |
|---|---|---|
| Seed / Primary | `#26A69A` | 青绿（teal），点睛色：FAB、激活态 chip、"旅人"胶囊、勾选框、主按钮 |
| Light surface | M3 `fromSeed(light)` | 近白，带极淡青绿倾向 |
| Dark scaffold bg | `#0F1923` | 深藏蓝黑，地图/夜间主背景 |
| Dark card | `#1A2733` | 深色卡片面 |
| 其余 role | M3 派生 | secondary / tertiary / error / outline 等由 seed 派生 |

- 全程走 Material 3 ColorScheme role（`surface` / `onSurface` / `primary` / `surfaceContainerHighest` …），不硬编码零散颜色。
- ⚠️ 基线隐患：地图浮层上的文字/图标对比需逐一核对（强光下可读）；深色 `#0F1923` 上正文需 ≥ 4.5:1。

## Typography

- **正文/标题**：Roboto（Flutter 默认，`uses-material-design: true`），走 M3 `TextTheme`。
- **技术/坐标/调试**：`fontFamily: 'monospace'`（经纬度、诊断、调试页）。
- 尚无自定义字体族与显式 type scale——排版层级主要靠 M3 默认 + 局部 `fontSize`。这是可提升点（typeset）。

## Components

| 组件 | 形状 / 半径 | 高度(elevation) | 备注 |
|---|---|---|---|
| Card | 圆角 **16** | 0（扁平） | 深色显式面 `#1A2733` |
| FAB | 圆角 **16** | **2** | 地图上的青绿录制主按钮 |
| AppBar | 无圆角 | 0（滚动后 light 1 / dark 0） | **居中标题** |
| ListTile | 圆角 **12** | — | 内边距 H16 / V4 |
| Chip | 圆角 **10** | — | 无描边（`side: none`） |
| FilledButton | 圆角 **12** | — | 主行动按钮 |
| SegmentedButton | 圆角 **12** | — | 分段选择 |
| SnackBar | — | floating | 浮动式 |

- 圆角尺度：**10 / 12 / 16** 三档（chip < 控件 < 卡片）。
- 图标：Material Icons + `cupertino_icons`。
- 地图：`flutter_map`（瓦片 + 迷雾图层 + 定位标记）。

## Layout

- Material 脚手架：AppBar（居中标题）+ body + 底部导航（附近手账 / 队友 / 歌单 / 更多）。
- 地图主界面：全屏地图 + 悬浮控件（左上图层条、右侧竖排功能按钮、右下 FAB、底部导航）。
- "更多"页：`GridView` 彩色功能磁贴（等大卡片网格——**M3/impeccable 视角下的待优化点：identical card grid**）。
- 间距目前较均匀，缺少节奏与层级对比。

## Motion

- 以 Material 默认转场为主，尚无成体系的、体现"轻盈游历"性格的动效语言。
- 尊重 `prefers-reduced-motion` 需作为硬约束补齐。
- 机会点：点亮迷雾 / 收集手账的**克制正反馈**（见 PRODUCT.md 原则 2）。

## Known baseline issues (优化候选)

1. **"更多"功能网格是等大彩色卡片平铺**——典型 identical-card-grid，缺层级（违背 PRODUCT.md 原则 4）。← 首个优化目标
2. 地图浮层文字/图标对比未逐一核验（a11y）。
3. 无自定义 type scale，排版层级弱。
4. 动效未成语言，"收集乐趣"的正反馈缺位。
