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
sudo mkdir -p /volume1/docker/web-front/data && cd /volume1/docker/web-front
# 取 web-front/docker-compose.ghcr.yml，然后：
printf 'EJ_DATA_PATH=/volume1/docker/web-front/data\n' > .env
sudo chown -R 65532:65532 /volume1/docker/web-front/data   # 容器以 UID 65532 运行
sudo docker compose up -d
curl localhost:48080/healthz        # {"status":"ok"}
```

**没有任何必填的环境变量。** 早先必填的 JWT secret、以及整个 `EJ_CORS_ORIGINS`
都不存在了——web 产物由这个服务自己托管，页面与 API 同源，压根不经过 CORS。

「web-front 镜像（GHCR）」这条 workflow 的运行摘要会把上面这段连同那次提交的确切
镜像 tag 一起打出来，从那里复制即可。

### 端口：别改回 80 / 443 / 8080

家宽运营商普遍封禁**入方向**的这三个端口，改回去会从公网完全连不上。
web-front 用 **48080**，`ej-backend`（排行榜 + 组队）用 **48081**。

### 经反代 / 内网穿透暴露时必须开一个开关

```yaml
environment:
  EJ_TRUST_PROXY: "1"
```

限流是**按客户端 IP 分桶**的。不开这个，服务看到的来源永远是反代自己的地址，于是
**所有访客共享同一个桶**——一个人试几次口令就能把别人也挡在外面。直接暴露端口时
保持 `0`（那时 `X-Forwarded-For` 是客户端可伪造的，信任它反而让限流失效）。

其余可调项（都有合理默认，不必动）：`EJ_WEB_ROOT`（覆盖镜像里自带的 web 产物）、
`EJ_METRICS_INTERVAL_SECS`（采样间隔）、`EJ_WORKERS`（工作线程数）。
两个 compose 文件里都已列出并写了说明。

### 数据放哪

`EJ_DATA_PATH` 不设 → Docker 命名卷（零宿主配置）；设成绝对路径 → bind mount，
但**首次启动前**要 `chown -R 65532:65532 <path>`，否则容器起不来。

目录里三个小文件（总计通常不到 1 MB）：`admin.json`（口令哈希与派生盐）、
`config.json`（配置密文）、`metrics.json`（指标）。

**放本地盘，不要放 NFS/SMB。** 落盘用「写临时文件 → fsync → 原子改名 → fsync 目录」，
网络文件系统对这套语义不可靠。

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
http://<NAS 或本机>:48080/auth.html     ← web-front 自托管（应用在根路径）
https://<你的域名>/app/auth.html        ← 宣传站部署（应用在 /app/ 下）
```

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

**解法**（任一）：在 NAS 本机用 `http://localhost:48080`；前面套一个带证书的反代
（Caddy / Nginx / Cloudflare Tunnel）走 https；或者只看数据不需要定位，接受上表缺失。

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
| `admin file error: ...` | `/data` 不可写。bind mount 忘了 `chown 65532` |
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

## I. 宣传站是另一条流水线

`.github/workflows/deploy-web.yml` 产出的是**合并站点**（宣传落地页在 `/`、应用在
`/app/`），推到 `web-build` 分支供 Vercel / Cloudflare Pages 部署。它与这里说的
web-front 镜像**不是**同一个东西，也无法共用一次构建（base-href 不同），镜像里根本
没有落地页。两者可以并存。
