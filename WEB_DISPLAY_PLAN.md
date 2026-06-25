# explore_journal Web 展示功能 — 最终实施方案

> 受众：项目所有者。本文档已将所有对抗性审查（grounding/security/gap）与集成发现折叠进设计本身——下面写的就是修正后的现实，不是各组件设计的原始措辞。凡是审查推翻了某个断言之处，本文采用更正后的事实。

---

## 1. 目标与定位

为 explore_journal 增加一个**只读 Web "回忆模式"**：用户在浏览器打开一个由自己 NAS 提供的 Flutter Web 构建，登录后看到自己的足迹地图、日记、照片与雾层，数据与原生端**逐字节一致地渲染**（fog 渲染规则不变，不触碰 `fog_layer.dart`）。配套地，把同步层抽象为可换后端的 `SyncStorage`，把所有凭证收进一个**零知识加密保险库**（NAS 只存密文、永不能解密），并让移动端在登录/改设置/手动同步时把保险库推上 NAS。Web 端绝不持有任何明文密钥或 PAT；CORS 受限的私有资源一律经由 NAS 同源代理。

---

## 2. 架构总览

```
                          ┌──────────────────────────── 用户的 NAS (Docker) ────────────────────────────┐
                          │  Go 单二进制 (chi + modernc.org/sqlite, CGO=0)                                │
                          │                                                                               │
  ┌───────────────┐  HTTPS │  POST /auth/register|login   (收 authVerifier, 绝不收明文口令/vaultKey)        │
  │ Flutter Web    │◄──────┤  GET  /auth/salt             (枚举抗性, 统一响应)                              │
  │ (只读 回忆模式) │       │  GET|PUT /vault              (不透明密文 blob + ETag/If-Match CAS)             │
  │  - 同源加载    │       │  GET|OPTIONS /proxy/gh/{o}/{r}/{br}/{path}   (私有 GitHub 图, PAT 在服务端)     │
  │  - localStorage │       │  GET|OPTIONS /proxy/url?u=…  (CORS-less 主机, 凭证服务端, 硬 host 白名单)        │
  │    只存 token   │       │  GET|OPTIONS /proxy/sync/{rel}  (Web 同步分片, 凭证服务端)                     │
  │  - 内存持密钥   │       │  GET|PROPFIND|OPTIONS /proxy/webdav?target=…  (可选, 默认关, SSRF 护栏)         │
  └──────┬─────────┘       │  存储: SQLite (users / vaults), /data 必须是本地卷(非 NFS/SMB)                  │
         │                 └───────────────────────────────────────────────────────────────────────────┘
         │ 本地优先                         ▲ PUT 密文                  ▲ 代理取回 (服务端持凭证)
         ▼                                  │                          │
  ┌───────────────┐                  ┌──────┴───────┐          ┌───────┴────────────────────────┐
  │ WASM Drift DB  │                 │ 移动端 App     │          │ 用户的真实存储                   │
  │ (OPFS/IndexedDB)│ importFromArchive│ (原生, 全读写)│         │ OneDrive Graph / WebDAV / GitHub │
  └───────────────┘                  └──────────────┘          └─────────────────────────────────┘
         ▲  SyncEngine.syncDown → SyncStorage(read) ── 经 NasVaultBackedStorage → /proxy/sync ──┘
```

**数据流（登录后）**

1. **本地优先即时渲染**：App 启动时 `dbProvider` 打开本地 WASM Drift DB（Web 上是 `WasmDatabase`，OPFS/IndexedDB 自动持久化），地图/日记立刻用已有数据绘制——不阻塞首帧。
2. **登录**：用户输入 email+口令。客户端用**单一规范 KDF** 派生出两个独立值：`authVerifier`（POST 给 NAS 换 session token）与 `vaultKey`（只在内存，永不上行）。NAS 只见 `authVerifier`，无法推出 `vaultKey`（HKDF 域分离保证独立）。
3. **取保险库**：`GET /vault` 拿到不透明密文 blob（404 即无库→null）。客户端用 `vaultKey` 解密成 `VaultPayload`（凭证+定位符+传输配置）。
4. **配置传输并后台 syncDown**：Web 端把传输配置注入**内存中的传输实例**（Web 上**绝不**写回 `PrefsStore`），选择 `NasVaultBackedStorage`（经 `/proxy/sync` 取分片），调用 `SyncEngine.syncDown(modules: 内容模块集, clearBeforeImport:false)` 增量按 UUID 去重合并进 WASM DB，进度经 `syncProgressProvider` 显示，可中断。
5. **重绘**：合并完成 bump `journalRefreshProvider`/`fogRefreshProvider`，已渲染的地图就地刷新。syncDown 失败（CORS/网络/过期）**非致命**：保留本地渲染并提示走手动 zip 导入回退。

---

## 3. 组件设计（按构建顺序）

构建顺序由集成发现的时序约束推导：**先冻结 crypto 契约 → NAS auth/vault 端点 → 移动端生产者 → Web/媒体消费者**；`SyncStorage` 抽象（除 NAS 装饰器外）无 crypto 依赖，与 crypto 并行先行。

---

### 3.1 权威密钥契约组件 `SettingsVault`（crypto + 序列化）— **最先构建**

这是整个特性的地基。三个组件（移动生产者、Web 消费者、NasVaultBackedStorage 凭证解析）都依赖它最终的 KDF + blob 帧 + payload 键集。冻结之前不准建任何消费者。

**重大修正（折叠自审查）**：原三个组件 KDF 互不兼容（Argon2id 64MiB vs PBKDF2-600k vs p2p 的 PBKDF2-50k/固定盐）。**裁定采用单一规范 KDF：PBKDF2-HMAC-SHA256，600,000 迭代**。理由：
- `cryptography` 在 Web 上**不**用 Web Crypto 加速 Argon2id（`BrowserCryptography` 继承纯 Dart `DartArgon2State`，`lib/src/browser/` 中零 Argon2 覆盖——已核实）。64MiB 内存硬化在浏览器主线程会卡死/OOM。
- PBKDF2-SHA256 在 Web 上经 Web Crypto 加速、跨平台一致、原生端也快。p2p 用的 50k 太低，保险库用 600k（OWASP 2024 下限）。
- KDF 参数与盐**存进 blob 自描述**（采纳 vault-crypto 的模型），这样未来提升成本可前后兼容；解密时永远从 blob 读 KDF，并强制一个**最低成本下限**拒绝降级 blob。

**域分离（采纳 mobile-vault-push 模型，全局统一）**：

```
master       = PBKDF2-HMAC-SHA256(password, salt, iterations=600000, dkLen=32)
vaultKey     = HKDF-SHA256(ikm=master, info="explore_journal/vault/v1/enc",  L=32)   # 只在设备内存
authVerifier = HKDF-SHA256(ikm=master, info="explore_journal/vault/v1/auth", L=32)   # 发给 NAS
```
不同 `info` 的 HKDF 输出密码学独立 → NAS 持 `authVerifier` 学不到 `vaultKey`。**口令绝不发给 NAS**（这修正了 nas-backend 原本"服务端 Argon2 哈希明文口令"的零知识违背）。

**新增文件**
- `/home/xyz/Projects/priv/explore_journal/lib/services/vault/settings_vault.dart` — `SettingsVault`、`VaultBlob`、`VaultKdfParams`、`VaultPayload`、`VaultDecryptException`/`VaultFormatException`。纯 Dart，Web 安全。导入 `package:cryptography/cryptography.dart`（已解析 2.9.0）、`dart:convert`、`dart:math`(`Random.secure`)、`lib/core/prefs.dart`。
- `/home/xyz/Projects/priv/explore_journal/test/services/vault/settings_vault_test.dart` — 往返、错口令→`VaultDecryptException`、篡改→认证失败、版本拒绝、下限拒绝、白名单排除非保险库字段、rekey 产生新盐+nonce、**断言 `kVaultPayloadKeys ⊇ _kSecretSettingsKeys`**。

**改动文件**
- `/home/xyz/Projects/priv/explore_journal/lib/services/backup/backup_service.dart` — 把私有 `_kSecretSettingsKeys`（:683-697，10 键）**提升为公开顶层 const** `kVaultSecretKeys`，`_scrubSettings` 引用同一 const，使备份擦除与保险库 payload 永不分叉。
- `/home/xyz/Projects/priv/explore_journal/lib/core/prefs.dart` — AppSettings 本身无需改；保险库经现有 `toJson`(:442-521)/`fromJson`(:523-619) 读写。

