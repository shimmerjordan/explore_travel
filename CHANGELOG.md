# Changelog

All notable changes to Explore Journal are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow SemVer once releases start.

## [Unreleased] — 2026-09-03

持续优化第一轮：清冗余 + CI 门禁。

### 清理

- 删除三块整体死代码（约 560 行）：从未挂载的 2D `HeatTileLayer` 栈、被 GroupService 取代的 `P2PService` 栈（含一个无法取消的 15 s mDNS 定时器）、孤儿 ZeroTier helper 及 `zerotierNetworkId` 设置字段。仍在用的 `p2p/crypto.dart` 迁为 `group/p2p_crypto.dart`。
- 删除零散死符号：`_FogDiagBadge`、`_platformGuard`、`pttActiveProvider`、`groupDiagnosticsProvider`、`kCountryToContinent`、`emojiFlagsSupportedOverride`、`TrackExport.importGpx`/`TrackPointImport`、`pixel.dart` 的 `PixelBadge`/`PixelScanlines`/5 个 `pixel*` 工具、`leaderboardServerSyncMin` 字段。
- 合并重复实现：新建 `lib/core/geo_math.dart`（haversine 与 Web Mercator 正反投影，此前 haversine 5 份、反投影 3 份）与 `lib/ui/common/format.dart`（`fmtBytes` / `fmtRelativeTime`，此前字节格式化 3 份且输出不一致、相对时间 2 份）。`FogEngine` / `HeatIndex` / `PointFilter` 上的同名静态方法保留为委托，80 个调用点不动。
- 地图页手账卡片预览改用 `quillToPreview`，修掉正则硬刮 Delta JSON 漏掉图片 embed、转义处理不全的问题。
- 移除 7 个零导入依赖：`video_player`、`photo_view`、`flutter_map_location_marker`、`web_socket_channel`、`audio_session`、`collection`、`riverpod_annotation`（连带 dev 的 `riverpod_generator`）。`pubspec.yaml` 补上 `flutter: '>=3.32.0'` 约束，本地与 CI 的 SDK 下限一致。
- `flutter analyze --fatal-infos` 清零（原 16 条 info）。

### CI

- 新增 composite `.github/actions/flutter-setup`：Flutter 版本号全仓库只钉这一处（原三条流水线各自硬编码 `3.32.1`），并统一开启 SDK 缓存。
- 新增 `flutter-check.yml`：push / PR 上跑 `flutter analyze --fatal-infos` + 全量 `flutter test`（此前 55 个测试文件从未在 CI 里跑过）。
- `deploy-web.yml`、`web-front.yml` 在构建前内联同一对门禁；`release.yml` 新增 `check` job（analyze 致命 + test），android / ios 依赖它，删掉原来的 `|| true`。

### 测试

- 新增 `test/core/geo_math_test.dart`（与合并前 5 处实现数值一致性、FogEngine 像素投影逐位不变）、`test/ui/format_test.dart`。全量 518 通过。

### 性能 / 功耗（第二轮，数据层与启动）

- 启动维护拆到 `lib/app/startup_maintenance.dart`：uuid 全表回填只在 schema 版本变化后跑一次（prefs 标记），孤儿图层自愈保留每次，8 次 `COUNT(*)` 探针仅 debug 构建或调试模式输出；新增 `peer_locations` 30 天 GC。
- 新增 8 条幂等索引：`fog_tiles(layer_id, zoom, tile_x, tile_y)`、`journal_entries(time|layer_id|uuid)`、`track_points(lat, lng)`、`peer_locations(time)`、`fog_erases(layer_id)`。单测用 `EXPLAIN QUERY PLAN` 钉住不再全表扫描 / 临时排序。
- 迷雾 reveal / erase 改为一次 bbox 范围读 + 一个事务批量 upsert，**位图未变的块直接跳过**（不写库、不刷 `updatedAt`、不发 delta）。真机重走已探索路段：写系统调用 −38%、写入字节 −40%；新路段无差别（写入量被底图瓦片缓存主导）。
- 回放的队友轨迹按时间窗读取，不再全表读；迷雾全量加载加计时日志（真机 46879 行 ≈ 0.9 s，本机 128 ms，索引对全量读无影响——成本在行对象化）。
- `LogBuffer` 只在 debug 构建或调试模式下安装（release 每条日志少一次分配与监听扫描）。

测试新增 18 个（索引 / GC / 批写等价 / 启动维护），全量 533 通过。

## [Unreleased] — 2026-08-27

借鉴「人生点点 2.0」的 3D 热图与自托管项目 Dawarich 的数据层算法（调研与
设计见 [docs/superpowers/specs/2026-08-27-heat-ridge-visits-design.md](docs/superpowers/specs/2026-08-27-heat-ridge-visits-design.md)）。

### 第五轮（09-01，时间窗口入口 + 行政区 3D 点云）

- **时间范围提到顶栏**。`heatRange`（全部 / 今年 / 近 30 天 / 自定义日期段）
  原本只在样式面板里，现在 3D 顶栏有一枚常驻胶囊，显示当前范围，点开即换；
  样式面板那份仍在，两边同一个设置。默认仍是「全部」。
- **新增「区域」视图**——3D 热图的第二种模式，与山脊共用同一个相机，切换
  不改变你所在的位置：
  - 轨迹点先落进 0.05°（≈5 km）网格，每个格子记下**去过的不同日期**；格子
    再按国家/省/市折叠成行政区。字号按**天数**（不是点数）log 缩放——采样
    频率差异太大，开车穿过一座城不该压过在那儿住了一年。
  - 每个格子画成一根发光的针（高度/颜色按天数分 5 档，批量绘制）；每个行政
    区一枚标签，贪心避让，忙的地方优先占位。
  - 名称旁显示国旗。**国行 ROM 的字体常常没有 regional-indicator 国旗字形**
    （🇨🇳 会裂成两个方块），所以先测量一个有效组合与一个无效组合的宽度差来
    判断设备是否支持，不支持就回退成两字母 ISO 徽章（颜色由代码稳定生成）。
  - 进入「区域」自动框住全部区域（＝查看全部）；点标签飞进该区域并切回山脊；
    右上角列表按天数排序列出所有地区，点一项同样飞过去。
  - 顶栏在窄屏上放不下这么多控件了（缩放时多出的瓦片 spinner 会撑出
    overflow 条纹）：chip 组改为占据固定图标之外的剩余空间并按需等比缩小，
    加载指示（载入瓦片 / 统计中 / 识别中 N）移到左下角 z 徽标旁。
  - 归属是**离线优先**：先用 `GeocodingService` 已有的 0.01° 网格缓存和内置
    国家 bbox 立即出图，再后台对没名字的格子按「天数最多优先」联网补齐
    （每次最多 180 个、间隔 140 ms、结果永久缓存）。境外靠系统 geocoder 补
    到市级，离线时退回国家级。

### 第四轮修订（09-01，按用户反馈：缩放后山脊高度消失）

三个独立缺陷叠加，缩放时山脊会塌成一张发光的平贴图：

- **网格索引 16 位溢出（主因）**。山脊网格最多 420×700 = 29 万个 cell，但
  `_cellOrder()` 把 cell 编号存进 `Uint16List`，`drawVertices` 的顶点索引
  同样是 16 位——超过 65535 就回卷，三角形被画到错误的位置，整片山脊等于
  消失。缩放/平移改变了轨迹落在网格中的行号，于是「一缩放就没了」。
  现在 mesh 按行分带（每带的顶点数刚好压在 16 位以内、各自重新编基），
  带内与带间都按 yaw 深度排序，画家算法照旧成立。
- **高度按视野峰值归一化**。放大到只剩一条路时，那条路自己就是峰值，
  `heightScale` 掉到 0.22 下限。改为**绝对刻度**：密度先换算成通过次数
  （一次通过的高斯峰是 `1/(√2π·σ)`），再按 `log1p(k·passes)/log1p(k·24)`
  映射——同一条路在任何缩放级别、任何时间窗、旁边有没有更热的路，山高
  都一样。只有当整屏最高的脊都不到 0.35 时才做一次温和的整体抬升。
- **脊宽随描边一起变宽**。2D 光晕的描边从 z14 的 3px 长到 z17 的 14px，
  高度却是屏幕常量，越放大越钝。密度场的 σ 现在钳在 [0.95, 1.6] 个 cell，
  山脊成为光晕里的一道锐脊；σ 下限同时消除了细线落在格线之间时的高度抖动。

另外：两次场重建之间地面按 2^Δz 拉伸，高度预算现在跟着拉伸（钳在 ±1 级），
手势结束后 70ms、0.08 级即重建（原为 280ms、0.35 级），过渡窗口更短更浅。

真机复验 z13 / z15 / z17 三档：山脊高度一致且立体，483 项测试通过。

### 第三轮修订（09-01，按用户反馈：参考 Google Maps 3D 的缩放与加载逻辑）

- **3D 热图重写为「实时瓦片 3D 地图」**，替换掉第二轮的「快照 + 松手重抓」：
  透视相机下直接渲染真实瓦片平面——地面（z=0）到屏幕是一个单应变换，用
  `canvas.transform(4×4 透视矩阵)` + `drawImageRect` 逐瓦片绘制（GPU 做
  透视校正采样），山脊仍走逐顶点投影（与单应矩阵同一套常数，有测试互相
  钉住）。核心组件：
  [heat3d_camera.dart](lib/services/heat/heat3d_camera.dart)（相机数学 +
  按距离分带选瓦片，11 个纯函数测试）、
  [tile3d_engine.dart](lib/services/heat/tile3d_engine.dart)（瓦片引擎）。
- **Google 式加载逻辑**：每个采样点的理想瓦片级别 ≈ `zoom − log2(w)`
  （w 为透视齐次分量）——近处用原生级别（俯仰大时底部甚至加载**更高一级**），
  远处逐带用金字塔粗级别；每块选中的瓦片投影到屏幕都是 ~180–360 px。
  瓦片走与 2D 地图**同一个磁盘缓存**（离线覆盖共享）；未到货时用已缓存的
  **父级瓦片子区域**放大顶住（经典的先糊后清），到货即重绘；失败 15 s 退避。
  内存上限 240 张、只淘汰不在当前工作集里的瓦片。
- **Google 式手势**：单指平移按**地面锚点**拖拽（远处自然拖得快）；双指
  捏合围绕手指锚点连续缩放（分数级 zoom，瓦片级别自动切换）、旋转、上下
  平行移动=俯仰；**双击放大一级**（围绕点击处）；指南针按钮回正。俯仰上限
  随缩放收紧（缩得越远越不让倾，Google 同款），z3–19 全程可用。
