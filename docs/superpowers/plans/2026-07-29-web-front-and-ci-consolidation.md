# web-front 去账号化 + 管理看板 + 双镜像与 CI 整理 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `nas-backend` 从多用户零知识保险箱改造成单 admin 的 web 前端宿主与管理面（更名 `web-front`），最终形成两个可独立部署的镜像，并整理 CI 与全部用户文档。

**Architecture:** `web-front` 单端口 48080 承载四件事：Flutter web 静态页（打进镜像）、admin 认证与配置存储（配置用 admin 密码派生密钥加密落盘）、管理看板与导出、WebDAV/图片代理（凭据由服务端注入，不下发浏览器）。`ej-backend` 保持单进程双模块（排行榜 + 组队），新增模块开关使其可分开部署。两镜像互不依赖。

**Tech Stack:** Rust（tiny_http、argon2、chacha20poly1305、ureq、serde）、Flutter/Dart、Docker buildx 双架构、GitHub Actions。

**设计依据：** [docs/superpowers/specs/2026-07-29-nas-console-and-ci-consolidation-design.md](../specs/2026-07-29-nas-console-and-ci-consolidation-design.md)

## Global Constraints

- **端口**：`web-front` 48080、`ej-backend` 48081。**绝不使用 80 / 443 / 8080**（家宽运营商封禁入方向）。web 展示端原 48082 随本次改造废弃。
- **容器用户**：`web-front` 以 distroless nonroot **UID 65532** 运行，镜像无 shell；`ej-backend` 以 `node`（UID 1000）运行。
- **双架构**：所有镜像必须产出 `linux/amd64` + `linux/arm64` 单 manifest。arm64 走**交叉编译**（`--platform=$BUILDPLATFORM`），不用 QEMU 编译。
- **交叉编译依赖**：`gcc-aarch64-linux-gnu` **和** `libc6-dev-arm64-cross` 两个都必须装（后者是 Recommends，`--no-install-recommends` 会跳过它，导致 ring/SQLite 编译失败）。
- **Dockerfile 的 RUN 块内不得出现 `#` 注释**（注释行不带续行反斜杠，可能使 RUN 提前终止）。
- **纯 Rust 优先**：新增依赖不得引入新的 C 编译单元。加密用 `chacha20poly1305`（RustCrypto）。
- **KDF**：Argon2id。登录哈希与配置密钥必须使用**两个不同的 salt**（域分离）。
- **体积上限**：配置载荷 ≤ 256 KiB；代理单对象 ≤ 32 MiB（`MAX_PROXY_BYTES`）。
- **注释语言**：`web-front/`（原 nas-backend）用**英文**注释，`backends/` 用**中文**注释——沿用各目录既有风格，不要统一。
- **commit message 不得包含 `Co-Authored-By` 或任何协作者署名**。
- **未经用户明确指令不得 `git push`**。
- **禁用命令**：不得在验证脚本里执行 `rm -rf /var/lib/apt/lists/*` 之类会作用于宿主的命令。

---

## File Structure

### web-front（原 nas-backend）

| 文件 | 责任 | 动作 |
|---|---|---|
| `web-front/src/main.rs` | HTTP 骨架、路由分派、`AppState` | 改造（删 7 个 handler，接入新模块） |
| `web-front/src/auth.rs` | Argon2 哈希/校验、配置密钥派生、token 生成 | 改造（删 JWT） |
| `web-front/src/admin_file.rs` | `admin.json` 的读写与首次初始化 | 新建 |
| `web-front/src/session.rs` | 单 admin 会话表（内存、TTL、滑动续期、全量吊销） | 新建 |
| `web-front/src/config_store.rs` | 配置密文信封的加解密与原子落盘 | 新建 |
| `web-front/src/static_files.rs` | 静态文件服务、MIME、index 兜底、空目录说明页、路径穿越防护 | 新建 |
| `web-front/src/metrics.rs` | 指标计数器、环形缓冲、落盘 | 新建 |
| `web-front/src/dashboard.rs` | 看板 HTML（`include_str!`）与 `/api/metrics`、`/api/export` | 新建 |
| `web-front/src/dav.rs` | WebDAV 代理：方法白名单、凭据注入、目标前缀限制 | 新建 |
| `web-front/assets/dashboard.html` | 看板单页（内联 CSS/JS/SVG，零外部依赖） | 新建 |
| `web-front/src/proxy.rs` | SSRF 受限解析器 | 保留（`dav.rs` 复用） |
| `web-front/src/config.rs` | 环境变量加载 | 改造（增删配置项） |
| `web-front/src/store.rs` | SQLite users/vaults | **删除** |

### 客户端（Flutter）

| 文件 | 动作 |
|---|---|
| `lib/services/vault/config_payload.dart` | 由 `vault_payload.dart` 改名，保留为字段集合的单一权威定义 |
| `lib/services/vault/admin_config_client.dart` | 由 `nas_vault_client.dart` 改造：登录、拉取、推送 |
| `lib/services/vault/admin_session_store.dart` | 由 `nas_session_store.dart` 改造：只存 token + 服务器地址 |
| `lib/services/vault/auth_controller.dart` | 改造为 admin 登录控制器 |
| `lib/services/vault/config_sync_controller.dart` | 由 `vault_sync_controller.dart` 改造 |
| `lib/ui/auth/login_screen.dart` | 改造为 admin 登录页（用户名 + 密码） |
| `lib/services/vault/settings_vault.dart` | **删除**（客户端加解密不再需要） |
| `lib/services/vault/nas_token_store.dart` | **删除** |

### backends

| 文件 | 动作 |
|---|---|
| `backends/server/server.js` | 按 `EJ_MODULE_*` 条件注册模块 |
| `backends/test/modules.test.js` | 新建：模块开关行为 |

### CI

| 文件 | 动作 |
|---|---|
| `.github/actions/publish-image/action.yml` | 新建 composite：QEMU/buildx/login/meta/push |
| `.github/workflows/web-front.yml` | 由 `nas-backend.yml` 更名，吸收 Flutter web 构建 |
| `.github/workflows/backend.yml` | 改造为调用 composite（文件名保持不变） |
| `.github/workflows/deploy-web.yml` | **删除** |

---

## 阶段① 更名与骨架

### Task 1: 目录更名与引用同步

**Files:**
- Rename: `nas-backend/` → `web-front/`（用 `git mv` 保留历史）
- Rename: `.github/workflows/nas-backend.yml` → `.github/workflows/web-front.yml`
- Modify: `web-front/docker-compose.yml`、`web-front/docker-compose.ghcr.yml`、`web-front/scripts/docker-smoke.sh`、`web-front/README.md`、`README.md`、`README.zh.md`

**Interfaces:**
- Produces: 目录 `web-front/`、镜像名 `web-front`、workflow `web-front.yml`。后续所有任务的路径均以此为准。

- [ ] **Step 1: 执行更名**

```bash
cd /home/xyz/Projects/priv/explore_journal
git mv nas-backend web-front
git mv .github/workflows/nas-backend.yml .github/workflows/web-front.yml
```

- [ ] **Step 2: 替换引用（镜像名、容器名、服务名、路径）**

```bash
# 镜像与容器名：ejnas → web-front
sed -i 's#ghcr.io/shimmerjordan/explore_travel/ejnas#ghcr.io/shimmerjordan/explore_travel/web-front#g; s/\bejnas:latest\b/web-front:latest/g; s/\bejnas:smoke/web-front:smoke/g; s/container_name: ejnas/container_name: web-front/; s/^  ejnas:/  web-front:/; s/\bEJ_IMAGE\b/EJ_WEB_FRONT_IMAGE/g' \
  web-front/docker-compose.yml web-front/docker-compose.ghcr.yml
# 路径引用
sed -i 's#nas-backend/#web-front/#g; s#nas-backend\b#web-front#g' \
  .github/workflows/web-front.yml web-front/scripts/docker-smoke.sh README.md README.zh.md
# smoke 脚本里的默认镜像与容器名
sed -i 's/IMAGE:-ejnas:smoke/IMAGE:-web-front:smoke/; s/ejnas-smoke-/web-front-smoke-/' web-front/scripts/docker-smoke.sh
```

- [ ] **Step 3: 人工核对残留**

```bash
grep -rn "nas-backend\|ejnas" --include="*.yml" --include="*.md" --include="*.sh" --include="*.rs" . \
  | grep -v "^./docs/superpowers/" | grep -v "\.git/"
```
Expected: 仅剩 `docs/` 里描述「原 ejnas / 已废弃」的历史语境；若有其他命中，逐条改掉。

- [ ] **Step 4: 确认 compose 仍可解析**

```bash
cd web-front && EJ_JWT_SECRET=x docker compose -f docker-compose.ghcr.yml config >/dev/null && echo OK
```
Expected: 输出 `OK`（此时 `EJ_JWT_SECRET` 尚未移除，Task 5 才删）

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "重命名 nas-backend 为 web-front"
```

---

### Task 2: 删除 SQLite 与账号相关 handler

**Files:**
- Delete: `web-front/src/store.rs`
- Modify: `web-front/src/main.rs`（`AppState`、路由表、7 个 handler）
- Modify: `web-front/Cargo.toml`

**Interfaces:**
- Produces: `AppState { cfg, limiter, agent }`（去掉 `store` 字段）。后续任务向其追加 `sessions`、`admin`、`metrics` 字段。

- [ ] **Step 1: 删除文件与依赖**

```bash
cd /home/xyz/Projects/priv/explore_journal/web-front
git rm src/store.rs
# Cargo.toml：删掉 rusqlite 与 jsonwebtoken 两行
sed -i '/^rusqlite = /d; /^jsonwebtoken = /d' Cargo.toml
```

- [ ] **Step 2: 从 main.rs 摘除账号相关代码**

删除以下项（`main.rs` 内）：
- `mod store;` 与 `use store::...`
- `AppState` 的 `store: Mutex<Store>` 字段及其初始化
- 函数：`authed`、`issue_session`、`handle_register`、`handle_login`、`handle_salt`、`handle_get_vault`、`handle_put_vault`
- 路由分派中的 `/auth/register`、`/auth/login`、`/auth/salt`、`/auth/me`、`GET /vault`、`PUT /vault` 六个分支
- 常量 `MAX_VAULT_BODY` 暂时保留（Task 8 改为配置载荷上限复用）

- [ ] **Step 3: 确认编译通过**

```bash
cargo build 2>&1 | tail -20
```
Expected: 编译成功。若报未使用的 import（如 `base64`、`sha2`），一并清理；**不要**因为报错就把 `store.rs` 加回来。

- [ ] **Step 4: 确认 SQLite 依赖真的消失**

```bash
cargo tree -i libsqlite3-sys 2>&1 | head -3
```
Expected: 输出类似 `error: package ID specification ... did not match any packages`，即已无此依赖。

- [ ] **Step 5: Commit**

```bash
cd .. && git add -A && git commit -m "删除SQLite与多用户账号相关代码"
```

---

### Task 3: auth.rs 改造（Argon2 + 密钥派生 + token）

**Files:**
- Modify: `web-front/src/auth.rs`（删 JWT，新增派生与 token）
- Test: `web-front/src/auth.rs` 内的 `#[cfg(test)] mod tests`