**关键接口（真实 cryptography 2.9.0 签名，已核实）**

```dart
class VaultKdfParams {
  final String algo;     // 'pbkdf2-sha256'
  final int iterations;  // 600000
  final int dkLen;       // 32
  const VaultKdfParams({this.algo='pbkdf2-sha256', this.iterations=600000, this.dkLen=32});
  Map<String,dynamic> toJson() => {'algo':algo,'iters':iterations,'dk':dkLen};
  factory VaultKdfParams.fromJson(Map j) => VaultKdfParams(
    algo: j['algo'] as String, iterations:(j['iters'] as num).toInt(), dkLen:(j['dk'] as num).toInt());
}

class SettingsVault {
  const SettingsVault();

  /// 派生两个独立值；salt 16-24 随机字节（首次）或来自 blob/缓存。
  /// 修正: 不要用 newNonce()..addAll()(定长 list 抛 UnsupportedError)；用 Uint8List.fromList([...,...])。
  static Future<({SecretKey vaultKey, List<int> authVerifier, Uint8List salt})>
      derive(String password, {Uint8List? salt, VaultKdfParams p = const VaultKdfParams()}) async {
    salt ??= _random(16);
    final master = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: p.iterations, bits: p.dkLen*8)
        .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    final mb = await master.extractBytes();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final vk = await hkdf.deriveKey(secretKey: SecretKey(mb),
        info: utf8.encode('explore_journal/vault/v1/enc'), nonce: const []);
    final av = await hkdf.deriveKey(secretKey: SecretKey(mb),
        info: utf8.encode('explore_journal/vault/v1/auth'), nonce: const []);
    return (vaultKey: vk, authVerifier: await av.extractBytes(), salt: salt);
  }

  /// 密封。AAD 绑定 header(version|kdf|salt) 防参数被换。
  Future<VaultBlob> encrypt(VaultPayload payload, SecretKey vaultKey, Uint8List salt,
      {VaultKdfParams p = const VaultKdfParams()}) async {
    final cipher = AesGcm.with256bits();                 // nonce 12B, tag 16B, key 32B
    final nonce = cipher.newNonce();
    final aad = _aad(VaultBlob.version, p, salt);
    final box = await cipher.encrypt(utf8.encode(jsonEncode(payload.toJson())),
        secretKey: vaultKey, nonce: nonce, aad: aad);
    return VaultBlob(kdf: p, salt: salt, nonce: Uint8List.fromList(box.nonce),
        ciphertext: Uint8List.fromList(box.cipherText), authTag: Uint8List.fromList(box.mac.bytes));
  }

  /// 解密。错口令/篡改 → SecretBoxAuthenticationError → VaultDecryptException。
  Future<VaultPayload> decrypt(VaultBlob blob, SecretKey vaultKey) async {
    _enforceKdfFloor(blob.kdf);                           // 拒绝降级 (iters<600000)
    final aad = _aad(VaultBlob.version, blob.kdf, blob.salt);
    final List<int> clear;
    try {
      clear = await AesGcm.with256bits().decrypt(
        SecretBox(blob.ciphertext, nonce: blob.nonce, mac: Mac(blob.authTag)),
        secretKey: vaultKey, aad: aad);
    } on SecretBoxAuthenticationError {
      throw const VaultDecryptException('wrong password or corrupted vault');
    }
    return VaultPayload.fromJson(jsonDecode(utf8.decode(clear)) as Map<String,dynamic>);
  }
}
```

**风险与对策**
- *Web 主线程阻塞*：PBKDF2-600k 在弱机/Web 上可感知。对策：派生在 `Isolate.run`/`compute`（Web 上用 worker，原生用 isolate）执行；每会话只派生一次并把 `vaultKey` 缓存在内存。
- *降级攻击*：AAD 用 blob 自身参数重建，**不能**单独防降级（攻击者可改参数+重封）。对策：`decrypt` 硬性拒绝 `iters < 600000` 的 blob（已写入 `_enforceKdfFloor`）。
- *口令是唯一熵源、离线可爆破*：blob 被偷后永久离线可爆破，库内含 OneDrive 刷新令牌+contents PAT。对策：**密封路径强制最小口令强度**（长度/zxcvbn），写进 `encrypt` 契约而非交给 UI。
- *字段漂移*：未来加密钥但漏加进 `kVaultPayloadKeys` → 不同步且只留本地。对策：单元测试断言超集 + `backup_service.dart` 交叉引用注释。
- *秘密内存卫生*：派生 key、明文字节、解码 JSON 都持明文。对策：`encrypt` 后用 `tryEraseBytes` 擦明文缓冲；登出销毁内存 `vaultKey`；Web 上无法可靠擦除——明确记录残留风险。

---

### 3.2 NAS 后端服务（Docker 单二进制）

Go + chi + `modernc.org/sqlite`（纯 Go、无 CGO、跨 amd64/arm64，适配 Synology/QNAP）。三件薄事：账户 auth、零知识 vault 存取、私有资源 CORS 代理。**绝不**存日记/轨迹/雾/媒体内容。

**修正（折叠自审查）**
- 原 WebDAV 代理"作为同步引擎 drop-in"是**错的**：真正的同步走 OneDrive Graph（`onedrive_service.dart:337`），WebDavService 全是 `dart:io`/temp file、Web 不可用。代理面**重新调和**为消费者实际需要的路由（见下），并由后端全部提供。
- auth 用 `authVerifier`（口令派生值），**不**收明文口令。服务端仍须对 `authVerifier` 做 Argon2id/scrypt + 每账户服务端盐再存储（它是"口令等价物"，泄库即可重放）。
- 每个需鉴权的浏览器调用（`GET /vault`、`/proxy/* + Authorization`）都触发 **OPTIONS 预检**——每条路由必须实现预检（精确回显 Origin、`Allow-Headers: Authorization`）。
- `EJ_DB_PATH` 必须是**本地 ext4/btrfs 卷**，不能是 NFS/SMB（SQLite WAL + POSIX 锁在网络挂载上不可靠）。丢 `ej.db` = 丢全部 vault 密文 → 文档要求卷级备份。