- 山脊密度场改为**世界锚定**：随相机平移直接重投影（零重算），只在缩放
  变化 >0.35 级或跑出覆盖范围时防抖重建；地面压暗直接画在瓦片平面上。
  左下角 z 徽标显示当前缩放。退出 3D 时相机（中心+缩放）回写 2D 地图，
  2D 正好落在 3D 离开的地方。
- 真机（Android 13）：chip 进 3D（热度索引 ~0.8 s）→ 连续平移跨越数公里
  瓦片流式补齐 → 双击放大到 z16 清晰 → 指南针/俯仰正常 → 退出后 2D 落点
  一致，全程无报错。全量测试 480 过。
- Web 注意：3D 瓦片经 XHR 拉取，需要瓦片源允许 CORS（OSM 可以，高德栅格
  在浏览器可能受限）——Web 只读版建议 OSM 底图。

### 第二轮修订（同日，按用户反馈）

- **热图＝3D 地图模式**：不再有独立的 2D 热图样式——点首页「火焰」chip
  直接把地图切入 3D 热力山脊视图（2D 发光瓦片层仍在，但只作为 3D 地面
  贴图的一部分在进入时短暂挂载）。3D 里**单指平移、双指俯仰/旋转/缩放**：
  平移与缩放先在冻结画面上即时预览，手势一停就把真实地图相机移过去、
  等瓦片与热度烘焙完重抓场景——3D 模式用起来是地图，不是一张照片。
  `heatMode` 设置字段随之移除（未发布过，无兼容负担）。
- **回放「合并记录」**（schema v11 `merged_trips`）：多选段后除了临时合并
  回放，还能「存为合并记录」并命名；列表顶部常驻，一条即可整体回放，可
  重命名 / 解散。**纯引用式**——只存 `{图层 uuid, 时间窗}` 列表，原始轨迹
  点一个不动（物理合并会破坏图层归属与同步语义）；按图层 uuid 引用 + 时间
  窗 ±1 分钟容差，换设备 / 图层 id 重排 / 会话边界微调后仍能命中。
- **到访与合并记录纳入备份与同步**（此前 v1 标注仅本机）：新模块
  `visits`（places + 用户处理过的 visits）与 `trips`。**机器识别行不出境**
  ——每台设备可从轨迹重建，且其 uuid 跨设备必然不同，导出只会翻倍；只同步
  用户确认 / 命名 / 归入 / 删除过的行（软删行随行传播，确认行在对端自动
  成为检测锚点）。跨设备引用全部走 uuid（visit→layer、visit→place、
  trip→layer），导入时重映射；无 uuid 命中的进入地点在本地 30 m 内有同点
  位地点时**收敛合并**（重钉本地 uuid）而不是插重复；地点 / 合并记录的
  删除走 tombstone。旧版本 App 读新档案会忽略未知模块，新版读旧档案模块
  缺失即跳过（manifest 机制原生兼容）。

第二轮真机（同设备，真实数据）：chip 一点直接进 3D（索引 0.8 s + 预热
0.9 s）；单指平移在冻结画面上即时预览、松手后真实相机移动并重抓场景
（视野从市区平移到南站以南，山脊随新画面重建，无报错）；回放页多选 2 段
「存为合并记录」→ 默认名保存 → 列表顶部出现「7月9日的旅程 2026-07-09 →
08-26 · 2 段 · 0.5 km」→ 点击即整体合并回放。备份/同步语义由
`test/backup/visits_trips_roundtrip_test.dart` 4 个真实往返用例钉住。

### 新增

- **热图图层**（[services/heat/](lib/services/heat/)、首页顶部「火焰」chip）：
  走过的路按经过次数叠加发光，走得越多越亮、最热处泛白（Strava /
  人生点点式个人热力图）。与迷雾同一套烘焙瓦片管线（手势合并更新器、
  同样的缓冲区），每段描两笔（宽软笔 + 细核心）以 `BlendMode.plus` 累积
  覆盖度，再过色板 LUT 上色。五套色板（青 / 火 / 彩虹 / 紫 / 白）、
  **曝光**与**粗细**两个连续参数（人生点点样式面板的同款两个量）、时间
  范围（全部 / 今年 / 30 天 / 自定义）、迷雾块底噪开关。显示模式点 chip
  循环：关 → 热图（隐藏迷雾走廊，深色模式下保留暗幕）→ 叠加；长按打开
  样式面板。热度数据 = 轨迹点 + 迷雾块底噪（导入的世界迷雾区域也有淡淡
  热度）。
- **3D 热力山脊**（右侧「倾斜」FAB，仅热图开启时出现；
  [heat_tilt_screen.dart](lib/ui/heat/heat_tilt_screen.dart)）：人生点点
  2.0「热图样式下倾斜地图即可看到 3D」的同款效果——把地图栈抓成快照贴在
  透视地面上，把屏幕内的热度栅格化成 **float 密度场**（8-bit 加法会饱和，
  峰值高度就没了）→ log 归一 → 高度场网格，法线光照、峰顶泛白，
  `drawVertices` 一次画完。单指上下俯仰 / 左右旋转、双指缩放、双击复位，
  进入时 0→52° 动画（尊重 `disableAnimations`）。纯 Dart 无新依赖，Web
  版同一份代码。局限：3D 内不能平移到快照之外，远端渐暗。
- **到访地点识别 + 足迹时间轴**（[services/visits/](lib/services/visits/)、
  [timeline_screen.dart](lib/ui/timeline/timeline_screen.dart)，「更多 →
  足迹时间轴」）：把 Dawarich v3 的停留检测管线移植成纯 Dart——单遍
  dwell sweep（半径 100 m、漂移上限 1.5×）→ 同地静默桥接（≤ 7 天）→
  链式合并（≤ 15 min）→ 过滤（≥ 3 点、≥ 5 min）→ 1/accuracy 加权中心；
  置信度权重 dwell .30 / tightness .25 / place .20 / density .15 /
  accuracy .10 / bridged .15，≥ 70 实心、≥ 40 淡显、更低折叠。三态
  suggested / confirmed / declined + 软删墓碑：机器行整体幂等重建、用户行
  是锚点（确认的不会被复制、删掉的不会再被建议）、tuple 不变则零写入。
  地点归属：50 m 内已有地点（手动 > 常去 > 最近）否则新建并用反向地理编码
  的城市命名；可确认 / 重命名（锁为手动）/ 归入已有地点（孤儿自动地点
  顺手清掉）/ 删除 / 在地图上查看。时间轴页按天列出到访与其间的移动段
  （距离 / 时长 / 均速 → 步行 / 骑行 / 驾车 / 火车），当日手账内嵌，
  日期条上有记录的日子字重更粗。触发：录制停止、导入完成、首次启动 8 s
  后全量按月扫一遍（在 isolate 里）。**到访数据 v1 仅本机**，不进备份 /
  同步（换机后会重新识别，但确认与命名不会带过去）。
- **探索进度 → 「足迹」Tab**（[footprint_tab.dart](lib/ui/explore/footprint_tab.dart)）：
  总里程 / 今年 / 本月 / 最长一天，记录天数 / 当前连续 / 最长连续 /
  足迹天龄，近 6 个月活动日历（像素格，颜色 = 日里程分档），24 小时
  节律条，国家 / 城市（城市按到访停留 ≥ 1 小时计，Dawarich 规则）与
  Days per Country，最常去的地方 Top 5（点一下地图飞过去）。里程规则同
  Dawarich：相邻点间隔 > 30 min 或隐含速度 > 300 km/h 的段不计。结果
  快照缓存在本地，打开即显示上次数字再静默刷新。
- **手账照片位置补全**（[track_interpolator.dart](lib/services/geo/track_interpolator.dart)）：
  照片只有拍摄时间没有 GPS 时，用前后 30 分钟内的轨迹点插值出位置
  （两侧间隔含隐含速度 > 12 km/h 且 > 500 m 时取更近一侧，坐车时不会钉到
  半路上），编辑弹窗提示「位置由当时轨迹推算（±N 分）」；「从照片导入手账」
  同样生效。借 Dawarich「Enrich Photos」。

### 数据层

- schema v10：`track_points.flags`（bit0 = GPS 异常）、`places` / `visits`
  表，`(layer_id, time)` / `(time)` / visits 索引（此前所有表零索引，回放 /
  地球 / 统计每次全表扫）。索引在 `beforeOpen` 幂等创建。
- **GPS 噪点过滤**（[point_filter.dart](lib/services/location/point_filter.dart)，
  录制与导入共用）：Null Island、坐标越界、精度 > 500 m 直接丢弃；隐含
  速度 > 250 m/s（1 h 内）或同时间戳位移 > 1 km **标记不删**，热图 / 到访 /
  统计 / 插值默认排除，迷雾不会被一次跳变画出 100 km 走廊。
- **导入去重**：同图层同毫秒同 1e-6° 的点跳过（重复导 GPX、与录制重叠的
  GPX 不再翻倍），提示「跳过 N 个重复点 / 丢弃 M 个无效定位」。
- 备份导出 / 导入携带 `flags`。

### 测试

- 新增 `test/heat/`（色板 LUT、段索引与 z12 分桶、真实瓦片烘焙、密度场）、
  `test/visits/`（停留检测合成一天、桥接 / 不桥接、漂移上限、置信度、
  引擎幂等 / 锚点 / 墓碑 / 归入）、`test/location/point_filter_test.dart`、
  `test/geo/track_interpolator_test.dart`、`test/db/schema_v10_test.dart`、
  `test/stats/footprint_summary_test.dart`。

### 真机验证（M2012K11C / Android 13，真实数据 1853 点 / 93k 迷雾行）

