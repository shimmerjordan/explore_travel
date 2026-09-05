# 部署与测试：Web 展示版

在浏览器里回看自己的足迹。数据仍然在**你自己的云**（WebDAV / OneDrive / GitHub）里，
这个服务只做三件事：托管 web 产物、保管一份「怎么访问你的云」的配置、以及替浏览器
去读它自己读不到的 WebDAV。

整条链路：

```
手机（配置的权威）──推配置──▶ web-front（NAS，48080）──▶ 浏览器
                                   │                    （登录后拉到配置，
                                   └──只读代理──▶ 你的 WebDAV   直连或经代理读数据）
```

> **一句话安全边界**：服务端**能**解密那份配置（密钥由 admin 口令派生）。这与项目
> 早期的「零知识保险箱」相反，是刻意的取舍——换来的是浏览器里不必持有任何云凭据。
> 详见 [web-front/README.md](../web-front/README.md)。

---

## A. 部署 web-front

### 用现成镜像（推荐，NAS 上不需要编译器）

```bash
sudo mkdir -p /share/Web/ej_data/front
sudo chown -R 65532:65532 /share/Web/ej_data/front   # 容器以 UID 65532 运行
cd /share/Web/ej_data/front
# 把 web-front/docker-compose.ghcr.yml 放到这里，然后：
sudo docker compose up -d
curl localhost:48080/healthz        # {"status":"ok"}
```

> compose 文件放在**这个服务自己的目录**里，别放到公共的 `/share/Web/ej_data`：
> 兄弟服务 `ej-backend` 的部署指引长得一样，两份 `docker-compose.yml` 落到同一个目录会
> 互相覆盖；而且 compose 用目录名当项目名，两个服务挤进一个 project 后，在那里
> `docker compose up -d --remove-orphans` 会把另一个容器当孤儿删掉。

那条 `chown` 是必须的：docker 会把不存在的挂载点自动建成 root 所有，而服务以
nonroot 运行——不改权限的话第一行日志就是 `admin file error`。

**没有 `.env`、没有任何必填的环境变量。** 早先必填的 JWT secret、以及整个
`EJ_CORS_ORIGINS` 都不存在了——web 产物由这个服务自己托管，页面与 API 同源，
压根不经过 CORS。

`docker-compose.ghcr.yml` 刻意**不使用 `${变量}`**，所以它也能整段粘进 **QNAP
Container Station / 群晖 Container Manager** 的「创建应用程序」YAML 框：那些图形
界面不做变量插值，粘一份带变量的进去会直接以 `invalid reference format` 失败（它
把整串变量当成镜像名）。用图形界面时，上面的 `mkdir` + `chown` 仍要 SSH 跑一次。

「web-front 镜像（GHCR）」这条 workflow 的运行摘要会把上面这段连同那次提交的确切
镜像 tag 一起打出来，从那里复制即可。

### 端口：别改回 80 / 443 / 8080

家宽运营商普遍封禁**入方向**的这三个端口，改回去会从公网完全连不上。
web-front 用 **48080**，`ej-backend`（排行榜 + 组队）用 **48081**。

### 经反代 / 内网穿透暴露时必须开一个开关

```yaml
environment:
  EJ_TRUST_PROXY: "1"   # GHCR 那份 compose 里已经是 1（默认姿态是走 Cloudflare）
```

限流是**按客户端 IP 分桶**的。不开这个，服务看到的来源永远是反代自己的地址，于是
**所有访客共享同一个桶**——一个人试几次口令就能把别人也挡在外面。

**反过来同样危险：没有任何反代却开着它，等于没有限流。** 那时转发头是调用方随手写的，
每个来访者都能自选分桶，登录那条 10 次/分钟的爆破防护就形同虚设。只在局域网里直连
端口用，请改回 `0`。