**新增文件**
- `nas-backend/cmd/server/main.go` — 入口：env 配置、开 SQLite、迁移、chi 路由（recoverer/requestID/real-IP/CORS/限流）、挂载 /auth /vault /proxy /healthz、优雅关闭。
- `nas-backend/internal/config/config.go` — 配置来源**双通道**（满足"后端可改配置"要求）：环境变量 **覆盖** 一个可选 YAML 配置文件 `EJ_CONFIG`(默认 `/data/config.yaml`)，文件挂在 `/data` 卷里、改完重启容器即生效，无需重新构建镜像。键：`EJ_JWT_SECRET`(必填≥32B)、`EJ_DB_PATH`(默认 /data/ej.db)、`EJ_LISTEN`(**默认 `:48080` 高端口**，避开 NAS 上常被占用的低端口；可改任意端口)、`EJ_CORS_ORIGINS`(csv 精确白名单)、`EJ_ALLOW_REGISTRATION`(默认 true，首注册后关)、`EJ_PROXY_ENABLED`/`EJ_PROXY_ALLOW_HOSTS`、`EJ_TOKEN_TTL`(默认 1h)、`EJ_TRUST_PROXY`。启动时把最终生效配置（脱敏后）打到日志，方便在 NAS 上确认端口/白名单。
- `nas-backend/internal/store/store.go` — SQLite 层：迁移、`CreateUser`/`GetUserByEmail`/`GetVault`/`PutVault`(version CAS)。WAL + busy_timeout。
- `nas-backend/internal/auth/auth.go` — Argon2id PHC 哈希 `authVerifier`、HS256 JWT mint/parse（`jwt.WithValidMethods(["HS256"])` + 断言 `*SigningMethodHMAC` 防 alg 混淆）、`RequireAuth` 中间件。
- `nas-backend/internal/handlers/auth_handlers.go` — register/login/me/salt；email 归一化；未知 email 走 dummy-hash 保持时序平、`/auth/salt` 统一响应抗枚举。
- `nas-backend/internal/handlers/vault_handlers.go` — GET/PUT，body 当不透明字节（`http.MaxBytesReader` 256KiB 前置上限），ETag=version，If-Match CAS（409 冲突/428 缺 If-Match/304 If-None-Match）。
- `nas-backend/internal/handlers/proxy_handlers.go` — `/proxy/gh`、`/proxy/url`、`/proxy/sync`、可选 `/proxy/webdav`。SSRF 管线 + 预检（见下）。
- `nas-backend/internal/middleware/{cors.go,ratelimit.go}` — 严格 CORS（精确回显，不用 `*`，无 Allow-Credentials）；令牌桶限流，/auth/* 更紧 + 429 Retry-After。
- `nas-backend/{Dockerfile,docker-compose.yml,README.md}` — **Docker 优先部署**（满足"放在 docker 里启动"要求）：多阶段 `CGO_ENABLED=0` → distroless static nonroot 单镜像，支持 amd64/arm64（Synology/QNAP），`EXPOSE 48080`，`VOLUME /data`。`docker-compose.yml` 把高端口映射到宿主（`48080:48080`，用户可改左侧宿主端口）、挂载 `/data` 本地卷（含 `config.yaml`+`ej.db`）、注入 `EJ_JWT_SECRET`。README 给一条 `docker compose up -d` 即可起。

**关键端点规格**

```
POST /auth/register   {email, authVerifier:b64(32), salt:b64} → 201 {token, expires_at, user_id}
POST /auth/login      {email, authVerifier:b64(32)}           → 200 {token, expires_at, user_id, vault_version}
GET  /auth/salt?email=…  → 200 {salt:b64}   # 未知 email 返回确定性伪盐 (抗枚举)
GET  /auth/me  (Bearer)  → 200 {user_id, email, vault_version}

GET  /vault  (Bearer)  → 200 octet-stream + ETag:"<v>" | 304(If-None-Match) | 404 ETag:"0"
PUT  /vault  (Bearer, If-Match:"<v>", octet-stream ≤256KiB)
                       → 200 {version, updated_at} + ETag | 409 {current_version} | 428 | 413

# 代理 (consumer 契约, 全部需 Bearer + 实现 OPTIONS 预检)
GET|OPTIONS /proxy/gh/{owner}/{repo}/{branch}/{path...}   # 私有 GitHub 图: NAS 用 vault 内 PAT 取 raw.githubusercontent.com, 流式回 + CORS
GET|OPTIONS /proxy/url?u=<pct-enc absolute url>           # CORS-less 主机: vault 内凭证服务端附加, 硬 host 白名单
GET|OPTIONS /proxy/sync/{rel}                             # Web 同步分片: NAS 用 vault 内传输凭证从真实存储取 <rel>
GET|PROPFIND|OPTIONS /proxy/webdav?target=…               # 可选, 默认关
```

**数据格式**

```sql
CREATE TABLE users  (id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL,
                     pw_hash TEXT NOT NULL,         -- Argon2id PHC(authVerifier) + 服务端盐
                     kdf_salt TEXT NOT NULL,        -- 客户端 KDF salt, GET /auth/salt 回传
                     created_at INTEGER NOT NULL);
CREATE TABLE vaults (user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                     blob BLOB NOT NULL,            -- 不透明密文; 服务端永不解析
                     version INTEGER NOT NULL DEFAULT 1,
                     updated_at INTEGER NOT NULL);
```

JWT: `{sub, iat, exp=iat+EJ_TOKEN_TTL, v:1}` HS256。无状态；唯一服务端撤销手段是轮换 `EJ_JWT_SECRET`。默认 **TTL 1h + 依赖廉价重登**（本地优先，重登即刻显本地数据），而非 30 天 localStorage bearer。

CORS（对白名单内 Origin）：`Access-Control-Allow-Origin: <精确回显>`、`Vary: Origin`、`Allow-Methods: GET,POST,PUT,PROPFIND,OPTIONS`、`Allow-Headers: Authorization,Content-Type,If-Match,If-None-Match,X-WebDAV-Authorization,Depth`、`Expose-Headers: ETag`、`Max-Age: 600`；**无** Allow-Credentials（用 header bearer，不用 cookie）。

**实现步骤**：scaffold go.mod → config(JWT 缺失/过短即 fail-fast) → store(CAS) → auth(Argon2id+JWT+RequireAuth) → auth_handlers(抗枚举) → vault_handlers(前置 MaxBytesReader + CAS) → proxy_handlers(SSRF 管线，见下) → CORS/限流中间件 → main 接线 + /healthz + 超时 → Dockerfile/compose → README(生成 secret、关注册、代理白名单) → curl 冒烟。

**风险与对策**
- *SSRF（最尖锐）*：`/proxy/url`、`/proxy/webdav` 接受可被影响的 target（媒体串来自同步/导入的其他设备 = 不可信）。**硬性要求**（非"待决"）：(a) target 必须解析为绝对 http(s)；(b) host 必须在 `EJ_PROXY_ALLOW_HOSTS`（限于用户配置的 webdav/custom host + 已知 CDN）；(c) 解析 DNS 后拒绝 loopback/RFC1918/link-local/ULA/169.254.169.254，**IPv6 全覆盖**(`::1`、`fc00::/7`、`fe80::/10`、`::ffff:0:0/96`、IPv4-mapped 元数据)；(d) **关闭上游重定向**（拒 3xx 或每跳重跑校验）；(e) 重新 pin 已解析 IP 防 DNS rebinding。NAS LAN WebDAV 需显式把私有 CIDR 加入白名单（文档说明此举削弱该段 SSRF 防护）。
- *零知识完整性*：服务端绝不 parse/log/transform vault blob；body 当 `[]byte`，禁 body 日志。
- *authVerifier 口令等价物*：泄库可重放。对策：Argon2id+服务端盐再哈希；TTL 短。
- *多用户代理是开放中继*：单 JWT + 全局白名单 → 多租户下用户 A 可代取白名单上任意 host。明确标注：代理**不适合多租户暴露**，目标场景是单用户/家庭。

---

### 3.3 SyncStorage 传输抽象 — 与 crypto 并行先行

抽出 3 方法 `SyncStorage`（write/read/delete，字节向、dio `CancelToken` 感知），与引擎已调用的 `OneDriveService` 方法 1:1 对应。引擎唯二耦合点：`onedrive_sync_engine.dart:92` 与 `:176` 的 `ref.read(oneDriveServiceProvider)`，加 `_readIndex` 参数类型(:216)。改这些 + 5 处方法调用名（:143/:150/:155/:192/:217）即整条 shard/diff/zip 管线、`SyncProgress`、`SyncUpResult`、`_throwIfCancelled`、CancelToken 流不变。

**修正**
- **引擎重命名**（折叠集成建议）：`OneDriveSyncEngine`/`oneDriveSyncEngineProvider` → `SyncEngine`/`syncEngineProvider`（仅触 `backup_screen.dart` 与文件底部 provider :259-260），因为 web-bootstrap-gate 引用 `syncEngineProvider`，且现名误导（已转为传输无关）。审计 OneDrive 字样 debugPrint。
- `providers.dart` 必须 `import '../services/sync/onedrive_service.dart'`（`oneDriveServiceProvider` 在 :395 而非 providers.dart——否则默认分支不编译）。
- **GitHub read >1MB 修正**：Contents API `raw` media type 上限 1MB；雾分片/月轨迹分片可能超。对策：(a) 当 backend=='github' 时引擎 `_shardFor` 分组把分片限在 <1MB，或 (b) 非 200/404 时 fallback 到 Git Blobs API。否则大分片静默损坏。
- **GitHub sha 冷启动修正**：进程重启后 `_shaCache` 空，首次覆盖已存在分片会 409/422。`write()` 必须实现 GET-then-retry-on-sha-mismatch（不只 delete）。
- **kIsWeb 硬护栏**（防御纵深）：`syncStorageProvider` 对 `'github'` 与直连 `'webdav'` 在 Web 上**抛错**，不靠上游 UI 阻止把 PAT 发进浏览器；Web 上只 `'nas'`（与 OneDrive 若 Graph CORS 可用）可选。
- **Web 上 syncUp 禁用**：`NasVaultBackedStorage` 在 Web 上 write/delete 是 no-op，若 web 误调 syncUp，索引写(:155)静默 no-op 却报成功。对策：在引擎/UI 层 `kIsWeb` 时直接拦截 syncUp。

**新增文件**
- `.../lib/services/sync/sync_storage.dart` — 抽象 `SyncStorage` + `SyncBackend` 常量。
- `.../lib/services/sync/github_sync_storage.dart` — GitHub Contents API（含 sha 缓存 + write 重试 + >1MB fallback）。仅原生可直连。
- `.../lib/services/sync/webdav_sync_storage.dart` — 经 `wd.Client.write/read/remove`（均 CancelToken 感知，已核实 webdav_client 1.2.2；`remove` 位置参、`read/write` 命名参），root `/explore_journal/Sync`，read 404→null、delete 404→no-op。mkdirAll catch 中**若是取消则 rethrow**，不要吞掉取消。
- `.../lib/services/sync/nas_vault_backed_storage.dart` — 装饰器：Web 上 read 经 `/proxy/sync/<rel>`，write/delete no-op；原生委托 vault 解析出的 inner 传输。

**改动文件**：`onedrive_sync_engine.dart`（重命名 + 改 ref.read/方法名/参数类型）、`onedrive_service.dart`（`implements SyncStorage`，3 方法 rename 为 write/read/delete，体不变）、`providers.dart`（加 `syncStorageProvider` switch 工厂 + imports + kIsWeb 护栏）、`core/prefs.dart`（加 `syncBackend` String 字段默认 `'onedrive'`，fromJson `?? 'onedrive'` 保旧 blob 行为）、`webdav_service.dart`（加 `wd.Client? get rawClient => _client`）。

**关键接口**

```dart
abstract class SyncStorage {
  Future<void> write(String rel, List<int> bytes, {CancelToken? cancelToken});
  Future<Uint8List?> read(String rel, {CancelToken? cancelToken});   // null == absent (载荷性)
  Future<void> delete(String rel, {CancelToken? cancelToken});       // 404/缺失幂等
}
final syncStorageProvider = Provider<SyncStorage>((ref) {
  final s = ref.watch(settingsProvider);
  if (kIsWeb && (s.syncBackend == SyncBackend.github || s.syncBackend == SyncBackend.webdav)) {
    throw StateError('Web 上不可直连 $s.syncBackend；请用 nas 代理');   // 防 PAT 入浏览器
  }
  switch (s.syncBackend) {
    case SyncBackend.github: return GithubSyncStorage.fromSettings(s);
    case SyncBackend.webdav: return WebdavSyncStorage(ref.watch(webdavServiceProvider));
    case SyncBackend.nas:    return NasVaultBackedStorage(ref);
    default:                 return ref.watch(oneDriveServiceProvider);  // implements SyncStorage
  }
});
```

**远端布局（不变契约，泛化 base path）**：key→bytes，root 按传输（OneDrive `approot:/Sync/`、WebDAV `/explore_journal/Sync/`、GitHub `<prefix>/Sync/`）。`rel` 如 `meta.zip`、`fog/<layer>/<bx>_<by>.zip`、`.ej_index.json`。`.ej_index.json` = `{ "<rel>": "<md5hex>" }`，read==null 视作空远端。各传输逐段 URL 编码。

**风险与对策**：每个 backend 是**独立 silo**——切 `syncBackend` 不迁移已同步数据（新 backend 无 `.ej_index.json`→syncDown 返 null→syncUp 全量重传）。对策：UI 在切换后端时警告。Provider rebuild 丢 sha 缓存：可接受（OneDrive/WebDAV 本就如此），但配合 write 重试避免 409。

---

### 3.4 移动端 → NAS 保险库推送

同口令派生 `vaultKey`+`authVerifier`（复用 3.1 `SettingsVault.derive`）。登录、改设置（debounce 5s）、手动同步时序列化秘密子集、客户端加密、`PUT /vault`。

**修正**
- **payload 键集统一**：用单一权威 `kVaultPayloadKeys`（见 3.5），**代码必须迭代它**——原 `buildVaultSecrets` 代码只迭代 10 键、漏 `leaderboardPrivateKey`（散文却说包含），导致新设备 leaderboard 身份损坏。加测试断言超集。
- **token 不能用 copyWith 清**：`AppSettings.copyWith` 用 `field ?? this.field`（已核实 prefs.dart:360-427），`copyWith(nasSessionToken:null)` 是 no-op。对策：session token **不存为可空 AppSettings 字段**；移动端存专用可清 prefs key 或 `flutter_secure_storage`（强烈建议，`SecureCredentials` 已在但死代码，仅为此 token 接线很小）。
- **盐生成修正**：`newNonce()..addAll()` 在定长 list 上抛 `UnsupportedError`；用 `Uint8List.fromList([...a,...b])` 或直接 `_random(16)`。
- **CAS 合并**：`PUT /vault` 409 时必须 refetch→按 per-secret `updatedAt` 字段级合并→重试（不能盲重试覆盖另一设备）。
- **nasServerUrl 校验**：自由文本字段，构造 client 前校验 https-only、拒私网（防 SSRF/凭证误投）。
- **blob 帧统一**：用 3.1 的 `VaultBlob`（KDF 参数+盐**在 blob 内**），不用 mobile 原本无盐/无参数的 `EJV1` 帧——否则 vault-crypto 的"解密总从 blob 读 KDF"前后兼容性破裂。

**新增文件**：`.../lib/services/vault/nas_vault_client.dart`（dio：register/login/getSalt/putVault/getVault，getVault 404→null）、`.../lib/services/vault/vault_secrets.dart`（`buildVaultSecrets`/`applyVaultSecrets` over `kVaultPayloadKeys`）、`.../lib/services/vault/vault_sync_controller.dart`（app-scoped，debounce push，仿 `groupLifecycleProvider`）。

**改动文件**：`core/prefs.dart`（加 `nasServerUrl`/`nasAccountEmail`/`nasKdfSalt` 非秘密配置字段；token **不**放这）、`app/providers.dart`（`nasVaultClientProvider` + `vaultSyncControllerProvider`）、`ui/backup/backup_screen.dart`（NAS 区：URL/email/口令字段 + 登录/注册/立即同步，复用 `_withProgress`(:282) 的 CancelToken+进度）。

```dart
class VaultSyncController {
  Future<void> login(String email, String password) async {
    final salt = await _client.getSalt(email);                       // 抗枚举端点
    final d = await SettingsVault.derive(password, salt: base64.decode(salt));
    final r = await _client.login(email, d.authVerifier);            // 发 authVerifier, 非口令
    _token = r.token; _vaultKey = d.vaultKey;                        // 仅内存
    await _persistTokenSecurely(_token);                             // 非 copyWith
    await pushNow();
  }
  // PUT 409 → refetch+字段级 updatedAt 合并 → retry; md5 跳过自冗余推送
  Future<bool> pushNow({...}) async { /* encrypt(kVaultPayloadKeys 子集) → putVault(If-Match) */ }
  void logout() { _vaultKey = null; _token = null; _clearTokenSecurely(); }  // 不擦本地秘密
}
```

**风险与对策**：改 NAS 口令 → `vaultKey` 变 → 旧 blob 不可解。v1 不做重封；至少 `getVault` 解密失败时**检测并警告**而非静默用新 key 覆盖。401（过期）后 App 重启 `vaultKey` 已丢（仅内存）→ 任何 vault 操作需**重新提示口令**，移动与 Web 流程都要明示。

---

### 3.5 权威 payload 键集（跨 3.1/3.4/Web 共用的单一常量）

定义于 `vault_secrets.dart`，被生产者与消费者**导入而非各自重定义**：

```dart
class VaultPayload {
  // 10 个擦除秘密 (= kVaultSecretKeys, 提升自 backup_service.dart:683)
  static const _secrets = {
    'webdavPass','p2pPassphrase','aiApiKey','githubPat','githubPrivatePat',
    'customAuthHeader','leaderboardRepoPat','leaderboardServerToken',
    'oneDriveRefreshToken','musicCredentials',
    // Ed25519 私钥, 两份旧列表都没有 (prefs.dart:169) — 见下产品裁定
    'leaderboardPrivateKey',
  };
  // 非秘密但缺之秘密无用的定位符
  static const _locators = {
    'webdavUrl','webdavUser','githubOwner','githubRepo','githubBranch','githubPathPrefix',
    'githubCdnTemplate','githubPrivateOwner','githubPrivateRepo','githubPrivateBranch',
    'githubPrivatePathPrefix','oneDriveClientId','oneDriveAccount','customUploadUrl',
    'customFileField','customResponseUrlPath','customDisplayUrlTemplate','customDeleteUrlTemplate',
    'aiBaseUrl','aiModel','leaderboardRepoOwner','leaderboardRepoName','leaderboardRepoBranch',
    'leaderboardServerUrl','leaderboardPublicKey',
  };
  static Set<String> get kVaultPayloadKeys => {..._secrets, ..._locators};

