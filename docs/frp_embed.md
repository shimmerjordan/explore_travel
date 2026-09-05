# 内置 frp 客户端（frpc）+ XTCP 打洞

组队的 `frp` transport 把 frpc 编译进 App，配合远端 frps 用 XTCP 在成员间打洞直连。

**已经全部接好并提交**：Dart 侧、Android（`FrpBridge.kt` + `MainActivity` 注册 + gradle 条件依赖）、
iOS（`AppDelegate.swift` 内联 `#if canImport` 桥 + Podfile 条件 vendoring + podspec）、以及
CI（`.github/workflows/build.yml` 的 android / ios job 里的 gomobile 构建步骤）。**唯一不能在当前环境跑的是
`gomobile bind` 本身**（需要 Go + Android NDK；iOS 还需要 macOS + Xcode），所以它在 CI 里跑。

设计上是**优雅降级**：原生侧通过反射（Android）/ `#if canImport`（iOS）引用 frpc，
gradle / Podfile 只在产物存在时才链接。所以**没构建 frpc 的裸 checkout 一样能编译运行**，
只是 frp transport 报"未内置"；CI 构建出库后同一份代码就点亮真正的 frpc。CI 里的两个
gomobile 步骤都是 `continue-on-error`，万一 frp 工具链出问题也不会拖垮既有的 APK/IPA 发布。

## 架构

```
Dart                              原生 (gomobile)                 远端
FrpGroupService                                                  frps
  ├─ 本地 TCP mesh server :47830   ── xtcp proxy ──►  打洞协助    ◄── 其他成员 frpc
  ├─ FrpConfigBuilder → frpc.toml                                    (xtcp proxy/visitor)
  └─ FrpEngine ──MethodChannel──►  FrpPlugin ──► frpmobile.Engine ──► frpc
                  EventChannel  ◄── LogSink   ◄── frpc 日志
```

- 每个成员暴露一个 xtcp **proxy**（名字 `ej-<group>.<peerId>`），把本地 mesh 端口暴露出去。
- 对每个 id 更大的成员建一个 xtcp **visitor**，绑定 `127.0.0.1:<48000+>`，打洞到对方 proxy。
- 现有 TCP mesh 协议（换行分帧 JSON + `v1|` 加密帧）原样跑在打洞隧道上，**与现有 LAN/WebRTC 互通**。
- XTCP 的 `sk` 由 `sha256(共享口令|群组ID|ej-xtcp)` 前 32 位派生，两端自动一致。
- 成员发现：轮询 frps dashboard `GET /api/proxy/xtcp`，按名字前缀筛出同组成员；或手动加 Peer ID。

## 1. 构建 gomobile 库

```bash
cd native/frpmobile
go mod tidy
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init

# Android AAR
gomobile bind -target=android -androidapi 23 -o ../../android/app/libs/frpmobile.aar .

# iOS XCFramework
gomobile bind -target=ios -o ../../ios/Frameworks/Frpmobile.xcframework .
```

> frp 的嵌入 API 在小版本间有变化。`go.mod` 里把 `github.com/fatedier/frp` 钉到你测试过的 tag
> （当前写的是 v0.58.1）。若编译报 `client.NewService` / `config.LoadClientConfig` /
> `UpdateAllConfigurer` 签名不符，按你钉的版本改 `frp.go` 的导入与调用即可。

## 2. Android（已接好）

无需手动操作 —— 以下都已提交：
- `android/app/src/main/kotlin/.../FrpBridge.kt`：反射桥（不在编译期依赖 AAR）。
- `MainActivity.configureFlutterEngine` 里 `FrpBridge.register(flutterEngine)`。
- `android/app/build.gradle.kts`：`if (file("libs/frpmobile.aar").exists()) implementation(...)`。

CI 会把 `gomobile bind` 产物输出到 `android/app/libs/frpmobile.aar`（gitignore 已忽略，不入库）。
本地想手动构建：
```bash
cd native/frpmobile && go mod tidy
go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init
gomobile bind -target=android -androidapi 23 -o ../../android/app/libs/frpmobile.aar .
```

## 3. iOS（已接好）

无需手动操作 —— 以下都已提交：
- `ios/Runner/AppDelegate.swift`：内联 `#if canImport(Frpmobile)` 桥 + `FrpBridge.register(with:)`
  （放在 AppDelegate 里，省去改 `project.pbxproj`）。
- `ios/Podfile`：`if File.directory?('frpmobile/Frpmobile.xcframework') pod 'frpmobile', :path => 'frpmobile'`。
- `ios/frpmobile/frpmobile.podspec`：把 XCFramework 作为 vendored framework。

