# Changelog

All notable changes to Explore Journal are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow SemVer once releases start.

## [Unreleased] — 2026-07-09

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
