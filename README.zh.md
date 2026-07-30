# Explore Journal · 旅行探索

> 一款受 **Fog of World** 启发的零后端旅行/探索 App。
> 走过即点亮迷雾、3D 地球俯瞰足迹、富文本旅行手账、AI 旅行规划、去中心化排行榜、
> 多通道 P2P 实时同行共享、WebDAV / 本地一键备份——
> **所有数据完全在你自己手里，没有任何自建后端。**
>
> **同一套 Flutter 代码**还构建出一个**只读的 Web「回忆版」**，在浏览器里重温旅程；
> 可选用一个极小的自建服务 **web-front（Rust + Docker）**：单 admin 登录，只把你的
> **设置**加密保管一份（密钥由你的 admin 口令派生），永远不碰你的原始旅行数据。

![flutter](https://img.shields.io/badge/Flutter-3.32+-02569B?logo=flutter)
![平台](https://img.shields.io/badge/平台-Android%20%7C%20iOS%20%7C%20Linux%20%7C%20Web-success)
![后端](https://img.shields.io/badge/可选后端-Rust%20%2B%20Docker-orange?logo=rust)
![license](https://img.shields.io/badge/license-CC%20BY--NC--SA%204.0-lightgrey)

[English README](README.md)

---

## 功能一览

| 模块 | 内容 |
|------|------|
| 🗺️ 地图 | OSM / 高德 / Google × 标准 / 卫星 / 混合，一键切换 · GCJ-02 ↔ WGS-84 自动换算 · 离线瓦片缓存（最多 10 万块 / 365 天）· 旋转锁定（默认关）+ 指北针 · 位置点在移动（>0.5 m/s）时显示朝向箭头 |
| 🌫️ 迷雾 | 与 **Fog of World 兼容**的位图瓦片（512×512 网格、每格 128×128 块、每块 64×64 bit，赤道约 9.55 m/像素）· 迷雾**烘焙成真正的地图瓦片**，与底图逐像素同步缩放 · **FoW 风格平滑显示**：z15–17 按瓦片原生烘焙（抗锯齿圆盘并集 + 高斯羽化），任何倍率都不出现像素阶梯，z≤14 位级精确 · 记录中的新走廊**增量合并**进快照（不再全表重读）· 可选彩色轨迹线按**逐点记录宽度**描边 · GPS 掉点自动断段（间隔 30s / 异常速度 / 精度 >150m）· 画笔半径/颜色/浓度可调 · 深色蒙版模式 |
| 🌍 3D 地球 | 在最小缩放再捏一次即进入 · 昼夜纹理球（日照分界线按 UTC 实时计算）· 去过的足迹叠加成热力辉光 · 拖动旋转、捏合缩放、定位飞行 |
| 📍 记录 | Android 前台服务（锁屏 / Doze 持续记录；进程被杀、重启后若在记录则自动恢复并补齐缓冲）· 三档模式 **高性能 1s/2m · 平衡 10s/15m · 省电 30s/40m** · 双流架构（实时 UI + JSONL 落盘缓冲，防止后台丢点）· 每行 UUID 跨设备去重 · **记录时相机自动跟随**（手动拖动/旋转即暂停，点定位键恢复居中）· GPS 信号格只看「能否拿到定位 + 精度」，静止不动不会掉格 |
| 🗂️ 图层 | 增删改 / 合并 / 可见性 · 每图层独立线条颜色、浓度(0.1–1)、宽度(2–60m) · 颜色 + 标签 · GPX / KML 导出 |
| 🖋️ 手账 | Quill 富文本 + 内嵌图片/视频 · 批量导入照片（每张一条，自动读 EXIF GPS 定位）· SQLite **FTS5 全文搜索** · 地图图钉（可单个 / 全局隐藏，**导入后即时刷新**）· 公开 / 私有 + 归属人 · 全屏画廊 |
| 🧭 探索成就 | **真实面积**进度（已点亮 km² ÷ 地区真实面积，非 bbox 估算）· 190+ ISO 国家 + 省级行政区 · **最小 bbox 归属**避免一个点被多省/多国重复计数 · 访问中「学习」出更精细的地区边界 |
| 🏆 排行榜 | **去中心化、仅追加、签名**（每台设备一对 Ed25519 密钥）· LWW 冲突合并 + TOFU 防伪 · 全球 km² + 逐月榜 · 通过 P2P 自动同步 / GitHub PR / 可选 REST 服务 |
| 🤖 AI 规划 | OpenAI 兼容（硅基流动 / OpenAI / DeepSeek / OpenRouter…，可自定义 base URL）· 流式生成、可中途取消、30 分钟超时 · 历史保留 30 天、回屏自动续上 · 从返回 JSON 渲染迷你地图 + 能量（千卡 / 步数 / 时长）估算 · 生成搜歌关键词 |
| 🎵 音乐 | **网易 / 酷我 / JOOX 直连后端 + GD聚合兜底** · WebView 抓登录 cookie · 按「地点 + 心情」生成 AI 歌单 · 收藏带 GPS · 收藏地图 · 可向同行广播同步播放 |
| 🛰️ P2P 同行 | **四种通道**：局域网 UDP 组播 (239.42.42.42) + 子网 TCP 扫描、ZeroTier 等虚拟局域网、WebRTC（WebDAV 信令）、frp XTCP 内网穿透 · 实时位置 / 轨迹共享 · 群聊 + 1:1 私聊 · 对讲(PTT) · 同步放歌 · **AES-GCM-256 端到端**（PBKDF2-SHA256 5 万轮）· WebDAV 离线信箱 · 群组诊断 |
| ☁️ 导出与导入 | 统一页：**12 个模块**可勾选 · **分块归档**（迷雾为**世界迷雾原生瓦片文件**、轨迹按月、聊天按对端）· 本地导出/导入 + WebDAV 上传/恢复，同一份字节互通 · **增量云同步**：MD5 索引只传变化分片 + 3 路并行 + 全程连续进度条 · **三向增量**：增量加（按位并集/按行）、增量改（行级 LWW，编辑会传播）、增量减（墓碑+擦除掩码，不复活）· 跨设备**图层按 uuid 重挂** · 导出会**剔除密钥字段** |
| 🌫️ FOW 兼容 | **双向互通**：云端/备份里的迷雾就是 FoW 原生瓦片文件，与世界迷雾 Sync 文件夹**直接互拷** · 手动导入：系统文件选择器**多选**（**支持 OneDrive 等云盘**，按文件魔数自动识别 zip / 瓦片）· 导出：打包成 zip 走系统分享 |
| 🖼️ 图床 | GitHub 直传（公开 / 私有库）+ jsDelivr / Statically CDN · 自定义图床（URL 模板）· 私有图走 `gh-private://` + PAT 加载器 + LRU 缓存 · 异步上传队列 + 自动重试 · 路径 `traveler/年/月/洲/国/省/市/标题-id/uuid` |
| 🎞️ 回放 | 按「记录会话」分组（间隔 ≥10 分钟自动断、≥10 点）· 年 / 月筛选 + 区间统计 · 多会话拼接回放 · 1–16× 倍速 · 同行轨迹 + 手账气泡（可隐藏） |
| 👤 个人资料 | 头像（256×256 JPEG ≤30 KB，base64）· 昵称内联编辑 · peerId 复制 · 头像内嵌进排行榜与同行标记 |
| 🐞 调试模式 | 隐藏入口（首页版本号连点 10 次）· 1000 条环形日志缓冲 + 过滤 / 分享 · 迷雾 / 记录诊断 · 模拟行走面板（Release 版也可用） |
| 🔒 安全 | 密钥（PAT / 令牌 / WebDAV 密码 / 同行口令）存 `flutter_secure_storage`（Android Keystore / iOS Keychain）· 备份导出与云同步都**从设置里剔除密钥**；两者都可选把密钥**单独加密**携带（随机盐 + 600k 轮 PBKDF2 + AES-GCM）——备份用导出时现场输入的口令，云同步用一个设一次的「同步凭据口令」（后台跑，没人能输口令）。没有口令的归档仍然什么都拿不到 · 运行时 HTTP 守卫拒绝**明文连公网**（局域网 HTTP 仍可）· 无埋点、无遥测、无第三方分析 SDK |
| 💾 数据可迁移 | 全部数据 = 一个 SQLite（全表 UUID、FTS5）+ 一个 `journal_media/` 目录 · 标准 GPX / KML / GeoJSON · 无任何厂商绑定 |
| 🌐 Web 回忆版 | 同一套代码构建到浏览器，作为**只读**展示/回忆版 · drift `WasmDatabase`（IndexedDB）· 导入备份 zip → 重温地图/迷雾/手账/3D 地球 · 可选**登录**：自建 Rust+Docker **web-front** 只保管一份**加密的设置**（你的数据仍在自己的 WebDAV/GitHub）· 支持 **PWA 安装** · 调试模式后门可解锁编辑 · [部署指南](docs/web-display-deploy.md) |

---

## 功能详解

下面挑几个不是一句话能讲清、但很影响体验的模块展开说明。

### 🌫️ 迷雾引擎与轨迹渲染

迷雾按 **Fog of World 的瓦片格式**存储：全球 512×512 个瓦片（zoom 9），每个瓦片 128×128 个 block，每个 block 是 64×64 bit 的位图（512 字节，MSB 在前），赤道处约 **9.55 m/像素**。这套格式既用于统计与同步，也保证能和世界迷雾互导。点亮采用「扫掠圆盘」沿线逐像素推进（不是按半径跳步），避免对角线出现扇贝状缺口；单段最多 8192 步以防失控写入。

探索区域**烘焙成真正的 Web-Mercator 地图瓦片**，由 flutter_map 的瓦片管线绘制——迷雾随底图逐像素平移/缩放，没有逐帧重栅格化，也没有动态 painter 时代的手势/粗细伪影。迷雾原生倍率（z14，1 迷雾格 = 1 px）及以下用**位级精确**的整数打孔，与 FOW 位图完全对齐；z15–17 每块瓦片按其倍率原生烘焙：每个已探索格画成抗锯齿圆盘，并集再过一次高斯羽化——得到**世界迷雾那种**圆角、柔边、自然融合的走廊，而不是放大的像素阶梯；超过 z17 后柔边瓦片继续放大也依旧平滑。记录中新点亮的走廊经 `FogEngine.changes` **增量流**合并进瓦片快照，不再每个刷新周期全表重读。

可选的彩色轨迹线沿记录轨迹描边，**每个点用它记录时的宽度**（改滑杆只影响之后的新点；手绘点按下笔时的尺寸显示）。掉点保护：相邻两点间隔 >30 秒、速度异常（≈70 m/s）或精度 >150m 就**断段**，不会在两次定位之间凭空连一条直线。画笔半径、颜色、浓度均可按图层调节。

### 📍 记录与定位的可靠性设计

- **双流**：前台 `LocationService` 喂实时 UI，后台 isolate 把样本落到 `pending_track.jsonl`（`SampleBuffer`）。即便主 isolate 被系统挂起、锁屏、Doze，后台仍在攒点；回到前台 / 冷启动 / 重新开始记录时把缓冲**去重后灌库**。
- **自动恢复**：若上次在记录中被杀进程或重启，冷启动会自动重新挂起前台服务并补齐缓冲，无需手动再点开始。
- **去重**：样本按 200ms 时间取整 + 6 位经纬度去重；每行带 UUID，跨设备备份导入也不会重复。
- **相机跟随**：记录中默认居中跟随你的位置；手动拖动 / 旋转 / 缩放会暂停跟随（定位键图标变为「搜索」样式），点定位键即恢复居中并跟随；开始一次新记录会自动重新打开跟随。
- **GPS 信号格**：只取决于「这次会话有没有拿到过定位」以及该定位的精度（≤10m 满格、≤30m、≤80m、更差 1 格）。**位置长时间不变不代表没信号**——静止时不会因为「没更新」而掉格。

### 🏆 排行榜的信任模型

完全去中心化：每台设备生成一对 **Ed25519** 密钥，每条榜单记录用规范化 JSON（键排序、无空白）签名。合并时按 `statsAt` 时间戳 **LWW（后写覆盖）**，对同一 peerId 采用 **TOFU**（首次见到的公钥即锁定，拒绝换钥）。同步有三条路：① 经 P2P 通道自动八卦（`lb_hello` 哈希 → `lb_pull` → `lb_batch`）；② 向社区注册仓库提 GitHub PR；③ 可选的 REST 服务（见 [docs/leaderboard-server-api.md](docs/leaderboard-server-api.md)）。逐月榜的 km² 由当月轨迹点数按比例分摊得到。

### 🛰️ P2P 同行的四种通道

App 不依赖任何中心服务器，发现 / 连接同伴有四条独立通道，全部走同一套「换行分隔的 JSON」线协议：

1. **局域网 UDP 组播**：`239.42.42.42:47829` 广播 + 子网 TCP 扫描（端口 47830–47834），Android 加 `MulticastLock`。
2. **ZeroTier 等虚拟局域网**：ZeroTier / Tailscale / 家庭 Wi-Fi 只是「网络底座」，App 在其上用同样的组播 + TCP 网格发现彼此。
3. **WebRTC**：用 WebDAV 上的文件交换 SDP/ICE 信令，建立 `RTCDataChannel`。
4. **frp XTCP 内网穿透**：内置 gomobile 版 frpc，按口令派生的 `secretKey` 校验，自动分配访客端口。

消息可选 **AES-GCM-256** 端到端加密：口令经 **PBKDF2-SHA256（5 万轮 + 固定盐）**派生 256 位密钥，每条消息一个随机 nonce。能力涵盖实时位置 / 轨迹共享、群聊、1:1 私聊、对讲（24kHz AAC、350ms 一块）、同步放歌；对方不在线时走 WebDAV 信箱离线投递。

### ☁️ 导出与导入 / FOW 兼容

「导出与导入」页把数据打成一份**分块 zip**：12 个模块（手账、图层、迷雾瓦片、收藏、轨迹点、聊天、AI 历史、设置、图床记录、地理编码缓存、学习地区、排行榜——排行榜与删除记录为必含）各自成目录，**迷雾直接是世界迷雾原生瓦片文件**（`fow/<图层uuid>/<混淆文件名>`，解压即可丢进 FoW 的 Sync 文件夹），轨迹按月、聊天按对端分文件。本地文件、WebDAV 上传是**同一份字节**，可互相搬。导入是**带比较的增量合并**：新行插入；日记 / 图层等可编辑行按 `updatedAt` 做**行级 LWW**（较新一方胜出，编辑真正传播）；轨迹点、聊天等不可变行按 UUID 去重；所有行经**图层 uuid 重映射**挂到正确图层（各设备的自增 id 并不相同）。导出时自动**从设置里剔除所有密钥字段**，所以泄露的归档不会泄露凭据。但只剔除会让备份
**恢复不了应用**（落到新机器上要手工重填 WebDAV 口令、各家令牌与 API 密钥），所以导出时可以
给一个**口令**，凭据会被**单独加密**成归档里的一个成员（随机盐 + 600k 轮 PBKDF2-HMAC-SHA256
+ AES-GCM-256，KDF 参数一并参与认证，防止被改成低轮次再递回来）。拿到 zip 而没有口令的人，
看到的与这个功能不存在时完全一样：脱敏后的设置，每个凭据都是 null。**口令不会被记住也无法
找回**——忘了它，那份备份里的凭据就取不出来了（数据本身不受影响）。不填口令则不带凭据，
那样的 zip 可以放心分享。自动云同步**不带**凭据：它在后台跑，没有人可以输口令。

**增量云同步**（OneDrive / GitHub / WebDAV / NAS，统一走 `SyncStorage` 接口）把上面的条目重组为分片：**迷雾瓦片按世界迷雾原生文件 1:1 原样直传**（不套 zip——云端 `Sync/fow/` 本身就是一套合法的 FoW 瓦片集，可与世界迷雾直接互拷；空间局部性让"只有走过的区域附近才重传"）；轨迹按年、聊天按对端、其余进 `meta.zip`，时间戳与擦除掩码等 FoW 格式装不下的元数据放 `fogindex.zip`；zip 分片原始体积超过 24 MB 时确定性地拆成 `.pN.zip` 分卷（压缩后每个约 ≤10 MB；只拆出一卷时保留原名）。云端 `.ej_index.json` 记录每片的 MD5，**上传和拉取都只传变化的分片**（类似 git 的增量——拉取前先在本地重建分片哈希做基线比对，日常拉取只需几个请求；「恢复」模式才全量下载）。小文件 8 路并行、大 zip 3 路并行，打包在后台 isolate 进行、OneDrive 超限文件自动走可续传上传会话；进度条从导出→打包→比对→传输→写索引**全程连续推进**。

**删除与擦除也会同步（增量减）**：擦除轨迹点、删除手账 / 图层 / 收藏都会记录**墓碑**（随每次导出自动携带）；导入时先应用墓碑（删除本地对应行）再合并、并跳过这些 uuid。迷雾按**位并集 + 擦除掩码**合并：两台设备在同一块里各自探索，合并后是**两边像素的并集**（谁都不丢）；橡皮擦扫过的像素记进 `fog_erases` 掩码（带时间戳，随导出携带），合并时只清除**早于该擦除**的副本上的像素——擦除传播到所有设备，擦除之后重新走过的区域（块时间戳更新）则正当复活。任何方向、任何顺序的同步都不会让已删数据复活，也不会丢并发新增。

**FOW（世界迷雾）双向兼容**：云同步与备份里的迷雾**就是** FoW 原生瓦片文件——把 `fow/<图层uuid>/` 里的文件拷进世界迷雾的 `Sync` 文件夹即可导入 FoW；反过来把 FoW 的瓦片放进备份 zip 的 `fow/` 下（带不带图层子目录都行）即可导入本应用，无图层信息时挂到默认图层。手动导入也仍然保留：系统文件选择器**多选**——这个弹窗能进 **OneDrive 等云盘**（SAF 的「选文件夹」反而看不到 OneDrive）；程序按文件魔数自动区分 zip 与原始瓦片。导出可把可见图层的迷雾打包成 zip 走系统分享。

---

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│  UI · 20+ 屏幕 · go_router · Material 3                     │
├─────────────────────────────────────────────────────────────┤
│  状态管理：Riverpod 2                                       │
├──────────┬─────────────┬─────────────┬──────────────────────┤
│   定位   │   数据库    │     P2P     │    外部 API          │
│ • 前台服务│  • Drift   │  • mDNS     │  • OpenAI 协议       │
│ • EXIF   │ (web:Wasm) │  • Socket   │  • gdstudio 音乐     │
│          │  • FTS5    │  • AES-GCM  │  • 地图瓦片服务      │
├──────────┴─────────────┴─────────────┴──────────────────────┤
│  迷雾引擎（自研）：64×64 位图瓦片，可压缩                   │
├─────────────────────────────────────────────────────────────┤
│  SyncStorage（与传输解耦）：WebDAV · GitHub · OneDrive       │
├─────────────────────────────────────────────────────────────┤
│  持久化边界：SQLite + 文件 → 备份 .zip                      │
└─────────────────────────────────────────────────────────────┘
         web 构建（只读） ┄┄┄ 可选 ┄┄┄┐
┌─────────────────────────────────────────────────────────────┐
│  NAS 后端（Rust + Docker，自建，极小）                      │
│  • argon2 单 admin 登录  • 只保管一份加密的设置（不存你的数据）│
│  • SSRF 防护的 WebDAV 代理        （永不接触你的原始数据）   │
└─────────────────────────────────────────────────────────────┘
```

**默认零自建后端。** 移动/桌面端唯一的"服务器"是你自己的 WebDAV
（坚果云 / Nextcloud / AList / Seafile / infinicloud / 自建 dav.sh …）。
**web-front 是可选的**，只为 Web 版做登录、并把*用户的设置*加密保管一份——
你真正的旅行数据从不落在它上面。详见下方 [Web 回忆版](#web-回忆版) 一节。

---

## Web 回忆版

浏览器版是同一个 App 的**只读「回忆」面**——用来在大屏上重温旅程，而不是记录。
手机仍是记录主战场，Web 端是「导入 → 展示」。

- **Web 上能用：** 地图 · 迷雾 · 3D 地球 · 手账 · 探索成就 · 回放。
  记录、Android 前台服务、P2P 聊天在浏览器里是 no-op。
- **存储：** drift 跑在 `WasmDatabase`（IndexedDB），打包 `sqlite3.wasm` + `drift_worker.js`。
- **导入数据：** 导入备份 `.zip`（与手机端同一 schema），或登录后由 App 从你的同步源拉取。
- **只读设计：** 编辑工具隐藏；打开**调试模式**是重新解锁编辑的后门。
- **PWA：** 可安装到桌面 / 主屏。

### 可选自建服务 web-front（Rust + Docker）

一个极小的自建服务 [`web-front/`](web-front/)（tiny_http + argon2 +
chacha20poly1305 + ureq，无 async 运行时、无数据库）。**单 admin 账号，没有注册、
没有多用户。** 它做四件事：托管 web 产物、保管一份加密的设置、提供运维看板、
以及替浏览器读它自己读不到的 WebDAV。

- 手机把「够用来访问你自己的云」的那部分设置推上来，服务端用 **ChaCha20-Poly1305**
  加密存一份，密钥由 admin 口令派生。**不存你的原始旅行数据**（那些仍在你自己的
  WebDAV / GitHub / OneDrive）。
- ⚠️ **服务端能解密这份设置。** 这与项目早期的「零知识保险箱」相反，是刻意的改变：
  保密边界从「客户端持有的密钥」换成了 **admin 口令**。换来的是浏览器里不必持有
  任何云凭据。静态状态下服务端不持有明文——只有登录时才派生密钥放进那个会话。
  **忘记 admin 口令 = 已存的设置永久读不出来**，出路是从手机端重推一份。
- 语音与音乐凭据**刻意不参与漫游**：只读 web 端不需要，上传只会扩大影响面。
- 它还提供一个**只读**的、有 SSRF 防护的 **WebDAV 代理**，让浏览器能访问没有 CORS
  的 WebDAV；写动词一律拒绝——一次 XSS 不能抹掉你的云备份。

```bash
cd web-front
# 不需要任何必填的环境变量
docker compose up -d          # 默认监听 :48080
```

### 部署 Web 版

`scripts/build-site.sh` 会拼出一个静态站——落地页在 `/`、Flutter App 在 `/app/`——输出到
`./dist`。CI（[`.github/workflows/deploy-web.yml`](.github/workflows/deploy-web.yml)）在每次推送
`main` 时构建，并把产物发布到 `web-build` 分支，由 Vercel / Cloudflare Pages 直接部署
（宿主端无需 Flutter SDK）。

📖 **完整部署与测试教程：** [docs/web-display-deploy.md](docs/web-display-deploy.md)

---

## 5 分钟上手

### 依赖

| 工具 | 最低版本 | 安装 |
|------|---------|------|
| Flutter SDK | 3.32 stable | https://docs.flutter.dev/get-started/install |
| Dart | 3.5 | 随 Flutter |
| Android SDK（仅 cmdline-tools） | 35 | https://developer.android.com/tools |
| Xcode | 15 | App Store（仅 iOS 需要） |
| Linux 编译依赖 | — | `sudo apt install xz-utils clang libgtk-3-dev ninja-build cmake` |

**不需要** 完整 Android Studio，只装 cmdline-tools 就够了。

### 1. 拉源码 & 装依赖

```bash
git clone <你的仓库> explore_journal
cd explore_journal
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter doctor   # 除 "Android Studio (not installed)" 之外应该都打勾
```

### 2. ⚡️ 加速首次 `flutter run`（强烈推荐）

`flutter run` 第一次运行会下载 Gradle 缓存、Android 工具链、Flutter 引擎构件，
卡 10-20 分钟是正常的。**提前预热缓存**，正式 `flutter run` 只要几秒：

```bash
# 1) 拉取所有 Flutter 平台构件（dart-sdk、gradle wrapper、engine .so 等）
flutter precache --android

# 2) 拉取 pub 依赖
flutter pub get

# 3) 先 build 一次 debug APK（触发 Gradle 全量下载并缓存）
flutter build apk --debug

# 4) 同时让 Gradle 把 Maven 依赖图全部解析下来（可选，进一步加速）
cd android
./gradlew :app:dependencies --console=plain
cd ..

# 5) 现在 flutter run 几乎瞬间启动
flutter run
```

> 这等价于 SO 上 [这条回答](https://stackoverflow.com/questions/59265825/why-is-flutter-run-taking-forever)
> 的做法：把 "首次依赖下载" 跟 "运行" 解耦。下载只会发生一次，之后命中本地缓存。

### 3. 跑到设备上

#### Android（推荐）

```bash
# 手机：USB 连接 → 开发者模式 → USB 调试 ON
flutter devices                    # 应该能看到设备
flutter run                        # 热重载模式

# 或直接装 APK：
flutter build apk --debug
adb install build/app/outputs/flutter-apk/app-debug.apk
```

#### iOS（仅 Mac）

```bash
cd ios && pod install && cd ..
open ios/Runner.xcworkspace        # Xcode 设置签名团队 → ⌘R
```

#### Linux 桌面

```bash
flutter build linux --release
./build/linux/x64/release/bundle/explore_journal
```

#### Web（只读回忆版 — 见 [Web 回忆版](#web-回忆版)）

```bash
# 纯 App 构建（部署在站点根目录）：
flutter build web --release
cd build/web && python3 -m http.server 8000

# 或整合站点（落地页在 /、App 在 /app/）→ ./dist：
bash scripts/build-site.sh
cd dist && python3 -m http.server 8080   # 打开根路径，不是 /app/
```

### 4. 首次配置

打开 App → 右下「设置」：

1. **AI**：填硅基流动 / OpenAI API Key + 选模型
2. **WebDAV**：URL + 用户 + 密码（点「立即备份到 WebDAV」测试）
3. **P2P 共享口令**：和朋友约定一个短语（如「我们一起去川西」），消息会用它派生的 AES-GCM 密钥加密
4. **地图提供商**：在 OSM / 高德 / Google 之间切换
5. **记录模式**：高性能 / 平衡 / 省电。日常用「省电」就够

然后进「地图」→ 点「开始记录」→ 走起，迷雾会逐步点亮。

---

## 各平台构建产物

| 目标 | 命令 | 输出 |
|------|------|------|
| Android Debug APK | `flutter build apk --debug` | `build/app/outputs/flutter-apk/app-debug.apk`（约 160 MB） |
| Android Release APK | `flutter build apk --release` | 需要签名 |
| Android AAB（上架 Play） | `flutter build appbundle --release` | `build/app/outputs/bundle/release/app-release.aab` |
| iOS IPA | `flutter build ipa --release` | `build/ios/ipa/explore_journal.ipa` |
| Linux | `flutter build linux --release` | `build/linux/x64/release/bundle/` |
| Web | `flutter build web --release` | `build/web/`（Drift 用 `sqlite3.wasm`；P2P 与前台服务在浏览器为 no-op，其余可用） |

### Android Release 签名

新建 `android/key.properties`：

```
storeFile=/绝对/路径/你的.keystore
storePassword=...
keyAlias=...
keyPassword=...
```

在 `android/app/build.gradle.kts`（或 `.gradle`）中加入：

```kotlin
signingConfigs {
    create("release") {
        storeFile = file(keystoreProperties["storeFile"] as String)
        storePassword = keystoreProperties["storePassword"] as String
        keyAlias = keystoreProperties["keyAlias"] as String
        keyPassword = keystoreProperties["keyPassword"] as String
    }
}
buildTypes {
    release { signingConfig = signingConfigs.getByName("release") }
}
```

生成 keystore：

```bash
keytool -genkey -v -keystore ~/explore-release.jks -keyalg RSA -keysize 2048 \
        -validity 10000 -alias explore
```

---

## 权限说明

App 只申请**真正用到的**权限：

| 权限 | 用途 |
|------|------|
| `ACCESS_FINE_LOCATION` / `ACCESS_BACKGROUND_LOCATION` | 记录轨迹、点亮迷雾、手账定位 |
| `FOREGROUND_SERVICE_LOCATION` | 锁屏后继续记录 |
| `POST_NOTIFICATIONS` | 显示「正在记录」常驻通知 |
| `CAMERA` + `READ_MEDIA_*` | 旅行手账拍照/选图 |
| `INTERNET` | 地图瓦片、AI、音乐、WebDAV |
| iOS `NSLocalNetworkUsageDescription` + `NSBonjourServices` | mDNS 发现局域网内的同伴 |

---

## 数据存放位置

```
<应用支持目录>/explore_journal.sqlite       # 主数据库（Drift）
<应用支持目录>/pending_track.jsonl          # 后台 GPS 缓冲
<应用文档目录>/journal_media/*              # 手账照片/视频（持久目录）
<应用文档目录>/exports/<图层名>.{gpx,kml}   # GPX/KML 导出
Android Keystore / iOS Keychain             # 全部凭据（PAT、密码、API key）
```

以上路径（Keystore 除外，由系统单独恢复）都在自动备份范围内
（`backup_rules.xml`），覆盖安装与换机迁移都不会丢数据。

WebDAV 远端镜像：

```
/explore_journal/latest.zip                # 始终最新的快照
/explore_journal/backup_<ISO 时间>.zip     # 历史版本（手动 + 自动）
/explore_journal/mailbox/<peer>/           # P2P 离线消息信箱
```

---

## 音乐 API 说明

默认调用 `https://music-api.gdstudio.xyz/api.php`，协议：

- `types=search&source={netease,tencent,kuwo,kugou,migu}&name=...`
- `types=url&source=...&id=...&br=320`
- `types=pic&source=...&id=...&size=300`

如果服务不可用，去**设置 → 音乐 API**改成你自己的 endpoint。
任何兼容此协议的服务都行（GitHub 上有公开源码可以自部署）。

---

## ZeroTier 设置（P2P 实时共享）

1. 注册 https://my.zerotier.com，创建一个 Network（免费）
2. 在所有要共享路径的设备装 ZeroTier 客户端
3. 用同一个 Network ID 加入，在网页后台 **Authorize** 每个设备
4. 在 App **设置 → P2P 共享口令** 填同一短语
5. 打开「同行聊天」，约 15 秒内 mDNS 会自动发现彼此

整个过程**没有任何中心服务器**。消息用 AES-GCM-256 封装，密钥由
PBKDF2-SHA256（5 万轮）从共享口令派生。

---

## 故障排查

| 现象 | 处理 |
|------|------|
| `Some Android licenses not accepted` | `flutter doctor --android-licenses`，一路 `y` |
| 高德/Google 地图瓦片空白 | 网络问题，到设置切回 OSM |
| 后台 GPS 没更新 | 首次记录时同意「忽略电池优化」 |
| WebDAV 报 530 / InRelease 错误 | 确认 URL 以 WebDAV 根结尾（如 `https://dav.jianguoyun.com/dav/`） |
| `pub get` 报 `Could not find package _macros` | 移除 `custom_lint` / `riverpod_lint`（与当前 Dart SDK 不兼容） |
| iOS `pod install` 失败 | `cd ios && pod repo update && pod install` |
| Web 构建卡在 `tree-shake-icons` | 加 `--no-tree-shake-icons` 参数 |
| `flutter run` 一直卡在 `Running Gradle task 'assembleDebug'…` | 先按上面"加速"步骤预热缓存 |

### 关于 `flutter run` 慢

参考 [Stack Overflow 上的解释](https://stackoverflow.com/questions/59265825/why-is-flutter-run-taking-forever)，
慢的真实原因是：

1. **首次 Gradle 同步** —— 从 Maven Central / Google Maven 下载 50+ 个 jar/aar
2. **首次 Flutter Engine 下载** —— 当前 channel 对应的 `.so` 构件
3. **Kotlin / KSP / AGP 元数据解析** —— Gradle 第一次会构建整个依赖图

**这些只发生一次**。按上面"加速"四步预热后，热重载启动 < 5 秒。

---

## 项目结构

```
lib/
├── main.dart / main_native.dart / main_web.dart   入口 + go_router（平台分流）
├── app/
│   ├── providers.dart            Riverpod 全局服务
│   └── recording_controller.dart 记录管线
├── core/prefs.dart               全局设置 + SharedPreferences
├── models/models.dart            DTO（含 RecordingMode 等枚举）
├── data/db/
│   ├── database.dart             Drift schema(v6) + helper + FTS5
│   └── database.g.dart           自动生成
├── services/
│   ├── ai/                       OpenAI 兼容客户端（流式 + 行程 JSON）
│   ├── export/                   GPX/KML/GeoJSON/FOW 进出
│   ├── fog/                      迷雾位图引擎 + FOW 兼容 + 扫掠圆盘渲染
│   ├── geo/                      坐标换算 · 分层地理编码 · 学习地区 · GeoJSON
│   ├── leaderboard/              Ed25519 签名榜单 + LWW 合并 + 同步
│   ├── location/                 前台 GPS · 前台服务 · 落盘缓冲
│   ├── map/                      瓦片源 · 离线缓存 · 迷雾 CustomPainter
│   ├── media/exif_service.dart   照片 GPS 读取
│   ├── music/                    网易/酷我/JOOX 直连 + GD 兜底
│   ├── imghost/                  GitHub/自定义图床 · 上传队列 · 私图加载
│   ├── group/                    LAN/ZeroTier/WebRTC/frp · 对讲 · 同步
│   ├── p2p/                      AES-GCM 加密 + 线协议
│   ├── security/                 安全存储 · HTTP 明文守卫
│   ├── sync/                     SyncStorage 抽象：WebDAV·GitHub·OneDrive·NAS
│   ├── vault/                    admin 登录 + 配置载荷 + 配置同步控制器
│   ├── backup/backup_service.dart 分块 zip 备份 / 恢复
│   └── webdav/webdav_service.dart
└── ui/                           home · map · globe · layers · journal ·
    explore · leaderboard · playback · ai_planner · music · chat ·
    group_setup · imghost · backup · settings · permissions · debug · about ·
    auth（Web 登录/注册）

web-front/                        可选 Rust + Docker 服务（登录 + 加密配置 + 看板 + 静态托管 + 只读 WebDAV 代理）
```

单一功能模块单一目录。

---

## 路线图

- [x] 瓦片化迷雾引擎
- [x] 图层、标签、颜色、合并、编辑
- [x] WebDAV 一键备份 + 历史恢复
- [x] AI 旅行规划 + 音乐关键词推荐
- [x] P2P 实时共享 + 端到端加密
- [x] 照片 EXIF GPS 自动定位
- [x] GPX / KML 导出
- [x] 收藏歌曲地图视图
- [x] Web 目标：迁移 `NativeDatabase` → `WasmDatabase` + 打包 `sqlite3.wasm` + `drift_worker.js`
- [x] 3D 地球俯瞰 + 足迹热力
- [x] 去中心化签名排行榜（P2P / GitHub PR / 可选 REST）
- [x] GitHub / 自定义图床 + 私有图加载
- [x] 多通道 P2P：局域网组播 / WebRTC / frp 内网穿透
- [x] 地图瓦片离线缓存
- [x] Quill 富文本内嵌图片
- [x] 只读 Web「回忆版」（导入 → 展示，支持 PWA）
- [x] 加密的设置保管 + 可选 Rust/Docker web-front（看板 / 导出 / 只读 WebDAV 代理）
- [x] CI：推送即构建 Web → `web-build` 分支 → Vercel / Cloudflare Pages
- [ ] 移动端「把设置推送到 NAS」的 UI（Web 端拉取闭环已就绪）
- [ ] Apple Watch / Wear OS 配套
- [ ] 实时共享地图中显示其他人的移动光标

---

## 协议

[**CC BY-NC-SA 4.0**](https://creativecommons.org/licenses/by-nc-sa/4.0/) — 见 `LICENSE`。

可自由使用、修改、分享，**仅限非商业用途**，且衍生作品须以相同协议发布（署名—非商业—相同方式共享）。商业使用需另获作者授权。

---

## 致谢

- [flutter_map](https://docs.fleaflet.dev/) — 地图基础
- [Drift](https://drift.simonbinder.eu/) — SQLite ORM + 响应式查询
- [flutter_foreground_task](https://pub.dev/packages/flutter_foreground_task) — Android 持久定位
- [flutter_quill](https://pub.dev/packages/flutter_quill) — 富文本编辑器
- [cryptography](https://pub.dev/packages/cryptography) — 纯 Dart AES-GCM
- gdstudio — 公共音乐 API
- Fog of World (com.ollix.fogofworld) — 灵感来源
