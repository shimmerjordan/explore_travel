# web-front 去账号化 + 管理看板 + 双镜像与 CI 整理 — 设计

日期：2026-07-29
状态：已确认，待实施

## 背景

`nas-backend`（ejnas）当前实现了一套多用户账号系统：注册/登录、Argon2 口令校验、
JWT 会话、以及零知识保险箱（vault）——服务端只存密文，客户端用口令派生的 `vaultKey`
自行加解密。

这套设计的唯一用途是解决一个具体问题：web 展示端的配置是**刻意不落盘**的
（`lib/core/prefs.dart` 在 `kIsWeb` 分支直接返回空 `AppSettings`，注释写明
"live only in memory. Never read/write them to localStorage"，因为 OneDrive token 与
WebDAV 密码不该进浏览器存储）。所以 web 每次刷新后需要一个地方把配置取回来，
vault 就是那个地方。

代价是：为了单人/家庭使用，背了一整套多用户注册体系、口令派生、TOFU 式的
版本冲突处理，以及 SQLite 依赖。实测这套系统承载的真实数据是
**1 个用户 + 1 份 1451 字节的 vault**，整个 `ej.db` 文件 24 KB。

同时暴露出三个周边问题：两条镜像 CI 有约 60% 的骨架重复；`backends` 把排行榜
（公开协议）与组队中继（私有实现）固定绑在一起，部署层面无法体现这层边界；
web 产物没有投递到 NAS 的链路。

## 目标

1. 删除多用户账号系统与零知识保险箱，替换为**单 admin**。
2. 配置集中存在服务端一份，由 admin 在看板里维护，web 端登录后拉取。
3. 新增管理看板：服务运行状况 + 配置/指标导出。
4. `48080` 一个端口承载全部（web 静态、看板、API、代理），消除 CORS 配置。
5. web 端 OneDrive 与 WebDAV 都可用。
6. 整理 CI：消除镜像 workflow 的重复骨架，补上 web 产物投递链路。
7. `backends` 的两个模块可各自开关，使「排行榜与组队是两件事」在部署层面成立。

## 非目标

- **服务端不实现云端同步逻辑**。web-front 不解析 FOW 瓦片、不读日志库、不做数据聚合。
  看板只展示服务自身的运行指标。云端数据的读取与渲染仍由 Flutter 侧完成。
- **不做多用户**。单 admin，无注册、无角色、无权限分级。
- **不把排行榜/组队物理拆成两个镜像**。用模块开关表达边界，不复制 CI 与部署资产。
- 不改动 `release.yml`（手动 APK 发布流程）。

## 已确认的决策

| # | 决策 | 理由 |
|---|---|---|
| 1 | 配置存服务端一份，web 端登录后拉取（写入见「谁能写配置」） | 备选是 localStorage（凭据落浏览器，XSS 风险）或每次重填（日常查看太繁琐） |
| 2 | web 端也过 admin 登录，与看板共用一份 session | 那份配置含凭据，无鉴权读取等于公开云凭据 |
| 3 | 看板 = 服务运行状况 + 配置备份导出 | 服务端不碰云端数据，避免在 Rust 里重写 Dart 的 SyncEngine |
| 4 | 一个端口全包，**web 产物打进镜像** | 同源 → `EJ_CORS_ORIGINS` 整体删除；`docker compose up` 即可用，不必往 NAS 拷产物。代价见「风险与权衡」 |
| 5 | OneDrive 与 WebDAV 都支持 | WebDAV 必须经代理，见下节 |
| 6 | 凭据用 admin 密码派生密钥加密 | 落盘即密文；卷备份外流不直接泄露 WebDAV 密码 / OneDrive token / GitHub token / AI key |
| 7 | web 由 web-front 托管，不放 Vercel | 见「为什么 web 不放 Vercel」 |
| 8 | 排行榜/组队同镜像 + 模块开关 | 逻辑边界已清晰，物理拆分对单人规模是纯负担 |
| 9 | **最终只有两个镜像**：`web-front`（web 静态 + admin + 配置 + 看板 + 代理）与 `ej-backend`（排行榜 + 组队） | 使用者视角的心智模型就是两件事：「看数据的地方」和「联机/榜单的地方」 |
| 10 | **`nas-backend/` 更名为 `web-front/`**，镜像 `ejnas` → `web-front` | 职责已本质变化：它不再只是 NAS 上的后端，而是 web 前端的宿主与管理面。GHCR 包建立仅一天、3 个标签，改名代价现在最小 |
| 11 | **删除 `deploy-web.yml`**，web 构建并入 `web-front` 镜像流水线 | docker 就是部署方式，web-build 分支随之冗余；同时消掉一处 Flutter 重复构建 |