服务优先读 `CF-Connecting-IP`，取不到才回退 `X-Forwarded-For` 的最左项。这个次序是
必须的，不是偏好：**Cloudflare 是把真实 IP 追加在 `X-Forwarded-For` 末尾的**，调用方
自带的伪造值留在最左，只看 XFF 会被它带偏（`ej-backend` 的 `clientIp()` 同样是这个
次序，两个服务在同一条隧道后面应当分桶一致）。

其余可调项（都有合理默认，不必动）：`EJ_WEB_ROOT`（覆盖镜像里自带的 web 产物）、
`EJ_METRICS_INTERVAL_SECS`（采样间隔）、`EJ_WORKERS`（工作线程数）。
两个 compose 文件里都已列出并写了说明。

### 经 Cloudflare Tunnel 暴露到公网（推荐）

家宽的入方向 80/443 被封，而 Tunnel 走的是**出**方向 443，所以不需要公网 IP、不需要
端口映射、还白拿 HTTPS。**一条 tunnel 就能同时带这两个服务**，不用起两个 cloudflared。

> ⚠️ **先看清你的 NAS 上有没有已经在跑的 cloudflared**，这决定走下面哪条路，而且两条
> 路**不能混**：cloudflared 只要看见 `TUNNEL_TOKEN` 环境变量（或命令行 `--token`），
> 就会去跑 token 对应的那条隧道并**完全忽略本地 `config.yml`**。往一台已经用
> config.yml 托着好几个服务的机器上再塞一个带 token 的容器，那些服务会一起哑掉。

#### 情况 1：NAS 上已经有 cloudflared 在跑本地 config.yml（多服务共用一条隧道）

这时**不要新建隧道、不要起第二个容器**，只往现有 `config.yml` 的 `ingress` 里加两条：

```yaml
ingress:
  # …你已有的那些服务…
  - hostname: ej-front.<你的域名>
    service: http://localhost:48080
  - hostname: ej-backend.<你的域名>
    service: http://localhost:48081
  # catch-all 必须留在最后一条，新条目一律插在它前面
  - service: http_status:404
```

然后重启那个容器（`docker restart <容器名>`，或在它的目录里 `docker compose restart`）。

DNS：如果你当初是把整个 `*.<你的域名>` 通配符 CNAME 指到这条隧道的，**DNS 侧什么都不用
动**；如果是逐条加的，就再加两条 CNAME 指向同一条隧道（`<隧道ID>.cfargotunnel.com`），
或者用 `cloudflared tunnel route dns <隧道名> ej-front.<你的域名>`。

`service:` 写 `http://`（不是 https）——隧道内部是明文到本机，对外 TLS 由 Cloudflare 边缘
终止。那个 cloudflared 容器需要能连到这两个端口：host 网络下 `localhost` 就是 NAS 本机；
若它跑在 bridge 网络里，把 `localhost` 换成 NAS 的局域网 IP。

#### 情况 2：从零起一条隧道（NAS 上还没有 cloudflared）

最省事的是 token 模式，hostname 在 Cloudflare 面板里管，本机不需要 config 文件：

**① 建 tunnel 拿 token** —— 面板 → **Zero Trust** → **Networks** → **Tunnels** →
**Create a tunnel** → 选 **Cloudflared** → 起个名（例如 `ej-nas`）→ 环境选 **Docker** →
复制它给你的那条 `--token eyJ…`（只要 token 那一段）。

**② NAS 上跑 cloudflared**（Container Station / Container Manager 里新建一个应用，粘这段）

```yaml
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: ej-cloudflared
    restart: unless-stopped
    # host 网络是刻意的：Container Station 里 web-front 与 ej-backend 是两个独立
    # 应用，各自在自己的 compose 网络里，cloudflared 用容器名连不到它们。走 host
    # 网络后，面板里的 ingress 直接写 http://localhost:48080 / 48081 就行。
    # 万一你的机器不给用 host 网络：删掉这一行，把面板里的 localhost 换成 NAS 的
    # 局域网 IP（例如 http://192.168.1.10:48080）。
    network_mode: host
    # token 直接填在这里（这份文件不含任何 ${变量}，图形界面能整段粘）。
    # ⚠️ 这一行让本容器进入 token 模式，它会忽略任何本地 config.yml。
    command: tunnel --no-autoupdate run --token 把你复制的token粘到这里
    mem_limit: 128m
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
```

