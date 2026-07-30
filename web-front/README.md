# explore_journal — web-front (Rust)

一个薄服务，把「在浏览器里回看自己的足迹」这件事变成可能。它做四件事，
并且**不存任何用户内容**（手账、轨迹、迷雾、照片都不在这里）：

1. **单管理员登录** —— 一个 admin 账号，没有注册流程。口令用 **Argon2id** 校验，
   会话是服务端内存里的一张表（进程重启即全部失效），不是 JWT。
2. **配置保管** —— 手机端把「够用来访问你自己的云」的那部分设置推上来，服务端
   **加密存一份**（ChaCha20-Poly1305，密钥由 admin 口令派生），登录后交给 web 端。
3. **只读 WebDAV 代理** —— 浏览器没办法直接读你的 WebDAV（几乎没有 WebDAV 服务端
   发 CORS 头），而且就算能，口令也会落进 JavaScript。走这个代理，口令始终不出服务端。
4. **静态托管 + 管理看板** —— 镜像里带着 Flutter web 产物，`/admin` 是运维看板。

技术栈：`tiny_http`（同步多线程）+ `argon2` + `chacha20poly1305` + `ureq`。
**没有** async 运行时、**没有** 数据库、**没有** 任何系统依赖。数据是 `/data` 下的
两个小文件加一个指标文件。

## 一分钟理解安全边界

> **服务端能解密你的配置。** 这与项目早期的「零知识保险箱」设计相反，是刻意的改变：
> 保密边界从「客户端持有的密钥」换成了「admin 口令」。换来的是 web 端不必在
> JavaScript 里持有任何云凭据，也不需要用户在浏览器里再记一套口令。
>
> 具体后果：
> - **静态状态下服务端不持有明文。** 只有登录时才由口令派生出密钥放进那个会话；
>   进程重启后，没人登录就没人能解密。
> - **改 admin 口令会顺带把配置重新加密一遍**，并吊销全部会话。
> - **忘记 admin 口令 = 已存的配置永久读不出来**（没有恢复通道，这是加密的定义）。
>   出路是从手机端重新推一份配置覆盖它——服务不会卡住，只是那份旧内容没了。
> - 谁能读到 `/data`，谁就拿到了密文 + Argon2 哈希；口令弱的话可以离线爆破。

## 默认口令是 `admin` / `admin`，必须尽快改

新部署起来就是这个口令，而且**任何能连到这个端口的人都能用它登录并读走你全部
云凭据**。所以：

- 登录响应与 `/api/metrics` 都会带 `is_default_password`，看板上是一条不可关闭的
  红色横幅，改密表单就内联在横幅里。
- 手机端「备份 → Web 前端 · 配置推送」也会显示同一条提醒。
- 服务端只在改密时校验长度（≥ 8 位），别把它当成口令强度策略。

## 在 NAS 上部署

CI 每次推 `main` 都会在容器级 smoke 通过之后，把双架构（amd64 + arm64）镜像推到
GHCR，所以 NAS 上不需要源码、不需要编译器：拿本目录的 `docker-compose.ghcr.yml`
（默认把数据放在宿主目录 `/share/Web/ej_data/front`，首次启动前要
`chown -R 65532:65532` 它），`docker compose up -d` 即可。它刻意不使用
`${变量}`，因此也能整段粘进 QNAP Container Station / 群晖 Container Manager 的
YAML 框。**不需要任何必填的环境变量**——早先那个必填的 JWT secret 已经不存在了。

逐步的部署、反代、排错、以及 OneDrive/WebDAV 那些云侧配置，都在
[docs/web-display-deploy.md](../docs/web-display-deploy.md)，这里不重复。
「web-front 镜像（GHCR）」这条 workflow 的**运行摘要**还会把同一套步骤连同那次提交
的确切镜像 tag 一起打出来，从那里复制最省事。

端口 **48080** 是刻意选的高端口：家宽运营商普遍封禁**入方向**的 80 / 443 / 8080，
改回那三个，家里/NAS 部署会从公网完全连不上。兄弟服务 `ej-backend` 用 48081。