> **实施时被否决（Task 17）**：该结论的前提是「deploy-web.yml 只是重复 Flutter 构建」，但它实际产出的是合并站点（宣传落地页在 `/`、应用在 `/app/`、base-href 不同），推到远端已存在的 `web-build` 分支接 Vercel。两份产物 base-href 不同因而无法共用一次构建，而镜像里根本没有 `website/` 的落地页——删掉它等于静默废掉宣传站部署。**已保留**，并在该文件头部写明分工。

### 两个镜像的职责

| 镜像 | 内容 | 端口 | 数据 |
|---|---|---|---|
| `web-front` | Flutter web 产物（打进镜像）+ admin 认证 + 配置存储 + 看板 + WebDAV/图片代理 | 48080 | `config.json`、`admin.json`、`metrics.json` |
| `ej-backend` | 排行榜（公开协议）+ 组队 WS 中继，可各自开关 | 48081 | 排行榜 JSON |

两者互不依赖，可单独部署。只想联机/看榜单的人只需 `ej-backend`；只想看自己数据的人只需 `web-front`。

### 为什么 web 不放 Vercel

web 端并非纯静态：按决策 1 与 5，它需要 ① 从 web-front 拉那份加密配置；② 经 web-front
代理读 WebDAV。因此**无论 web 托管在哪，NAS 都必须公网可达**，放 Vercel 省不掉这一点，
只会把 `EJ_CORS_ORIGINS` 请回来（历史上最容易配错的一项），净收益仅剩静态资源走 CDN。

真正的「零后端 web」需要退回决策 1 与 5（配置存 localStorage、只支持 OneDrive、
放弃 WebDAV），已明确不采用。

### 为什么 WebDAV 必须经代理

同源只解决 web ↔ web-front，不解决 web ↔ WebDAV。群晖/坚果云一类的 WebDAV 服务通常
不发 CORS 头，浏览器直连会被拦。而 Microsoft Graph 支持 CORS，所以 OneDrive 可直连。

现有代理只有 `GET /proxy/url` 与 `GET /proxy/gh/*`，**没有 PROPFIND**，无法列目录。

## 架构

### URL 布局（单端口 48080）

```
/                    web 展示端静态文件（从 EJ_WEB_ROOT 读，默认 /web）
/admin               管理看板（单页 HTML，include_str! 内嵌进二进制）
/api/session         POST 登录（发 session）/ DELETE 登出
/api/password        PUT  改密（旧密码解密 → 新密码重加密配置）
/api/config          GET  拉取解密后的配置 / PUT 写入配置（手机端推送为主，看板可导入 JSON）
/api/metrics         GET  指标快照 + 历史采样
/api/export          GET  导出：配置 JSON（可选含凭据）+ 指标 CSV
/proxy/dav/*         WebDAV 代理（PROPFIND / GET / HEAD / OPTIONS，支持 Range）— 新增
/proxy/gh/*          GitHub 私有图床代理（保留）
/proxy/url           无 CORS 图片源代理（保留）
/healthz             保留
```

web 与 API 同源；手机端是原生 HTTP，不涉及跨域。因此删除 `EJ_CORS_ORIGINS`。

### 后端模块划分

| 模块 | 职责 | 状态 |
|---|---|---|
| `session.rs` | 单 admin 会话：随机 token、内存表、TTL、Cookie/Bearer 双通道 | 新增 |
| `config_store.rs` | 配置的加密读写（JSON 文件 + 原子改名） | 新增 |
| `dav.rs` | WebDAV 代理：方法白名单、凭据注入、目标前缀限制 | 新增 |
| `dashboard.rs` | 看板 HTML + 指标采集与落盘 | 新增 |
| `static_files.rs` | 静态文件服务：MIME 表、index 兜底、空目录说明页 | 新增 |
| `auth.rs` | 仅保留 Argon2 哈希/校验 + 密钥派生；删除 JWT | 改造 |
| `proxy.rs` | SSRF 防护与受限解析器，`dav.rs` 复用 | 保留 |
| `config.rs` | 环境变量/配置文件加载 | 改造（增删配置项） |
| `store.rs` | SQLite users/vaults | **删除** |

