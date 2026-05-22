# Explore Journal · 旅行探索

> 一款受 **Fog of World** 启发的零后端旅行/探索 App。
> 走过即点亮迷雾、WebDAV 备份、AI 旅行规划、ZeroTier 局域网实时同行共享、富文本旅行手账——
> **所有数据完全在你自己手里。**

![flutter](https://img.shields.io/badge/Flutter-3.32+-02569B?logo=flutter)
![平台](https://img.shields.io/badge/平台-Android%20%7C%20iOS%20%7C%20Linux%20%7C%20Web%E2%9A%A0-success)
![license](https://img.shields.io/badge/license-MIT-blue)

[English README](README.md)

---

## 功能一览

| 模块 | 内容 |
|------|------|
| 🗺️ 地图 | OSM / 高德 / Google · 标准 / 卫星 / 混合 · 一键切换 |
| 🌫️ 迷雾 | 64×64 位图瓦片 · 颜色/浓度/粗细可调 · 点击擦除或新增 |
| 📍 轨迹 | Android 前台服务（`flutter_foreground_task`，锁屏继续记录） · 三档功耗 · 自动读取照片 EXIF GPS |
| 🗂️ 图层 | 颜色 + 标签 + 可见性 + 合并 + GPX/KML 导出 |
| 🌐 探索成就 | 30+ 国家 + 中国 34 省级行政区 + 美/英/日省级 · bbox 网格基础算法 · 可选 GeoJSON 多边形精确判定 |
| ☁️ 同步 | 直连 **WebDAV**：SQLite + 媒体打包成 ZIP · 手动/自动备份 · 历史版本恢复 |
| 🤖 AI | OpenAI 兼容协议（硅基流动/OpenAI/DeepSeek/OpenRouter…）· 随机旅行规划 · 根据位置+心情生成搜歌关键词 |
| 🎵 音乐 | 网易 / QQ / 酷我 / 酷狗 / 咪咕 五大源搜索 · 播放 · 收藏带 GPS · AI 旅行歌单 · 收藏地图视图 |
| 🖋️ 手账 | Quill 富文本 · 照片/视频附件 · SQLite FTS5 全文搜索 |
| 🎞️ 回放 | 月度/年度/自定义时间段轨迹动画 · 里程/点数/天数总结 |
| 🛰️ P2P | mDNS 发现（基于 ZeroTier 虚拟局域网） · 实时路径共享 · 文字聊天 · **AES-GCM-256 端到端加密**（PBKDF2 派生密钥） · WebDAV 信箱模式离线消息 |
| 💾 数据可迁移 | 一个 SQLite 文件 + 一个 media 目录就是全部数据，标准格式（GPX/KML/GeoJSON），无任何厂商绑定 |

---

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│  UI · 11 个屏幕 · go_router · Material 3                    │
├─────────────────────────────────────────────────────────────┤
│  状态管理：Riverpod 2                                       │
├──────────┬─────────────┬─────────────┬──────────────────────┤
│   定位   │   数据库    │     P2P     │    外部 API          │
│ • 前台服务│  • Drift   │  • mDNS     │  • OpenAI 协议       │
│ • EXIF   │  • FTS5    │  • Socket   │  • gdstudio 音乐     │
│          │             │  • AES-GCM  │  • 地图瓦片服务      │
├──────────┴─────────────┴─────────────┴──────────────────────┤
│  迷雾引擎（自研）：64×64 位图瓦片，可压缩                   │
├─────────────────────────────────────────────────────────────┤
│  持久化边界：SQLite + 文件 → WebDAV (.zip)                  │
└─────────────────────────────────────────────────────────────┘
```

**零自建后端。** 唯一的"服务器"是你自己的 WebDAV
（坚果云 / Nextcloud / AList / Seafile / infinicloud / 自建 dav.sh …）。

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

#### Web

```bash
# Drift 已迁移到 sqlite3.wasm（web/ 目录下已经打包好）。
# P2P 聊天与 Android 前台服务在浏览器上是 no-op，其余功能正常。
flutter build web --release
cd build/web && python3 -m http.server 8000
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
| Web | `flutter build web --release` | （暂不可用，见 Roadmap） |

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
<应用支持目录>/explore_journal.sqlite      # 主数据库（Drift）
<应用文档目录>/media/<uuid>.{jpg,mp4}      # 照片与视频
<应用文档目录>/exports/<图层名>.{gpx,kml}  # GPX/KML 导出
<临时目录>/restore.zip                     # 临时
```

WebDAV 远端镜像：

```
/explore_journal/latest.zip                # 始终最新的快照
/explore_journal/backup_<ISO 时间>.zip     # 历史版本（手动 + 自动）
/explore_journal/mailbox/<peer>/           # P2P 离线消息信箱
```

---

## 可选：接入真实 GeoJSON 边界

默认探索进度用矩形 bbox（速度快、文件小，但略粗）。要换成精确多边形：

1. 找一份各国边界 GeoJSON（如 [datasets/geo-countries](https://github.com/datasets/geo-countries)
   或 [Natural Earth](https://www.naturalearthdata.com/)），按国家拆分。
2. 命名为 `assets/boundaries/<国家名>.geojson`，国家名必须与 `countries.json` 完全一致
   （如 `assets/boundaries/中国.geojson`）。
3. 重跑 `flutter pub get`，assets 通配符会自动包含新文件。

启动时 `GeoJsonLoader.tryLoad()` 会扫描每个国家。有多边形用多边形（射线法 point-in-polygon），
没有就回落到 bbox。

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
| Web 构建报 `dart:ffi` 错 | Web 暂不支持，参见 Roadmap |
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
├── main.dart                     入口 + go_router
├── app/
│   ├── providers.dart            Riverpod 全局服务
│   └── recording_controller.dart 记录管线
├── core/prefs.dart               全局设置 + SharedPreferences
├── models/models.dart            DTO
├── data/db/
│   ├── database.dart             Drift schema + helper
│   └── database.g.dart           自动生成
├── services/
│   ├── ai/ai_service.dart        OpenAI 兼容客户端
│   ├── export/track_export.dart  GPX/KML 进出
│   ├── fog/fog_engine.dart       迷雾位图算法
│   ├── geo/geojson_loader.dart   多边形 PIP
│   ├── location/
│   │   ├── location_service.dart    前台 GPS
│   │   └── background_task.dart     前台服务
│   ├── map/
│   │   ├── tile_providers.dart   OSM/高德/Google × 标/卫/混
│   │   └── fog_layer.dart        CustomPainter 叠加层
│   ├── media/exif_service.dart   照片 GPS 读取
│   ├── music/music_service.dart  gdstudio API
│   ├── p2p/
│   │   ├── p2p_service.dart      mDNS + Socket
│   │   └── crypto.dart           AES-GCM via cryptography 包
│   └── webdav/webdav_service.dart
└── ui/
    ├── home/         九宫格首页
    ├── map/          地图 + 迷雾 + 画笔
    ├── layers/       图层 CRUD + 合并 + 导出
    ├── settings/     全部配置
    ├── journal/      Quill 编辑器 + 媒体
    ├── playback/     轨迹回放 + 统计
    ├── explore/      国家/行政区进度
    ├── ai_planner/   AI 旅行规划
    ├── music/        搜索 · AI 歌单 · 收藏地图
    └── chat/         P2P 实时聊天
```

总计约 **8200 行 Dart**，单一功能模块单一目录。

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
- [ ] 所有内置国家都配上 GeoJSON 多边形（目前仅支持框架）
- [ ] Quill 工具栏支持图片内嵌（目前是侧栏附件）
- [ ] 地图瓦片离线缓存
- [ ] Apple Watch / Wear OS 配套
- [ ] 实时共享地图中显示其他人的移动光标

---

## 协议

MIT — 见 `LICENSE`。

---

## 致谢

- [flutter_map](https://docs.fleaflet.dev/) — 地图基础
- [Drift](https://drift.simonbinder.eu/) — SQLite ORM + 响应式查询
- [flutter_foreground_task](https://pub.dev/packages/flutter_foreground_task) — Android 持久定位
- [flutter_quill](https://pub.dev/packages/flutter_quill) — 富文本编辑器
- [cryptography](https://pub.dev/packages/cryptography) — 纯 Dart AES-GCM
- gdstudio — 公共音乐 API
- Fog of World (com.ollix.fogofworld) — 灵感来源