| 项目 | 结果 |
|---|---|
| 热图 2D | 索引 70 点 + 46879 迷雾块 1.1 s；青色发光轨迹按预期叠加。两处观感问题当场修：z>14 不再画迷雾块底噪（成了灰色大方块）、LUT alpha 渐入 6%→20%（单次经过不再是深色涂抹） |
| 3D 山脊 | 首开崩在 `initState` 里读 MediaQuery（测试没覆盖）→ 改到 `didChangeDependencies`；单条走过一次的路被归一到满高成了一堵墙 → 高度上限随原始峰值密度增长（1 次 ≈ 0.25，20 次 → 1）；顶部工具条被 Stack 居中 → Positioned。修后底图透视、山脊光照、单指俯仰/旋转均正常 |
| 到访 | 首启全量识别 4 个月 1853 点 → 9 处到访 < 0.1 s；时间轴自动跳到最近有数据的 8/26，识别出 15:43–16:22 一处 38 分（置信 80，反向地理编码命名「上海市 · 未命名地点」）；确认后实心点、去掉「建议」 |
| 足迹 Tab | 8.3 km / 15 天 / 活动日历 / 节律 / 1 国 1 市 3 地点 / 最常去 5 次 67 小时（含桥接静默）渲染正常 |
| 未量 | 热图平移掉帧率与 3D 逐帧耗时未做 SurfaceFlinger 采样（数据量太小无参考意义） |

## [Unreleased] — 2026-08-26

### 新增

- **奥维地图底图**（[tile_providers.dart](lib/services/map/tile_providers.dart)）：
  `MapProvider.ovital`（枚举末尾追加，存量设置索引不漂移）。奥维没有公开
  瓦片端点，接的是用户自己奥维实例开启的「WEB 瓦片服务」
  `http://IP:端口/getomap_{地图ID}_{z}_{x}_{y}_{ext}_{time}.png`；设置页
  「瓦片源与 API Key」抽屉新增 URL 与「GCJ-02」开关，模板自动兼容奥维自家
  的 `{$z}/{$x}/{$y}` 写法，未配置时回落 OSM 并在设置页提示。提供商选择由
  三段选择器改为下拉（四家放不进一行）。
- **回放多选合并 + 导出视频**（[playback_screen.dart](lib/ui/playback/playback_screen.dart)、
  [services/playback/](lib/services/playback/)）：列表可勾选多段记录合并回放；
  各轨迹各画各的线（按图层颜色），共用一条**去掉空档的时间轴**（同时段
  的并行播放、隔天的首尾相接），游标从「第几个点」改为真实时间 ×N 倍率，
  头部在采样点之间插值；新增相机跟随。「导出视频」按 15/30/60 秒把整段
  回放压成 30 fps H.264 mp4（`flutter_quick_video_encoder`，MediaCodec 硬编，
  Unlicense），逐帧抓取地图 RepaintBoundary，完成后可 SAF 保存到本地或分享。
  分段改为**按图层分别切段**（此前两图层同时段记录会被混成一段、距离
  在两条轨迹间来回跳），回放页底图坐标补上 GCJ-02 纠偏。

### 性能（缩放 / 滑动）

- 迷雾两层 TileLayer 加**手势合并更新器**：手势中不再逐帧 load+prune，
  停手 120 ms 后一次到位（长手势至少每 400 ms 一次）；录制增量发布在
  手指按下期间挂起。参考 fog.vicc.wang 的做法：缩放动画期间只缩放已有
  栅格，重活推到手势结束。
- `_FogCompositor` 两次全屏 saveLayer 合成一次（颜色矩阵把白色走廊掩膜
  直接变成带孔的雾幕，像素结果与原 dstOut 方案一致，有测试钉住）。
- 迷雾烘焙：z12–14 逐格档改走 8×8 子块占位 memo（消除 z11→z12 的 64 倍
  成本断崖）；z15–17 逐格 `drawCircle` 改为一次 `drawRawPoints`；掩膜→RGBA
  改 32 位写入。
- 底图/迷雾瓦片缓冲对齐为 keep 3 / pan 2（此前 5/3 vs 默认 2/1，工作集
  约 6.6× 视口，且迷雾先被修剪露出雾幕）；底图更新 throttle 80 ms、去掉
  淡入、显式 `retinaMode: false`；ImageCache 条目上限 1000→4000。
- 首页：`MapEventMoveEnd` 只在旋转角真正变化时 setState（此前每次平移/
  缩放结束整屏重建）；手账图钉加 `cacheWidth` + `RepaintBoundary`；
  `FogEngine.changes` 改为固定字段（广播流每次 getter 都是新对象，曾使
  地图每次重建都重新订阅并丢增量）。

### 功耗

- **首页地图定位流**：录制中改为镜像录制管线的点（不再与前台服务并开
  第二路 high/3 m 流）；非录制时 high/10 m + 10 s 间隔（旧写法没设间隔，
  真机实测落在 geolocator 默认的 `ProviderRequest[@+5s0ms]`，等于请求频率
  减半、回调频率降到 1/3）；退后台/锁屏时全部停掉（流、看门狗、重订），
  回前台恢复。看门狗 30 s/90 s → 60 s/3 min。
- **静止检测**（后台服务）：3 分钟内位移 < 25 m 视为静止，主动补定位
  从每 10–60 s 放宽到每 2 分钟，不再重订流，通知栏标「静止省电」。
  去掉 `allowWifiLock`。
- **组队局域网扫描**：60 s 全子网 TCP 扫描改为自适应（无人 1→2→4→8→10 min
  退避；已连上队友每 10 min 一次）。
- 中央录制按钮的脉冲动画只在录制时跑（此前不录制也 60 fps tick，让
  首页永无空闲帧）；队友刷新定时器 10 s→30 s 且无队友不触发重建；
  旅伴卡的相位灯在 `disableAnimations` 时真正停掉控制器。

### 修复

- `AppSettings.fromJson` 枚举索引越界不再抛 RangeError——此前会让整份设置
  回落默认（升级后选了新底图再降级=丢所有设置），现在只该字段回默认。
- 回放播放器顶栏加渐变遮罩：该页不画雾幕，白色返回键与操作图标（含新的
  「导出视频」）此前压在明亮底图上几乎不可见。

### 真机验证（Redmi M2012K11C / Android 13 / 120 Hz）

同一套脚本化手势（8 次平移 + 跨 4 级缩放来回 + 2 次平移），
SurfaceFlinger 逐帧时间戳统计：

| 指标 | 改动前 (82fd02a) | 改动后 |
|---|---|---|
| 掉帧 >1.5 vsync | 33.1% | 11.3% |
| 卡顿 >3 vsync | 5.5% | 0.7% |
| p95 帧间隔 | 33.0 ms | 16.6 ms |
| p99 帧间隔 | 66.1 ms | 24.8 ms |

其余实测：奥维模板 `{$z}` 归一化后真实发出 `getomap_202_{z}_{x}_{y}_0_0.png`
请求并正确渲染；缩放 11 帧零黑块（与改动前持平，未回退）；定位注册数
空闲前台 1 路 / 后台 0 路 / 录制 1 路（@10 s，前台服务那路）/ 停止后回到 1 路；
15 秒导出得到 496×1080、30 fps、450 帧、15.000 s 的 H.264 mp4，SAF 保存到
Download 成功。

## [Unreleased] — 2026-07-28

### 性能（同步/备份大提速）

- **分组导出缓存**（[onedrive_sync_engine.dart](lib/services/sync/onedrive_sync_engine.dart)）：
  导出拆成 journal / tracks / chat / fog / meta 五个分片组，每组用 drift
  表版本计数器做指纹——相关表自上次同步以来没有写入的组，直接复用上次打包
  好的 (bytes, MD5)，整组跳过全表读 + jsonEncode + FoW 瓦片重建 + 逐分片
  MD5。「上传后马上下载校验」的本地基线从全量导出变为近乎瞬时。
- **确定性 manifest**：同步导出不再写 `exportedAt` 时间戳。此前它导致
  meta.zip 的 MD5 每次必变 → 每次 syncUp 都重传、每次 syncDown 都重新拉取
  并重新合并 settings/layers 等模块，哪怕什么都没改。
- `gcFogErases` 先探测再删除——drift 对 0 行 DELETE 也会发表更新通知，
  曾使 fog 组指纹永不稳定、缓存永不命中。

### 安全（把"写好没接线"的防线接上）

- **HttpGuardInterceptor 真正生效**：全部 16 处 `Dio()` 改经
  `guardedDio()` 工厂构造，明文 HTTP 到公网地址一律拒绝（LAN/RFC1918/
  Tailscale 照常放行）。JOOX 音乐 API 无 HTTPS，按 host 显式豁免并注明风险。
- **凭据迁入平台安全存储**：PrefsStore 读写时把 `kVaultSecretKeys`（WebDAV
  密码、PAT、AI key、OneDrive refresh token、音乐 Cookie 等）透明迁移至
  Android Keystore / iOS Keychain，明文 prefs 里只留 `__secure__` 占位。
  旧安装首次启动自动迁移；安全存储不可用时回退明文（不丢凭据）。

### 修复

- **手账照片持久化**：选图/拍照后把文件从 image_picker 的**缓存目录**复制到
  `documents/journal_media/` 再入库——此前存的是缓存路径，系统清缓存后照片
  静默丢失。旧条目显示时按文件名在持久目录回退查找。
- 后台定位 task-data 回调在取消订阅时正确注销（此前每次开始/停止录制泄漏
  一个回调）。

### 功耗

- 录制时不再同时挂**前台 + 后台两条 GPS 流**：前台服务在跑时主 isolate 复用
  它推送的样本（此前两条流的重复样本全部被去重丢弃，白白多一路 GPS 请求）。
  无前台服务的平台（web/桌面）仍用前台流兜底。后台定位链路（watchdog、
  LocationManager 兜底、唤醒锁）完全未动。
- 组内音乐广播不再每 5 秒重新解析一次直链（一次真实网络请求），同一首歌
  只解析一次。

### 清理

- 删除死代码：`zerotier_helper.dart`、`geojson_loader.dart`（无任何引用）；
  README 中对应的「接入真实 GeoJSON 边界」章节一并移除。
- README / README.zh「数据存放位置」更新为真实布局（journal_media/、
  Keystore、后台 GPS 缓冲）。

## [Unreleased] — 2026-07-10

### 重构（路径/迷雾渲染对齐 Fog of World：任意缩放恒定清晰 + 彩色图层同几何）

对照 fogofworld.app（「路径在任何缩放级别保持清晰并无缝改变粗细」）与
fog.vicc.wang/eraser.html 的渲染逻辑（每个探索点渲染为 ~3px 恒定屏幕尺寸的
GL 方点；迷雾/线条两种模式共用同一几何）重写了烘焙管线：