## 详细设计

### 1. 单 admin 认证

- **初始凭据**：首次启动若 `data/admin.json` 不存在，写入用户名 `admin`、密码 `admin`
  的 Argon2id 哈希。看板顶部持续显示醒目提示，直到密码被改掉。
- **登录**：`POST /api/session {username, password}` → Argon2 校验 → 生成 32 字节随机
  token（`rand`）→ 存入内存表（token → 过期时刻 + 配置密钥）。
- **双通道**：web 端下发 `HttpOnly; SameSite=Strict` Cookie（浏览器 JS 读不到，
  XSS 无法窃取）；手机端用 `Authorization: Bearer`。两者服务端同一套校验。
- **TTL**：沿用 `EJ_TOKEN_TTL_SECS`（默认 3600），滑动续期。
- **会话不持久化**：进程重启即失效，重新登录即可。省掉一套持久化，也避免重启后
  仍持有旧密码派生的密钥。
- **改密**：`PUT /api/password {old, new}` → 校验旧密码 → 用旧密钥解密配置 →
  用新密钥重新加密写回 → 吊销所有现存 session。
- 删除 `jsonwebtoken` 依赖。

### 2. 配置存储与加密

**文件**（均在 `EJ_DATA_DIR`，默认 `/data`）：

- `admin.json` — 用户名、Argon2id 密码哈希（含其 salt）、**另一个独立的
  `key_salt`**、配置格式版本号。
- `config.json` — 密文信封：`{v, nonce, ciphertext}`。
- `metrics.json` — 指标历史（见第 4 节）。

**密钥派生的域分离**：登录哈希与配置密钥都来自 admin 密码，但使用**两个不同的
salt**（`admin.json` 里的 `password_salt` 与 `key_salt`）。因此拿到密码哈希无法推出
配置密钥。

**加密**：ChaCha20-Poly1305（`chacha20poly1305` crate，纯 Rust，不引入 C 依赖），
每次写入生成新 nonce。

**解密时机**：仅在登录成功时派生密钥并放入该 session。`GET /api/config` 用 session
里的密钥解密。**未登录无法解密**——服务端静态状态下不持有明文。

**字段集合**：直接复用客户端现有的 `kVaultPayloadKeys`（`secrets ∪ locators`，
定义在 `lib/services/vault/vault_payload.dart`）。该文件保留为单一权威定义（改名为
`config_payload.dart`），避免两侧各写一份而漂移。

**谁能写配置**（三条写入路径，避免在看板里重做一套 20+ 字段的表单）：

1. **手机端推送**（主路径）：`PUT /api/config`。手机端已有完整且持续维护的配置 UI，
   它是配置的权威源。这与现有 vault 的数据流一致，因此**不需要迁移工具**。
2. **看板导入 JSON**：`PUT /api/config`，配合导出功能构成「导出 → 编辑 → 导入」
   的闭环，也是迁移到另一台 NAS 的路径。让看板在没有手机的情况下也能改配置。
3. **看板单字段编辑**：仅开放少数确实需要在服务端侧调整的项（如 `webdavUrl`、
   `leaderboardServerUrl` 这类 locator），凭据字段只显示「已设置 / 未设置」并支持
   整体替换，不做逐字段明文回显。

看板**不复刻**手机端那套完整配置表单——那会造成两份 UI 长期漂移，而收益只在
「没带手机时改配置」这一个边缘场景，导入 JSON 已能覆盖。

### 3. WebDAV 代理

**凭据不下发浏览器。** web 端只发相对路径，服务端从解密配置里取
`webdavUrl / webdavUser / webdavPassword`，补全 URL 并注入 `Authorization` 头。

- **方法白名单**：`PROPFIND`（转发 `Depth`）、`GET`（转发 `Range`，回传
  `Content-Range` / `Accept-Ranges`）、`HEAD`、`OPTIONS`。其余一律 405。
