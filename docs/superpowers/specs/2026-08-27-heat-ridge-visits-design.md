# 热力山脊（3D 热图）+ 到访地点 + 足迹统计 —— 设计文档

日期：2026-08-27　状态：已与用户确认方案（A 路线；C1/C3/C7 + C2 + C5；热度=轨迹点+迷雾底噪）

## 0. 背景与结论

### 0.1 人生点点 2.0 的「3D 热图」是什么
- **不是柱状/六边形柱**。是 Strava 式「沿轨迹叠加发光」热图样式；把地图倾斜后，热度高的路段隆起成发光**山脊**，峰顶泛白、侧面渐暗，底图一起透视倾斜。官方原话：「在总览的热图样式下倾斜地图，即可看到 3D 效果」。
- 参数只有两个连续量：**粗细**、**曝光**；加一列渐变色板（青 / 橙火 / 彩虹 / 紫 / 白…）。
- iOS 独占，MapKit 底图 + 自绘 GPU 层（推断）。

### 0.2 Dawarich 值得抄的是数据层算法与参数（不是渲染）
- 到访检测（v3 管线）：半径 100 m、≥3 点、≥5 min、15 min 链式合并、静默 60 min 关闭片段、同地静默 ≤7 天桥接、drift cap ×1.5、中心按 1/accuracy 加权、半径下限 15 m；置信度权重 dwell .30 / tightness .25 / place .20 / density .15 / accuracy .10 / bridged .15 / corroboration .10，≥70 high / ≥40 medium；三态 suggested/confirmed/declined + 软删墓碑 + 机器行整体幂等重建、用户行做锚点。
- 路线切段 30 min；速度 >500 km/h 不计国家；城市停留 ≥60 min 才算、间隔 >120 min 不计；GPS 噪点：accuracy>10 km、Null Island、速度三明治（标记不删）。
- 反面教训：到访误报与 23 h CPU 占用是最大抱怨 → 我们只对新数据增量算、在 isolate 里算。

## 1. 范围

| 编号 | 内容 | 阶段 |
|---|---|---|
| C1 | `track_points(layer_id,time)` 索引；导入去重 | P1 |
| C3 | GPS 噪点：录制/导入丢弃 accuracy>500 m 与 Null Island；速度三明治**标记** `flags&1` | P1 |
| C7 | 手账照片无 GPS 时按 EXIF 时间从轨迹插值补位置（±30 min） | P1 |
| H1 | 2D「热图」烘焙瓦片图层（与 FogTileLayer 同管线），色板/曝光/粗细/时间范围，显示模式 迷雾/热图/叠加 | P2 |
| H2 | 「倾斜」3D 热力山脊视图（快照 + 密度场 + drawVertices） | P3 |
| C2 | 到访地点识别 + 每日时间轴页 | P4 |
| C5 | 统计升级：总里程、记录/连续天数、国家/城市数、Days per Country、活动日历、Top 地点、24h 活跃 | P5 |

不做：maplibre、H3、交通方式识别（速度启发式仅用于时间轴显示）、Google Timeline 导入（C4 未选）。

## 2. 数据层（P1）

### 2.1 schema v10
- `track_points` 新增 `flags INTEGER NOT NULL DEFAULT 0`（bit0 = anomaly）。
- 索引 `idx_track_points_layer_time (layer_id, time)`、`idx_track_points_time (time)`，在 `beforeOpen` 用 `CREATE INDEX IF NOT EXISTS`（老库无需 bump 也能补上，但仍 bump 到 10 以加列）。
- 新表 `places`：id, uuid, name, lat, lng, radius(m), source(0 auto/1 manual), country/province/city(nullable), createdAt, updatedAt。
- 新表 `visits`：id, uuid, placeId(nullable), layerId, startedAt, endedAt, lat, lng, radius, pointCount, bridgedSec, status(0 suggested/1 confirmed/2 declined), confidence(0..100), confidenceJson, detectionVersion, deletedAt(nullable), createdAt, updatedAt。索引 (startedAt), (placeId)。
- 备份：新增模块 `visits`（places + visits，uuid 去重，LWW by updatedAt），tombstone 表名 `places`/`visits`。（若 backup_service 的模块机制改动过大，P4 结束时评估；未纳入则在 CHANGELOG 明示「到访数据仅本机」。）

### 2.2 噪点过滤 `lib/services/location/point_filter.dart`
纯函数 `PointFilter.judge(prev, cur) → keep|drop|anomaly`：
- drop：`accuracy > 500`、`|lat|<0.05 && |lng|<0.05`（Null Island）、坐标越界。
- anomaly：与上一保留点隐含速度 > 250 m/s（900 km/h）且间隔 ≤ 1 h；或同一时间戳位移 > 1000 m。标记不删。
- 录制 `_handleSample` 与导入 `TrackImport.ingest` 都走它；热图/到访/统计/回放查询默认 `flags & 1 = 0`。