- **z≤14（原生及以下）**（[fog_tile_provider.dart](lib/services/map/fog_tile_provider.dart)）：
  保留逐位精确的整数骨架（数据域完全不动），但渲染改为 掩膜 → GPU
  `ImageFilter.dilate` + 轻微 blur——走过的路径在低/中缩放保持 **~3px 恒定
  屏幕宽度**，不再是又细又碎、缩小就看不见的 1px staircase；成本以 dim²
  为界，密集 FOW 导入区在低缩放不会爆炸（掩膜带 pad 消除瓦片接缝）。
  z≥15 沿用已验收的平滑盘+羽化管线不变。
- **彩色图层 = 同一几何**：所有可见图层的走廊先统一在雾上打洞，设了
  `pathColor` 的图层再用 **同一掩膜/盘几何 + 同一滤镜** 以 srcIn 着色叠加
  （浓淡=`pathOpacity`）。删除了原来的 TrackPoint 彩色折线层
  （fog_layer.dart 整体移除，LiveTrackPoint 迁至
  [live_track_point.dart](lib/services/map/live_track_point.dart)）——
  彩色路径背后不再有透明打洞的"双重标识"，透明色/自定义颜色只是同一路径
  样式的颜色差异；FOW 导入数据（无 TrackPoints）从此也能整层着色。
  图层编辑对话框随之简化（去掉独立"路径粗细"滑条，宽度由记录笔刷决定）。
- **一致性保证**：渲染只依赖位图字节 → FOW 导入、本地录制、导出→导入
  往返在像素级完全一致（测试逐字节锁定）。
- **冷启动白闪修复**：①Android 启动屏从白色改为夜色 `#0F1E28`
  （launch_background.xml 两个变体）；②Flutter 首帧到 prefs/图层列表就绪
  之间，地图上覆盖近似雾色层，随真实雾瓦片就绪替换——完整链路
  夜色启动屏→雾罩首帧→完整渲染，全程无白色裸地图。
- **像素风应用图标**：程序化生成（[test/tool/gen_app_icon_test.dart](test/tool/gen_app_icon_test.dart)，
  24×24 像素画：纸质地图+橙色轨迹+红 pin+青绿雾角，夜色底）；legacy 全尺寸
  mipmap + adaptive icon（foreground 自带满幅夜色底，规避 MIUI 白底合成）。
- **测试**（[test/fog_tile_bake_test.dart](test/fog_tile_bake_test.dart) 重写，10 用例）：
  骨架精确性、z10/z12/z14 恒定屏宽、对角线无断珠、彩色几何与透明几何逐像素
  匹配、双图层混合、位图唯一性（导入=录制=往返）、**真实 Sync.zip 数据**
  z8-14 烘焙（原件只读拷贝）；PNG 预览输出 build/fog_bake_preview/。
  全套 233 测试通过；真机（Redmi）多缩放/彩色图层/冷启动/图标截图验证。

### 新增（自建后端 `backends/`：排行榜服务器 + 组队云中继，Docker/ECS/frpc/CF Tunnel）

排行榜与组队此前完全靠"规避后端"的手段（P2P gossip、GitHub PR、局域网多播、
frp 打洞、WebRTC+WebDAV 信令）。本次补上可选的自建后端，让互不见面的用户能同步
排行榜、组队在任何网络下可连通——同时保持"无后端也完整可用"的原设计。

- **服务端**（[backends/](backends/)）：零依赖 Node（≥20）单进程单端口，模块注册制
  （`(cfg) => {name, routes?, onUpgrade?, status?, shutdown?}`，加模块=加一个文件+一行）。
  - **排行榜模块**：完整实现 [docs/leaderboard-server-api.md](docs/leaderboard-server-api.md)
    v1（`/entries` CRUD、`/monthly/{ym}`、`/index` 探针）；服务端 Ed25519 验签
    （canonical JSON 与 Dart `_sortedJson` 逐字节一致，有 Dart 生成的交叉验证向量锁定，
    见 [tool/gen_lb_vector.dart](tool/gen_lb_vector.dart)）+ TOFU 公钥锁定 + LWW +
    未来时钟拒收；全量响应缓存单 Buffer + ETag/304；每 IP 限流（读60/写10每分）；
    JSON 防抖原子持久化，SIGTERM 落盘，重启不丢。
  - **组队中继模块**：`/group/v1/ws` 手写 RFC6455 WebSocket（无依赖），按群组分房间
    转发；**零知识**——负载原样直转（配共享口令即端到端加密，服务器只见密文）；
    定向消息走 `@peerId|` 路由前缀（1:1 聊天/语音不广播全房间）；单连接限速
    （50条/s、512KB/s）+ 慢消费者断开 + 30s ping 重连保活 + 房间上限（默认32）。
  - **测试**：`npm test` 22 用例全绿（Dart 签名向量跨语言验签、API 全行为、
    LWW/TOFU/token、持久化重启、WS 广播/定向/隔离/鉴权）。
  - **部署**：Dockerfile（node:22-alpine 非 root + healthcheck，实测 RSS 11 MB /
    CPU 0.02%）；docker-compose 内置可选 `--profile frp`（frpc 旁路容器）与
    `--profile cloudflare`（cloudflared 旁路容器）两种公网暴露；样例配置在
    [backends/deploy/](backends/deploy/)。
- **客户端**：
  - 新增联机方式 **云中继服务器**（`GroupTransport.relay`，enum 尾部追加不破坏旧配置）：
    [relay_group_service_io.dart](lib/services/group/relay_group_service_io.dart) 复用
    与 LAN/frp 完全相同的线格式（JSON 行 + `v1|` 加密帧），WebSocket 自动重连
    （2→30s 退避）、25s hello 心跳出席、75s 静默剔除；闲时每成员 ~10 B/s。
  - 组队设置页新增中继配置区（服务器地址/中继令牌/指南/诊断入口）；
    prefs 新增 `relayServerUrl`/`relayToken`，纳入 GroupLifecycle 身份变更重建。
  - 排行榜的「配置社区服务器/同步社区服务器」原有功能与新后端开箱互通（无改动）。
  - **关于页新增两篇内置文档**：《自建服务器·部署指南》（ECS+Docker+frpc+CF Tunnel
    全流程）与《自建服务器·客户端配置》（排行榜/组队逐步接入+排障+流量说明）；
    组队设置与排行榜菜单均有直达入口。
- **验证与自动化测试（三层）**：
  - **Flutter 集成层**（spawn 真实 Node 后端，共享 [test/helpers/spawn_backend.dart](test/helpers/spawn_backend.dart)）：
    [test/relay_group_service_test.dart](test/relay_group_service_test.dart) 覆盖出席、
    全部消息类型（聊天/位置/PTT 语音字节往返/音乐同步/自定义 gossip）、定向路由、
    端到端加密偷听者零解码、房间隔离、**服务器重启后客户端自动重连**（~4s 恢复）；
    [test/leaderboard_server_client_test.dart](test/leaderboard_server_client_test.dart)
    用 App 自己的 LeaderboardService+HttpLeaderboardClient 验证 push→fetch **逐字节
    数据正确性**（double 精度/中文/月度表/contentHash）、拉回条目客户端验签通过、
    服务器端 LWW/TOFU/伪造 422 从客户端视角生效、/monthly //index 与推送数据一致。
  - **Docker 容器层**（[backends/scripts/docker-e2e.sh](backends/scripts/docker-e2e.sh)
    + [backends/test/docker-e2e.test.js](backends/test/docker-e2e.test.js)）：构建生产
    镜像后按生产形态（volume+healthcheck+非 root）跑两轮——开放模式 17 用例（全 API
    面、数据正确性、100KB 大帧中继、unicode 直转、状态计数器、**`docker restart`
    后数据逐字节存活**）+ 鉴权模式 5 用例（双 token 强制）+ healthcheck 转 healthy。
  - **CI**（[.github/workflows/backend.yml](.github/workflows/backend.yml)）：backends/
    任何改动触发——`npm test`（23 用例含 Dart 跨语言签名向量）→ 构建 Docker 镜像 →
    跑完整容器级 E2E，失败时自动吐容器日志。
  - 全套 Flutter 226 测试通过；`flutter analyze` 0 错误 0 警告；真机验证组队设置 UI
    与应用内指南渲染。

### 修复（冷启动地图偶发无迷雾/无轨迹，需点定位或缩放才出现）

- **根因**：flutter_map 7.0.2 的 `TileLayer.reset` 流本身是坏的（订阅是
  `late final`，只在 dispose 被引用，从未激活），项目改用 `additionalOptions`
  换代触发就地重载；但 `reloadImages` **只重载已存在的 TileImage** ——冷启动时
  fog 行从 DB 异步到达，若此刻瓦片管理器里还没有当前相机的瓦片（图层插入早于
  布局/相机就绪、且其后无任何地图事件），就永远不会加载，直到用户平移/缩放/点
  定位触发地图事件。
- **修复**（[fog_tile_provider.dart](lib/services/map/fog_tile_provider.dart)）：
  快照在「空 ↔ 有数据」间翻转时给 TileLayer 换 `ValueKey` 强制重挂载——重挂载
  必然执行 initState→didChangeDependencies→按当前相机全量 load-and-prune；
  数据保持非空的后续更新仍走无闪烁的就地重载路径。另外 generation 改用跨实例
  单调种子，避免退出再进入地图页时新快照撞上旧 ImageCache 键。
- 真机验证：连续 3 次冷启动（零交互）迷雾蒙版 + 已走走廊全部首屏直出；
  `flutter test test/fog_tile_bake_test.dart` 3/3 通过。

### 性能（探索进度首开 10s+ → 0.7s：双组归属一次跑 + 块级快路径 + 精简取数）

- `computeAggregates` 支持 **regions2 第二归属组**：国家与省份两个独立归属
  pass 在同一次取数、同一个 isolate 运行内完成（探索页从 2 次调用 → 1 次）。
- **块级快路径**（`_RegionGroup.classify`）：若某候选 bbox 完全包含整个 64×64
  块、且没有更小面积的候选部分相交，则整块所有亮像素必然归它 →
  `popcount×cellArea` 一步归属，跳过 4096 像素循环。绝大多数块（~600m 见方 vs
  省级 bbox）走快路径，仅边界块回退逐像素——**数学等价，真机数值逐位一致**。
- 取数改精简三列 `customSelect`（tile_x/tile_y/bitmap），砍掉全行 drift
  数据类反序列化开销。
- debug 构建输出 `[FogAgg] rows/fetch/total` 计时日志（assert 内，release 剥离）。
- 真机实测（46872 行, 33 国+50 省+1 learned）：**fetch 407ms + 计算 ~330ms =
  736ms**，页面亚秒级完整呈现；`fog_engine_test.dart` 20/20 通过。