- **目标限制**：解析后的绝对 URL 必须以配置里的 `webdavUrl` 为前缀，否则 403。
  这同时堵住把代理当开放中继使用的路径。
- **SSRF 防护**：复用 `proxy.rs` 现有的受限解析器（只返回校验过的公网 IP、连接钉
  住已校验 IP、禁用重定向）。
- **鉴权**：需要有效 session。
- **体积上限**：沿用 `MAX_PROXY_BYTES`（32 MiB）。

相比「web 端拿凭据直连」，WebDAV 密码不进浏览器内存、不进 devtools、不进任何前端
日志。OneDrive 做不到这点——Graph 直连必须把 access token 交给浏览器，那部分维持原样。

### 4. 看板与指标

- **形态**：单页 HTML，`include_str!` 内嵌进二进制，零外部依赖，深色，与项目风格一致。
  折线用内联 SVG，不引图表库。
- **采集**：进程内计数器 → 内存环形缓冲（最近 N 个采样点）→ 每分钟落盘
  `metrics.json`（原子改名）。
- **指标项**：uptime、RSS、按路径分组的请求数与状态码分布、代理转发字节数与
  4xx/5xx 计数、WebDAV 代理命中、登录失败次数、最近若干条访问记录。
- **导出**：`GET /api/export?what=config|metrics|all`
  - 配置 JSON：`?secrets=0` 时凭据字段以 `null` 占位（便于分享排查），`?secrets=1`
    时含明文凭据（用于迁移到另一台 NAS）。
  - 指标 CSV：采样点时间序列。
- 默认密码未改时，看板顶部横幅告警。

### 5. 静态托管

- Flutter `build/web` 产物在镜像构建时 `COPY` 到 `/web`；`EJ_WEB_ROOT` 保留为覆盖项
  （默认 `/web`），供本地开发挂载自己的构建产物、免于每次重建镜像。
- MIME 表覆盖 `html/js/css/wasm/json/png/svg/woff2/map` 等；`.wasm` 必须正确
  （`application/wasm`），否则 `sqlite3.wasm` 加载失败。
- 未命中路径回退 `index.html`（Flutter web 用 hash 路由，但直接访问子路径需要兜底）。
- **目录不存在或为空时，`/` 返回一张说明页**（写明如何挂载 web 产物），而不是 404。
  这类部署问题最容易卡住，直接把答案放在报错的位置上。
- 路径穿越防护：规范化后必须仍在 `EJ_WEB_ROOT` 内。

### 6. backends 模块开关

- 新增 `EJ_MODULE_LEADERBOARD` / `EJ_MODULE_GROUP`（默认均为开）。
- 关闭的模块不注册路由、不参与 WS upgrade；`/api/status` 的 `modules` 中如实反映。
- 想分开部署时：同一镜像起两个容器，各开一个模块，端口各自映射。
- 两个模块都关闭时启动失败并打印明确原因，而不是静默跑一个空服务。

### 7. CI 整理

**抽公共骨架**：新增 `.github/actions/publish-image/action.yml`（composite），封装
QEMU/buildx 初始化、GHCR 登录、`metadata-action` 标签计算、双架构 `build-push`，
并把 tags/digest 作为 outputs 返回。`backend.yml` 与 `nas-backend.yml` 各自保留
`paths` 过滤与专属验证逻辑（Node E2E vs Rust 交叉编译 + 双架构 smoke），调用该 composite。

**摘要不抽**：两个服务的运行摘要里，部署指导、环境变量表、排查项几乎完全不同，
可复用的只有标题行与镜像信息表格。为几行共性把整段摘要参数化，只会让 heredoc 的
转义更难维护——这类文本已经因转义出过问题。各自保留完整摘要。

**不用 matrix 合并**：matrix 无法按分支做 `paths` 过滤，会导致改 `backends/` 也触发
web-front 构建，且失败归属变模糊。

**workflow 最终形态**（从四条变三条）：

| 文件 | 变化 | 职责 |
|---|---|---|
| `web-front.yml` | 由 `nas-backend.yml` 更名而来，并吸收 `deploy-web.yml` | Flutter web 构建 → Rust 交叉编译 → 双架构镜像 → smoke → 推 GHCR |
| `backend.yml` | 文件名不变（避免断掉历史运行链接与分支保护引用） | npm test → 容器 E2E → 双架构镜像 → 推 GHCR |
| `deploy-web.yml` | **删除** | 职责并入 `web-front.yml` |