### 2.3 导入去重
`ingest` 前查目标图层在导入时间范围内已有点的 `(time_ms, lat×1e6, lng×1e6)` 集合，命中则跳过；返回 `(inserted, skipped)`，提示「已点亮 N 个轨迹点（跳过 M 个重复）」。

### 2.4 照片位置插值 `lib/services/geo/track_interpolator.dart`
`TrackInterpolator.positionAt(db, DateTime t, {tolerance: 30 min})`：取 t 前后各一点（跨图层不限，排除 anomaly）；两侧都有且间隔 ≤ tolerance → 线性插值；只有一侧且 ≤ tolerance → 取该点；否则 null。返回附带 `source: interpolated|nearest` 与时间差供 UI 提示「由轨迹推算（±3 分）」。接入 journal 编辑弹窗（EXIF 有时间无 GPS 时）与「从照片导入手账」。

## 3. 热图 2D 图层（P2）

### 3.1 数据源 `lib/services/heat/heat_source.dart`
- `HeatSegments`：从 `track_points`（可见图层、时间范围、非 anomaly）按 (layer,time) 排序，相邻点 Δt ≤ 30 min 且距离 ≤ 2 km 连成段，否则孤立点。坐标先按当前底图做 WGS→GCJ（与 FogSnapshot 一样带 mapProvider），再投到 **Web-Mercator 世界坐标 [0,1)**，存 `Float32List (x0,y0,x1,y1)`。
- 空间索引：按 z12 瓦片分桶（段长 ≤2 km ≤ 1 个 z12 瓦片宽的 1/4），`forEachSegmentIn(worldRect)`。
- 迷雾底噪：复用 `FogSnapshot.forEachBlockInWindow`，每个已探索块按 popcount/4096 给一个很低的常数密度。
- 时间范围：全部 / 今年 / 近 30 天 / 自定义（起止日）。
- 生成规则与 FogSnapshot 一致：图层集合/底图/时间范围/样式变化 → generation++ → 瓦片缓存失效。

### 3.2 色板 `heat_palette.dart`
`HeatPalette { name, stops }` 五套：青（#0B2A33→#12B5C8→#FFFFFF）、火（#3B0A00→#FF6A00→#FFD36B→#FFFFFF）、彩虹、紫（#2A0A3B→#C03BFF→#FFFFFF）、白。`lut(exposure)` 预计算 256 项 ARGB：`t = clamp(I × exposure)`，alpha 在 t<0.03 处渐入。

### 3.3 烘焙 `heat_tile_provider.dart`
- `HeatTileProvider(snapshot)` / `_HeatTileImage` 键含 generation，`OneFrameImageStreamCompleter`。
- `_bakeHeatTile(z,x,y,dim)`：瓦片世界矩形外扩 `glowPx` 边距；在 PictureRecorder 上以 **BlendMode.plus** 画每段两次：宽软笔（w×3, alpha 0.05×exp）+ 核心（w, alpha 0.12×exp），`StrokeCap.round`；孤立点画圆。宽度 w 随 zoom：`w = width × clamp(2^(z-14)×3, 1.2, 12)` px。toImage → `toByteData(rawRgba)` → 取 A 通道做强度 → LUT 上色 → `decodeImageFromPixels`。
- 8-bit 加法饱和 = 峰顶白，正是目标观感。`errorTile` 回退透明。
- TileLayer 参数与迷雾一致：`keepBuffer/panBuffer = kNativeTile*`、`tileUpdateTransformer` 复用合并器、`tileDisplay.instantaneous()`。
- 显示模式 `heatMode`：0 关 / 1 热图（隐藏迷雾幕布，保留 darkMap）/ 2 叠加（迷雾之上）。

### 3.4 设置（prefs.dart 5 处）
`heatMode int=0`, `heatPalette int=0`, `heatExposure double=1.0 (0.3..3)`, `heatWidth double=1.0 (0.5..3)`, `heatRange int=0`, `heatRangeFrom/To int? (epoch ms)`, `heatHeight double=1.0 (0.3..2, 3D 高度)`。

### 3.5 UI
- 顶部 chip 行新增「热图」chip（Icons.local_fire_department），点一下循环 关→热图→叠加；长按打开样式面板 `HeatStyleSheet`（色板一行色条、曝光/粗细/高度滑杆、时间范围 SegmentedButton）。
- 右侧 FAB 列在 heatMode>0 时出现「倾斜」FAB（Icons.landscape_rounded）→ 进入 P3 视图。