**③ 面板里加两条 Public hostname**（同一条 tunnel 下，**Public Hostname** 标签页）

| Subdomain | Domain | Type | URL |
|---|---|---|---|
| `ej-front` | `<你的域名>` | HTTP | `localhost:48080` |
| `ej-backend` | `<你的域名>` | HTTP | `localhost:48081` |

Type 填 **HTTP**（不是 HTTPS），理由同上。DNS 那两条 CNAME 由 Cloudflare 自动建。

> 如果你以后还要往这台机器加别的服务、或者想给某个 origin 配 `noTLSVerify` 之类的
> `originRequest` 选项，改用 config.yml 模式（`cloudflared tunnel login` +
> `tunnel create` + `tunnel --config … run`，**不设 TUNNEL_TOKEN**）会更好管：
> 一条隧道 + 一个通配符 CNAME，之后加服务只动 ingress。

**④ 验证**

```bash
curl https://ej-front.<你的域名>/healthz        # → {"status":"ok"}
curl https://ej-backend.<你的域名>/healthz      # → ok
```

之后：浏览器开 `https://ej-front.<你的域名>/`（看板在 `/admin`）；手机 App 的
「Web 前端 · 配置推送」服务器地址填 `https://ej-front.<你的域名>`；排行榜与
组队中继填 `https://ej-backend.<你的域名>`（组队的 `wss://…/group/v1/ws` 由
App 自己转换，Cloudflare 默认放行 WebSocket，不用额外配置）。

**换成 https 之后白捡的东西**：整站进入**安全上下文**，于是地理定位、PWA「安装到桌面」、
`crypto.subtle` 全部可用——这些在 `http://<局域网IP>:48080` 下是拿不到的（见下面 E 节）。
代价是 OneDrive 要在 Azure 里补一条 SPA 重定向 URI：
`https://ej-front.<你的域名>/auth.html`（Azure 不做前缀匹配，逐字一致）。

**几件必须知道的事**

- **`/admin` 现在暴露在公网上，任何人都能打开那个登录页。** 服务只校验口令 ≥ 8 位，
  没有别的强度策略，也没有第二因素。**改一个真正强的口令**，否则等于把全部云凭据
  挂在公网上赌 10 次/分钟的限流。想加一层就在 Cloudflare 面板给 `/admin` 挂一条
  Access 策略（邮箱 OTP），它不影响 App 推配置与浏览器登录 API。
- **单次 HTTP 请求有超时**（免费版约 100 秒，超时给 524）。日常 API 都在毫秒级，唯一
  可能撞上的是 WebDAV 只读代理拉一个很大的媒体文件。
- **请求体上限 100 MB**（免费版）。配置推送 ≤ 256 KiB，够不着。
- **别拿它当视频分发**：大量非 HTML 大文件走 CDN 属于 Cloudflare 服务条款的灰区。
  照片级别的 WebDAV 回读没问题。
- 两个服务的**限流分桶**依赖上一节那个开关：web-front 的 GHCR compose 已经是 `1`，
  `ej-backend` 的 `TRUST_PROXY` 本来就是 `1`，不用改。

`ej-backend` 侧的部署与它自己的暴露方式见 [self-host.md](self-host.md)。

### 数据放哪

三个小文件（总计通常不到 1 MB）：`admin.json`（口令哈希与派生盐）、
`config.json`（配置密文）、`metrics.json`（指标）。两份 compose 的默认位置
**刻意不同**：

| compose | 默认 | 首次启动前要做的事 |
|---|---|---|
| `docker-compose.ghcr.yml`（NAS 部署） | 宿主目录 `/share/Web/ej_data/front` | `mkdir -p` + `chown -R 65532:65532`（见上） |
| `docker-compose.yml`（源码构建 / 本地开发） | Docker 命名卷 `ej-web-front-data` | 无。命名卷继承镜像里 nonroot 拥有的 `/data` |