> **实施时被否决（Task 17）**：该结论的前提是「deploy-web.yml 只是重复 Flutter 构建」，但它实际产出的是合并站点（宣传落地页在 `/`、应用在 `/app/`、base-href 不同），推到远端已存在的 `web-build` 分支接 Vercel。两份产物 base-href 不同因而无法共用一次构建，而镜像里根本没有 `website/` 的落地页——删掉它等于静默废掉宣传站部署。**已保留**，并在该文件头部写明分工。
| `release.yml` | 不动 | 手动 APK 发布 |

`web-front.yml` 的构建顺序：先 `flutter build web`（带 pub 缓存），产物交给
`docker build` 的 context，再走双架构交叉编译。Flutter 构建只跑一次，两个架构共用
同一份 web 产物（纯静态资源，与架构无关）。

**`release.yml` 不动。**

### 8. 环境变量增删

| 变量 | 变化 |
|---|---|
| `EJ_CORS_ORIGINS` | **删除**（同源） |
| `EJ_ALLOW_REGISTRATION` | **删除**（无注册） |
| `EJ_DB_PATH` | **删除**（无 SQLite） |
| `EJ_DATA_DIR` | 新增（默认 `/data`） |
| `EJ_WEB_ROOT` | 新增（默认 `/web`） |
| `EJ_MODULE_LEADERBOARD` / `EJ_MODULE_GROUP` | 新增（backends 侧，默认开） |
| `EJ_JWT_SECRET` | **删除**（不再签 JWT；session 是随机 token） |
| `EJ_LISTEN` / `EJ_TOKEN_TTL_SECS` / `EJ_PROXY_*` | 保留 |

`EJ_JWT_SECRET` 的删除意味着 compose 里那个 `:?` 必填项消失，部署少一步。

## 删除与改造清单

### 后端（nas-backend）

| 动作 | 对象 |
|---|---|
| 删除 | `src/store.rs`（211 行，SQLite users/vaults） |
| 删除 | `main.rs` 中 `handle_register` / `handle_login` / `handle_salt` / `/auth/me` / `issue_session` / `handle_get_vault` / `handle_put_vault`（约 156 行） |
| 改造 | `src/auth.rs`：保留 Argon2 哈希与校验，新增配置密钥派生，删除 JWT 签发/验签 |
| 依赖 | 移除 `rusqlite`、`jsonwebtoken`；新增 `chacha20poly1305` |

移除 `rusqlite` 让最大的一块 C 编译（bundled SQLite）消失，arm64 构建会明显变快。
但 `ureq → rustls → ring` 仍需交叉工具链，**Dockerfile 的交叉编译部分不变**
（`gcc-aarch64-linux-gnu` + `libc6-dev-arm64-cross` 保留）。

### 客户端（Flutter）

| 动作 | 对象 |
|---|---|
| 删除 | `lib/services/vault/settings_vault.dart`（293 行，客户端加解密） |
| 删除 | `nas_token_store.dart` + `nas_session_store.dart`（173 行） |
| 改造 | `lib/ui/auth/login_screen.dart`（177 行）→ admin 登录页（用户名+密码，无注册、无口令派生提示） |
| 改造 | `nas_vault_client.dart` → `admin_config_client.dart`（登录、拉取、推送） |
| 改造 | `auth_controller.dart` → admin 登录控制器 |
| 改造 | `vault_sync_controller.dart` → 配置推送/拉取控制器 |
| 保留改名 | `vault_payload.dart` → `config_payload.dart`（字段集合的单一权威定义） |

`test/vault/` 下 4 个测试文件相应重写。

## 更名涉及的引用点

`nas-backend/` → `web-front/`，镜像 `ejnas` → `web-front`，容器名同步。用 `git mv`
保留历史。必须一并更新的引用：