  final Map<String,dynamic> fields;  // 含 schema 版本: {'_schema':1, ...}
  factory VaultPayload.extract(AppSettings s) { final j=s.toJson();
    return VaultPayload({'_schema':1, for (final k in kVaultPayloadKeys) if (j.containsKey(k)) k:j[k]}); }
  /// 修正: 跳过 null/空 vault 值, 不覆盖本地已设秘密 (本地优先)
  AppSettings applyTo(AppSettings cur) { final m = cur.toJson();
    fields.forEach((k,v){ if (k!='_schema' && v!=null && v!='') m[k]=v; });
    return AppSettings.fromJson(m); }
}
```

**`leaderboardPrivateKey` 产品裁定（默认建议）**：**不漫游**（每设备身份），Web 只读无 leaderboard 签名身份。理由：漫游签名私钥使单个被破口令永久危及全设备 leaderboard 身份（可伪造签名）。若产品明确要共享身份再纳入——无论选哪个，该决定只在这一个常量里体现一次。

---

### 3.6 Web 登录门 + 只读模式 + 本地优先引导

**修正**
- **删 "Web 回退 oneDriveSyncEngineProvider"**：OneDrive OAuth 用自定义 scheme 重定向(`onedrive_service.dart:53,132-135`)+`login.microsoftonline.com`/`graph.microsoft.com`，浏览器 CORS 阻断、自定义 scheme 无效——Web 完全不可跑。Web 同步**必须**经 `NasVaultBackedStorage`→`/proxy/sync`（NAS 持 OAuth/WebDAV 凭证、重供 CORS）。BootstrapController 把"无 Web 可用传输"处理为：渲染本地 IndexedDB + 提供手动 zip 导入，**绝不**尝试原生引擎。
- **Web 秘密绝不落盘（最高优先级全局不变量）**：Web 上 `shared_preferences` 是明文 localStorage/IndexedDB。**绝不**把解密秘密经 `SettingsNotifier.update`→`PrefsStore.save` 写盘；解密 `VaultPayload` 只存非持久化内存 provider，传输凭证**直接注入内存传输实例**。这是零知识在真正暴露处（浏览器）成立的前提。
- **`web:` 加为直接依赖**：`package:web` 现仅是传递依赖(pubspec.lock:1853)，lib/ 零引用；用 `window.localStorage` 前须在 pubspec 加 `web:`。
- **`flutter_secure_storage` 在 Web 上不安全**（值与 key 都在 localStorage）→ 不用于 token；用 `WebTokenStore`（直接 localStorage）只存 token + **零知识 vault 密文**（安全，无口令不可解）；派生 key 绝不入 localStorage。
- **`_BottomNav.onQuickNote` 是非空 required**(map_screen.dart:2010)→传 null 编译错。在 `_BottomNav` 内（它是 ConsumerWidget）`ref.watch(viewOnlyProvider)` 自门控，或传 `(){}`。
- **`main.dart:28` 的 `show groupLifecycleProvider`** 须扩展加入新 provider，否则未定义。
- **conditional import 方向**：默认=原生 stub，`if (dart.library.js_interop)`=web 实现（对齐 `main.dart:31`），原设计写反了。
- **`syncEngineProvider` 守卫**：用 throwUnimplemented 占位（同 AuthApi/VaultClient），使本组件可独立编译（且 3.3 已把引擎重命名为 `syncEngineProvider`，使引用真实存在）。
- **group/P2P 自动连接门控**：`groupLifecycleProvider`(providers.dart:136) 在 main.dart:130 早读、于 viewOnly/auth 门控**之前**触发网络。在 Web/viewOnly 上跳过 eager read 或 GroupLifecycle 自连接前检查 `viewOnlyProvider`——**纳入本组件范围**，非待决。
- **共享浏览器隐私**：登出**不**擦 IndexedDB（本地优先），但"仅用本地数据"按钮在不验证身份下渲染前用户内容 = 读绕过。对策：提供显式"清除本设备数据"(`deleteDatabase`)；登出时 `DefaultCacheManager().emptyCache()` 清缓存的私有图字节；离线渲染路径加确认提示。
- **Web syncDown OOM**：引擎下载全分片→内存 Map 解压→整包重 zip 再 importFromArchive，雾密数据集在浏览器内存 ~2x 物化 → tab 崩。对策：首次 Web 同步对 `fog_tiles` 流式/分片导入或跳过。
- **过期态**：NAS 401 或 OneDrive 刷新失败 → authState 翻 loggedOut/重认证提示，不留死 loggedIn 会话。

**新增文件**：`auth_controller.dart`(ChangeNotifier + `authStateProvider`)、`web_token_store.dart`(+`web_token_store_stub.dart` 原生 stub，默认导入 stub)、`auth_contracts.dart`(`AuthApi`/`VaultClient` 接口 + throwUnimplemented 占位)、`bootstrap_controller.dart`、`ui/auth/login_screen.dart`、`ui/common/sync_progress_banner.dart`。

**改动文件**：`main.dart`（`_router` 改为 build 内实例 + `redirect`(kIsWeb 门控) + `refreshListenable`=authController，加 `/login` route，eager read `bootstrapProvider`，web MaterialApp 用 builder 叠 banner，**router 只建一次**避免丢导航栈）、`main_web.dart`(`initPlatform` 触发 auth restore)、`app/providers.dart`(`viewOnlyProvider=StateProvider<bool>((_)=>kIsWeb)`、auth/bootstrap/syncProgress providers)、`recording_controller.dart`(`start()`(:74)/`resumeIfRecording()`(:114) 首行 `if(ref.read(viewOnlyProvider)) return …`——源头门控)、`ui/map/map_screen.dart`(FAB null + `_BottomNav` 内门控 + initState 跳过 resume/group)、`chat_screen.dart`/`group_setup_screen.dart`/`home_screen.dart`(viewOnly 隐藏写/PTT/P2P/上传入口；保留只读入口与手动导入回退)。

```dart
GoRouter _buildRouter(WidgetRef ref) => GoRouter(
  refreshListenable: ref.read(authControllerProvider),
  redirect: (ctx, st) {
    if (!kIsWeb) return null;                              // 原生不门控
    final s = ref.read(authStateProvider);
    if (s.status == AuthStatus.unknown) return null;       // 解析中, 不跳
    final atLogin = st.matchedLocation == '/login';
    if (s.status == AuthStatus.loggedOut && !atLogin) return '/login';
    if (s.status == AuthStatus.loggedIn && atLogin) return '/';
    return null;
  },
  routes: [ /* 现有 + */ GoRoute(path:'/login', builder:(_, __)=>const LoginScreen()) ],
);
```

**待修复前置（被多组件依赖的 v1 回退）**：`backup_screen._pickAndImport`(:407-420) 用 `withData:false`+`dart:io File` 在 Web 不可用。改 `withData:true` + `res.files.single.bytes`——`BackupService.importFromArchive` 本身已 Web 兼容（纯 bytes+drift，写入 WASM DB 持久化）。**这个小修必须显式排期**。

**风险与对策**：redirect 须 kIsWeb + unknown 双护栏防误门控原生/抖动；router 一次性构建防 rebuild 丢栈；syncDown 失败非致命；settings 模块 syncDown 会整体覆盖 SharedPreferences → **post-login 模块集排除 `settings`**（及 `imghost_uploads`/`geocode_cache`/`learned_regions`/`planner_history` 等设备本地便利数据），只拉内容模块（journal/layers/fog_tiles/track_points/chat_messages/song_favorites）；`leaderboard` 是 requiredModules 被强并，确认其在只读下 no-op（`BackupService.leaderboard` 注入但导入端 :660 leaderboard 模块对空安全）。

---

### 3.7 Web 媒体渲染（只读）

一个平台分支 `MediaResolver` + 薄 `MediaImage` widget，替换三处重复的 3-way 分支（`journal_screen.dart:765`/`:829`、`quill_editor_screen.dart:168`）。原生逐字节复现今日行为；Web：公共 CDN 直渲、`gh-private://` 重写到 `/proxy/gh`（浏览器永不见 PAT）、CORS-less http(s) 经 `/proxy/url`、本地文件→broken 占位。