### 性能（修复探索进度/个人卡/排行榜卡死 ANR：雾聚合移入后台 isolate + 缓存）

- **根因**：fog_tiles 在 FOW 导入后有 ~46872 行 × 512B 位图；旧代码在**主 isolate**
  做合并/popcount/区域归属（探索页最重路径 = 每个亮像素 × 数百个区域 bbox 判定），
  且探索页每个 learned 省份再全量扫一遍库、个人卡同样的全球扫描连做三遍 →
  9 秒级 ANR（logcat: Skipped 1593 frames）。
- **修复**（[fog_engine.dart](lib/services/fog/fog_engine.dart)）：
  - 新增 `computeAggregates(layerIds, {regions, bboxes})` → `FogAggregates`
    （globalKm2 / 按区域归属 km² / 按 bbox km²）：行数据打包为平坦
    Int32List+Uint8List 后送 `compute()` 后台 isolate；isolate 内 256 查表
    popcount、跨图层 OR 合并（视图零拷贝、重复才复制）、**区域归属加
    per-block 候选预筛**（数百 bbox → 通常 0–5 个）。
  - **结果缓存**：键 = layerIds + 引擎写入修订号 + `COUNT(*)/MAX(rowid)` 探针
    （捕捉不经引擎的批量导入）+ 参数签名；容量 6 的小 LRU。二次进入秒开。
  - 旧三方法（globalExplorationPercent / revealedAreaInBboxKm2 /
    revealedAreaByRegionsKm2）改为薄封装，所有调用方自动受益。
- **调用方改造**：探索页 = 2 次聚合调用（country/prov 归属各一次，learned
  bboxes + 全球数搭车）替代 3+N 次全量扫描；个人资料卡 = 1 次聚合 +
  `COUNT(*)` 区块数（原来三次全量扫描）；排行榜自动走缓存。
- `PixelDitherFade` 加 RepaintBoundary（滚动时不再重画数万方块）。
- 真机验证：探索页计算全程 UI 流畅（spinner 活跃、0 跳帧 0 ANR），数值与旧版
  **完全一致**（0.0001077767% / 0.0003959564% / 亚洲 0.0186378065%）；个人卡
  3 秒内弹出（原 9 秒 ANR）。

### UI（像素风 v2：像素字体全局化 + 轻快亮主题 + 组件重构）

- **像素字体全局化**（按用户要求）：`fontFamily: 'PixelZh'` 进 ThemeData——正文、
  按钮、二三级标题、tip、引用全部像素字；生僻字/emoji 自动回退系统字体。
  **国旗 emoji 修复**：探索页旗帜 Text 显式 `fontFamily: 'Roboto'`（否则
  regional-indicator 被像素字体渲染成字母方块）。
- **轻快亮主题 + 外观开关**：`AppSettings.themePref`（'light' 默认 /'dark'/'system'），
  设置页新增「外观 → 主题」三段开关（轻快/暗黑/系统），实时切换。亮色 =
  vibrant 种子 + 薄荷纸底 `#F3FAF8`；暗色提亮为 `#14212C`（脱离纯黑）。
- **圆角回调**（按用户反馈"不要全方形"）：按钮/输入框 10、卡片 8、FAB 12、
  对话框 14、底板 16——脆但友好；阶梯像素角仍保留给 hero 面板。
- **菜单/下拉重构**：popup/menu/dropdown 统一「道具面板」样式——tonal 面 +
  1.5px 描边 + 低阴影，替代默认 Material 浮影。

### UI（全 App 像素风设计语言：像素作表达层，M3 作骨架）

FOW「点亮地图」本就是游戏机制，像素语言承载「收集乐趣」。原则：**展示层说像素话，
正文/标签/控件保持系统字体与 Material 3 语义**（product register 禁止 display 字体
进标签）；有物理含义的圆形（定位点、精度圈、头像）保留圆形。

- **中文像素字体**：缝合像素字体 fusion-pixel-font 12px 简中（OFL，许可证随包）→
  `assets/fonts/FusionPixelZh.ttf`，family `PixelZh`。仅用于 display 时刻。
- **像素设计系统** [`lib/ui/common/pixel.dart`](lib/ui/common/pixel.dart)：
  `PixelText`（display/headline/label，12 的倍数对齐像素网格）、`PixelPanel`
  （阶梯像素角面板 + 描边 + 裁剪）、`PixelBlockBar`（8-bit 血条式分段进度）、
  `PixelDitherFade`（4×4 Bayer 抖动渐隐，替代 gradient scrim）、`PixelBadge`、
  `PixelSprite` + `PixelSprites`（地图/书/指南针/脚印/音符/云 手绘像素图元）、
  `PixelScanlines`、量化/网格吸附工具函数。
- **Atmosphere 新增 `AtmosphereStyle.pixel`（默认）**：8-bit 天气——三朵手绘像素云
  横向漂移（整数圈无缝回绕）+ 方形光尘吸附 3px 网格、闪烁量化为 4 档（blink 而非
  breathe），指针拨开交互与 reduced-motion 静帧保留。
- **全局主题硬边化**（main.dart，明暗双主题统一 `_buildTheme`）：卡片/按钮/FAB/输入
  框/对话框/弹层圆角从 10–16 收到 2–8；新增 elevated/outlined/text button、dialog、
  bottomSheet、popupMenu、inputDecoration 的 shape 主题。
- **逐页落地**：
  - 首页：App 名与「探索进度」像素字；hero 换 PixelPanel + 像素地图 sprite +
    像素氛围；分组标题加像素方块色标（=分组色钥匙）；紧凑入口方形图标片。
  - 探索进度：hero 卡 PixelPanel + Bayer 抖动 + 像素云；两个大百分比像素字；
    进度条全部换 PixelBlockBar（含国家详情 sheet）；国家旗格改硬角方块。
  - 地图：右侧按钮堆/工具方形化；图层胶囊+方块色标；录制键方形化（图标语义
    不变：圆点=录制/方块=停止，脉冲量化 4 档）；等级卡 Lv 像素字 + 块状经验条；
    资料卡/统计片/横幅胶囊硬边化；底部导航徽点方块化。
  - 手账：列表标题像素字、书本 sprite 占位、硬角卡片/缩略图/徽章；详情地图条、
    坐标胶囊、画廊页码硬边化。
  - 回放/总结：标题像素字；统计四联数（次记录/km/小时/采样点）像素字；
    播放器面板/速度片/信息条硬边化。
  - 排行榜：标题像素字；前三名名次像素字 + 奖牌色。
  - 歌单：标题像素字；收藏空状态加像素音符 sprite + 教学文案。
  - 其余（设置/备份/图层/组队/AI 规划/关于/聊天/图床/权限/globe/toast）：
    硬编码大圆角统一收紧到 3–10。
- 真机 6159e157 验证：地图浮层/首页/探索/手账列表+详情/回放/排行榜/歌单逐页截图
  确认。`flutter analyze` 0 error 0 warning（17 个 info 均为历史遗留）。
- **已知问题（改造前就存在，未动）**：排行榜刷新触发的重型雾数据聚合在主线程
  运行，可造成 ~9s ANR（logcat 中 07-09 旧版本即有同签名 ANR）。待专项优化。

### UI（手账：正文改为内联富文本编辑，图文可穿插；列表可直接上传图床）

- **编辑模式下正文即内联富文本区**：进入「✎」编辑后，正文直接是可编辑的富文本，
  **文字与图片自由穿插**，不再需要点「编辑正文」进二级全屏编辑器。新增可复用组件
  [`QuillBodyField`](lib/ui/journal/quill_editor_screen.dart)（紧凑格式工具条 + 专用
  「插入图片」按钮 + `scrollable: false` 的内联 `QuillEditor`，随内容自然增高、整页滚动）。
  正文由 `_JournalDetailScreenState` 持有的 `QuillController` 承载，保存时序列化为 Delta JSON。
- **图片=正文内的本地关联链接**：插图存为可移植的本地文件路径 embed（与只读渲染、
  图床上传队列同一格式）；`_UploadStatusBar._localImages()` 早已同时采集 mediaPaths 与
  正文内联图，故正文里的图片走同一条图床上传链路。
- **手账列表可直接上传图床**：列表行在仍有本地未托管图片时显示「⬆ 上传 N」chip
  （`_ListUploadChip`，本地图统计复用新的 `_entryLocalImages()`），一键入队并 `drainNow()`，
  无需先打开条目。手账详情页（查看态）的 `_UploadStatusBar` 上传入口保持不变。
- 「封面照片 · 相册（可选）」区保留（喂列表缩略图与查看态相册），置于正文之下并标注为可选。
- 真机 6159e157 全流程验证：进编辑 → 正文内联可编辑（保留原着色）→ 工具条插图 →
  图文穿插 → 保存 → 只读视图正确渲染内联图 + 文字 + 自动进图床上传；列表「上传 N」chip
  显示正确。`flutter analyze` 干净（两文件 0 问题）。

### UI（手账：全屏详情页 + 同页编辑，替代二级弹窗；列表/附近卡片重构）

- **点开手账 = 近全屏只读详情页**（`JournalDetailScreen`，`lib/ui/journal/journal_screen.dart`），
  取代原来的小 `AlertDialog` 查看窗。含大标题、时间/级别 meta、**正文区内嵌一栏地图**
  标识该手账位置（复用同款高德/OSM 瓦片 + GCJ-02 转换 + 青绿定位 pin + 坐标胶囊）、
  富文本渲染、照片墙（点开全屏画廊）、图床状态。
- **同页切换编辑模式**：详情页右上「✎」→ 本页变为可编辑——标题、级别（公开/私有
  SegmentedButton）、归属人、拍照/图库加图与删图、「编辑正文」（富文本内插图）、删除，
  全部在同一页完成，**不再二级进入编辑弹窗**。新建仍走原单层编辑器。
- **三个入口统一**改为打开详情页：手账列表、地图手账 pin、首页「附近手账」弹窗
  （删除了旧的 `showJournalViewer` 弹窗函数）。
- **手账列表卡重构**：缩略图左置（首图带「+N」多图角标，无图用品牌占位图）+ 标题/日期/
  预览/定位/上传徽标分层，tonal 面，扫读性更好。
- **「附近手账」弹窗重构**：拖拽手柄、📍标题 + 「~5km 内 N 条」副标题、tonal 卡片层级、
  更大圆角。