## 从源码构建

```bash
cd web-front
docker compose up -d            # 就地构建，监听 :48080

# ……或者不用 Docker
cargo build --release
EJ_DATA_DIR=/tmp/ejdata EJ_LISTEN=127.0.0.1:48080 ./target/release/web-front
```

> `EJ_DATA_DIR` 不设的话默认是 `/data`——在本机直接跑会往那个目录写 `admin.json`，
> 所以本地调试务必显式指定。

## 数据放在哪

`/data`（`EJ_DATA_DIR`）。它挂到哪儿由 compose 决定：NAS 那份默认是宿主目录
`/share/Web/ej_data/front`，源码构建那份默认是 Docker 命名卷 `ej-web-front-data`
（本地开发不落到你的文件系统上）。两者的取舍、备份与互相迁移见
[docs/web-display-deploy.md](../docs/web-display-deploy.md) 的「数据放哪」。

里面有三个文件，都很小（总计通常不到 1 MB）：

| 文件 | 内容 | 丢了会怎样 |
|---|---|---|
| `admin.json` | 用户名、Argon2 口令哈希、派生盐 | 退回默认 `admin`/`admin`，且**配置再也解不开** |
| `config.json` | 加密后的配置密文 | 从手机端重推一份即可 |
| `metrics.json` | 计数器与 24 小时采样序列 | 只丢历史曲线 |

放在**本地文件系统**上。不要指向 NFS/SMB：落盘用的是「写临时文件 → fsync →
原子改名 → fsync 目录」，而网络文件系统对这套语义不可靠。

自检：

```bash
BUILD=1 ./scripts/docker-smoke.sh
```

它会真起容器，跑完整链路：默认口令登录 → 未鉴权全部 401 → 配置往返字节一致 →
导出脱敏 → 改密后配置仍可读（验重加密）→ 重启后会话消失而数据还在 →
代理的两种姿态。amd64 与 arm64 都跑得动（arm64 走 QEMU）。

## 配置项

两个通道：环境变量**覆盖**一个可选的 JSON 文件。改文件 + `docker compose restart`，
不用重建。

`EJ_CONFIG` 默认是**绝对路径** `/data/server.json`，不随 `data_dir` 变——它没法随，
因为 `data_dir` 本身就来自这个文件。容器里 `data_dir` 就是 `/data`，所以默认即正确；
在本机直接跑并改了 `EJ_DATA_DIR` 时，要自己显式给 `EJ_CONFIG`。

> **注意别把它和加密配置搞混。** `<data_dir>/config.json` 是 `PUT /api/config`
> 写的**用户配置密文**，不是服务端设置。早先这两者的默认路径是同一个，而且因为
> 设置里每个字段都可选，加密信封会被**解析成功**并静默退回全默认值。现在设置文件
> 改名为 `server.json`，并且未知键会让启动直接失败——指错文件或拼错键名都会当场报错
> 并告诉你差别在哪。

| 环境变量 | 文件键 | 默认 | 说明 |
|---|---|---|---|
| `EJ_LISTEN` | `listen` | `0.0.0.0:48080` | 高端口，别改回 80/443/8080 |
| `EJ_DATA_DIR` | `data_dir` | `/data` | 上面那三个文件所在目录；本地文件系统 |
| `EJ_WEB_ROOT` | `web_root` | `/web` | 静态产物目录。镜像里已经有一份；挂载同名目录可覆盖 |
| `EJ_TOKEN_TTL_SECS` | `token_ttl_secs` | `3600` | 会话有效期，**每次使用都滑动续期** |
| `EJ_PROXY_ENABLED` | `proxy_enabled` | `false` | 打开 WebDAV 代理与图片读代理 |
| `EJ_PROXY_ALLOW_HOSTS` | `proxy_allow_hosts` | — | `/proxy/url` 的精确主机白名单 |
| `EJ_TRUST_PROXY` | `trust_proxy_header` | `false` | 信任转发头（`CF-Connecting-IP` 优先，回退 `X-Forwarded-For` 最左项）。**经 frp / Cloudflare 暴露时必须开**，否则所有访客共享一个限流桶；**没有反代却开着**则限流桶由调用方自选，等于没有限流 |
| `EJ_METRICS_INTERVAL_SECS` | `metrics_interval_secs` | `60` | 采样间隔（上限 86400）。落盘是每 10 个采样点一次 |
| `EJ_WORKERS` | `workers` | `8` | 工作线程数。**注意**：服务是 thread-per-request 的，见下方威胁模型里关于慢连接的那段 |