**Interfaces:**
- Produces:
  - `pub fn hash_password(pw: &[u8]) -> Result<String, String>` — 返回 Argon2id PHC 串
  - `pub fn verify_password(phc: &str, pw: &[u8]) -> bool`
  - `pub fn derive_config_key(pw: &[u8], key_salt: &[u8]) -> Result<[u8; 32], String>`
  - `pub fn new_token() -> String` — 32 字节随机，base64url 无填充
  - `pub fn new_salt_b64() -> String` — 16 字节随机 salt 的 base64

- [ ] **Step 1: 写失败测试**

追加到 `web-front/src/auth.rs` 的 `mod tests`：

```rust
    #[test]
    fn password_hash_roundtrip_and_reject() {
        let phc = hash_password(b"admin").unwrap();
        assert!(verify_password(&phc, b"admin"));
        assert!(!verify_password(&phc, b"admin2"));
        assert!(!verify_password(&phc, b""));
    }

    #[test]
    fn config_key_is_deterministic_and_salt_dependent() {
        let s1 = b"salt-one-16bytes";
        let s2 = b"salt-two-16bytes";
        let k1 = derive_config_key(b"admin", s1).unwrap();
        let k1_again = derive_config_key(b"admin", s1).unwrap();
        let k2 = derive_config_key(b"admin", s2).unwrap();
        assert_eq!(k1, k1_again, "同密码同 salt 必须得到同密钥");
        assert_ne!(k1, k2, "换 salt 必须换密钥");
        assert_ne!(derive_config_key(b"other", s1).unwrap(), k1);
    }

    #[test]
    fn password_hash_does_not_leak_config_key() {
        // 域分离：PHC 串里不得出现配置密钥的任何字节片段
        let salt = b"salt-one-16bytes";
        let key = derive_config_key(b"admin", salt).unwrap();
        let phc = hash_password(b"admin").unwrap();
        let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
        assert!(!phc.contains(&hex[..16]));
    }

    #[test]
    fn tokens_are_unique_and_urlsafe() {
        let a = new_token();
        let b = new_token();
        assert_ne!(a, b);
        assert!(a.len() >= 40);
        assert!(a.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd web-front && cargo test auth:: 2>&1 | tail -15
```
Expected: 编译失败，`cannot find function derive_config_key` / `new_token` 等。

- [ ] **Step 3: 实现**

在 `auth.rs` 中：删除所有 JWT 相关函数（`issue_jwt` / `verify_jwt` 之类）与 `jsonwebtoken` import。新增：

```rust
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use argon2::password_hash::{SaltString, rand_core::OsRng};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD, engine::general_purpose::STANDARD};
use rand::RngCore;

pub fn hash_password(pw: &[u8]) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(pw, &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

pub fn verify_password(phc: &str, pw: &[u8]) -> bool {
    match PasswordHash::new(phc) {
        Ok(parsed) => Argon2::default().verify_password(pw, &parsed).is_ok(),
        Err(_) => false,
    }
}

/// Derive the 32-byte config encryption key. Uses a salt that is DELIBERATELY
/// different from the login hash's salt (domain separation): leaking the
/// password hash must not reveal this key.
pub fn derive_config_key(pw: &[u8], key_salt: &[u8]) -> Result<[u8; 32], String> {
    let mut out = [0u8; 32];
    Argon2::default()
        .hash_password_into(pw, key_salt, &mut out)
        .map_err(|e| e.to_string())?;
    Ok(out)
}

pub fn new_token() -> String {
    let mut b = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut b);
    URL_SAFE_NO_PAD.encode(b)
}

pub fn new_salt_b64() -> String {
    let mut b = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut b);
    STANDARD.encode(b)
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cargo test auth:: 2>&1 | tail -12
```
Expected: 4 个新测试全部 PASS，原有 `auth` 测试若涉及 JWT 应已被删除。

- [ ] **Step 5: Commit**

```bash
cd .. && git add -A && git commit -m "auth改造：Argon2校验与配置密钥派生，移除JWT"
```

---

### Task 4: admin.json 初始化与读写

**Files:**
- Create: `web-front/src/admin_file.rs`
- Modify: `web-front/src/main.rs`（`mod admin_file;`、启动时加载）
- Test: `web-front/src/admin_file.rs` 内 `mod tests`

**Interfaces:**
- Consumes: `auth::hash_password`、`auth::new_salt_b64`（Task 3）
- Produces:
  - `pub struct AdminFile { pub v: u32, pub username: String, pub password_phc: String, pub key_salt_b64: String, pub is_default: bool }`
  - `pub fn load_or_init(dir: &Path) -> Result<AdminFile, String>` — 文件不存在时写入 `admin`/`admin` 并置 `is_default = true`
  - `pub fn save(dir: &Path, a: &AdminFile) -> Result<(), String>` — 原子改名
  - `pub fn key_salt(&self) -> Result<Vec<u8>, String>`