- 真机 6159e157 全流程验证：附近弹窗 → 全屏详情（地图栏定位正确）→ 同页编辑 → 列表卡；
  `flutter analyze` 干净。

### UI（氛围层：雾气 + 光尘，克制且可交互）

- **新增可复用氛围层** [`lib/ui/common/atmosphere.dart`](lib/ui/common/atmosphere.dart)：
  CustomPainter 绘制**缓慢飘动的柔雾云团**（加色混合的柔光晕）+ **稀疏光尘粒子**
  （视差、微弱明灭）。呼应本 App「拨开迷雾(Fog of World)」的核心隐喻，是主题内生
  的氛围，而非廉价装饰。刻意做到**不廉价**：
  - **慢**：全部运动以 120s 循环的**整数周期**表达，1→0 回绕无缝、永不明显重复；
  - **低对比**：云/尘低透明置于内容之下，不损文字对比（a11y）；
  - **可交互**：拖动/悬停会把光尘从指针处**拨开**再缓缓聚回（"伸手拨雾"）；
  - **尊重 reduced motion**：系统"移除动画"开启时渲染单帧静态、关闭交互；
  - 性能：`RepaintBoundary` + 预生成粒子、paint 内零分配。
- **应用到两处 hero**：探索进度页 `_GlobalCard`（青绿覆盖率卡，可交互拨雾）与首页
  `_FeaturedTile`（更克制、仅氛围）。真机 6159e157 验证：渲染正常、文字清晰；隔 3s
  两帧 hero 区域 0.17% 像素变化 → 证明动效为"活的"（非静态误画）。

### UI（首页「更多」重构 · 接入 impeccable 设计技能）

- **接入 impeccable 设计技能**（`.claude/skills/impeccable/` + PostToolUse 检测 hook），
  并为项目落地设计上下文：`PRODUCT.md`（register=product / platform=android / 气质=
  轻盈·游历·收集乐趣 / 5 条策略原则 / a11y）+ `DESIGN.md`（从 main.dart 主题抽取：
  M3、seed `#26A69A`、明暗、圆角/字体基线）。
- **重构首页「更多」功能网格**（`home_screen.dart`）：原本是 **11 张等大全饱和彩虹
  渐变卡 + 彩色投影**——命中 impeccable 三条反模式（identical card grid / 非激活态
  重色装饰 / 无层级平铺）。重构为：
  - **Hero「探索进度」**整宽 primaryContainer 卡（收集乐趣的落点，置于层级顶端）；
  - 其余入口按意图**分组**（记录与回顾 / 发现与同行 / 数据与设置），层级由使用频率
    决定，而非平铺；
  - 磁贴改用 **Material 3 role 色**（primary/secondary/tertiary Container 图标片 +
    surfaceContainerHigh tonal 面），去掉硬编码彩虹与彩色辉光，自动适配对比；
  - 触控目标 ≥ 48dp；按压 97% 缩放微反馈**尊重 `disableAnimations`（reduced motion）**。
  - 路由不变；`flutter analyze` 干净；真机 6159e157 验证渲染与「探索进度」跳转正常
    （App 为 `ThemeMode.dark` 固定深色，故仅深色需验）。

### Import（删除后再导入无法恢复 → 备份/恢复对所有模块一劳永逸）

- **备份恢复现在会复活本地删除的行**: 复现步骤「新建手账 → 导出 → 删除该手账 →
  导入」，被删的手账不回来。根因是通用的：任何按项删除（`deleteJournalById` /
  `erasePointsAround` / `deleteSongFavoriteById` / `deleteLayer`）都会写一条本地
  **墓碑**（tombstone），而导入端最先无条件应用**所有**本地墓碑作为跳过集，于是
  归档里明明有这条数据也被跳过——手账、轨迹点、图层、聊天、歌曲收藏 5 张墓碑表
  **全都**中招（不止手账）。
- **修法（区分"同步"与"恢复"两种语义）**: `importFromFiles` 新增 `restore` 参数。
  - `restore=false`（默认，**云同步**语义，保持不变）：本地墓碑仍阻止复活——
    "本地删除不能被拉取旧云端副本复活"是之前用户亲验过的修复
    (`sync_engine_test`: "local tombstone must block resurrection from old cloud")。
    OneDrive「同步/从 OneDrive 恢复」与登录后台拉取都走这条，行为不变。
  - `restore=true`（**备份恢复**语义）：只有**归档自身携带**的墓碑才生效；导出之后
    才产生的**本地独有**墓碑不再阻止归档把行带回来，且复活后顺手清掉这条本地墓碑，
    避免下次 syncUp 又把它删掉。归档里真实记录的删除仍然照常传播（不会复活）。
- **接线**: 用户主动发起的备份恢复口都置 `restore: true`——「从本地文件夹导入」
  (`syncDown`)、「从本地 zip 导入」/ WebDAV 恢复 (`importFromArchive`)。OneDrive 的
  双向同步维持严格 sync（不改此前验证过的反复活行为）。
- 测试 `restore_resurrects_deletes_test.dart`：journal/song_favorites/track_points
  三模块各自「新建→导出→删除→导入(restore)=回来」，加两条护栏（默认模式仍不复活、
  归档自带墓碑在恢复模式下仍生效）。
- **全覆盖补充** `import_export_coverage_test.dart`（13 例）：restore 覆盖第 4 个生产者
  layers（deleteLayer）+ restore 幂等 / 混合墓碑（本地独有复活·归档自带仍删）/
  restore+clearBeforeImport / restore 不越权 LWW / **经真实 SyncEngine 分片路径端到端**
  syncUp→删→syncDown(restore) + 对照默认 sync 不复活；字段保真（journal 全列 +
  layer path* 样式）；导入边界（空图层不清空 / 版本前向兼容 / 选择性导入 / 空档抛错）。
  全量 `flutter test` **218 过 +2 skip**。
- **真机端到端验证**（Redmi 6159e157）：手账 4 条→导出到本地文件夹→编辑页删「李山航解决」
  (剩 3)→从本地文件夹导入→恢复到 4 条，logcat 铁证 `journal import done — incoming=4
  insertedNew=1 skipped=3 → localAfter=4` + `restore cleared 1 stale tombstone` +
  `import done — restore=true`，列表视觉确认「李山航解决」回来。

### Import（FOW 导入落在隐藏图层 → "导入不生效/清除后再导入就没了"）

- **FOW 导入现在保证目标图层可见**: FOW import writes to the effective-active
  layer, which falls back to the FIRST layer when EVERY layer's eye is off. The
  map only draws VISIBLE layers, so the fog landed in the DB but rendered nothing
  — exactly the "清除迷雾后再导入就没了" report. On-device logs pinned it:
  `[FOW] import → activeLayer=22 written=46872` immediately followed by
  `[FOG] reload visibleLayers=[] → loaded=0`. The FOW import now un-hides its
  target layer (`setLayerVisible(id, true)`) and forces a reload, so imported fog
  always shows. Verified on device: after the fix the next reload logged
  `visibleLayers=[22] → loaded=46872` and the fog rendered. (DB persistence was
  never the problem — a `clearModule('fog_tiles')` → re-import round-trip keeps
  the rows; guarded by `clear_then_reimport_fog_test.dart`.)

### Import（FOW Sync.zip 走错导入口的天书错误）

- **把 FoW `Sync.zip` 拖进「从本地 zip 导入」不再报天书**: a Fog of World Sync
  folder / `Sync.zip` is raw obfuscated tile files with no `manifest.json`, so
  the BACKUP importer rejected it with the cryptic "manifest.json 不存在，这可能
  不是一个 explore_journal 备份" — which read as "导入不生效". The backup importer
  now detects a FoW tile set (`looksLikeFowTileName`) and says exactly what to do:
  改用「Fog of World 兼容 → 导入 FOW 数据」. (The FOW import path itself was verified
  bug-free on-device: a real 1.8 MB Sync.zip restored 46 872 fog blocks and
  rendered. The earlier data loss was a prior module-clear having emptied
  fog_tiles — confirmed by a 281 MB SQLite freelist — not an import failure.)

## [Unreleased] — 2026-07-08

### Sync / 数据（导入图层重复 + 轨迹未应用的根因，本地文件夹镜像）

- **导入产生大量重复图层的真正根因（含轨迹"没应用"）**: even after the same-name
  collapse, `remapLayerId` returned the RAW archive layer id whenever an
  incoming layer's uuid wasn't found locally (i.e. it had just been folded away).
  Content pointing at that id was orphaned, and the startup self-heal
  (`ensureLayersForContent`) then recreated a phantom `图层 N` per orphan id —
  re-inflating the duplication AND scattering tracks onto layers the user never
  made (so they "没应用"到期望图层). The layer merge now records
  `archiveId → localId` for EVERY archive layer (uuid-match / name-match /
  collapse / insert), and remap resolves through that, then the raw id only if
  it is a live local layer, and finally the default layer — it never returns a
  non-existent id, so no phantom layers, and every track lands on a real,
  visible layer. Reproduced + guarded by `test/backup/layer_dup_regression_test.dart`.
- **本地导出/导入与 OneDrive 统一为同一条流水线**: new `LocalFolderStorage`
  (a `SyncStorage` backed by a plain on-disk folder) lets "导出到本地文件夹 /
  从本地文件夹导入" run the EXACT `SyncEngine` syncUp/syncDown pipeline as
  OneDrive — only the transport differs. The folder ends up byte-identical to a
  OneDrive Sync folder (`meta.zip`, `journal.zip`, `tracks/<yyyy>.zip`,
  `fow/<layer>/<tile>`, `.ej_index.json`), so a sync bug reproduces with no
  network / no second device: export → clear → import back. Covered by
  `local_folder_storage_test.dart` (real temp-dir round-trip) + a readable
  `mirror_demo_test.dart`.
- **OneDrive 逐请求/响应日志彻底关掉**: the Dio `LogInterceptor` had
  `request: true`, printing a line for every one of the (thousands of) per-tile
  calls during a sync. Now ERRORS ONLY (`request: false`) — the SyncEngine's
  key-node summary already answers "什么变了 / 拉了什么".

### Sync / 数据（同步与清除语义）

- **「清除本机数据」不再打墓碑**: the per-module clear was tombstoning the whole
  table, which (1) blocked a later pull/import from ever restoring the rows
  ("清空后导入不生效") and (2) turned a local reset into a propagated delete. It's
  a LOCAL clear now — a subsequent sync restores from the cloud. Deliberate
  single-item deletes still tombstone.