- `docker-compose.yml`、`docker-compose.ghcr.yml`（服务名、镜像名、容器名、卷名）
- `.github/workflows/nas-backend.yml` → `web-front.yml`（含 `paths` 过滤、`IMAGE` 环境变量、concurrency group）
- `scripts/docker-smoke.sh`（默认镜像名、容器名前缀）
- `nas-backend/README.md` → `web-front/README.md`
- 根 `README.md` / `README.zh.md` 的服务清单
- `docs/web-display-deploy.md`（整篇重写，见下）
- 旧 GHCR 包 `ejnas`：保留为归档，README 注明已废弃；不再推送新标签

## 文档同步范围

用户可见的说明必须与实现同时更新，否则「一键部署」会在文档这一环断掉。

| 文档 | 处理 |
|---|---|
| `README.md` / `README.zh.md` | 顶层架构图与服务清单改为「两个镜像」；快速开始给出两条 `docker compose` |
| `web-front/README.md` | 由 `nas-backend/README.md` 重写：单 admin、配置存储、看板、代理、静态托管 |
| `backends/README.md` | 补模块开关 `EJ_MODULE_*` 与分开部署示例 |
| `docs/web-display-deploy.md` | **整篇重写**：删掉注册/口令/CORS 全部内容，改为「拉镜像 → compose up → admin 登录 → 手机推配置」 |
| `docs/self-host-server-deploy.md` | 补 `web-front` 的部署；排行榜/组队部分补模块开关 |
| `docs/self-host-client-config.md` | 客户端侧从「注册账号」改为「admin 登录 + 推送配置」 |
| `docs/onedrive_setup.md` | 重定向 URI 端口 48082 → 48080 |
| `docs/leaderboard-server-api.md` | 不动（公开协议契约，未变） |
| 两条 workflow 的运行摘要 | 各自给出对应镜像的完整部署步骤（沿用现有「复制粘贴即可」的风格，内联 compose 文件） |

**APP 内文档不需要单独写**：`lib/ui/about/about_screen.dart` 的 `_kDocs` 表通过
asset bundle 直接读 `docs/*.md`，更新 docs 即等于更新 APP 内指南。但**新增文档时必须
同时**在 `_kDocs` 追加一行并在 `pubspec.yaml -> assets` 声明，否则 APP 里打不开
（该文件注释已明确这一约定）。本次若新增 `docs/web-front-deploy.md`，需照此处理。

## 测试策略

**Rust 单测**
- 密钥派生的域分离：同一密码 + 两个 salt 得到不同密钥；密码哈希无法推出配置密钥
- 配置加解密往返；密文被篡改时解密失败（AEAD 生效）
- 改密后配置可用新密码解开、旧密码失效
- session：TTL 过期、改密吊销全部 session、Cookie 与 Bearer 等价
- DAV 代理：方法白名单、目标前缀越界被 403、`Depth`/`Range` 正确转发
- 静态托管：路径穿越被拒、MIME 正确、index 兜底
- 现有 SSRF 判定测试保留

**容器级 smoke**（扩展 `nas-backend/scripts/docker-smoke.sh`）
1. 默认密码 `admin/admin` 可登录，看板返回默认密码告警
2. 改密后旧密码失效、新密码可用
3. 手机端路径：`PUT /api/config` → `GET /api/config` 字节一致
4. 未登录访问 `/api/config`、`/proxy/dav/*`、`/api/export` 全部 401
5. `GET /api/export` 可下载，`secrets=0` 时凭据为 null
6. 静态托管：挂载一个最小 `index.html` 能取到；空目录时 `/` 返回说明页而非 404
7. `docker restart` 后配置仍在（需重新登录）
8. 维持 amd64 + arm64 双架构都跑完整流程

**backends smoke**
- 模块开关：只开排行榜时 WS upgrade 被拒且 `/entries` 正常；只开组队时反之；
  两个都关时启动失败

**Dart 测试**
- `config_payload` 键集合与服务端契约一致（防漂移）
- admin 登录、session 恢复、拉取后设置生效
- 推送配置的往返

## 迁移与部署

**不需要迁移工具。** 手机端是配置的权威源，改造后重推一次即可。现有那份 vault
（1451 字节）内容在手机上全都有，旧 `ej.db` 可直接删除。