**修正**
- **不要盲删 `journal_screen.dart` 的 `dart:io`**：该文件三处用 dart:io，`:113 File(f.path).lastModified()` 在照片导入流（非渲染分支）。删 import 不编译。对策：只替换两处渲染分支为 `MediaImage`，单独平台守卫 `:113`（`if(!kIsWeb)`）。`quill_editor_screen.dart` 的 dart:io **可**删（仅 :188 File 分支用）。
- **`imageRenderMethodForWeb: HttpGet` 必设**于所有带 auth header 的 `CachedNetworkImage`（代理媒体）：cached_network_image 3.4.1 默认 `HtmlImage` 经 `<img>` 渲染、**静默丢弃 httpHeaders**（已核实），Bearer 永不达代理。无 header 的公共 CDN 留默认 `HtmlImage`（绕 CORS）。→ `MediaPlan.NetworkMedia` 加 `bool needsHeaderFetch` 区分。
- **NAS 预检**：`/proxy/gh`、`/proxy/url` 带 Authorization 触发 OPTIONS 预检 → 后端两端点都须实现（已并入 3.2）。
- **SSRF 硬性**（非待决）：`/proxy/url` host 限于用户配置 webdav/custom host + CDN 白名单 + 拒私网，因媒体串来自不可信导入。
- **登出清缓存**：`DefaultCacheManager().emptyCache()`，否则解密的私有库图字节无限驻留浏览器存储。
- **CJK 路径**：`gh-private://` 路径含 CJK slug，构造 `/proxy/gh` URL 时**逐段 percent-encode**，否则代理 404。
- **Quill embed 无 Riverpod scope**：`EmbedBuilder.build` 无 WidgetRef → 不能直接放 ConsumerWidget 的 `MediaImage`。用**显式 (settings, nas) 构造变体**，经现有 `_embedSettings` ValueNotifier(:139，类型 `dynamic` 可空，保留 :170 null→`_BrokenImage` 守卫) 旁加 `_embedNas` notifier 注入。