- **清除图层归并到单一默认图层**: clearing the layers module deleted the layers
  then immediately sprang them all back via the startup self-heal (content still
  referenced their ids → "没有清空全部"). It now wipes layers and re-homes ALL
  content onto ONE fresh default (`resetContentToDefaultLayer`).
- **图层去重再加固（云端自带重复的折叠）**: on top of the name-fallback match, the
  importer now folds a cloud that itself carries many same-named layers (old
  churn: 11×默认图层) onto a single local row instead of re-inserting the 2nd..Nth.
- **同步日志改为关键节点**: dropped the per-shard (`↑`/`↓`/`✗`, thousands of fow
  tiles) and per-row logs that spammed the console and cost time; syncUp/syncDown
  now log one line each splitting fow-tile counts from the named content shards
  (journal.zip / meta.zip / tracks / chat), and import ends with one detailed
  `imported/skipped/errors` report.

### Journal（手账）

- **保存失败有原因了**: the editor's save button silently no-op'd on an empty
  title. It now shows an inline "标题不能为空" error under the (now "标题（必填）")
  field instead of looking broken.
- **图床上传状态进列表 + 自动上传开关 + 上传队列**: each journal row with photos
  shows a live upload pill (待传/已传/失败); a new toolbar button opens an upload
  queue sheet (per-image state, manual 上传, retry); and a new
  `autoUploadImages` setting (image-host settings screen) lets uploads stay
  queued until manually triggered — a data saver.

### Layers（图层 UI）

- **图层批量勾选删除**: the layers screen's multi-select now offers 删除所选 (with a
  single confirm) alongside the existing merge.
- **图层悬浮窗眼睛实时切换**: the map's layer sheet was built from a one-off
  snapshot, so tapping the eye didn't flip its icon until reopened. It now watches
  the layer + active-layer providers and updates live.

## [Unreleased] — 2026-07-07

### Testing（本地自测机制）

- **真实往返测试地基 `test/support/roundtrip_harness.dart`**: seeds a realistic
  cross-module dataset (layers / journal / tracks / fog / chat / favourites + every
  prefs-backed module), then exercises the REAL `exportToFiles → importFromFiles`
  round-trip with zero network and zero device — exactly what a OneDrive upload+pull does.
  Provides `seedRealisticData`, `snapshotDb` (per-module counts + uuid sets), a shared
  in-memory `FakeSyncStorage`, and the prefs-key constants. The isolated "hand-craft an
  archive and import it" tests could never catch the layer-duplication bug; a round-trip
  test does. Reduces the need for manual on-device verification.
- **New round-trip / merge suites** (28 new tests): `roundtrip_test.dart` (full-dataset
  fidelity, idempotent double-pull, data-loss recovery, tombstone-not-resurrected,
  two-/three-device sync), `fog_merge_test.dart` (bit-union, erase-mask 增量减, native FoW
  passthrough, layer remap, idempotency), `prefs_modules_test.dart` (planner/settings-LWW/
  imghost/geocode/learned-regions merge semantics), `sharded_modules_test.dart` (yearly
  track shards + incremental diff, per-peer chat shards, uuid-dedup, width fidelity,
  delete propagation). Total suite 190 tests.

### Cleanup（清冗余）

- Removed dead code flagged by the analyzer: unused `_pctColor` (explore_screen), unused
  `_remove` (upload_queue), unused `_seq` field + writes (ptt_controller), unused import
  (debug_screen); deduped the `FakeSyncStorage` copy in sync_engine_test into the shared
  harness. `flutter analyze lib/` warnings 20→16 (remaining are pre-existing style infos).

### Sync（同步·增量合并）

- **图层不再无限重复（按名兜底匹配 + uuid 收敛）**: layer import matched cloud rows to
  local ones by uuid only. Historically the "默认图层" was minted with a random (or empty)
  uuid per device, so the cloud copy never matched the local one → a fresh duplicate was
  inserted on *every* pull (the "同步前一个图层，拉完一堆重复" report; empty-uuid rows
  duplicated unconditionally). Import now falls back to a **name match** when exactly one
  unclaimed local layer shares the incoming name, reuses that layer instead of inserting,
  and **re-stamps the local uuid to the incoming one** so future pulls match by uuid and
  stop duplicating. Locked by `test/backup/backup_service_merge_test.dart` (4 new tests).
- **诊断日志（多加日志方便定位）**: export logs journal/layer counts (+empty-uuid counts);
  layer/journal import log incoming vs inserted/updated/name-matched/skipped and the
  before/after row counts + local uuid list; `syncDown` prints the per-shard fetch decision
  by NAME for `journal.zip`/`meta.zip` (unchanged→skipped vs changed→fetch) so "手账/图层
  没同步" is diagnosable from the log instead of a bare count.

### Fixed（修复）

- **底栏导致的框架崩溃**: the `BottomAppBar` `CircularNotchedRectangle` notch installed a
  clipper that read `Scaffold.geometryOf()` during hit-test; a pointer landing between a
  route transition's layout-invalidation and the next paint tripped the "only during the
  paint phase" assertion (seen on back-button transitions). Dropped the notch shape — no
  clipper, no race. The centre FAB still docks over the bar.

## [Unreleased] — 2026-07-02

### Rendering（渲染）

- **Fog-of-World-style smooth reveal at high zoom（高倍率平滑迷雾）**: fog tiles between
  z15–z17 are now baked natively per tile zoom — every explored cell drawn as an
  anti-aliased disk, the union feathered by a single gaussian pass — instead of scaling the
  z14 bake up into hard pixel staircases. Overzoom past z17 scales already-soft edges, so
  corridors stay smooth (rounded corners, soft feather, merged unions) at every zoom.
  z14-and-below keeps the exact integer punch, byte-for-byte compatible with the stored
  FOW bitmaps. Pinned by rasterisation tests (`test/fog_tile_bake_test.dart`), which also
  dump before/after PNGs to `build/fog_bake_preview/`.
- **Per-point trail width honoured（逐点宽度真正生效）**: trail lines and dots now stroke
  each point at its recorded width (the brush/slider size at record time), matching what
  the settings screen always promised. Manual dabs finally render at the size they were
  painted; legacy null-width rows keep following the layer's live style width.
- **Cold-start style flash fixed（启动闪现修复）**: fog veil and trail layers wait for
  the persisted settings to actually load before first paint. Previously the first frames
  rendered with the DEFAULT veil colour / 14 m trail width and self-corrected later —
  visible as "启动时路径变粗/闪一下错误渲染".
- Track point `width` is now included in backups / sync archives (it was silently dropped,
  so restores flattened all trails to the layer default).

### Performance（性能）

- **Recording no longer re-reads the world every tick**: fog rows written by
  reveal/erase stream incrementally (`FogEngine.changes`) into the fog tile layer's
  in-memory snapshot, and freshly recorded points append to the trail layer via a live
  stream. Previously every 250 ms tick re-queried the whole `fog_tiles` table (~45k rows
  after a FOW import) plus every track point of every visible layer.
- **Journal pins**: the native pin layer now rebuilds only when zoom crosses a 0.1 bucket
  instead of on every camera frame — pin thumbnails (`Image.file`) are no longer churned
  while panning.
- **Backup import batched**: track points / chat messages / fog tiles insert in batches
  (one transaction per file / 2000 rows) instead of one `await` per row.

### Sync（同步）

- **Real staged progress（分阶段进度）**: sync-up reports one continuous 0–100% bar across
  export → shard packing → index diff → transfers → index write, with per-stage labels and
  per-module export/import progress. The dialog no longer sits at "0% 导出本地数据".
- **No more monolithic zip round-trip**: the engine now consumes the exporter's file map
  directly (`exportToFiles` / `importFromFiles`) — previously every sync zipped ~45k
  entries into one archive, unzipped it, and re-zipped per shard (and the mirror image on
  restore).
- **Chunky shards（更大的分片）**: track points shard per **year** (entries inside stay
  monthly); zip shards whose raw entries exceed **24 MiB** split into deterministic
  `.pN.zip` parts (≈6–9 MB zipped for this data mix, within the user-approved ≤10 MB per
  file). A split that yields a single part keeps the ORIGINAL shard name — the
  `fogindex.zip ↔ fogindex.p0.zip` rename flip-flop (one pointless delete+re-upload per
  crossing) is gone. The MD5-index diff (git-like "only changed shards upload") is
  unchanged.
- **Fog is stored as NATIVE Fog of World tiles（世界迷雾原生格式，双向互通）**: the cloud
  Sync folder now carries fog as `fow/<layerUuid>/<obfuscatedName>` — real FoW tile
  files (zlib, obfuscated names, one per 128×128-block tile), uploaded RAW and 1:1,
  never zipped. Copy them straight into a Fog of World Sync folder to hand your
  exploration to FoW; drop FoW's own tiles into a backup/import (with or without the
  layer folder) and they merge in, landing on the default layer when no layer is named.
  Manual `.zip` backups carry the same layout, so extracting a backup also yields a
  FoW-ready tile set. What FoW's format can't carry (per-block timestamps, erase masks,
  layer identity) rides in `fogindex.zip` side-cars. Archives in the old
  `fog/<layerId>/*.bin` layout still import.