CI（macOS runner）会把产物输出到 `ios/frpmobile/Frpmobile.xcframework`（gitignore 已忽略）。
本地（在 Mac 上）手动构建：
```bash
cd native/frpmobile && go mod tidy
go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init
gomobile bind -target=ios -o ../../ios/frpmobile/Frpmobile.xcframework .
```
注意 iOS QUIC/KCP 打洞走 UDP，确认没有被额外的网络扩展拦截。

## 4. CI（已接好，`.github/workflows/build.yml` 的 android / ios job）

android / ios 两个 job 都已加 `actions/setup-go@v5` + gomobile 构建步骤（android 自动探测
`$ANDROID_HOME/ndk/*`），在 Flutter build / pod install 之前运行。两步均 `continue-on-error: true`：
frpc 构建失败时，APK/IPA 仍照常出，只是不带 frp（运行时报"未内置"）。

## 5. 远端 frps 最小配置（frps.toml）

```toml
bindPort = 7000
auth.method = "token"
auth.token  = "和 App 里一致"

# 成员自动发现用（可选，但强烈建议）
webServer.addr     = "0.0.0.0"
webServer.port     = 7500
webServer.user     = "admin"
webServer.password = "和 App dashboard 配置一致"
```

XTCP 打洞由 frps 自动协助（natHole），无需额外端口配置；服务器只转发打洞握手，
真正的位置/聊天数据在成员间 P2P 直连，所以带宽占用极小。

## 运行时风险 / 待真机验证

- **gomobile 绑定名**：`New()`→Kotlin `new_()` / Swift `FrpmobileNew()`，接口 `LogSink`→
  Swift `FrpmobileLogSinkProtocol`。不同 gomobile 版本命名可能微调，编译报错按提示改桥接文件。
- **XTCP 成功率**：对称型 NAT 下打洞可能失败；frp 此时无 relay 兜底（不像 WebRTC 的 TURN）。
  失败先把协议从 quic 切 kcp；仍不行需换网络或退回 WebRTC transport。
- **roster 依赖 dashboard**：不开 frps webServer 时，只能手动加 Peer ID。
- **reload 行为**：`UpdateAllConfigurer` 不可用的 frp 版本会退化为重启 frpc，已建隧道会短暂断开重连。
- 以上 Dart 侧逻辑只过了静态分析，端到端打洞务必真机 + 真实 frps 验证。

---

## 首次 CI 排查 checklist

两个 gomobile 步骤是 `continue-on-error`，所以即使全挂，APK/IPA 也会照常产出（只是不带
frp）。判断 frp 到底有没有进包：看 **Build embedded frpc** 那步的日志，结尾应有
`frpmobile.aar`（几 MB）或 `Frpmobile.xcframework/` 列出来；没有就是没构建成功，按下面逐条查。

### A. `gomobile bind` 编译失败（最可能）

frp 的嵌入 API 在小版本间会变。[native/frpmobile/frp.go](../native/frpmobile/frp.go) 写的是 v0.5x
的形态，报错对照改：

| 报错关键字 | 含义 / 改法 |
|---|---|
| `client.NewService` undefined / 签名不符 | 该 frp 版本的 `ServiceOptions` 字段名变了。`go doc github.com/fatedier/frp/client.ServiceOptions` 看真实字段，对应改 `New().Start()` 里的构造。 |
| `config.LoadClientConfig` undefined | 加载函数改名/改包。常见替代：`pkg/config.LoadConfigure` 或 `pkg/config/load`。`go doc github.com/fatedier/frp/pkg/config` 查。 |
| `validation.ValidateAllClientConfig` undefined | 校验包路径变了或返回值变了；查不到就**直接删掉校验调用**（非必需，frpc 启动时也会校验）。 |
| `svc.UpdateAllConfigurer` undefined | 该版本不支持运行时热更。把 `Reload()` 改成 `e.Start(cfg)`（全量重启），并接受隧道会短暂重连。 |
| `ProxyConfigurer` / `VisitorConfigurer` 类型不符 | v1 配置类型名变了，按 `go doc .../pkg/config/v1` 的真实类型改 `parse()` 返回值。 |

**最稳的版本对策**：先 `cd native/frpmobile && go get github.com/fatedier/frp@vX.Y.Z` 钉到一个你查过
API 的 tag（go.mod 现钉 v0.58.1），再 `go mod tidy`。改完务必本地 `gomobile bind` 跑通再推 CI——
CI 迭代一轮好几分钟，本地（有 Go+NDK 的机器）调最快。