`server.json` 示例：

```json
{ "listen": "0.0.0.0:48080", "proxy_enabled": true,
  "proxy_allow_hosts": ["dav.jianguoyun.com"], "token_ttl_secs": 3600 }
```

## 端点

```
GET    /                     静态产物（Flutter web）；未命中回退 index.html
GET    /admin                运维看板（HTML，免 session —— 它自己渲染登录表单）
GET    /healthz              {"status":"ok"}

POST   /api/session          {username, password} → {ok, is_default_password, token}
DELETE /api/session          登出（并让 ej_session cookie 过期）
PUT    /api/password         {old, new}  改密 + 重加密配置 + 吊销全部会话

GET    /api/config           → 配置明文 JSON（尚无配置时是 200 {}）
PUT    /api/config           配置 JSON 对象，≤ 256 KiB
GET    /api/metrics          → 指标快照 + is_default_password
GET    /api/export?what=config|metrics|all[&secrets=1]
                             脱敏是默认；只有精确 secrets=1 才输出明文凭据

PROPFIND|GET|HEAD|OPTIONS /proxy/dav/<path>   只读 WebDAV 代理（写动词 405）
GET    /proxy/gh/{owner}/{repo}/{branch}/{path...}
GET    /proxy/url?u=<abs-url>
```

会话凭据两种都认：`Authorization: Bearer <token>`（原生端）或 `ej_session` cookie
（浏览器）。**两者等价**——所以在公用设备上登出失败时要清 cookie。

限流按「重放这个请求对攻击者有无收益」分桶，每 IP 每分钟：登录与改密 10 次
（爆破防护），其余 `/api/*` 120 次，`/proxy/*` 600 次，`/healthz` 120 次，
静态 1200 次。

## 威胁模型

**能读到 `/data` 的人**拿到 Argon2 口令哈希与配置密文。口令够强则密文无用；
口令弱则可离线爆破后解密。这里没有任何手账/轨迹/迷雾/媒体内容。

**代理是最大的残留面**，默认关闭。打开后：

- `/proxy/url` 的目标来自**请求**，所以它拒绝私网地址（经典 SSRF 支点），并且
  只允许白名单主机。
- `/proxy/dav/*` 的目标来自**管理员自己的配置**，所以它**允许**私网地址——家用
  WebDAV 通常就在局域网里。仍然拒绝环回与链路本地（云元数据 169.254.169.254 在其内），
  并且路径被约束在配置的 `webdavUrl` 前缀内。
- 两个代理共用一个 SSRF 解析器：只返回校验过的 IP 并把连接钉在上面（挫败 DNS
  rebinding），重定向一律不跟随。
- **别把它当多租户暴露**：白名单是全局一份，那等于对白名单主机的开放中继。

**必须置于带超时的反向代理之后。** 服务是 thread-per-request 的，`tiny_http`
不暴露读写超时：8 个慢速连接（`curl --limit-rate 1k` 拉一个大资源就够）能把全部
worker 占死，连 `/healthz` 都超时。反代需要**同时**有读超时与响应写超时（或做
响应缓冲），只有读超时挡不住慢读者。健康探针最好也不要和用户流量共用这几个 worker。

## 与项目早期设计的偏离

- **没有多用户、没有注册、没有 JWT。** 单 admin + 服务端会话表。
- **服务端能解密配置。** 见上面「安全边界」一节的取舍。
- **没有 SQLite。** 数据是几个小 JSON 文件，原子改名 + fsync 落盘。
- **配置是 JSON**（不是 YAML），不引额外依赖。