**新增文件**：`media_resolver.dart`(`MediaPlan` sealed + `resolveMedia` + conditional export，默认 web 实现、`if(dart.library.io)` 原生——对齐 `native_file_image_io.dart`)、`media_resolver_native.dart`、`media_resolver_web.dart`、`media_image.dart`、`nas_media_provider.dart`(`NasMediaConfig{baseUrl,sessionToken}`，Web 上 baseUrl=同源 `window.location.origin`、token 来自 auth session provider；原生返 null)。

**改动文件**：`journal_screen.dart`(两渲染分支→`MediaImage`，守卫 :113，**不删** import)、`quill_editor_screen.dart`(分支→`MediaImage` 显式变体，删 dart:io)、`private_image_loader.dart`(可选抽 `fetchPrivateBytes()` 供原生 MemoryMedia；`PrivateImageRef.tryParse` + 64-LRU 复用)。

```dart
sealed class MediaPlan {}
class NetworkMedia extends MediaPlan { final String url; final Map<String,String> headers;
  final bool needsHeaderFetch; }   // needsHeaderFetch → CachedNetworkImage(imageRenderMethodForWeb: HttpGet)
class MemoryMedia extends MediaPlan { final String ghPrivateUrl; }   // 原生 PAT 字节路径
class FileMedia extends MediaPlan { final String path; }             // 原生
class BrokenMedia extends MediaPlan {}                               // Web 本地文件/不可解析

MediaPlan resolveMedia(String src, {required AppSettings settings, NasMediaConfig? nas});
// cacheKey = 原始 src (非代理 URL) → token 轮换不失缓存
```

**风险与对策**：`raw.githubusercontent.com` 无 CORS + Bearer 预检不满足 = Web 硬阻断；无 `/proxy/gh` 则私有图 degradeto BrokenMedia（不崩）。401/token 轮换：用 `cacheKey=src` 避免轮换失缓存，过期请求→errorWidget，下次 rebuild 取新 token（静态画廊可能需导航刷新——明确记录）。`flutter_cache_manager` 在 Web 缓存非持久（HtmlImage 路径还不走 cache manager）——"磁盘缓存跨轮换存活"仅在 HttpGet 路径成立。

---

## 4. 关键契约（跨组件单一权威定义）

各组件**引用**本节，不得重定义。

### 4.1 `SyncStorage` 接口
> **P0 实现决定**：方法名沿用 `OneDriveService` 已有的 `putSyncFile/getSyncFile/deleteSyncFile`（而非原计划的 write/read/delete）。这三者签名与接口需求逐字一致，于是 OneDrive 实现零改动、引擎调用点零改名——"原生行为逐字节不变"风险降到最低。后续所有传输/消费者引用此名。
```dart
abstract class SyncStorage {
  Future<void> putSyncFile(String rel, List<int> bytes, {CancelToken? cancelToken});  // CancelToken = dio
  Future<Uint8List?> getSyncFile(String rel, {CancelToken? cancelToken});  // null == 缺失 (载荷性, _readIndex 依赖)
  Future<void> deleteSyncFile(String rel, {CancelToken? cancelToken});     // 404/缺失幂等
}
```
`rel` 可含 `/`；各实现逐段编码并保证父容器存在。`getSyncFile` 缺失**返回 null 而非抛**；`deleteSyncFile` 对缺失幂等。

### 4.2 Vault blob 格式（NAS 不透明存储的字节）
单一帧，**KDF 参数与盐在 blob 内**（前后兼容成本提升），JSON 形（NAS 当文本/octet-stream 不透明存）：
```json
{ "v": 1,
  "kdf": { "algo": "pbkdf2-sha256", "iters": 600000, "dk": 32 },
  "salt":  "<b64 16B>", "nonce": "<b64 12B>",
  "ct":    "<b64 N>",   "tag":   "<b64 16B>" }
```
- 明文 = `jsonEncode(VaultPayload.toJson())`，含 `_schema` 版本 + `kVaultPayloadKeys` 子集（4.4）。
- AAD = `utf8(JSON{v,kdf,salt})` 认证但不单独存；解密重建。
- 解密**强制 KDF 下限**（`iters≥600000`）拒降级。`fromJson` 拒未知 `v`。

### 4.3 口令 → 双密钥派生（域分离）
```
master       = PBKDF2-HMAC-SHA256(password, salt, iterations=600000, dkLen=32)   # salt 来自 GET /auth/salt 或 blob
vaultKey     = HKDF-SHA256(master, info="explore_journal/vault/v1/enc",  L=32)   # 仅设备内存, 永不上行
authVerifier = HKDF-SHA256(master, info="explore_journal/vault/v1/auth", L=32)   # 发给 NAS auth
```
- NAS auth 收 **`authVerifier`**（绝非明文口令），服务端再 Argon2id+服务端盐哈希存储。
- HKDF 域分离 → 持 `authVerifier` 学不到 `vaultKey` → 零知识。
- KDF 在 Web 上须 off-main-thread（`compute`/worker）；下限参数须 Web 可承受。
- 重启后 `vaultKey`（仅内存）丢失 → 任何 vault 操作需重新提示口令。

### 4.4 Vault payload 键集
单一 `VaultPayload.kvaultPayloadKeys` = `_secrets`(11，含 `leaderboardPrivateKey`) ∪ `_locators`(24)，见 3.5。测试断言 `⊇ _kSecretSettingsKeys`(10) 与 `SecureCredentials.all`(8，camelCase↔snake_case 映射)。生产者/消费者**导入同一常量**。`applyTo` 跳过 null/空（本地优先）。

### 4.5 进度/取消契约（已一致，保持不变）
`SyncProgress = void Function(int done,int total,String label)` 推送回调 + dio `CancelToken`。UI 映射 `total==0?null:done/total`。被 SyncEngine、Web bootstrap(`syncProgressProvider`)、移动推送(`_withProgress`)逐字复用。

### 4.6 多设备合并 / token 位置
- `PUT /vault` ETag/If-Match CAS；客户端 409 → refetch → 按明文 JSON 内 per-secret `updatedAt` 字段级最后写赢合并 → 重试。
- session token：Web 存 `WebTokenStore`(localStorage)；移动存专用可清 prefs key 或 secure_storage——**绝不**存为可空 AppSettings 字段（copyWith 清不掉）。

---

## 5. 安全与威胁模型

**NAS 被攻破暴露什么（零知识下）**：DB(`ej.db`)+JWT secret 被偷 → 暴露 (a) `authVerifier` 的 Argon2id 哈希（弱口令才离线可破）、(b) vault **密文**（无口令的 `vaultKey` 不可解，HKDF 域分离使持 `authVerifier` 推不出）。**不**暴露任何明文秘密（GitHub PAT、WebDAV 口令、Ed25519 私钥等），**不**暴露日记/轨迹/雾/媒体内容（从不存于 NAS）。残余风险：弱口令的 vault 永久离线可爆破 → **密封路径强制最小口令强度**。代理是最大残余面（见下）。