`/share/Web/…` 是 QNAP 上共享文件夹的真实路径（`/share/<共享文件夹名>/…`），群晖
一般是 `/volume1/docker/…`。换成另一种方案只需改 compose 里挂载那一行的左边：
绝对路径 = 宿主目录，名字 = 命名卷。

宿主目录方案的好处是数据在容器之外，升级、删了重建、NAS 自带的备份任务都不受影响；
命名卷方案的好处是零权限配置，代价是 **`docker compose down -v` 会连数据一起删掉**
（停服务请用不带 `-v` 的 `down`），而且只能用 docker 命令导出：

```bash
# 备份 —— 宿主目录方案
sudo tar czf web-front-backup-$(date +%F).tgz -C /share/Web/ej_data/front .

# 备份 —— 命名卷方案
docker run --rm -v ej-web-front-data:/data -v "$PWD":/backup busybox \
  tar czf /backup/web-front-data.tgz -C /data .

# 从命名卷迁到宿主目录（含 2026-07-30 之前部署用的 `<项目名>_ejdata`）
sudo mkdir -p /share/Web/ej_data/front
docker run --rm -v ej-web-front-data:/from -v /share/Web/ej_data/front:/to \
  busybox sh -c 'cd /from && cp -a . /to'
sudo chown -R 65532:65532 /share/Web/ej_data/front
```

**放本地盘，不要放 NFS/SMB。** 落盘用「写临时文件 → fsync → 原子改名 → fsync 目录」，
网络文件系统对这套语义不可靠。

> 兄弟服务 `ej-backend`（排行榜 + 组队）的数据目录是 `/share/Web/ej_data/backend`，
> 但它以 `node`（UID **1000**）运行，`chown` 的 UID 与这里不同。部署见
> [self-host.md](self-host.md)。

---

## B. 第一次登录

1. `http://<NAS>:48080/` —— 应用本身。
2. `http://<NAS>:48080/admin` —— 运维看板。
3. 两处都用默认口令 **`admin` / `admin`**。
4. **立刻改掉它。** 看板顶部有一条不可关闭的红色横幅，改密表单就内联在里面。

> 任何能连到这个端口的人都能用默认口令登录并读走你**全部**云凭据。改密会顺带把
> 已存的配置重新加密一遍，并吊销全部会话（手机端与这一页都要重新登录）。
>
> **忘记 admin 口令 = 已存的配置永久读不出来。** 没有恢复通道——那是加密的定义。
> 出路是从手机端重推一份覆盖它；服务不会卡住，只是那份旧内容没了。

---

## C. 把配置从手机推上来

web 端**不能**配置云——它是只读展示端。配置的权威在手机上：

**手机 App → 备份 → 「Web 前端 · 配置推送」**

填服务器地址（`http://<NAS>:48080`）、用户名、口令，点「登录并推送当前配置」。

几件值得先知道的事：

- 口令**不存在手机上**，只有会话令牌会存。换设备或重装要重新输入。
- 这个动作会**先与服务器上已有的配置合并**（服务器已有的值优先），再整份上传。
  所以刚在手机上改完还没推的值可能被服务器上的旧值覆盖——成功提示里会告诉你有
  几项被改写了。想让手机侧的值赢，就改完立刻推。
- 语音与音乐凭据**刻意不参与漫游**（`sttApiKey` / `ttsApiKey` / `volcTtsToken` /
  `musicCredentials`）：只读 web 端不需要它们，上传只是扩大 admin 口令被攻破时的
  影响面。
- 服务器地址改了必须重新登录——会话是绑定到某一台服务器的，界面会自动要求重登。

推完刷新浏览器，web 端登录后就会拉到这份配置。

---

## D. 让 web 能读到数据

取决于你用的云：