- [ ] **Step 1: 写失败测试**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        let d = env::temp_dir().join(format!("wf-admin-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn first_run_creates_default_admin() {
        let d = tmpdir("init");
        let a = load_or_init(&d).unwrap();
        assert_eq!(a.username, "admin");
        assert!(a.is_default, "首次初始化必须标记为默认密码");
        assert!(crate::auth::verify_password(&a.password_phc, b"admin"));
        assert!(d.join("admin.json").exists());
    }

    #[test]
    fn second_run_reads_back_without_resetting() {
        let d = tmpdir("reload");
        let first = load_or_init(&d).unwrap();
        let second = load_or_init(&d).unwrap();
        assert_eq!(first.password_phc, second.password_phc);
        assert_eq!(first.key_salt_b64, second.key_salt_b64);
    }

    #[test]
    fn changing_password_clears_default_flag() {
        let d = tmpdir("chpw");
        let mut a = load_or_init(&d).unwrap();
        a.password_phc = crate::auth::hash_password(b"s3cret").unwrap();
        a.is_default = false;
        save(&d, &a).unwrap();
        let reloaded = load_or_init(&d).unwrap();
        assert!(!reloaded.is_default);
        assert!(crate::auth::verify_password(&reloaded.password_phc, b"s3cret"));
        assert!(!crate::auth::verify_password(&reloaded.password_phc, b"admin"));
    }

    #[test]
    fn key_salt_decodes_to_16_bytes() {
        let d = tmpdir("salt");
        let a = load_or_init(&d).unwrap();
        assert_eq!(a.key_salt().unwrap().len(), 16);
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd web-front && cargo test admin_file:: 2>&1 | tail -10
```
Expected: `cannot find module admin_file` 或 `load_or_init` 未定义。

- [ ] **Step 3: 实现**

`admin_file.rs`：`AdminFile` 用 `serde` 派生；`load_or_init` 读 `dir/admin.json`，
解析失败或不存在则用 `hash_password(b"admin")` + `new_salt_b64()` 造一份、`is_default: true`、
落盘后返回；`save` 写 `admin.json.tmp` 再 `rename`（原子）；`key_salt` 用 `STANDARD` 解码。
`v` 固定为 `1`。在 `main.rs` 顶部加 `mod admin_file;`。

- [ ] **Step 4: 运行测试确认通过**

```bash
cargo test admin_file:: 2>&1 | tail -10
```
Expected: 4 个测试 PASS。

- [ ] **Step 5: Commit**

```bash
cd .. && git add -A && git commit -m "新增admin.json的初始化与原子读写"
```

---

### Task 5: session 表与登录/登出/改密端点

**Files:**
- Create: `web-front/src/session.rs`
- Modify: `web-front/src/main.rs`（路由 + `AppState.sessions`/`admin`）
- Modify: `web-front/src/config.rs`（删 `jwt_secret`、`cors_origins`、`allow_registration`、`db_path`；加 `data_dir`）
- Modify: `web-front/docker-compose.yml`、`docker-compose.ghcr.yml`（删 `EJ_JWT_SECRET` 等）
- Test: `web-front/src/session.rs` 内 `mod tests`

**Interfaces:**
- Consumes: `auth::new_token`、`auth::derive_config_key`、`admin_file::AdminFile`
- Produces:
  - `pub struct Sessions` with `pub fn new(ttl_secs: u64) -> Self`、`pub fn create(&self, key: [u8;32]) -> String`、`pub fn get_key(&self, token: &str) -> Option<[u8;32]>`（命中即滑动续期）、`pub fn revoke_all(&self)`、`pub fn len(&self) -> usize`
  - HTTP：`POST /api/session`、`DELETE /api/session`、`PUT /api/password`
  - `fn session_token(req: &Request) -> Option<String>` — 先看 `Authorization: Bearer`，再看 `Cookie: ej_session=`

- [ ] **Step 1: 写失败测试**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_then_get_returns_same_key() {
        let s = Sessions::new(60);
        let key = [7u8; 32];
        let t = s.create(key);
        assert_eq!(s.get_key(&t), Some(key));
    }

    #[test]
    fn unknown_token_is_rejected() {
        let s = Sessions::new(60);
        assert_eq!(s.get_key("nope"), None);
    }

    #[test]
    fn expired_token_is_rejected() {
        let s = Sessions::new(0); // 立即过期
        let t = s.create([1u8; 32]);
        std::thread::sleep(std::time::Duration::from_millis(1100));
        assert_eq!(s.get_key(&t), None);
    }

    #[test]
    fn revoke_all_drops_every_session() {
        let s = Sessions::new(60);
        let a = s.create([1u8; 32]);
        let b = s.create([2u8; 32]);
        assert_eq!(s.len(), 2);
        s.revoke_all();
        assert_eq!(s.get_key(&a), None);
        assert_eq!(s.get_key(&b), None);
        assert_eq!(s.len(), 0);
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd web-front && cargo test session:: 2>&1 | tail -10
```
Expected: `cannot find module session`。

- [ ] **Step 3: 实现 session.rs 与三个端点**

`Sessions` 内部 `Mutex<HashMap<String, (u64 /*expires_at*/, [u8;32])>>`，`ttl_secs` 字段；
`get_key` 命中且未过期则把 `expires_at` 刷新为 `now + ttl`（滑动续期）后返回密钥，过期则移除并返回 `None`。

`main.rs` 路由新增：

- `POST /api/session`：读 `{username, password}` → 用 `AdminFile` 校验 → `derive_config_key(pw, key_salt)` → `sessions.create(key)` → 返回
  `{ok: true, is_default_password: <bool>}`，并下发
  `Set-Cookie: ej_session=<token>; HttpOnly; SameSite=Strict; Path=/; Max-Age=<ttl>`，
  响应体同时带 `token` 供手机端用 Bearer。校验失败返回 401（**不区分**用户名错还是密码错）。
- `DELETE /api/session`：移除当前 token，回 `Set-Cookie: ej_session=; Max-Age=0`。
- `PUT /api/password`：读 `{old, new}`；`new` 长度 < 8 返回 400；校验 `old` → 写入新 PHC、`is_default=false` → **调用 `sessions.revoke_all()`** → 200。
  （此时配置存储尚未实现，Task 8 会在这里补「用旧密钥解密、新密钥重加密」。）

`config.rs`：删 `jwt_secret` / `cors_origins` / `allow_registration` / `db_path` 及其环境变量分支；
新增 `data_dir`（`EJ_DATA_DIR`，默认 `/data`）与 `web_root`（`EJ_WEB_ROOT`，默认 `/web`）。
同步从两个 compose 文件删除 `EJ_JWT_SECRET`（含那个 `:?` 必填）、`EJ_CORS_ORIGINS`、`EJ_ALLOW_REGISTRATION`、`EJ_DB_PATH`，新增 `EJ_DATA_DIR`。

- [ ] **Step 4: 运行测试并手动验证端点**

```bash
cargo test session:: 2>&1 | tail -8
```
Expected: 4 个测试 PASS。

```bash
EJ_DATA_DIR=$(mktemp -d) EJ_LISTEN=127.0.0.1:18995 cargo run --quiet &
sleep 2
curl -si -X POST localhost:18995/api/session -H 'content-type: application/json' \
  -d '{"username":"admin","password":"admin"}' | grep -E "HTTP/|Set-Cookie|is_default"
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:18995/api/session \
  -H 'content-type: application/json' -d '{"username":"admin","password":"wrong"}'
kill %1
```
Expected: 首个请求 `200`、带 `Set-Cookie: ej_session=...; HttpOnly`、`"is_default_password":true`；第二个请求 `401`。

- [ ] **Step 5: Commit**

```bash
cd .. && git add -A && git commit -m "新增单admin会话与登录登出改密端点"
```

---

## 阶段② 配置存储与静态托管

### Task 6: config_store.rs 加密读写

**Files:**
- Create: `web-front/src/config_store.rs`
- Modify: `web-front/Cargo.toml`（加 `chacha20poly1305 = "0.10"`）
- Modify: `web-front/src/main.rs`（`mod config_store;`）
- Test: `web-front/src/config_store.rs` 内 `mod tests`

**Interfaces:**
- Produces:
  - `pub fn save(dir: &Path, key: &[u8; 32], plaintext: &[u8]) -> Result<(), String>`
  - `pub fn load(dir: &Path, key: &[u8; 32]) -> Result<Option<Vec<u8>>, String>` — 文件不存在返回 `Ok(None)`；密钥不对或密文被篡改返回 `Err`
  - `pub fn reencrypt(dir: &Path, old: &[u8; 32], new: &[u8; 32]) -> Result<(), String>`
  - `pub const MAX_CONFIG_BYTES: usize = 256 * 1024;`

- [ ] **Step 1: 写失败测试**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("wf-cfg-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn missing_file_reads_as_none() {
        let d = tmpdir("none");
        assert_eq!(load(&d, &[1u8; 32]).unwrap(), None);
    }

    #[test]
    fn roundtrip_returns_exact_bytes() {
        let d = tmpdir("rt");
        let key = [9u8; 32];
        let payload = br#"{"webdavUrl":"https://dav.example.com","aiModel":"x"}"#;
        save(&d, &key, payload).unwrap();
        assert_eq!(load(&d, &key).unwrap().unwrap(), payload.to_vec());
    }

    #[test]
    fn wrong_key_fails_to_decrypt() {
        let d = tmpdir("wrongkey");
        save(&d, &[1u8; 32], b"secret").unwrap();
        assert!(load(&d, &[2u8; 32]).is_err(), "错误密钥必须解密失败，而不是返回垃圾");
    }

    #[test]
    fn tampered_ciphertext_is_rejected() {
        let d = tmpdir("tamper");
        let key = [3u8; 32];
        save(&d, &key, b"secret").unwrap();
        let p = d.join("config.json");
        let mut s = std::fs::read_to_string(&p).unwrap();
        // 翻转密文里的一个字符
        let idx = s.find("\"ct_b64\"").unwrap() + 12;
        let ch = s.as_bytes()[idx];
        s.replace_range(idx..idx + 1, if ch == b'A' { "B" } else { "A" });
        std::fs::write(&p, s).unwrap();
        assert!(load(&d, &key).is_err(), "AEAD 必须拒绝被篡改的密文");
    }

    #[test]
    fn each_save_uses_a_fresh_nonce() {
        let d = tmpdir("nonce");
        let key = [4u8; 32];
        save(&d, &key, b"same").unwrap();
        let first = std::fs::read_to_string(d.join("config.json")).unwrap();
        save(&d, &key, b"same").unwrap();
        let second = std::fs::read_to_string(d.join("config.json")).unwrap();
        assert_ne!(first, second, "相同明文两次写入的密文必须不同（nonce 必须换）");
    }

    #[test]
    fn reencrypt_switches_key_and_preserves_content() {
        let d = tmpdir("reenc");
        let (old, new) = ([5u8; 32], [6u8; 32]);
        save(&d, &old, b"payload").unwrap();
        reencrypt(&d, &old, &new).unwrap();
        assert_eq!(load(&d, &new).unwrap().unwrap(), b"payload".to_vec());
        assert!(load(&d, &old).is_err(), "换密钥后旧密钥必须失效");
    }

    #[test]
    fn reencrypt_on_missing_file_is_a_noop() {
        let d = tmpdir("reenc-none");
        reencrypt(&d, &[1u8; 32], &[2u8; 32]).unwrap();
        assert_eq!(load(&d, &[2u8; 32]).unwrap(), None);
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd web-front && cargo test config_store:: 2>&1 | tail -10
```
Expected: `cannot find module config_store`。

- [ ] **Step 3: 实现**

`Cargo.toml` 加 `chacha20poly1305 = "0.10"`。`config_store.rs`：

信封结构 `{ "v": 1, "nonce_b64": "...", "ct_b64": "..." }`，写 `config.json.tmp` 后 `rename`。
`save`：生成 12 字节随机 nonce（`rand`），`ChaCha20Poly1305::new(key.into())` 加密。
`load`：文件不存在 → `Ok(None)`；解析 JSON → 解码 → `decrypt` 失败一律映射为
`Err("config decrypt failed".into())`（**不要**把底层错误细节回传给 HTTP 层，避免成为
判别密钥是否正确的预言机）。
`reencrypt`：`load(old)` → `None` 时直接 `Ok(())`；否则 `save(new)`。

- [ ] **Step 4: 运行测试确认通过**

```bash
cargo test config_store:: 2>&1 | tail -12
```
Expected: 7 个测试全部 PASS。

- [ ] **Step 5: 确认没引入新的 C 依赖**

```bash
cargo tree -i cc 2>&1 | grep -c chacha20poly1305 || true
cargo tree | grep -iE "chacha|cc v" | head -5
```
Expected: `chacha20poly1305` 及其依赖（`chacha20`、`poly1305`、`aead`）均为纯 Rust，不出现新的 `cc` 构建依赖。

- [ ] **Step 6: Commit**

```bash
cd .. && git add -A && git commit -m "新增配置密文信封的加解密与原子落盘"
```

---

### Task 7: /api/config 读写端点，并补齐改密时的重加密

**Files:**
- Modify: `web-front/src/main.rs`（两个路由 + 改密逻辑补全）

**Interfaces:**
- Consumes: `config_store::{save, load, reencrypt, MAX_CONFIG_BYTES}`、`Sessions::get_key`
- Produces: `GET /api/config`、`PUT /api/config`；`PUT /api/password` 补全为「校验旧密码 → `reencrypt` → 写新 PHC → `revoke_all`」

- [ ] **Step 1: 实现三处改动**

`GET /api/config`：无有效 session → 401。`load` 返回 `None` → `200 {}`（尚未推送过配置，
不是错误）；`Err` → 500 `{"error":"config decrypt failed"}`。成功 → 原样回传明文 JSON。

`PUT /api/config`：无 session → 401。body 超过 `MAX_CONFIG_BYTES` → 413。
body 必须能解析成 JSON **对象**（不是数组/标量），否则 400。通过后 `save`。回 `{"ok":true}`。

`PUT /api/password` 补全（替换 Task 5 留下的简化版）——顺序至关重要：
1. 校验 `old`（失败 → 401）
2. `new` 长度 < 8 → 400
3. `old_key = derive_config_key(old, key_salt)`；`new_key = derive_config_key(new, key_salt)`
4. `config_store::reencrypt(dir, &old_key, &new_key)` —— **失败则整个操作中止并回 500，
   不得写入新密码**（否则配置将永久无法解密）
5. 写 `admin.json`（新 PHC、`is_default=false`）
6. `sessions.revoke_all()`

- [ ] **Step 2: 手动验证完整链路**

```bash
cd web-front && D=$(mktemp -d)
EJ_DATA_DIR=$D EJ_LISTEN=127.0.0.1:18996 cargo run --quiet & sleep 2
T=$(curl -s -X POST localhost:18996/api/session -H 'content-type: application/json' \
     -d '{"username":"admin","password":"admin"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
echo "未登录取配置：$(curl -s -o /dev/null -w '%{http_code}' localhost:18996/api/config)"
echo "登录后取空配置：$(curl -s -H "Authorization: Bearer $T" localhost:18996/api/config)"
curl -s -X PUT localhost:18996/api/config -H "Authorization: Bearer $T" \
  -H 'content-type: application/json' -d '{"webdavUrl":"https://dav.example.com"}' >/dev/null
echo "回读：$(curl -s -H "Authorization: Bearer $T" localhost:18996/api/config)"
echo "改密：$(curl -s -o /dev/null -w '%{http_code}' -X PUT localhost:18996/api/password \
  -H "Authorization: Bearer $T" -H 'content-type: application/json' \
  -d '{"old":"admin","new":"newpass123"}')"
echo "改密后旧token应失效：$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" localhost:18996/api/config)"
T2=$(curl -s -X POST localhost:18996/api/session -H 'content-type: application/json' \
     -d '{"username":"admin","password":"newpass123"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
echo "新密码登录后配置仍在：$(curl -s -H "Authorization: Bearer $T2" localhost:18996/api/config)"
kill %1
```
Expected: 依次为 `401`、`{}`、`{"webdavUrl":"https://dav.example.com"}`、`200`、`401`、
以及**改密后配置内容原样可读**（证明重加密成功，这是本任务最关键的一条）。

- [ ] **Step 3: Commit**

```bash
cd .. && git add -A && git commit -m "新增配置读写端点并在改密时重加密配置"
```

---

### Task 8: static_files.rs 静态托管

**Files:**
- Create: `web-front/src/static_files.rs`
- Modify: `web-front/src/main.rs`（兜底路由：未匹配任何 API/代理路径时交给它）
- Test: `web-front/src/static_files.rs` 内 `mod tests`

**Interfaces:**
- Produces:
  - `pub enum Served { File { bytes: Vec<u8>, mime: &'static str }, NotConfigured, NotFound }`
  - `pub fn serve(root: &Path, url_path: &str) -> Served`
  - `pub fn mime_for(name: &str) -> &'static str`
  - `pub const SETUP_HTML: &str` — 目录缺失/为空时返回的说明页

- [ ] **Step 1: 写失败测试**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn tmproot(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("wf-web-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn mime_table_covers_flutter_web_assets() {
        assert_eq!(mime_for("index.html"), "text/html; charset=utf-8");
        assert_eq!(mime_for("main.dart.js"), "text/javascript; charset=utf-8");
        assert_eq!(mime_for("sqlite3.wasm"), "application/wasm");
        assert_eq!(mime_for("style.css"), "text/css; charset=utf-8");
        assert_eq!(mime_for("manifest.json"), "application/json");
        assert_eq!(mime_for("icon.png"), "image/png");
        assert_eq!(mime_for("f.woff2"), "font/woff2");
        assert_eq!(mime_for("unknown.xyz"), "application/octet-stream");
    }

    #[test]
    fn empty_or_missing_root_yields_not_configured() {
        let d = tmproot("empty");
        assert!(matches!(serve(&d, "/"), Served::NotConfigured));
        assert!(matches!(serve(&d.join("nope"), "/"), Served::NotConfigured));
    }

    #[test]
    fn serves_index_at_root() {
        let d = tmproot("index");
        std::fs::write(d.join("index.html"), "<h1>hi</h1>").unwrap();
        match serve(&d, "/") {
            Served::File { bytes, mime } => {
                assert_eq!(bytes, b"<h1>hi</h1>");
                assert_eq!(mime, "text/html; charset=utf-8");
            }
            _ => panic!("根路径应返回 index.html"),
        }
    }

    #[test]
    fn unknown_path_falls_back_to_index() {
        let d = tmproot("fallback");
        std::fs::write(d.join("index.html"), "<h1>spa</h1>").unwrap();
        match serve(&d, "/deep/link") {
            Served::File { bytes, .. } => assert_eq!(bytes, b"<h1>spa</h1>"),
            _ => panic!("未命中路径应回退 index.html"),
        }
    }

    #[test]
    fn path_traversal_is_refused() {
        let d = tmproot("traverse");
        std::fs::write(d.join("index.html"), "ok").unwrap();
        let secret = d.parent().unwrap().join("wf-secret.txt");
        std::fs::write(&secret, "TOPSECRET").unwrap();
        for attack in ["/../wf-secret.txt", "/..%2fwf-secret.txt", "/a/../../wf-secret.txt"] {
            match serve(&d, attack) {
                Served::File { bytes, .. } => {
                    assert_ne!(bytes, b"TOPSECRET", "路径穿越必须被拒: {attack}");
                }
                _ => {}
            }
        }
    }

    #[test]
    fn serves_nested_asset() {
        let d = tmproot("nested");
        std::fs::create_dir_all(d.join("assets")).unwrap();
        std::fs::write(d.join("assets/a.png"), [0x89, 0x50]).unwrap();
        match serve(&d, "/assets/a.png") {
            Served::File { mime, .. } => assert_eq!(mime, "image/png"),
            _ => panic!("嵌套资源应能取到"),
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd web-front && cargo test static_files:: 2>&1 | tail -10
```
Expected: `cannot find module static_files`。

- [ ] **Step 3: 实现**

`serve`：先判 `root` 是否存在且非空（只含 `.gitkeep` 视为空）→ `NotConfigured`。
URL 先做百分号解码，再按 `/` 分段，**丢弃 `.` 与 `..` 段**（不是字符串替换，要按段过滤），
拼到 `root` 下；`canonicalize` 后必须仍以 `root` 的 canonical 路径为前缀，否则 `NotFound`。
命中文件则读出并配 MIME；未命中且 `index.html` 存在则回退 `index.html`。

`main.rs`：把静态托管放在路由链**最后**（所有 `/api/*`、`/proxy/*`、`/admin`、`/healthz`
之后），`NotConfigured` 时对 `/` 返回 `SETUP_HTML`（HTTP 200，内容说明如何提供 web 产物：
镜像内 `/web` 为空，可挂载 `EJ_WEB_ROOT` 或用带 web 产物的镜像标签）。

- [ ] **Step 4: 运行测试确认通过**

```bash
cargo test static_files:: 2>&1 | tail -12
```
Expected: 6 个测试全部 PASS。

- [ ] **Step 5: Commit**

```bash
cd .. && git add -A && git commit -m "新增静态文件托管与空目录说明页"
```

---

### Task 9: web 产物打进镜像

**Files:**
- Create: `web-front/web-dist/.gitkeep`
- Modify: `web-front/Dockerfile`
- Modify: `web-front/.dockerignore`

**Interfaces:**
- Produces: 镜像内 `/web` 目录。CI（Task 17）在 `docker build` 前把 `flutter build web` 的产物拷进 `web-front/web-dist/`。

**关键约束：** Docker 不支持可选 `COPY`。仓库里保留 `web-dist/.gitkeep` 使该目录始终存在，
于是**没有 web 产物时镜像照样能 build**，运行时由 Task 8 的说明页兜底。这条是刻意设计，
不要改成「构建前必须先跑 Flutter」。

- [ ] **Step 1: 创建占位并改 Dockerfile**

```bash
cd web-front && mkdir -p web-dist && touch web-dist/.gitkeep
```

`Dockerfile` 的 runtime 阶段，在 `COPY --from=build /ejnas /ejnas` 之后追加（注意二进制
也要随更名改为 `web-front`）：

```dockerfile
COPY --chown=65532:65532 web-dist/ /web/
```

`.dockerignore` 中**不要**排除 `web-dist/`。

- [ ] **Step 2: 构建并验证空产物场景**

```bash
DOCKER_BUILDKIT=0 docker build -q -t web-front:local . && echo BUILD_OK
D=$(mktemp -d)
docker run -d --name wf-empty -p 127.0.0.1:18997:48080 -v "$D:/data" web-front:local >/dev/null
sleep 3
curl -s localhost:18997/ | head -c 200; echo
docker rm -f wf-empty >/dev/null
```
Expected: `BUILD_OK`；`/` 返回说明页 HTML（含「web 产物」字样），**不是** 404。

- [ ] **Step 3: 验证有产物场景**

```bash
mkdir -p /tmp/wf-web && echo '<h1>web ok</h1>' > /tmp/wf-web/index.html
docker run -d --name wf-full -p 127.0.0.1:18997:48080 \
  -v /tmp/wf-web:/web:ro -v "$(mktemp -d):/data" web-front:local >/dev/null
sleep 3
curl -s localhost:18997/ ; docker rm -f wf-full >/dev/null; rm -rf /tmp/wf-web
```
Expected: 输出 `<h1>web ok</h1>`（证明 `EJ_WEB_ROOT` 默认路径可被挂载覆盖）。

- [ ] **Step 4: Commit**

```bash
cd .. && git add -A && git commit -m "web产物打进镜像并保留空目录兜底"
```

---

### Task 10: 客户端改造 — 配置载荷与 admin 客户端

**Files:**
- Rename: `lib/services/vault/vault_payload.dart` → `lib/services/vault/config_payload.dart`
- Rename: `lib/services/vault/nas_vault_client.dart` → `lib/services/vault/admin_config_client.dart`
- Delete: `lib/services/vault/settings_vault.dart`、`lib/services/vault/nas_token_store.dart`
- Modify: `lib/services/vault/nas_session_store.dart` → `admin_session_store.dart`
- Test: `test/vault/config_payload_test.dart`（由 `vault_payload_test.dart` 改名）

**Interfaces:**
- Produces:
  - `class ConfigPayload`（原 `VaultPayload`）保留 `kVaultPayloadKeys` 的等价物，改名为 `kConfigPayloadKeys`，以及 `Map<String,dynamic> toJson(AppSettings)` / `AppSettings applyTo(AppSettings, Map<String,dynamic>)`
  - `class AdminConfigClient { Future<String> login(String baseUrl, String user, String pw); Future<Map<String,dynamic>?> fetch(String baseUrl, String token); Future<void> push(String baseUrl, String token, Map<String,dynamic> cfg); }`
  - `class AdminSession { final String baseUrl; final String token; }` + `AdminSessionStore.read()/write()/clear()`

- [ ] **Step 1: 改名并删除**

```bash
cd /home/xyz/Projects/priv/explore_journal
git mv lib/services/vault/vault_payload.dart lib/services/vault/config_payload.dart
git mv lib/services/vault/nas_vault_client.dart lib/services/vault/admin_config_client.dart
git mv lib/services/vault/nas_session_store.dart lib/services/vault/admin_session_store.dart
git rm lib/services/vault/settings_vault.dart lib/services/vault/nas_token_store.dart
git mv test/vault/vault_payload_test.dart test/vault/config_payload_test.dart
git rm test/vault/nas_vault_sync_test.dart test/vault/settings_vault_test.dart
```

- [ ] **Step 2: 写契约测试（守住与服务端的字段集合一致）**

`test/vault/config_payload_test.dart` 追加：

```dart
  test('配置载荷的键集合是 secrets ∪ locators，且不含排行榜私钥', () {
    final keys = ConfigPayload.kConfigPayloadKeys;
    // 凭据与定位符都在
    expect(keys, contains('webdavUrl'));
    expect(keys, contains('webdavUser'));
    expect(keys, contains('oneDriveClientId'));
    expect(keys, contains('aiBaseUrl'));
    expect(keys, contains('leaderboardServerUrl'));
    // 排行榜身份是 per-device，绝不进配置
    expect(keys, isNot(contains('leaderboardPrivateKey')));
    expect(keys, isNot(contains('leaderboardPublicKey')));
  });

  test('toJson 只输出键集合内的字段，applyTo 能原样还原', () {
    const s = AppSettings(webdavUrl: 'https://dav.example.com', webdavUser: 'u');
    final json = ConfigPayload.toJson(s);
    expect(json.keys, everyElement(isIn(ConfigPayload.kConfigPayloadKeys)));
    final back = ConfigPayload.applyTo(const AppSettings(), json);
    expect(back.webdavUrl, 'https://dav.example.com');
    expect(back.webdavUser, 'u');
  });
```

- [ ] **Step 3: 运行测试确认失败**

```bash
flutter test test/vault/config_payload_test.dart 2>&1 | tail -12
```
Expected: 编译失败（`ConfigPayload` 未定义 / `kConfigPayloadKeys` 未定义）。

- [ ] **Step 4: 实现改名与新客户端**

`config_payload.dart`：类名 `VaultPayload` → `ConfigPayload`，`kVaultPayloadKeys` →
`kConfigPayloadKeys`，删掉与客户端加密（`settings_vault`）相关的 import 与方法，
保留 `locatorKeys` 与 `kVaultSecretKeys` 的并集逻辑不变。

`admin_config_client.dart`：删除所有口令派生/信封解析代码，改为三个方法：
`login` 打 `POST /api/session` 取 `token`；`fetch` 带 `Authorization: Bearer` 打
`GET /api/config`，`{}` 视为「尚无配置」返回 `null`；`push` 打 `PUT /api/config`。
401 统一抛 `NasAuthException(401)`（该异常类型已被 `session_restore_test.dart` 使用，
保持名称不变以免测试连带改动）。

`admin_session_store.dart`：`NasWebSession` 精简为 `AdminSession { baseUrl, token }`
（去掉 email 与 vaultVersion 字段），读写键名保持 `ej_nas_session` 不变以复用现有
`session_restore_test.dart` 的持久化断言。

- [ ] **Step 5: 运行测试确认通过**

```bash
flutter test test/vault/ 2>&1 | tail -12
```
Expected: `config_payload_test.dart` 全绿；`session_restore_test.dart` 若因字段精简失败，
同步更新其断言（**只改断言，不要为迁就测试把字段加回来**）。

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "客户端改造：配置载荷与admin配置客户端"
```

---

### Task 11: 客户端改造 — admin 登录页与同步控制器

**Files:**
- Modify: `lib/ui/auth/login_screen.dart`
- Modify: `lib/services/vault/auth_controller.dart`
- Rename: `lib/services/vault/vault_sync_controller.dart` → `config_sync_controller.dart`
- Modify: `lib/main.dart`（路由与门禁）
- Test: `test/vault/session_restore_test.dart`

**Interfaces:**
- Consumes: `AdminConfigClient`、`AdminSessionStore`、`ConfigPayload`（Task 10）
- Produces: `ConfigSyncController` with `Future<bool> restoreSession()`、`Future<void> login(String baseUrl, String user, String pw)`、`Future<void> pushCurrentSettings()`、`Future<bool> pullIntoSettings()`

- [ ] **Step 1: 改造登录页**

`login_screen.dart`：三个输入框——服务器地址（默认 `http://localhost:48080`）、
用户名（默认 `admin`）、密码。删除：邮箱输入、口令强度提示、「注册并同步」按钮、
所有关于「口令即加密密钥、丢失不可恢复」的文案。改为单个「登录」按钮。
登录成功后若服务端返回 `is_default_password: true`，在页面顶部显示一条持续可见的
提醒：「仍在使用默认密码 admin/admin，请尽快在管理看板中修改」。

- [ ] **Step 2: 改造控制器**

`auth_controller.dart`：删除注册流程与口令派生；只保留 `login` / `logout` / 会话恢复。
`config_sync_controller.dart`（原 `vault_sync_controller.dart`）：
`restoreSession` 从 `AdminSessionStore` 读 token → 打 `GET /api/config` 验活；401 则清会话返回 `false`。
`pullIntoSettings` 拉配置并 `ConfigPayload.applyTo` 到内存设置。
`pushCurrentSettings` 把当前设置 `toJson` 后 `push`（手机端调用）。

- [ ] **Step 3: 更新 main.dart 门禁**

web 端（`kIsWeb`）未登录时重定向到 `/login`；登录后自动 `pullIntoSettings`。
原生端不设门禁（`if (!kIsWeb) return null` 的既有逻辑保留）。

- [ ] **Step 4: 运行全部 Dart 测试**

```bash
flutter test test/vault/ 2>&1 | tail -15
```
Expected: 全绿。`session_restore_test.dart` 中涉及 email / vaultVersion 的断言按新结构改写；
`http://localhost:48082` 一类的 fixture 改为 `48080`。

- [ ] **Step 5: 静态分析**

```bash
flutter analyze lib/services/vault lib/ui/auth lib/main.dart 2>&1 | tail -8
```
Expected: 无 error（warning 若来自既有代码可暂留）。

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "客户端改造：admin登录页与配置同步控制器"
```

---

## 阶段③ 看板与导出

### Task 12: metrics.rs 指标采集与落盘

**Files:**
- Create: `web-front/src/metrics.rs`
- Modify: `web-front/src/main.rs`（`mod metrics;`、`AppState.metrics`、每个响应出口调用 `record`）
- Test: `web-front/src/metrics.rs` 内 `mod tests`

**Interfaces:**
- Produces:
  - `pub struct Metrics`；`pub fn new(dir: PathBuf) -> Metrics`；`pub fn load_or_new(dir: PathBuf) -> Metrics`
  - `pub fn record(&self, route: &str, status: u16, bytes_out: u64)`
  - `pub fn record_login_failure(&self)`
  - `pub fn snapshot_json(&self, uptime_secs: u64, rss_mb: u64) -> serde_json::Value`
  - `pub fn take_sample(&self)` — 向环形缓冲追加一点，**上限 1440 点**（1 分钟采样 × 24 小时）
  - `pub fn persist(&self) -> Result<(), String>`
- 路由归一化：把 `/proxy/gh/owner/repo/...` 归到 `"/proxy/gh"`、`/proxy/dav/...` 归到 `"/proxy/dav"`，避免路径基数爆炸。

- [ ] **Step 1: 写失败测试**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("wf-metrics-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn counts_group_by_route_and_status_class() {
        let m = Metrics::new(tmpdir("count"));
        m.record("/api/config", 200, 100);
        m.record("/api/config", 200, 100);
        m.record("/api/config", 401, 0);
        m.record("/healthz", 200, 2);
        let s = m.snapshot_json(10, 50);
        let routes = &s["routes"];
        assert_eq!(routes["/api/config"]["total"], 3);
        assert_eq!(routes["/api/config"]["ok"], 2);
        assert_eq!(routes["/api/config"]["client_err"], 1);
        assert_eq!(routes["/healthz"]["total"], 1);
        assert_eq!(s["bytes_out"], 202);
    }

    #[test]
    fn proxy_routes_are_normalised() {
        let m = Metrics::new(tmpdir("norm"));
        m.record("/proxy/gh/o/r/main/a.png", 200, 10);
        m.record("/proxy/gh/o/r/main/b.png", 200, 10);
        m.record("/proxy/dav/Sync/x.zip", 200, 10);
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["routes"]["/proxy/gh"]["total"], 2, "同类代理路径必须归并");
        assert_eq!(s["routes"]["/proxy/dav"]["total"], 1);
        assert!(s["routes"].get("/proxy/gh/o/r/main/a.png").is_none());
    }

    #[test]
    fn login_failures_are_counted_separately() {
        let m = Metrics::new(tmpdir("login"));
        m.record_login_failure();
        m.record_login_failure();
        assert_eq!(m.snapshot_json(1, 1)["login_failures"], 2);
    }

    #[test]
    fn ring_buffer_is_capped() {
        let m = Metrics::new(tmpdir("ring"));
        for _ in 0..1500 {
            m.take_sample();
        }
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["samples"].as_array().unwrap().len(), 1440, "采样点上限必须是 1440");
    }

    #[test]
    fn persist_then_load_keeps_totals() {
        let d = tmpdir("persist");
        let m = Metrics::new(d.clone());
        m.record("/healthz", 200, 5);
        m.take_sample();
        m.persist().unwrap();
        let m2 = Metrics::load_or_new(d);
        let s = m2.snapshot_json(1, 1);
        assert_eq!(s["routes"]["/healthz"]["total"], 1, "重启后累计值应从磁盘恢复");
        assert_eq!(s["samples"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn corrupt_metrics_file_does_not_crash() {
        let d = tmpdir("corrupt");
        std::fs::write(d.join("metrics.json"), "{not json").unwrap();
        let m = Metrics::load_or_new(d);
        assert_eq!(m.snapshot_json(1, 1)["bytes_out"], 0, "损坏的指标文件应静默重置，而不是 panic");
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd web-front && cargo test metrics:: 2>&1 | tail -10
```
Expected: `cannot find module metrics`。

- [ ] **Step 3: 实现**

内部 `Mutex<Inner>`，`Inner { routes: BTreeMap<String, RouteStat>, bytes_out: u64, login_failures: u64, samples: VecDeque<Sample> }`。
`RouteStat { total, ok, client_err, server_err }`（按状态码 2xx/4xx/5xx 归类，3xx 计入 `ok`）。
`normalise_route`：以 `/proxy/gh`、`/proxy/dav`、`/proxy/url` 前缀开头的一律截断到前缀；其余原样。
`take_sample` 用 `VecDeque::push_back` + 超过 1440 则 `pop_front`。
`persist` 序列化 `Inner` 写 `metrics.json.tmp` 再 `rename`。`load_or_new` 解析失败则返回空实例（不 panic）。
`main.rs`：启动一个后台线程，每 60 秒 `take_sample()` + `persist()`；在响应发出前统一调用 `record`。

- [ ] **Step 4: 运行测试确认通过**

```bash
cargo test metrics:: 2>&1 | tail -12
```
Expected: 6 个测试全部 PASS。

- [ ] **Step 5: Commit**

```bash
cd .. && git add -A && git commit -m "新增指标采集环形缓冲与落盘"
```

---

### Task 13: 看板页面与 /api/metrics

**Files:**
- Create: `web-front/assets/dashboard.html`
- Create: `web-front/src/dashboard.rs`
- Modify: `web-front/src/main.rs`（路由 `/admin`、`/api/metrics`）

**Interfaces:**
- Consumes: `Metrics::snapshot_json`、`Sessions`、`AdminFile.is_default`
- Produces: `GET /admin`（HTML，**不需要** session——页面自身负责跳登录）、`GET /api/metrics`（需 session）

- [ ] **Step 1: 写看板页面**

`assets/dashboard.html`：单文件，内联 `<style>` 与 `<script>`，深色（背景 `#0f1115`、
文字 `#e6e6e6`、强调色 `#4db6ac`）。零外部请求。包含：
- 未登录时显示登录表单（用户名/密码）→ `POST /api/session`
- 默认密码横幅：当 `/api/session` 或 `/api/metrics` 返回 `is_default_password: true` 时，
  顶部固定一条醒目提示，附「修改密码」表单（`PUT /api/password`）
- 状态卡片：uptime、RSS、请求总数、错误数、代理出流量、登录失败数
- 路由表格：每行 route / total / ok / 4xx / 5xx
- 一条内联 SVG 折线：用 `samples` 画请求速率，**不引任何图表库**
- 导出按钮三个：配置（脱敏）、配置（含凭据，点击前 `confirm()` 二次确认）、指标 CSV
- 每 10 秒轮询 `/api/metrics` 刷新

- [ ] **Step 2: 实现 dashboard.rs**

```rust
pub const DASHBOARD_HTML: &str = include_str!("../assets/dashboard.html");
```
`main.rs`：`GET /admin` 回 `DASHBOARD_HTML`（`text/html; charset=utf-8`）；
`GET /api/metrics` 需 session，回 `metrics.snapshot_json(uptime, rss_mb)`，并附
`"is_default_password": <admin.is_default>`。RSS 从 `/proc/self/statm` 读（distroless 有 `/proc`）。

- [ ] **Step 3: 手动验证**

```bash
cd web-front && D=$(mktemp -d)
EJ_DATA_DIR=$D EJ_LISTEN=127.0.0.1:18998 cargo run --quiet & sleep 2
echo "看板可取: $(curl -s -o /dev/null -w '%{http_code}' localhost:18998/admin)"
echo "未登录取指标: $(curl -s -o /dev/null -w '%{http_code}' localhost:18998/api/metrics)"
T=$(curl -s -X POST localhost:18998/api/session -H 'content-type: application/json' \
     -d '{"username":"admin","password":"admin"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s -H "Authorization: Bearer $T" localhost:18998/api/metrics \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('默认密码标记:', d['is_default_password']); print('路由数:', len(d['routes']))"
kill %1
```
Expected: `/admin` → 200；未登录取指标 → 401；登录后 `is_default_password: True`、路由数 ≥ 1。

- [ ] **Step 4: 确认看板无外部依赖**

```bash
grep -ncE "https?://|src=|href=.*//" assets/dashboard.html
```
Expected: `0`（除了可能的注释；任何指向外部主机的 `src`/`href` 都必须移除，CSP 与离线可用性依赖这点）。

- [ ] **Step 5: Commit**

```bash
cd .. && git add -A && git commit -m "新增管理看板页面与指标接口"
```

---

### Task 14: /api/export 导出

**Files:**
- Modify: `web-front/src/dashboard.rs`（导出处理）
- Modify: `web-front/src/main.rs`（路由）

**Interfaces:**
- Produces: `GET /api/export?what=config|metrics|all&secrets=0|1`（需 session）
  - `what=config`：`application/json`，`Content-Disposition: attachment; filename="web-front-config.json"`
  - `what=metrics`：`text/csv`，表头 `ts,requests,errors,bytes_out`
  - `what=all`：JSON，`{config, metrics}` 两个字段
  - `secrets` 默认 `0`；为 `0` 时凭据字段值替换为 `null`

- [ ] **Step 1: 实现**

凭据字段名单从一处常量取（与客户端 `kVaultSecretKeys` 对应），在 `dashboard.rs` 里定义
`const SECRET_KEYS: &[&str]`，脱敏时遍历该名单置 `null`。**默认脱敏**：缺省或非法的
`secrets` 参数都按 `0` 处理，只有精确等于 `"1"` 才输出凭据。

- [ ] **Step 2: 手动验证脱敏与含密两种模式**

```bash
cd web-front && D=$(mktemp -d)
EJ_DATA_DIR=$D EJ_LISTEN=127.0.0.1:18999 cargo run --quiet & sleep 2
T=$(curl -s -X POST localhost:18999/api/session -H 'content-type: application/json' \
     -d '{"username":"admin","password":"admin"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s -X PUT localhost:18999/api/config -H "Authorization: Bearer $T" \
  -H 'content-type: application/json' \
  -d '{"webdavUrl":"https://dav.example.com","webdavPassword":"SECRET123"}' >/dev/null
echo "默认(脱敏): $(curl -s -H "Authorization: Bearer $T" 'localhost:18999/api/export?what=config')"
echo "显式含密:   $(curl -s -H "Authorization: Bearer $T" 'localhost:18999/api/export?what=config&secrets=1')"
echo "非法值按脱敏: $(curl -s -H "Authorization: Bearer $T" 'localhost:18999/api/export?what=config&secrets=yes')"
echo "指标CSV头: $(curl -s -H "Authorization: Bearer $T" 'localhost:18999/api/export?what=metrics' | head -1)"
kill %1
```
Expected: 第一行与第三行的 `webdavPassword` 为 `null`、`webdavUrl` 保留；第二行含 `SECRET123`；
CSV 首行为 `ts,requests,errors,bytes_out`。

- [ ] **Step 3: Commit**

```bash
cd .. && git add -A && git commit -m "新增配置与指标导出接口"
```

---

## 阶段④ WebDAV 代理

### Task 15: dav.rs

**Files:**
- Create: `web-front/src/dav.rs`
- Modify: `web-front/src/main.rs`（路由 `/proxy/dav/*`，需放在静态托管之前）
- Test: `web-front/src/dav.rs` 内 `mod tests`

**Interfaces:**
- Consumes: `proxy::is_safe_ip` 与受限解析器、`config_store::load`、`Sessions::get_key`
- Produces:
  - `pub fn resolve_target(base: &str, rest: &str) -> Result<String, &'static str>` — 纯函数，便于测试
  - `pub const ALLOWED_METHODS: &[&str] = &["PROPFIND", "GET", "HEAD", "OPTIONS"];`
  - `pub fn handle(...) -> Out`

- [ ] **Step 1: 写失败测试（重点是前缀限制这条安全边界）**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "https://dav.example.com/remote.php/dav/files/me";

    #[test]
    fn joins_relative_path_under_base() {
        assert_eq!(
            resolve_target(BASE, "Sync/fow/a.png").unwrap(),
            format!("{BASE}/Sync/fow/a.png")
        );
    }

    #[test]
    fn tolerates_leading_slash_and_double_slash() {
        assert_eq!(resolve_target(BASE, "/Sync/a").unwrap(), format!("{BASE}/Sync/a"));
        assert_eq!(resolve_target("https://d.example.com/dav/", "x").unwrap(),
                   "https://d.example.com/dav/x");
    }

    #[test]
    fn refuses_escaping_the_base_prefix() {
        for bad in ["../../etc", "..%2f..%2fetc", "/../outside", "a/../../../outside"] {
            assert!(resolve_target(BASE, bad).is_err(), "必须拒绝越出 base 的路径: {bad}");
        }
    }

    #[test]
    fn refuses_absolute_url_injection() {
        for bad in [
            "https://evil.example.com/x",
            "http://evil.example.com/x",
            "//evil.example.com/x",
        ] {
            assert!(resolve_target(BASE, bad).is_err(), "必须拒绝绝对 URL 注入: {bad}");
        }
    }

    #[test]
    fn result_always_starts_with_base() {
        for ok in ["a", "a/b/c", "%E4%B8%AD%E6%96%87/x"] {
            let t = resolve_target(BASE, ok).unwrap();
            assert!(t.starts_with(BASE), "结果必须落在 base 前缀内: {t}");
        }
    }

    #[test]
    fn method_whitelist_excludes_writes() {
        for m in ["PUT", "DELETE", "MKCOL", "MOVE", "COPY", "POST", "PROPPATCH"] {
            assert!(!ALLOWED_METHODS.contains(&m), "{m} 不应被允许（本代理只读）");
        }
        for m in ["PROPFIND", "GET", "HEAD", "OPTIONS"] {
            assert!(ALLOWED_METHODS.contains(&m));
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd web-front && cargo test dav:: 2>&1 | tail -10
```
Expected: `cannot find module dav`。

- [ ] **Step 3: 实现**

`resolve_target`：先拒绝含 `://` 或以 `//` 开头的 `rest`（绝对 URL 注入）；百分号解码后
按 `/` 分段过滤掉 `.` 与 `..`（**按段过滤，不是字符串替换**）；重新编码每段后拼到
`base` 之后（`base` 去掉尾部 `/`）；最后断言结果 `starts_with(base)`，否则 `Err`。

`handle`：
1. 校验 session（无效 → 401）
2. 方法不在 `ALLOWED_METHODS` → 405
3. 从 `config_store::load` 取 `webdavUrl/User/Password`；未配置 → 409 并提示「先推送配置」
4. `resolve_target` → 失败 403
5. 用 `proxy.rs` 的受限 agent 发起请求，注入 `Authorization: Basic base64(user:pass)`，
   转发 `Depth`（PROPFIND）与 `Range`（GET），回传 `Content-Type`/`Content-Length`/
   `Content-Range`/`Accept-Ranges`/`ETag`
6. 响应体上限 `MAX_PROXY_BYTES`
7. **不得**把上游的 `WWW-Authenticate` 回传给浏览器（避免浏览器弹原生认证框）

- [ ] **Step 4: 运行测试确认通过**

```bash
cargo test dav:: 2>&1 | tail -12
```
Expected: 6 个测试全部 PASS。

- [ ] **Step 5: 验证未配置与未登录时的行为**

```bash
cd web-front && D=$(mktemp -d)
EJ_DATA_DIR=$D EJ_LISTEN=127.0.0.1:19000 cargo run --quiet & sleep 2
echo "未登录: $(curl -s -o /dev/null -w '%{http_code}' -X PROPFIND localhost:19000/proxy/dav/x)"
T=$(curl -s -X POST localhost:19000/api/session -H 'content-type: application/json' \
     -d '{"username":"admin","password":"admin"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
echo "未配置WebDAV: $(curl -s -o /dev/null -w '%{http_code}' -X PROPFIND -H "Authorization: Bearer $T" localhost:19000/proxy/dav/x)"
echo "写方法被拒: $(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $T" localhost:19000/proxy/dav/x)"
kill %1
```
Expected: `401`、`409`、`405`。

- [ ] **Step 6: Commit**

```bash
cd .. && git add -A && git commit -m "新增WebDAV只读代理与目标前缀限制"
```

---

## 阶段⑤ CI 与模块开关

> 本阶段与 ①–④ 无依赖，可提前或并行执行。

### Task 16: backends 模块开关

**Files:**
- Modify: `backends/server/server.js`
- Create: `backends/test/modules.test.js`
- Modify: `backends/README.md`（配置项表）

**Interfaces:**
- Produces: `EJ_MODULE_LEADERBOARD` / `EJ_MODULE_GROUP`（默认 `1`）；两者都关时进程以非零码退出

- [ ] **Step 1: 写失败测试**

```javascript
'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const path = require('node:path');

function start(env) {
  return spawn(process.execPath, [path.join(__dirname, '..', 'server', 'server.js')], {
    env: { ...process.env, PORT: '0', DATA_DIR: require('node:fs').mkdtempSync('/tmp/ejmod-'), ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

test('两个模块都关闭时启动失败并说明原因', async () => {
  const p = start({ EJ_MODULE_LEADERBOARD: '0', EJ_MODULE_GROUP: '0' });
  let err = '';
  p.stderr.on('data', (d) => { err += d; });
  const code = await new Promise((r) => p.on('exit', r));
  assert.notStrictEqual(code, 0, '应以非零码退出');
  assert.match(err, /module/i, '错误信息应说明是模块配置问题');
});

test('只开排行榜时 /entries 可用而 WS 升级被拒', async () => {
  const p = start({ EJ_MODULE_GROUP: '0', PORT: '19101' });
  await new Promise((r) => setTimeout(r, 700));
  const res = await fetch('http://127.0.0.1:19101/entries');
  assert.strictEqual(res.status, 200);
  const status = await (await fetch('http://127.0.0.1:19101/api/status')).json();
  assert.ok(status.modules.leaderboard, '排行榜模块应在 status 中');
  assert.ok(!status.modules.group, '关闭的组队模块不应出现在 status 中');
  p.kill();
});

test('只开组队时 /entries 返回 404', async () => {
  const p = start({ EJ_MODULE_LEADERBOARD: '0', PORT: '19102' });
  await new Promise((r) => setTimeout(r, 700));
  assert.strictEqual((await fetch('http://127.0.0.1:19102/entries')).status, 404);
  assert.strictEqual((await fetch('http://127.0.0.1:19102/group/v1/info')).status, 200);
  p.kill();
});
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd backends && node --test test/modules.test.js 2>&1 | tail -12
```
Expected: 失败——当前无论环境变量如何两个模块都注册。

- [ ] **Step 3: 实现**

`server.js`：`cfg` 增加 `moduleLeaderboard: process.env.EJ_MODULE_LEADERBOARD !== '0'`、
`moduleGroup: process.env.EJ_MODULE_GROUP !== '0'`。`MODULES` 数组按开关条件构建：

```js
const MODULES = [
  cfg.moduleLeaderboard ? require('./modules/leaderboard')(cfg) : null,
  cfg.moduleGroup ? require('./modules/group')(cfg) : null,
].filter(Boolean);

if (MODULES.length === 0) {
  log.error('main', '两个模块都被关闭了（EJ_MODULE_LEADERBOARD / EJ_MODULE_GROUP），没有可提供的服务');
  process.exit(2);
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
node --test test/modules.test.js 2>&1 | tail -8 && npm test 2>&1 | tail -6
```
Expected: 新测试 3 个 PASS，且原有 22 个测试仍全绿。

- [ ] **Step 5: Commit**

```bash
cd .. && git add -A && git commit -m "backends支持按模块开关部署"
```

---

### Task 17: composite action + web-front 镜像流水线

**Files:**
- Create: `.github/actions/publish-image/action.yml`
- Modify: `.github/workflows/web-front.yml`（加 Flutter web 构建、改用 composite）
- Modify: `.github/workflows/backend.yml`（改用 composite）
- Delete: `.github/workflows/deploy-web.yml`

**Interfaces:**
- Produces: composite action 的 inputs `image`、`context`、`platforms`、`push`；outputs `tags`、`digest`

- [ ] **Step 1: 写 composite action**

`inputs`: `image`（必填）、`context`（必填）、`platforms`（默认 `linux/amd64,linux/arm64`）、
`push`（默认 `true`）、`cache-scope`（必填）。
`runs.using: composite`，`steps` 依次为 `setup-qemu-action@v3`（platforms: arm64）、
`setup-buildx-action@v3`、`login-action@v3`（ghcr.io，`github.actor` + `github.token`）、
`metadata-action@v5`（tags: `type=raw,value=latest,enable={{is_default_branch}}` 与
`type=sha,prefix=sha-`）、`build-push-action@v6`。
`outputs`: `tags: ${{ steps.meta.outputs.tags }}`、`digest: ${{ steps.push.outputs.digest }}`。

- [ ] **Step 2: 改造 web-front.yml**

`paths` 增加 Flutter 侧触发源（因为 web 产物现在进镜像）：
`web-front/**`、`lib/**`、`web/**`、`pubspec.yaml`、`pubspec.lock`、`.github/workflows/web-front.yml`。

在 `cargo test` 之后、镜像构建之前插入：

```yaml
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - name: 构建 Flutter web 产物
        run: |
          flutter pub get
          flutter build web --release
          rm -rf web-front/web-dist && mkdir -p web-front/web-dist
          cp -r build/web/. web-front/web-dist/
          echo "产物大小：$(du -sh web-front/web-dist | cut -f1)"
```

Flutter 只构建一次，两个架构共用（纯静态资源与架构无关）。随后 smoke 与推送步骤改为调用
composite action。

- [ ] **Step 3: 删除 deploy-web.yml 并改造 backend.yml**

```bash
git rm .github/workflows/deploy-web.yml
```
`backend.yml` 把 QEMU/buildx/login/meta/push 五步替换为一次 composite 调用，保留
`npm test`、`./scripts/docker-e2e.sh`、以及它自己的摘要步骤。

- [ ] **Step 4: 本地校验所有 workflow 与 action 的 YAML**

```bash
cd /home/xyz/Projects/priv/explore_journal
python3 -c "
import yaml,glob,sys
for f in sorted(glob.glob('.github/workflows/*.yml')) + ['.github/actions/publish-image/action.yml']:
    d=yaml.safe_load(open(f)); print(f'{f}: OK')
assert not glob.glob('.github/workflows/deploy-web.yml'), 'deploy-web.yml 应已删除'
print('workflow 总数:', len(glob.glob('.github/workflows/*.yml')))
"
```
Expected: 全部 `OK`，workflow 总数为 `3`（web-front / backend / release）。

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "CI整理：抽取镜像发布composite并把web构建并入web-front流水线"
```

---

### Task 18: 扩展容器级 smoke 覆盖新链路

**Files:**
- Modify: `web-front/scripts/docker-smoke.sh`

**Interfaces:**
- Consumes: 镜像 `web-front:smoke-*`
- Produces: 覆盖登录/改密/配置往返/未授权/导出/静态托管/重启持久化的容器级验证，amd64 与 arm64 都跑

- [ ] **Step 1: 重写断言集**

删除原有针对 `/auth/register`、`/vault`、`EJ_ALLOW_REGISTRATION` 的断言，改为：

1. `/healthz` → `{"status":"ok"}`
2. 默认密码 `admin`/`admin` 登录成功，响应含 `"is_default_password":true`
3. 未登录访问 `/api/config`、`/api/metrics`、`/api/export`、`/proxy/dav/x` → 全部 401
4. `PUT /api/config` 推入 `{"webdavUrl":"https://dav.example.com","webdavPassword":"S3CRET"}` → `GET` 回读字节一致
5. `GET /api/export?what=config` 中 `webdavPassword` 为 `null`；`&secrets=1` 时含 `S3CRET`
6. 改密为 `newpass123` → 旧 token 401 → 新密码登录后**配置内容仍可读**（验证重加密）
7. `/admin` 返回 200 且响应体含 `<!doctype html` 或 `<html`
8. 静态托管：容器内 `/web` 为空时 `/` 返回说明页（HTTP 200，含「web」字样），不是 404
9. `docker restart` 后：需重新登录（旧 token 失效），登录后配置仍在
10. `PROPFIND /proxy/dav/x` 在未配置 WebDAV 时 → 409；`PUT` 方法 → 405
11. `LEVEL=boot` 时只跑 1、2 两项与架构核对（供快速探测新架构用）

架构核对（`PLATFORM` 非空时）沿用现有实现：`docker inspect --format '{{.Architecture}}'`
必须等于 `${PLATFORM##*/}`。

- [ ] **Step 2: 本地跑一遍（amd64）**

```bash
cd web-front && BUILD=1 ./scripts/docker-smoke.sh 2>&1 | tail -25
```
Expected: 全部断言通过，末行 `ALL SMOKE CHECKS PASSED`。

- [ ] **Step 3: Commit**

```bash
cd .. && git add -A && git commit -m "smoke脚本覆盖admin登录配置往返与静态托管"
```

---

## 阶段⑥ 文档同步

### Task 19: 全部用户可见文档

**Files:**
- Modify: `README.md`、`README.zh.md`、`web-front/README.md`、`backends/README.md`
- Modify: `docs/web-display-deploy.md`（整篇重写）、`docs/self-host-server-deploy.md`、`docs/self-host-client-config.md`、`docs/onedrive_setup.md`
- Modify: `.github/workflows/web-front.yml`、`backend.yml`（摘要段）
- Modify: `lib/ui/about/about_screen.dart`（若新增文档则追加 `_kDocs` 行）、`pubspec.yaml`（同步 assets）

**Interfaces:**
- Consumes: 前 18 个任务的最终行为
- Produces: 一套自洽的部署文档；照文档从零可部署成功

- [ ] **Step 1: 两个 README 的服务清单改为两个镜像**

根 `README.md` / `README.zh.md`：架构说明改为「两个镜像」——`web-front`（48080，看数据 +
管理面）与 `ej-backend`（48081，排行榜 + 组队），各给一条 `docker compose up -d`。
明确写出**端口 48080/48081，禁用 80/443/8080 的原因**（家宽封禁入方向）。

- [ ] **Step 2: 重写 web-front/README.md**

覆盖：单 admin（默认 admin/admin 及**必须尽快改**）、配置存储与加密（含「忘记密码则配置
需从手机端重推」）、看板与导出、WebDAV 代理（只读、凭据不下发浏览器）、静态托管
（镜像自带产物；`EJ_WEB_ROOT` 可覆盖）、环境变量全表、`BUILD=1 ./scripts/docker-smoke.sh`
自检方式。

- [ ] **Step 3: backends/README.md 补模块开关**

配置项表加 `EJ_MODULE_LEADERBOARD` / `EJ_MODULE_GROUP`，并给出「只跑排行榜」「只跑组队」
两个 compose 片段示例。

- [ ] **Step 4: 整篇重写 docs/web-display-deploy.md**

**删除**：注册账号、口令派生、`EJ_CORS_ORIGINS` 排错、48082 静态服务、CORS 日志排查
（这些概念本次全部消失）。**改为**：拉镜像 → `compose up` → 浏览器开 48080 → admin 登录 →
手机端推配置 → 改默认密码。保留并更新「容易踩的点」：端口封禁、数据别放网络盘、
安全上下文（`crypto.subtle` 需 localhost 或 https）、**Azure 重定向 URI 从 48082 改到 48080**。

- [ ] **Step 5: 更新其余三篇 docs**

`self-host-server-deploy.md`：补 `web-front` 部署；排行榜/组队部分补模块开关。
`self-host-client-config.md`：客户端侧从「注册账号」改为「admin 登录 + 推送配置」。
`onedrive_setup.md`：重定向 URI 端口 48082 → 48080（全篇）。
`leaderboard-server-api.md`：**不动**（公开协议未变）。

- [ ] **Step 6: 更新两条 workflow 的运行摘要**

`web-front.yml` 摘要：镜像地址与标签、验证项、NAS 一键部署（内联 `docker-compose.ghcr.yml`
的实际内容）、admin 默认密码提醒、Azure 重定向 URI 提醒。
`backend.yml` 摘要：补模块开关的分开部署示例。
两者的镜像可见性说明沿用已修正的版本（**包随公开仓库公开、无需 docker login**，
仅在报 `denied` 时才需处理）。

- [ ] **Step 7: 若新增文档则同步 APP 内清单**

若本次新增了 `docs/` 下的新文件（例如 `docs/web-front-deploy.md`），必须**同时**：
在 `lib/ui/about/about_screen.dart` 的 `_kDocs` 追加一行（path/title/summary），
并在 `pubspec.yaml` 的 `assets` 声明该文件。否则 APP 内打不开——该文件注释已写明此约定。
若只是改现有文档内容，则无需改这两处。

- [ ] **Step 8: 一致性校验**

```bash
cd /home/xyz/Projects/priv/explore_journal
echo "--- 不应再出现的旧概念 ---"
grep -rn "EJ_CORS_ORIGINS\|EJ_ALLOW_REGISTRATION\|EJ_JWT_SECRET\|EJ_DB_PATH\|48082\|注册并同步\|零知识保险箱" \
  README.md README.zh.md web-front/README.md backends/README.md docs/*.md .github/workflows/*.yml \
  | grep -v "^docs/superpowers/" || echo "  ✔ 无残留"
echo "--- APP 内文档清单与实际文件对齐 ---"
python3 -c "
import re,os
src=open('lib/ui/about/about_screen.dart').read()
paths=re.findall(r\"path: '([^']+)'\", src)
missing=[p for p in paths if not os.path.exists(p)]
print('  _kDocs 引用:', paths)
assert not missing, f'引用了不存在的文档: {missing}'
pub=open('pubspec.yaml').read()
notdecl=[p for p in paths if p not in pub]
assert not notdecl, f'未在 pubspec.yaml 声明: {notdecl}'
print('  ✔ 全部存在且已声明')
"
```
Expected: 两项均通过。

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "文档同步：两个镜像的部署与使用说明"
```

---

## Self-Review 结果

**Spec 覆盖核对**（逐条对照 spec 章节）

| spec 章节 | 对应任务 |
|---|---|
| 单 admin 认证 | Task 3、4、5 |
| 配置存储与加密（含域分离） | Task 3（派生）、Task 6（信封）、Task 7（端点与重加密） |
| 谁能写配置（三条路径） | Task 7（手机推送 + 导入同一端点）、Task 13（看板导入 UI） |
| WebDAV 代理 | Task 15 |
| 看板与指标 | Task 12、13 |
| 导出 | Task 14 |
| 静态托管 | Task 8、9 |
| backends 模块开关 | Task 16 |
| CI 整理 | Task 17 |
| 环境变量增删 | Task 5（config.rs 与 compose） |
| 更名引用点 | Task 1 |
| 文档同步范围 | Task 19 |
| 客户端删除与改造 | Task 10、11 |
| 测试策略 | 各任务内的单测 + Task 18 容器级 |
| 迁移（无需工具） | Task 19 文档说明；行为上由 Task 7 的 `PUT /api/config` 承载 |

无遗漏项。

**命名一致性核对**：`derive_config_key`、`hash_password`、`verify_password`、`new_token`、
`new_salt_b64`（Task 3 定义）在 Task 4/5/7 中引用一致；`config_store::{save,load,reencrypt}`
（Task 6 定义）在 Task 7/15 中引用一致；`Sessions::{create,get_key,revoke_all,len}`
（Task 5 定义）在 Task 7/13/14/15 中引用一致；`ConfigPayload.kConfigPayloadKeys`
（Task 10 定义）在 Task 11 与 Task 14 的 `SECRET_KEYS` 对应关系已说明。

**已知的跨任务依赖**：Task 5 交付的 `PUT /api/password` 是简化版（不含重加密），
Task 7 Step 1 第三项将其补全。这一点在两个任务里都已显式标注，执行时不要漏。