## 4. 3D 热力山脊视图（P3）`lib/ui/heat/heat_tilt_screen.dart`

### 4.1 进入
1. `map_screen` 把 `FlutterMap` 包在 `RepaintBoundary(key: _mapCaptureKey)`（仅地图栈，不含浮层）。
2. 点「倾斜」：`toImage(pixelRatio: min(dpr, 2))` 得底图快照（含迷雾/热图 2D 层）；同时记录 `MapCamera`（center/zoom/rotation/size）。
3. 用 `HeatSegments.forEachSegmentIn(viewportWorldRect)` 生成**密度场**（见 4.2），push 全屏 `HeatTiltScreen(snapshot, field, palette, params)`；进入动画 pitch 0→50°/700 ms（`disableAnimations` 时直接到位）。

### 4.2 密度场 `lib/services/heat/heat_field.dart`（纯 Dart，可测）
- 网格 cell = 3 逻辑 px（W×H → ~130×280），`Float32List`。
- 每段沿线以 ≤0.5 cell 步长采样，盖 **高斯核**（σ = 0.9×width cell，半径 3σ）；孤立点盖一次；迷雾块底噪加常数。
- `h = log1p(k·d) / log1p(k·dmax)`（k 随曝光），再做一次 3×3 分离高斯平滑。float 累积避免 8-bit 饱和，峰值不丢。
- 输出 `HeatField{w,h,cell,values}` + `maxIndex`。

### 4.3 渲染 `heat_tilt_painter.dart`
- 模型空间：屏幕平面 (x∈[0,W], y∈[0,H])，z 向上，`z = h × Hmax × heatHeight`，Hmax = 0.22×H。
- 相机：先绕中心 yaw（θ），再绕 x 轴 pitch（φ∈[0°,65°]），透视 `s = f/(f + depth)`，f = 1.6×H，pitch=0 时缩放恒为 1。
- 底图：把快照贴到 24×48 的四边形网格上，`drawVertices(TriangleList, BlendMode.modulate, paint..shader=ImageShader)`，顶点色随「远」渐暗（远端 ×0.25），并整体乘 0.75 使山脊更亮。
- 山脊：所有 `h>0.02` 的格子输出四边形（4 顶点高度取网格角点），按 **深度降序**（画家算法）排列成 TriangleList，顶点色 = `palette(h)` × 光照（法线来自高度梯度，光从左上 45°，`0.55+0.45·max(0,n·l)`），`h>0.9` 混向白色（峰顶泛白），`h<0.15` alpha 渐入。所有格子只有 yaw 变化时重排一次。
- 单帧成本：~38k 顶点投影 + ~30k 三角，Impeller/CanvasKit 均可；无手势时不重绘。

### 4.4 交互
- 单指上下拖 = pitch，左右拖 = yaw；双指捏合 = 缩放（0.6–3）；双击复位；右上「×」退出；底部一行：色板选择、高度/曝光滑杆（改参数只重算颜色/高度，不重算密度场）。
- 局限（写进 CHANGELOG）：3D 内不能平移到快照之外；远端渐暗。

### 4.5 Web
纯 Dart，无新依赖；`toImage`/`toByteData`/`drawVertices`/`ImageShader` 在 CanvasKit 可用；密度场直接主线程算（<50 ms）。

## 5. 到访地点（P4）`lib/services/visits/`

### 5.1 纯算法 `stay_detector.dart`（移植 Dawarich v3，参数与 0.2 相同）
输入 `List<StayPoint{lat,lng,tMs,accuracy}>`（单图层、时间升序、非 anomaly）→
1. `dwellSweep`：单遍；与当前片段 last 点 Δt > 3600 s 或不共址（到运行均值中心 > R 或到首点 > 1.5R）则关闭；输出所有 run。
2. `bridgeGaps`：相邻 run 间隔 ≤ 7 d 且中心距 ≤ R → 合并，中心按点数加权，`bridgedSec` 只计 > 3600 s 的静默。
3. `assemble`：链式合并（间隔 ≤ 15 min 且中心距 ≤ R）→ 过滤 `duration ≥ 5 min && count ≥ 3` → 中心 1/max(acc,1) 加权、半径 max 距离下限 15 m。
输出 `Stay{start,end,lat,lng,radius,count,bridgedSec,medianAcc}`。可在 `compute()` 中跑（输入打包为 Float64List）。

### 5.2 置信度 `confidence_scorer.dart`
权重如 0.2（无 corroboration → 归一化其余）；`place_match`：manual place 0.85 / auto place 0.6 / 无 0.35。band：≥70 high、≥40 medium、否则 low。