| 云 | 浏览器能否直连 | 说明 |
|---|---|---|
| **OneDrive** | 能 | Microsoft Graph 发 CORS 头。见 D2 |
| **GitHub** | 能 | Contents API 发 CORS 头 |
| **WebDAV** | **不能** | 几乎没有 WebDAV 服务端发 CORS 头 → 走 web-front 的只读代理 |

### D1. WebDAV 要打开代理

```yaml
# docker-compose 的 environment 里
EJ_PROXY_ENABLED: "1"
```

打开后 `PROPFIND|GET|HEAD|OPTIONS /proxy/dav/<path>` 可用；凭据由服务端从配置里取出
注入，**不下发给浏览器**。写动词（PUT/DELETE/MKCOL/MOVE/PROPPATCH）一律 405——
这是只读代理，一次 XSS 不能抹掉你的云备份。目标路径被约束在配置的 `webdavUrl`
前缀内（字面 `../`、`%2f` 单编码、`%252f` 双编码三种穿越都拒绝）。

代理默认关闭，且关闭时连「这个功能存在」都不暴露（返回 404 而不是 401）。

### D2. OneDrive 需要在 Azure 里加重定向 URI

必须是 **SPA 平台**，URI 与页面实际所在的 origin + 路径**逐字一致**（Azure 不做
前缀匹配）：

```
https://ej-front.<你的域名>/auth.html   ← 经 Cloudflare Tunnel（推荐姿态）
http://<NAS 或本机>:48080/auth.html             ← 局域网直连 web-front（应用在根路径）
https://<你的域名>/app/auth.html                ← 宣传站部署（应用在 /app/ 下）
```

三个可以同时存在（Azure 允许一个应用注册挂多条 SPA 重定向 URI），所以走 Cloudflare
之后不必删掉局域网那条——两种访问方式都还能登。

没加会在登录后报 `AADSTS9002326`。细节见 [onedrive_setup.md](onedrive_setup.md)。

> 早先文档里的 `48082` 是那个已经不存在的独立静态服务的端口。

---

## E. 安全上下文：局域网部署最容易踩的坑

浏览器把一批能力限制在**安全上下文**（https 或 `http://localhost`）里。用
`http://<局域网IP>:48080` 打开时，这些会失效：

| 能力 | 在 `http://<LAN-IP>` 下 |
|---|---|
| 地理定位 | 失败。地图右上会给一次性提示 |
| PWA「安装到桌面」 | 不出现安装按钮 |
| `crypto.subtle` | 不可用 |

