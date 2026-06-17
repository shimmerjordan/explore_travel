# 内置 frp 客户端（frpc）+ XTCP 打洞

组队的 `frp` transport 把 frpc 编译进 App，配合远端 frps 用 XTCP 在成员间打洞直连。

**已经全部接好并提交**：Dart 侧、Android（`FrpBridge.kt` + `MainActivity` 注册 + gradle 条件依赖）、
iOS（`AppDelegate.swift` 内联 `#if canImport` 桥 + Podfile 条件 vendoring + podspec）、以及
CI（`.github/workflows/release.yml` 里的 gomobile 构建步骤）。**唯一不能在当前环境跑的是
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

## 4. CI（已接好，`.github/workflows/release.yml`）

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