- **Edits now propagate（增量改，行级 LWW）**: imports used to skip ANY row whose uuid
  already existed — edits made on another device never applied ("从 OneDrive 拉取后所有
  数据都没有更新"). Journal entries and layers now carry an `updatedAt` stamp (schema
  **v8**), set by every edit path (journal editor, image-host URL rewrite, layer
  rename/style/visibility, layer merge); import compares per row and applies the
  incoming copy only when strictly newer — so edits land, and an older cloud copy can
  never clobber a newer local one. Settings sync the same way (an LWW stamp that
  volatile token rotations don't touch), and the image-host registry merges by key
  instead of being overwritten.
- **Fog merges by UNION + erase masks（迷雾增量加减）**: fog blocks now merge by bitwise
  union of both sides — two devices exploring the same ~600 m block keep BOTH sets of
  pixels (the old whole-block LWW silently dropped one side). Erases record the swept
  pixels into a new `fog_erases` table (schema v8) as (mask, erasedAt); masks ride in
  `fog/erases.jsonl`, and the merge clears a pixel only from copies OLDER than the
  erase — so erases propagate to every device, deleted areas stay deleted through any
  down-before-up ordering, and re-exploring after an erase legitimately resurrects
  (newer block timestamp beats the mask). Masks GC after 180 days, like tombstones.
- **Deletes now propagate（增量减）**: local deletions no longer resurrect on the next
  merge. A `tombstones` table (schema v7) records (table, uuid, deletedAt) whenever the
  user erases track points, deletes a journal / layer / song favorite, or merges
  layers. Tombstones always ride along in exports (auto-included module, like the
  leaderboard), imports **first** merge + apply them (deleting matching local rows,
  FTS included) and then skip those uuids while merging. GC'd after 180 days.
- **Cross-device layer identity（图层重映射）**: rows reference layers by local
  autoincrement id, which differs across devices; `layers.json` now carries each
  layer's (id, uuid) and imports remap journal / track / fog rows id → uuid → local id,
  so data lands on the RIGHT layer instead of whatever happened to share the number.
- **Pulls are diffed too（拉取也走增量）**: syncDown used to download EVERY shard on
  every pull — with per-tile FoW files that meant hundreds of requests each time. It now
  rebuilds the local shard hashes (same pipeline as syncUp) and fetches only shards whose
  cloud MD5 differs, so a routine pull is a handful of requests; "从 OneDrive 恢复"
  (replace-local restore) still fetches everything. There is no folder-level upload
  primitive in Graph/WebDAV — per-file requests are inherent — so the fix is fewer
  requests (diff) plus more parallelism (below).
- **Parallel transfers**: small files (raw FoW tiles, most zips) and downloads run
  8-wide (latency-bound, far below Graph throttling); multi-MB zip uploads stay 3-wide
  so they don't saturate a mobile uplink. Progress stays byte-weighted; packing of large
  shards runs in a background isolate.
- **OneDrive large files**: sync files above ~3.5 MB automatically switch to a resumable
  Graph upload session (simple PUT is capped at 4 MB and used to fail).
- **Note**: the first sync after this upgrade re-uploads fog once (new native-FoW
  layout; old shards are cleaned up automatically), then incremental behaviour resumes.
  Schema migrates v6/v7 → v8 automatically on first launch.

- **Restores no longer log you out of OneDrive/WebDAV（恢复不再抹掉登录凭据）**:
  exports scrub every secret field to null, and the settings import wrote that scrubbed
  blob verbatim over local prefs — so every restore silently nulled the OneDrive
  refresh token (and WebDAV password, PATs…). After the next app start OneDrive showed
  "未连接" and both sync buttons were disabled — which read as "点了没反应，连弹窗都没有".
  Imported settings now graft the LOCAL values back into every secret field (forced
  restores included), a `scrubFailed` stub can never overwrite settings, and a restore
  hot-reloads the settings provider so the imported values (and the connection state)
  apply immediately instead of after a restart.
- **Import hardening（导入容错与可诊断性）**: one corrupt row used to abort its WHOLE
  module (every row after it was silently lost — reads exactly like "拉取后什么都没
  应用"); rows are now fault-isolated, with per-module `N 行损坏已跳过` surfaced in the
  restore dialog. A diffed pull that arrives without `meta.zip`/manifest no longer
  hard-fails; shards listed in the cloud index but missing from the cloud (interrupted
  old uploads) are reported instead of silently skipped; duplicate historical uuids
  can't abort the journal merge; every import ends with one greppable
  `[BackupService] import done — imported/skipped/errors` logcat line, and the restore
  dialog wording now distinguishes "applied" from "local already newest".

### Fixes（修复）

- **Layer proliferation & delete/recreate churn, fixed（图层增殖与反复重建修复）**: the
  auto-created "默认图层" got a RANDOM per-device uuid, so two devices' defaults never
  matched on sync and the default layer duplicated (one per device), scattering content
  across the copies. It now has a **stable device-independent uuid** (schema v9 re-stamps
  the existing default), so all devices reconcile onto one. Separately, the layer
  self-heal used a deterministic uuid but did NOT clear a stale tombstone for it — so a
  tombstoned layer got deleted every sync, recreated, deleted again ("recreated N
  orphaned layer(s)" on every pull). Recovery now clears the layer's tombstone (a
  recreate is an un-delete), breaking the loop. Layer import already reconciles by uuid
  (LWW update when the uuid matches, insert only when there's no corresponding layer) —
  the stable uuids are what finally let that reconcile converge instead of duplicating.
- **uuid backfill guard（补全缺失 uuid）**: sync identity (dedup + last-write-wins) is
  keyed on uuid; a content row with an empty uuid silently fails to update and can
  duplicate on re-import. Startup now backfills any missing uuid on journal / layers /
  points / chat / favorites (idempotent), and the `[DB] no-uuid — journal=… layers=…`
  probe flags the condition.


- **Deleting a layer no longer crashes the app（删除图层崩溃修复）**: the edit-layer
  dialog's buttons popped with the SCREEN's context instead of the dialog's, so "删除"
  popped the layers PAGE off go_router's stack ("popped the last page…") and cascaded
  into a locked navigator + a half-torn-down widget tree. Buttons now pop the dialog's
  own route; delete also gets a confirm step (it drops the layer's points/fog too).
- **Layer sheet no longer overflows with many layers（图层面板溢出修复）**: the map's
  layer bottom sheet was a non-scrolling Column — with 10+ layers (e.g. after a
  multi-layer import or the layer self-heal) it "overflowed by 463 pixels". It's now a
  height-capped scrollable list.
- **Per-module local clear（按模块清除本机数据）**: every module row on the backup page
  now has a trash button (with a confirm) that wipes just that module's local data —
  content modules record tombstones so the deletion propagates on the next sync, a
  settings clear keeps credentials, and clearing layers reseeds a default so the map is
  never left blank. Leaderboard (community-shared) is not locally clearable.

### Rendering / data integrity（渲染与数据完整性）

- **Blank map with data present, fixed（有数据却整屏空白）**: the map, trail and journal
  layers are ALL layer-driven — they iterate `track_layers` and render only rows for
  visible layers. A DB left with **zero layers but with content** (points / fog /
  journals referencing a now-missing layerId — from an over-eager tombstone, a bad
  merge, or a `clearBeforeImport` restore whose incoming layer list was empty) therefore
  rendered a completely blank map even though every row was still in the database. This
  was the "从 OneDrive 恢复后手账/图层/路径全没有效果" report — the sync had long since
  landed the data; the layers it hangs off had been wiped.
  * New `AppDb.ensureLayersForContent()` self-heal recreates a visible layer for every
    orphaned layerId (reusing the id so existing content re-homes with no row rewrites;
    deterministic `recovered-layer-<id>` uuid so devices converge instead of
    proliferating). It runs at startup and at the end of every import — so an existing
    broken install fixes itself on next launch, and a restore can never leave content
    orphaned.
  * `clearBeforeImport` no longer wipes the layer table when the incoming layer list is
    empty (clearing-to-import-nothing is never desirable).
  * Startup logs a one-line `[DB] rows — journal=… layers=… points=… fog=…` probe, so
    "synced but nothing shows" is one glance to triage: zeros → data never landed;
    non-zero → data is here and rendering is the problem.

### Web（网页版）

- **Sessions survive a refresh（刷新不再掉登录）**: the NAS login session (token +
  password-DERIVED vault key — never the password) now persists in localStorage and is
  silently resumed on page load; an expired/rejected token falls back to the login page
  and wipes the record, as does logging out. Previously the key lived only in memory,
  so every refresh bounced to the login page.
- **Login page defaults（登录页体验）**: the server field is now labelled 后端地址,
  prefilled with `http://localhost:48080` (or the last-used backend + email), instead of
  a blank "NAS 地址".
- **Sessions last until you log out（仅手动注销才过期）**: the backend's JWT TTL default
  was 1 HOUR — even with the persisted web session, every refresh an hour later bounced
  to the login page. Default is now 365 days (`EJ_TOKEN_TTL_SECS` to tune); combined
  with localStorage session restore, a web login now survives until an explicit logout.
  Existing deployments must restart the backend once to mint long-lived tokens.
- **OneDrive login works on web（网页版 OneDrive 登录）**: connecting OneDrive from the
  browser used to dead-end in a "要打开 …oauth 吗？" prompt — the OAuth redirect went to
  the mobile app's custom scheme, which no browser can route back into a web page. Web
  now redirects through a hosted `auth.html` callback (popup closes itself and hands the
  code back). Requires registering the SPA-platform redirect URI in Azure
  (`…/auth.html`, see docs/onedrive_setup.md) — without it Microsoft rejects the
  browser-side token exchange (AADSTS9002326).

### Tests

- Fog bake rasterisation suite (feather presence, veil exactness, native-zoom pixel parity,
  soft-dot geometry) with PNG artefacts for eyeballing.
- Shard split determinism + cap behaviour (incl. single-part name stability); per-year
  track sharding; per-point width survives the full export → shard → transport → import
  round-trip.
- Deletion propagation: erased track point stays gone through down-before-up AND reaches
  the second device; fog erase beats an older cloud copy and propagates.
- Merge semantics end-to-end (two in-memory devices over a fake transport): journal /
  layer edits propagate and an older cloud copy loses LWW to a newer local edit; two
  devices exploring the SAME fog block converge to the pixel union; an erase clears the
  other device and a later re-exploration resurrects; rows re-attach to the uuid-matched
  layer when autoincrement ids differ; the cloud fog file parses as a genuine FoW tile
  and a hand-copied FoW tile imports onto the default layer.
- Web session restore (`test/vault/session_restore_test.dart`): session record
  round-trips prefs and rejects corrupt records; a valid stored session resumes logged-in
  with the NAS config applied; an expired token wipes the record; the OneDrive web
  redirect URI derives correctly for hash routes, `/app/` sub-path deploys, and
  query-bearing bases.
- Import-merge matrix (`test/backup/backup_service_merge_test.dart`, service-level):
  corrupt rows in journal/layers/track_points are skipped without killing the module;
  legacy v2 archives (fog `.bin` + v1 index, no id/updatedAt fields) import fully;
  settings LWW × 6 (fresh device adopts cloud stamp, newer-local survives, newer-cloud
  applies, forced restore, legacy no-meta both ways, export ships the stamp); image-host
  registry merges by key / restore replaces; a manifest-less partial sync set imports
  while a foreign zip is still rejected; devices with overlapping history keep local
  copies and gain only new rows; duplicate uuids don't abort; clearBeforeImport
  replaces. Engine-level: pulling into a device with overlapping history lands A-only
  rows and preserves B-only rows with zero module errors; a cloud still in the OLD
  zip-shard layout imports fully on the new client.