**解法**：走 [Cloudflare Tunnel](#经-cloudflare-tunnel-暴露到公网推荐)（`https://ej-front.…`，
上表三项全部恢复，且不需要自己管证书）——这是本仓库的默认姿态；或在 NAS 本机用
`http://localhost:48080`；或前面自套带证书的 Caddy / Nginx；或者只看数据不需要定位，
接受上表缺失。

> **另一件必须做的事**：web-front 是 thread-per-request 的，`tiny_http` 不暴露读写
> 超时。8 个慢速连接就能把全部 worker 占死（`curl --limit-rate 1k` 拉一个大资源即可），
> 连 `/healthz` 都会超时。所以**要置于带超时的反代之后**，而且反代需要**同时**有
> 读超时与响应写超时（或做响应缓冲）——只有读超时挡不住慢读者。

---

## F. Web 端的行为与限制

1. **只读 · 展示模式**：地图顶部居中有徽标，记录/编辑入口隐藏。
   *后门*：菜单页连点版本号 10 次开调试模式 → 解除只读（用于调试）。
2. **自动推送在 web 端是关闭的**。web 拉下配置后本地设置会变化，若还挂着自动推送，
   浏览器里任何本地改动都会覆盖手机推上来的权威配置。
3. **进入 3D 地球**：桌面没有双指捏合——把地图滚轮缩到最小后再向下滚 3 次
   （底部有「再向下滚动 N 次」提示）。手机仍是捏合 3 次。
4. **桌面排版**：设置页、备份页在 >800px 宽时内容居中限宽到 720px
   （`ResponsiveContent`），不拉满整行。
5. **PWA**：`web/manifest.json` 已配 standalone + 192/512 + maskable 图标 +
   `theme_color`。安全上下文下地址栏会出现「安装」按钮。
6. **手动导入备份 zip** 这条路依然可用——不配任何云也能在 web 上看数据，用来单独
   验证渲染是否正常。

---

## G. 验证清单速查

| 测什么 | 怎么测 |
|---|---|
| 服务端逻辑 | `cd web-front && cargo test --offline` |
| 整个镜像（真容器、完整链路） | `cd web-front && BUILD=1 ./scripts/docker-smoke.sh` |
| 客户端逻辑 | `flutter test` |
| web 能编译 | `flutter build web --release` |
| 登录门 + 配置往返 | 浏览器走 B、C 两节 |
| 改密后配置没丢 | 改密 → 用新口令登录 → 配置内容仍在（smoke 里也有这一条） |
| 手机 → web 全链路 | C 节推配置 → 刷新浏览器 |

---

## H. 排错

### 页面打得开但登录报错

| 提示 | 含义与做法 |
|---|---|
| 用户名或密码错误 | 服务端不区分「用户名不存在」与「口令错」，这是有意的 |
| 登录过于频繁，请 N 秒后再试 | 登录桶是 **10 次/分钟**。等一分钟；继续重试只会一直把桶填满 |
| 无法连接到服务器 | 浏览器能打开 `http://<NAS>:48080/healthz` 吗？ |
| 服务器的 HTTPS 证书不被信任 | 自签证书：改用 http，或先装证书 |

### 登录成功但看不到数据

1. 配置推上来了吗？看板上看 `/api/config` 是否有内容（或用导出看）。
2. 用的是 WebDAV 吗？`EJ_PROXY_ENABLED` 打开了吗？
3. 看 `docker logs web-front` 里 `/proxy/dav/...` 的状态码：
   - `404` = 代理没打开；
   - `409` = 配置里没有可用的 `webdavUrl`，重推配置；
   - `403` = 目标路径越出了配置的前缀；
   - `502` = 上游 WebDAV 没应答。

### 容器起不来

看 `docker logs web-front` 第一行：

| 日志 | 原因 |
|---|---|
| `admin file error: ...` | `/data` 不可写。挂宿主目录时忘了 `chown -R 65532:65532`（最常见）；docker 自动创建的挂载点是 root 所有的 |
| `config error: parse ... unknown field` | `EJ_CONFIG` 指错了文件，或设置里键名拼错。**注意** `<data_dir>/config.json` 是配置**密文**，不是服务端设置；设置文件默认是 `<data_dir>/server.json` |
| `listen on ...: Address already in use` | 端口被占 |

### 把服务端状态导出来看

看板底部三个按钮，或直接：

```bash
T=$(curl -s -X POST localhost:48080/api/session -H 'content-type: application/json' \
     -d '{"username":"admin","password":"<你的口令>"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s "localhost:48080/api/export?what=config"  -H "Authorization: Bearer $T"   # 脱敏
curl -s "localhost:48080/api/export?what=metrics" -H "Authorization: Bearer $T"   # CSV
```

**默认脱敏**，凭据字段为 `null`。只有精确 `&secrets=1` 才输出明文（用于迁到另一台
NAS），而且那一次会在服务端日志里留下一条 `AUDIT:` 记录。

---

## I. 宣传站是另一个 job

`.github/workflows/build.yml` 的 `site` job 产出的是**合并站点**（宣传落地页在 `/`、
应用在 `/app/`），推到 `web-build` 分支供 Vercel / Cloudflare Pages 部署。它与同一条
流水线里 `image` job 产出的镜像**不是**同一个东西，也无法共用一次构建（base-href
不同），镜像里根本没有落地页。两者可以并存。