**Web token 存储**：`flutter_secure_storage` 在 Web 不安全（值+key 同在 localStorage、"清除站点数据"即抹）→ 不用。`WebTokenStore` 经 localStorage 只存 session token + **vault 密文**（安全）。派生 `vaultKey` 与解密秘密**只在内存**，登出/刷新即弃。**Web 秘密绝不落盘**（全局不变量）：解密秘密绝不经 `PrefsStore.save` 写入明文 localStorage；直接注入内存传输实例。token 在 localStorage 仍可被 XSS/扩展读取 → 短 TTL(1h)+廉价重登，token 失窃即全 NAS 账户访问。共享浏览器：登出不擦 IndexedDB，提供显式"清除本设备数据"+登出清图缓存；"仅用本地"离线路径加确认（否则是看前用户内容的读绕过）。

**CORS 代理 SSRF 防护（硬性要求，非待决）**：`/proxy/url`、`/proxy/webdav` target 来自不可信同步/导入串。管线：(a) 必须绝对 http(s)；(b) host 在 `EJ_PROXY_ALLOW_HOSTS`(限用户配置 webdav/custom host + 已知 CDN)；(c) 解析 DNS 后拒 loopback/RFC1918/link-local/ULA/169.254.169.254，**IPv6 全覆盖**(`::1`/`fc00::/7`/`fe80::/10`/IPv4-mapped 元数据)；(d) **禁上游重定向**（拒 3xx 或每跳重校验）防绕过 pre-dial 检查；(e) 重 pin 已解析 IP 防 DNS rebinding；(f) 严格精确字符串 Origin 匹配（非前缀/子串，防 `evil.user.com.attacker.com`）；(g) 凭证 header 绝不日志，零持久化。NAS LAN WebDAV 须显式把私有 CIDR 加白名单（文档说明此举削弱该段 SSRF 防护，且代理**不可多租户暴露**——单 JWT+全局白名单是对所有白名单 host 的开放中继）。预检：每代理路由响应 OPTIONS（精确 ACAO + `Allow-Headers: Authorization` + `Allow-Methods: GET`），否则带 Bearer 的 GET 在 GET 前预检失败。

**auth 诚实标注**：`authVerifier` 是口令等价物——当前方案仅 vault **payload** 零知识，账户访问需信任服务端哈希。建议后续上 SRP/PAKE 使口令等价物永不离设备。

---

## 6. 分期路线图

每期可独立交付，App 不分叉（原生默认 `syncBackend='onedrive'`、`viewOnly=false`，行为逐字节不变）。

**Phase 0 — 地基与解耦（无 crypto/无 Web 依赖）**
- 产出：`SyncStorage` 抽取；`OneDriveService implements SyncStorage`；引擎重命名 `SyncEngine`/`syncEngineProvider` 并改 ref.read/方法名；`GithubSyncStorage`(含 sha 重试 + >1MB fallback)、`WebdavSyncStorage`；`syncStorageProvider` + kIsWeb 护栏 + `syncBackend` prefs 字段；`NasVaultBackedStorage` 编译 stub。提升 `kVaultSecretKeys` 公开。修复 `backup_screen` 文件选择器 `withData:true`。
- 验收：`flutter analyze` 过；原生 OneDrive 同步逐字节不变（同 CancelToken 流、同 `approot:/Sync/` base、同 404→null）；Web 可手动 zip 导入并持久化进 WASM DB。

**Phase 1 — Crypto 契约冻结**
- 产出：`SettingsVault`(PBKDF2-600k + HKDF 域分离 + AAD + KDF 下限 + off-main-thread 派生)；`VaultBlob` JSON 帧；`VaultPayload`/`kVaultPayloadKeys`(含 leaderboardPrivateKey 裁定)；完整单测（往返/错口令/篡改/降级拒绝/超集断言）。
- 验收：测试全绿；blob 帧字节稳定；`kVaultPayloadKeys ⊇ _kSecretSettingsKeys`。

**Phase 2 — NAS 后端**
- 产出：Go 服务 /auth(register/login/salt/me, 收 authVerifier, Argon2id+服务端盐, 抗枚举)、/vault(CAS+预检)、严格 CORS+限流；**默认高端口 `:48080`（可改）**；**env + 可选 `/data/config.yaml` 双通道配置**（改完重启即生效）；**Docker 优先**（distroless 单镜像 + `docker-compose.yml`，`docker compose up -d` 起）；本地卷 + 备份文档。
- 验收：`docker compose up -d` 在 NAS 上一键起、监听 48080；curl 端到端（register→login→PUT If-Match:"0"→GET ETag→stale PUT 期望 409）；改 config.yaml 端口重启后生效；预检 OPTIONS 通过；JWT alg 锁 HS256。

**Phase 3 — 移动推送**
- 产出：`NasVaultClient`、`vault_secrets`、`VaultSyncController`(登录派生双密钥/debounce push/409 字段级合并/token 安全存储/nasServerUrl https 校验)；`backup_screen` NAS 区 UI。
- 验收：登录后 NAS vault == 本地；改秘密 5s 后自动 push；并发设备 409 合并不丢秘密；登出清 token 不擦本地秘密；过期/重启需重提示口令。

**Phase 4 — NAS 代理**
- 产出：`/proxy/gh`、`/proxy/url`、`/proxy/sync` + 完整 SSRF 管线（IPv6/禁重定向/重 pin/host 白名单）+ 每路由 OPTIONS 预检。
- 验收：白名单 host 取回成功、私网 IP/重定向到元数据期望 403；带 Bearer 的浏览器 GET 预检通过。

**Phase 5 — Web 门 + 引导 + 媒体**
- 产出：登录门(GoRouter redirect kIsWeb + refreshListenable)、`viewOnlyProvider` + 全写面门控 + RecordingController 源头门控 + group 自连接门控；`AuthController`/`WebTokenStore`(web: 加直接依赖)/`BootstrapController`(本地优先→解密→NasVaultBackedStorage syncDown，fog 流式/跳过防 OOM，settings 模块排除，失败非致命)；`MediaResolver`/`MediaImage`(HttpGet 设置/proxy 重写/CJK 编码/登出清缓存)；"清除本设备数据"。
- 验收：登出态→/login；返回用户本地 IndexedDB 即时渲染；登录触发可见后台同步且可中断；公共图直渲、私有图经 /proxy/gh(网络面板无 PAT)、WebDAV 图经 /proxy/url、本地文件 broken 占位；原生构建仍正常记录（无门、无只读）；秘密绝不出现在 Web localStorage。

---

## 7. 待决问题（附建议默认值）

| # | 问题 | 建议默认 |
|---|------|---------|
| 1 | KDF 在 Web 上 off-main-thread 的具体实现 | `compute`/`Isolate.run`（原生），Web worker；先测 600k 在 Web 的耗时再锁参数 |
| 2 | `leaderboardPrivateKey` 是否漫游 | **不漫游**（每设备身份，Web 无 leaderboard 签名）；产品要共享身份才纳入 |
| 3 | `frpToken`/`frpDashboardPass`/`avatarBase64` 是否入 vault | **不入**（非同步/恢复必需）；如新设备需要再加进 `_secrets` 单一常量 |
| 4 | NAS auth 用 authVerifier 还是 SRP/PAKE | v1 用 authVerifier + 服务端 Argon2id+盐；后续升 SRP（口令等价物永不离设备） |
| 5 | `/auth/salt` 枚举抗性形式 | 未知 email 返回**确定性伪盐**（HMAC(serverSecret,email)），统一时序与响应 |
| 6 | Web 是否永远只读 | **v1 永远只读**(`viewOnlyProvider` 默认 kIsWeb)；将来写回是 per-account 而非 per-platform |
| 7 | post-login syncDown 模块集 | 仅内容模块（journal/layers/fog_tiles/track_points/chat_messages/song_favorites）；排除 settings 及设备本地便利模块；leaderboard 被强并但只读 no-op |
| 8 | JWT TTL vs 刷新 | **TTL 1h + 廉价重登**（本地优先即时显本地数据）；不发长效 localStorage bearer |
| 9 | 改 NAS 口令后旧 blob 不可解的重封 | v1 不自动重封；`getVault` 解密失败时检测并警告，不静默用新 key 覆盖 |
| 10 | Web syncDown 雾密数据集 OOM | 首次 Web 同步 `fog_tiles` 流式/分片导入或跳过；后续增量补 |
| 11 | `WebTokenStore` 自动免口令重登 | **每会话重输口令**（vault 始终仅内存可解）；不持久化包裹密钥 |
| 12 | NAS 同步分片代理 `/proxy/sync` 的精确路由/凭证解析 | `GET /proxy/sync/{rel}` + Bearer；NAS 从该用户解密 vault 服务端解析传输凭证、从真实存储取 `rel` |
| 13 | inner payload schema 迁移 | 明文 JSON 带 `_schema:1` + 字段重命名映射表；字段重命名时迁移而非静默丢秘密 |
| 14 | 共享浏览器本地数据清除入口 | 提供独立"清除本设备数据"(`deleteDatabase`)；登出仅清 token+内存 key+图缓存，不动 IndexedDB |