### B. gomobile 符号名对不上（编译过了但链接/运行期报错）

`gomobile bind` 的命名规则可能随版本微调。**确认真实名字**：

- Android：解压 `frpmobile.aar`，看 `classes.jar` 里 `frpmobile/` 下的类名
  （`unzip -l frpmobile.aar` → `javap -classpath classes.jar frpmobile.Frpmobile`）。
  [FrpBridge.kt](../android/app/src/main/kotlin/com/explorejournal/explore_journal/FrpBridge.kt)
  里用到的是：工厂类 `frpmobile.Frpmobile` 的静态 `new_()`、实例类 `frpmobile.Engine` 的
  `start/reload/stop/running/setLogSink`、接口 `frpmobile.LogSink`。名字不符就改这几个常量/方法名。
- iOS：看 `Frpmobile.xcframework/.../Headers/Frpmobile.objc.h`（gomobile 生成的头）。
  [AppDelegate.swift](../ios/Runner/AppDelegate.swift) 里用的是 `FrpmobileNew()`、`FrpmobileEngine`、
  `FrpmobileLogSinkProtocol`。Swift 找不到符号时按头文件里的真实名改。
- Go 端可加 `//gobind` 注释或重命名导出标识符来稳定生成名，但通常不必。

### C. Android NDK 没找到

`gomobile bind -target=android` 需要 NDK。CI 步骤里 `NDK_DIR=$(ls -d "$ANDROID_HOME"/ndk/* ...)`
自动探测；若日志显示 `Using NDK: <none>`，说明 runner 镜像把 NDK 放在别处或没装：
- 加一步 `sdkmanager "ndk;27.0.12077973"` 显式安装，或
- 设 `ANDROID_NDK_HOME` / 传 `gomobile bind -ndk "$NDK_DIR"`。
- `gomobile init` 报错时确认 `go version` ≥ 1.21 且 `$(go env GOPATH)/bin` 在 `PATH` 里。

### D. iOS 链接了但 `#if canImport(Frpmobile)` 没生效

- 确认 **Build embedded frpc (iOS)** 步骤在 **pod install 之前**跑（已是此顺序）。
- 确认产物路径正好是 `ios/frpmobile/Frpmobile.xcframework`（Podfile 按这个目录判断是否 vendoring）。
- `pod install` 日志里应能看到 `Installing frpmobile`。没有就是目录名/路径不对。
- XCFramework 必须含 `ios-arm64`（真机）切片；只有模拟器切片会导致真机链接失败。

### E. 跑起来了但连不上（运行时）

打开 App 里 **组队配置 → 诊断日志**，按顺序找这些行（tag `frp`）：
1. `Starting frpc → <addr>:<port>, proxy=ej-<group>.<peerId>` —— frpc 起来了。
   - 没有这行、而是 `内置 frpc 不可用` → 库没进包，回 A/C/D。
2. `frpc: ...`（来自 frpc 自身日志）出现 `login to server success` → 和 frps 通了。
   - 卡在登录 → frps 地址/端口/`token` 不对，或 frps 没开。
3. `roster: N member(s), initiating to M` → dashboard 发现成员了。
   - 一直 `0 member(s)` → dashboard URL/账号密码不对，或对方还没上线注册 proxy；
     可先用「手动添加成员」填对方 Peer ID 验证打洞本身。
4. `visitor → <peerId> via 127.0.0.1:<port>` 然后 `HANDSHAKE OK` → 打洞 + mesh 握手成功 ✅。
   - 有 visitor 行但迟迟不 HANDSHAKE → XTCP 打洞失败：把打洞协议 QUIC↔KCP 互换试；
     仍不行多半是对称 NAT，需换网络或退 WebRTC transport（frp 无 TURN 兜底）。
   - `解密失败` → 两端"共享口令"不一致（sk 由它派生，必须完全相同）。

### F. frps 侧最易忽略的点

- XTCP 打洞要求 frps 版本与 frpc **大版本一致或兼容**（建议两端同一 minor）。
- 自动发现要 frps 开 `webServer`（dashboard），且 App 里 dashboard 地址填 `http://host:7500`
  （**不要**带 `/api/...`，代码会自己拼 `/api/proxy/xtcp`）。
- frps 默认就支持 natHole，无需为 XTCP 单独开端口；但确认 frps 所在机器的安全组放行了
  `bindPort`（默认 7000）的 UDP+TCP。