**部署顺序**
1. 升级服务端（新镜像 + 新 compose，删掉 `EJ_JWT_SECRET` 等项，挂 `EJ_WEB_ROOT`）
2. 取 web 产物：`curl` 下载 `web-dist.tar.gz` 解到挂载目录
3. 手机端升级 → 用 admin 登录 → 推送配置
4. 浏览器打开 `48080/` → admin 登录 → 数据可见
5. 改掉默认密码

**破坏性变更**
- 现有账号与 vault 作废。
- `EJ_JWT_SECRET`、`EJ_CORS_ORIGINS`、`EJ_ALLOW_REGISTRATION`、`EJ_DB_PATH` 四个
  环境变量移除（compose 需同步更新；`EJ_JWT_SECRET` 那个 `:?` 必填项消失）。
- **Azure 应用注册的 SPA 重定向 URI 必须改**：web 端从 `48082` 挪到 `48080`，
  原先登记的 `http://localhost:48082/auth.html` 需改为 `http://localhost:48080/auth.html`
  （线上域名同理，路径仍是 `/auth.html`）。不改会在 OneDrive 登录后报 `AADSTS9002326`。
  这一步在 Azure 门户手工完成，代码侧改不了。
- 端口 `48082` 与配套的独立静态服务不再需要。

**导出明文凭据的传输注意**：`GET /api/export?secrets=1` 会在响应体里带明文凭据。
经 Cloudflare Tunnel 访问时是 HTTPS，安全；在局域网直连 `http://<NAS>:48080` 时是
明文传输。建议仅在可信网络内使用该参数。

## 分阶段实施

| 阶段 | 内容 | 验收 |
|---|---|---|
| ① 更名与骨架 | `git mv nas-backend web-front`、删 `store.rs` 与 7 个 handler、去掉 `rusqlite`/`jsonwebtoken`、单 admin + session | `cargo test` 过；容器起得来，默认密码可登录 |
| ② 配置与静态托管 | `config_store.rs` 加密读写、`/api/config`、静态文件服务、web 产物打进镜像、客户端改造 | 手机推配置 → 浏览器打开 48080 登录后能用 OneDrive 看数据 |
| ③ 看板与导出 | 指标采集与落盘、看板页面、`/api/export` | `/admin` 可看状态、可导出配置与指标 |
| ④ WebDAV 代理 | `dav.rs`、凭据注入、目标前缀限制 | web 端能用 WebDAV 读数据 |
| ⑤ CI 与模块开关 | composite action、`web-front.yml`（含 Flutter 构建）、删 `deploy-web.yml`、`EJ_MODULE_*` | 两条镜像 CI 各自触发正确、双架构推送成功；模块可单独部署 |
| ⑥ 文档 | 上表全部文档 + 两条 workflow 摘要 | 照文档从零走一遍能部署成功 |

阶段 ⑤ 的模块开关部分与 ①–④ 无依赖，可提前。阶段 ⑥ 必须在 ①–⑤ 之后（否则文档
描述的是尚不存在的行为），但每个阶段完成时应同步更新对应文档片段，避免最后堆积。
每阶段自身可测、可验收，不留半成品状态。

## 风险与权衡

| 风险 | 处理 |
|---|---|
| 忘记 admin 密码 → 配置无法解密 | 配置可从手机端重推；云端数据本身不受影响。看板导出（`secrets=1`）作为备份手段 |
| session 存内存 → 重启需重新登录 | 单人使用可接受；换来无需持久化密钥 |
| 服务端持有凭据明文（运行时内存） | 相比零知识是安全性下降，属决策 1 的既定代价；静态落盘仍是密文 |
| web 与后端版本绑定（产物打进镜像） | 决策 4 的既定代价。缓解：`EJ_WEB_ROOT` 保留覆盖能力，开发时可挂载本地产物；契约由 `config_payload` 键集合测试守住 |
| `web-front` 镜像体积上升（27MB → 60MB+） | 单次拉取代价，NAS 上可接受；换来无需拷产物 |
| `web-front` CI 时长上升（多一次 Flutter web 构建，约 +5~10 分钟） | 只跑一次、两架构共用产物；pub 依赖走缓存 |
| `ring` 仍需交叉工具链 | 已明确不承诺消除；仅 SQLite 那块 C 编译消失 |
| 单端口承载全部 → 单点 | 与「家宽端口越少越好」的取舍一致；`/healthz` 保留供外部探活 |