---

## 8. 实施进度（截至 2026-06-25）

> 按 Phase 落地，每个 Dart 阶段都过 `flutter analyze` + `flutter test`。测试总计 **95 passed / 2 skipped / 0 failed**；改动文件零新增 analyze 问题。

| Phase | 状态 | 说明 |
|-------|------|------|
| **P0 解耦** | ✅ 完成并测试 | `SyncStorage` 接口；`OneDriveService implements SyncStorage`（零改动）；引擎→`SyncEngine`/`syncEngineProvider` 走 `syncStorageProvider`；`GithubSyncStorage`/`WebdavSyncStorage`/`NasVaultBackedStorage(stub)`；`AppSettings.syncBackend`+kIsWeb 护栏；`kVaultSecretKeys` 公开；backup 导入 `withData:true`。测试 `test/sync/`（10）。 |
| **P1 Crypto** | ✅ 完成并测试 | `SettingsVault`（PBKDF2-600k+HKDF 域分离+AES-GCM+AAD+KDF 下限+弱口令拦截）；`VaultBlob` JSON 帧；`VaultPayload`/`kVaultPayloadKeys`（leaderboard 私钥按裁定排除）。测试 `test/vault/`（19）。 |
| **P2 NAS 后端** | ✅ 已编译并测试 | `nas-backend/`（**Rust**，改自原 Go 规格）：`tiny_http`+`rusqlite(bundled)`+`argon2`+`jsonwebtoken`+`ureq`。auth(Argon2id+HS256 alg 锁定+抗枚举伪盐)、vault(CAS+ETag+OPTIONS 预检)、严格 CORS/限流、env+JSON 双通道配置、默认高端口 48080、Docker(distroless)。`cargo test` **6 通过**（CAS/冲突、唯一 email、JWT 往返+错密钥拒绝、Argon2、SSRF IP 表）。 |
| **P3 移动推送** | ✅ 核心完成并测试 | `NasVaultClient`(+Http 实现)、`NasTokenStore`(secure/memory)、`VaultSyncController`(账户盐模型/登录/push/pull/CAS 重试/debounce/logout)、`vaultSyncControllerProvider`、NAS 配置字段。测试 `test/vault/nas_vault_sync_test.dart`（4，含双设备往返+CAS）。**backup_screen NAS UI 段未做**（见 TODO）。 |
| **P4 NAS 代理** | ✅ 已编译并测试 | `nas-backend/src/proxy.rs`：`/proxy/gh`、`/proxy/url` + SSRF 管线（自定义 `ureq` resolver 只返校验过的公网 IP→连接 pin、拒私网含 IPv6/IPv4-mapped/metadata、禁重定向、host 白名单）。SSRF IP 表单测通过。 |
| **P5 Web** | ✅ 主干完成并验证 | `viewOnlyProvider`+录制源头门控+`AuthController`/`authStateProvider`；**web 登录门**(`main.dart` `ConsumerStatefulWidget`+kIsWeb `redirect`+`refreshListenable`+`/login`)、**登录页** `ui/auth/login_screen.dart`、登录→拉 vault→后台 `syncDown(内容模块)`、**PrefsStore web 不落盘**(秘密绝不进 localStorage)、journal 本地图改 `NativeFileImage`(web 安全)。`flutter analyze` 净；`flutter test` **95 通过**(widget_test 修复了"build 期 notify"); **`flutter build web` ✓ 32.4s**。**待做**：mobile 端 NAS 推送 UI（接 `vaultSyncControllerProvider`，目前 web 端可注册/登录、数据走手动 zip 导入）、`gh-private` web 取图(`PrivateAwareImage`)、quill 富文本内嵌本地图 web 化、各写面 viewOnly 隐藏。 |

### 阻塞点 / Blockers — 复查结论

1. **～~`flutter build web` 被全仓 `dart:io` 阻塞`~～ → 已证伪（2026-06-25 实测）**。`flutter clean` 后**从零** `flutter build web` **成功**（Flutter 3.32.1，dart2js，33.6s，`✓ Built build/web`，6.3MB main.dart.js），零错误。事实核对：`main.dart` **直接** import 了 `map_screen`/`journal_screen`/`backup_screen`（均 `import 'dart:io'` 且用 `File(...)`），`dart:io` 也确实**不在** web SDK `libraries.json` 里——但 dart2js **不会**因 `dart:io` 的 import/引用在编译期报错；它把这些引用编进产物，只在**运行时**真正调用 `File`/`Directory` 等才抛 `UnsupportedError`。
   - **结论**：web "能编译" 从来不是阻塞；P5 剩余工作（路由门/登录页/MediaResolver/bootstrap）是普通特性开发，不需要"全仓 dart:io 大改"。
   - **真正的残留风险（运行时，低且可控）**：view-only web 若执行到原生路径会运行时抛错。最主要的一处是 `journal_screen.dart:841` `Image.file(File(path))` 渲染**本地路径**的日记图——这正是 P5 `MediaResolver` 要处理的（本地路径→broken/远程占位）。其余 File 路径（导出、照片导入、FOW 导出）在 view-only 下不会被触发（写面入口已被 `viewOnlyProvider` 隐藏 + RecordingController 源头门控）。所以是"逐个把 view-only 会触达的原生调用点改成 web 安全"的**渐进**工作，不是一次性大重构。
2. **～~Go 后端无工具链~～ → 已解决**：后端按要求改为 **Rust**，本机 `cargo build` + `cargo test`（6 通过）均已验证。无残留阻塞。

### 剩余 TODO（非阻塞，可直接做）

- **P3 UI**：backup_screen 加 NAS 段（URL/email/口令 + 登录/注册/立即同步），接 `vaultSyncControllerProvider`。纯 widget 代码，本环境无法运行验证，故未做。
- **P5 后续**（**不再被阻塞**，可直接做）：`main.dart` 路由 `redirect`(kIsWeb 门控)+`refreshListenable=authController`、登录页、`WebTokenStore`(localStorage+`package:web` 直接依赖)、`BootstrapController`(本地优先→解密 vault→`syncDown` via `NasVaultBackedStorage`/`proxy/sync`)、`MediaResolver`/`MediaImage`(公共 CDN 直渲 / `gh-private`→`/proxy/gh` / 本地文件→broken；`imageRenderMethodForWeb: HttpGet`)、各写面 viewOnly 门控、登出清缓存/清本设备数据。建议 P5 收尾后把 `flutter build web` 加进 CI，防止有人新引入会**运行时**炸的原生调用。
- **CAS 字段级合并**：当前 `VaultSyncController` 冲突走 LWW（pull→merge→repush 一次），未做 per-secret `updatedAt` 字段级合并（需 schema 加每字段时间戳）。

### 方案修正（实施中相对原计划的偏离）

- **后端语言用 Rust**（原计划 Go；用户要求）——同样的 API 契约；`tiny_http`(同步多线程)+`rusqlite(bundled，无系统依赖)`+`argon2`+`jsonwebtoken`(HS256 alg 锁定)+`ureq`。本机已 `cargo build`+`cargo test` 验证。
- **`SyncStorage` 方法名**用 `putSyncFile/getSyncFile/deleteSyncFile`（非原 write/read/delete）——零改动复用 OneDrive 既有方法（见 §4.1）。
- **代理凭证来源更正**：原文写"NAS 用 vault 内 PAT"，但零知识下 NAS 解不开 vault。已改为 **客户端每请求经 `X-Upstream-Authorization` 头提供上游凭证**，NAS 仅瞬时转发、不存。
- **NAS 配置用 JSON 文件**（`/data/config.json`）而非 YAML——避免引入 YAML 依赖（纯 stdlib）。
- **NAS 服务器 URL 不拒私网**：用户的 NAS 常在内网（`http://192.168.x.x:48080`），故 `normalizeServerUrl` 只校验是合法 http(s) 绝对 URL；"拒私网"仅用于代理 target 的 SSRF 防护。
- **`leaderboardPrivateKey/PublicKey` 排除出 vault**（每设备身份），与 §3.5 裁定一致。