### 5.3 引擎 `visit_engine.dart`
- 触发：录制 `stop()` 后；导入 ingest 结束后；App 启动 5 s 后若 `visits_last_run` 为空则全量按月分块。窗口 = [触发范围 − 6 h, +6 h]。
- 落库（幂等）：事务内删除窗口内 `status=0 && deletedAt IS NULL` 的机器行；新 stay 若与锚点行（confirmed/declined/软删）时间重叠 > 50% 则跳过；否则匹配 50 m 内已有 place（manual 优先，其次 visit 数，其次距离），无则新建 auto place；名称异步经 `GeocodingService.resolve(allowNetwork: 用户设置)` 取 `city/province`（我们的 geocoder 无 POI）→ 默认「城市 · 未命名地点」，用户可改名。
- 用户操作：确认（status=1）、改名（place.name + source=manual）、归入已有地点（visit.placeId 改、原 auto place 若无引用则删）、删除（deletedAt=now，机器不再重建）。
- 每次运行只写变化行（tuple 比较），避免同步重传。

### 5.4 时间轴页 `lib/ui/timeline/timeline_screen.dart`（路由 `/timeline`）
- 顶部日期条（左右滑天、点击日历跳转，有记录的日期字重更粗——借人生点点「字重日历」的思路，用 PixelZh）。
- 列表：到访（地点名 / 时间段 / 时长；confirmed 实心、medium 淡显、low 折叠到「N 条低置信度」）与移动段（距离、时长、均速 → 步行 <7 / 骑行 <25 / 驾车 <150 / 火车·飞行 km/h 的图标）交替；当日手账条目内嵌。
- 点到访 → 底部操作单（确认/改名/归入/删除/在地图上看）；「在地图上看」用 `mapFocusProvider` 让首页地图飞过去。
- 入口：首页「更多」→ 记录与回顾 → 「足迹时间轴」。

## 6. 统计升级（P5）`lib/services/stats/footprint_stats.dart` + explore_screen 第三个 Tab「足迹」

- 日里程：按本地日分区，相邻点 haversine 累加，Δt > 30 min 的段与隐含速度 > 300 km/h 的段不计（Dawarich 规则）；结果缓存到 SharedPreferences（`footprint_stats_v1`，含最大 point id，增量只算新点）。
- 卡片（克制、符合 PRODUCT.md 不做仪表盘）：① 总里程 / 今年 / 本月（PixelZh 大数字）；② 记录天数、当前连续天数、最长连续；③ 活动日历（近 12 个月 GitHub 式格子，颜色=日里程分档，CustomPaint 像素格）；④ 去过国家 N / 城市 M（城市来自 places.city 且累计到访 ≥ 60 min）；Days per Country 列表（每日首点 → `CountryLookup` 离线 bbox）；⑤ Top 5 地点（到访次数、累计停留）；⑥ 24 h 活跃环（各小时点数占比）。
- 依赖 C2 的部分在 visits 为空时显示引导「去时间轴确认几处到访」。

## 7. 测试
- `test/heat/heat_field_test.dart`：单段 → 峰值在线上、对称；两段交叉 → 交叉点最高；log 归一 ≤1；迷雾底噪。
- `test/heat/heat_palette_test.dart`：LUT 单调、曝光缩放、末端白。
- `test/heat/heat_tile_bake_test.dart`：一条水平线烘焙后中间行 alpha>0、边缘 0；两次叠加更亮。
- `test/visits/stay_detector_test.dart`：合成轨迹（家 8 h → 通勤 → 公司 9 h → 红灯 2 min）→ 2 个 stay，红灯被过滤；隔夜静默桥接；drift cap。
- `test/visits/confidence_scorer_test.dart`：权重归一、band 边界。
- `test/visits/visit_engine_test.dart`（内存 DB）：幂等重跑不产生重复；确认行为锚点；删除留墓碑不重建。
- `test/location/point_filter_test.dart`、`test/geo/track_interpolator_test.dart`、`test/stats/footprint_stats_test.dart`、`test/db/schema_v10_test.dart`（v9→v10 迁移保留数据、索引存在）。
- 真机：热图 2D 平移掉帧对比（SurfaceFlinger --latency，参考 08-26 方法）、3D 视图帧率、到访检测对真实 DB 的结果抽检。

## 8. 实施顺序
P1 数据基础 → P2 热图 2D → P3 3D 视图 → P4 到访 + 时间轴 → P5 统计 → 真机验证 → CHANGELOG/README。每阶段 `flutter analyze` 零新增问题、新测试全过后再进下一阶段；不 commit（等用户指令）。
