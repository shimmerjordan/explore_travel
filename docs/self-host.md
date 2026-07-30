# 自建服务器 · 部署与接入

Explore Journal 的排行榜与组队（位置共享 / 聊天 / 对讲 / 音乐同步）默认走
去中心化方案（P2P gossip、局域网、frp 打洞），**不强制任何后端**。但自建一台
后端可以让「互不见面」的用户也能同步排行榜、让组队在任何网络下都能连通。

项目有**两个互不相关的自建服务**，别把地址填串：

| 服务 | 默认端口 | 干什么 | 本文对应部分 |
|---|---|---|---|
| `ej-backend` | **48081** | 社区排行榜 + 组队云中继 | 第一、二部分 |
| `web-front` | **48080** | 浏览器里回看足迹（配置保管 + 看板 + 静态托管） | 只在本文第三部分「Web 展示版接入」出现；部署见 [web-display-deploy.md](web-display-deploy.md) |

两个可以只装一个。下文里「**服务器地址**」在排行榜与组队两节指 ej-backend
（如 `http://1.2.3.4:48081`），在 Web 展示版那节指 web-front（如 `http://<NAS>:48080`）。

后端代码在仓库 `backends/` 目录：**一个 Node 进程、一个端口、零依赖**，
同时提供两个模块：

| 模块 | 协议 | 端点 | 开关 |
|---|---|---|---|
| 排行榜 | HTTP JSON | `/entries` `/monthly/{yyyy-MM}` `/index` | `EJ_MODULE_LEADERBOARD` |
| 组队中继 | WebSocket | `/group/v1/ws` | `EJ_MODULE_GROUP` |

资源占用极小：常驻内存 ~40 MB、空闲 CPU≈0、闲时每成员带宽 ~10 B/s，
最低配 ECS（1核1G 甚至更小）即可长期运行。

---

# 第一部分：部署 ej-backend

两条路，选一条：

- **用现成镜像**（NAS / 不想装编译环境）：`backends/docker-compose.ghcr.yml`
  直接拉 GHCR 上的多架构镜像。那份文件刻意不含 `${变量}`，可以整段粘进 QNAP
  Container Station / 群晖 Container Manager 的 YAML 框。「ej-backend 镜像（GHCR）」
  这条 workflow 的运行摘要会把它连同那次提交的确切 tag 一起打出来，从那里复制最省事。
- **从源码构建**（ECS / 想改代码）：见下面「一、准备」。

## 一、准备（源码路线）

- 一台 ECS / VPS（任何架构，能跑 Docker 即可）
- 已安装 Docker + docker compose 插件

```bash
# 把 backends/ 传到服务器
scp -r backends/ user@your-ecs:/opt/ej-backend
ssh user@your-ecs
cd /opt/ej-backend
```

## 二、启动服务

```bash
# 可选：写访问令牌（推荐公网环境设置）
cat > .env <<'EOF'
LB_WRITE_TOKEN=换成你的排行榜写入令牌
GROUP_TOKEN=换成你的组队房间令牌
EOF

docker compose up -d --build

# 验证
curl http://localhost:48081/healthz      # → ok
curl http://localhost:48081/api/status   # 模块状态 / 内存 / 在线人数
```

用现成镜像那条路不需要 `.env`：令牌直接填在 `docker-compose.ghcr.yml` 的
`environment:` 里，然后 `docker compose up -d`。

### 数据存哪

排行榜数据是 `/data/leaderboard.json`（防抖原子写，SIGTERM 时自动落盘）。
备份它等于备份全部服务端状态。两份 compose 的默认位置**刻意不同**：

| compose | 默认 | 首次启动前要做的事 |
|---|---|---|
| `docker-compose.ghcr.yml`（NAS 部署） | 宿主目录 `/share/Web/ej_data/backend` | `sudo mkdir -p` 它，再 `sudo chown -R 1000:1000` 它。容器以 `node`（UID 1000）运行，而 docker 会把不存在的挂载点建成 root 所有 —— 不改权限排行榜写不进去 |
| `docker-compose.yml`（源码构建 / 本地开发） | Docker 命名卷 `ej-backend-data` | 无。命名卷继承镜像里的所有权 |

两种都能换成另一种：改 compose 里挂载那一行的左边即可（绝对路径 = 宿主目录，
名字 = 命名卷）。命名卷方案下 **`docker compose down -v` 会连数据一起删掉**，
停服务请用不带 `-v` 的 `down`。

```bash
# 备份 —— 宿主目录方案
sudo tar czf ej-backend-backup-$(date +%F).tgz -C /share/Web/ej_data/backend .

# 备份 —— 命名卷方案
docker run --rm -v ej-backend-data:/data -v "$PWD":/backup busybox \
  tar czf /backup/ej-backend-data.tgz -C /data .

# 从命名卷迁到宿主目录
sudo mkdir -p /share/Web/ej_data/backend
docker run --rm -v ej-backend-data:/from -v /share/Web/ej_data/backend:/to \
  busybox sh -c 'cd /from && cp -a . /to'
sudo chown -R 1000:1000 /share/Web/ej_data/backend
```

宿主路径只能指向本机文件系统，别指向 NFS/SMB：落盘依赖原子改名 + fsync 语义，
网络文件系统对这套语义不可靠。

`/share/Web/...` 是 QNAP 上共享文件夹的真实路径（`/share/<共享文件夹名>/…`），
群晖一般是 `/volume1/docker/…`，换机器记得改。

### 主要环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `EJ_MODULE_LEADERBOARD` / `EJ_MODULE_GROUP` | 都开 | 设 `0`（或 `false`/`no`/`off`）只跑其中一半。见下方「只跑一半」 |
| `LB_WRITE_TOKEN` | 空 | 设置后提交成绩需令牌；读取始终公开 |
| `GROUP_TOKEN` | 空 | 设置后组队连接需令牌 |
| `GROUP_MAX_ROOM_SIZE` | 32 | 单房间人数上限 |
| `TRUST_PROXY` | `1`（compose 内） | 经 frp/CF 暴露时信任转发头做限流分桶 |
| `LOG_LEVEL` | info | trace / info / warn / error |

### 只跑一半

两个模块相互独立，可以只启用需要的那个。关掉的模块**不会被构造**——不注册路由、
不开文件、不起定时器，而不只是被路由绕过。

```yaml
# 只要排行榜（不需要组队中继）
environment:
  EJ_MODULE_GROUP: "0"
# 结果：/entries /monthly /index 正常；WebSocket 升级被拒；/api/status 里只有 leaderboard
```

```yaml
# 只要组队中继（不需要排行榜）
environment:
  EJ_MODULE_LEADERBOARD: "0"
# 结果：/group/v1/ws 正常；/entries /monthly /index 返回 404
```

两个都关会**拒绝启动并以非零码退出**：带零个模块占着端口会通过所有健康检查，却对
一切真实请求返回 404，那是最难定位的一类故障。

值拼错（比如 `flase`）时模块**保持启用**并在日志里告警——「你想关的还在跑」是吵闹
且可恢复的，「你想要的服务悄悄没了」才难发现。

## 三、暴露到公网（三选一，可叠加）

### 方式 1：直接放行端口

安全组放行 `48081/tcp`，客户端填 `http://ECS公网IP:48081`。
最简单，但没有 TLS——建议只在配合共享口令（组队端到端加密）时使用，
或前面自套 Nginx/Caddy 做 HTTPS。

家宽 / NAS 部署要注意：运营商普遍封禁**入方向**的 80 / 443 / 8080，
所以本服务固定用高端口 48081（web-front 用 48080），别改回那三个。

### 方式 2：frpc（复用你现有的 frps）

适合 ECS 没有公网入方向、或想统一走 frps 的场景：

```bash
cp deploy/frpc.toml.example deploy/frpc.toml
vi deploy/frpc.toml          # 填 frps 地址 / 端口 / token
docker compose --profile frp up -d
```

样例里提供两种代理：
- `tcp`：客户端填 `http://frps主机:18080`
- `http` 虚拟主机（frps 需开 `vhostHTTPPort`）：客户端填 `http://ej.example.com`

建议开 `transport.tls.enable = true` 保护 frpc→frps 链路。

### 方式 3：Cloudflare Tunnel（推荐）

免公网 IP、自动 HTTPS/WSS、自带 CDN 抗量，走的是**出**方向 443，不受入方向封禁影响。

**如果你同时也在跑 web-front**（NAS 上的常见情形）：**一条 tunnel 就能带两个服务**，
不要起两个 cloudflared。完整步骤（建 tunnel、cloudflared 的 compose、两条 public
hostname 怎么填、Cloudflare 的几条硬限制）写在
[web-display-deploy.md 的「经 Cloudflare Tunnel 暴露到公网」](web-display-deploy.md#经-cloudflare-tunnel-暴露到公网推荐)
一节，本仓库的命名约定是：

| Subdomain | 指向 | 服务 |
|---|---|---|
| `ej-front` | `localhost:48080` | web-front（浏览器回看足迹 + 看板） |
| `ej-backend` | `localhost:48081` | 本服务（排行榜 + 组队中继） |

**只跑 ej-backend** 的话，本目录的 compose 自带一个 cloudflared 旁路容器：

```bash
export TUNNEL_TOKEN=eyJ...
docker compose --profile cloudflare up -d
```

它用 `network_mode: "service:backend"`，所以面板里的 Public hostname 填
`HTTP://localhost:48081`。

客户端侧：排行榜的 `Base URL` 与组队的**服务器地址**都填
`https://ej-backend.<你的域名>`，App 会自己把组队那条转成 `wss://…/group/v1/ws`
（Cloudflare 默认放行 WebSocket，不用额外配置；组队心跳约 25 秒一条，够不上
Cloudflare 的空闲断连线）。

> 经 frp / Cloudflare / 任何反代暴露时，`TRUST_PROXY` 必须是 `1`（compose 里已经是），
> 否则限流看到的来源永远是反代自己，**所有用户共享同一个桶**。反之**直接暴露端口时应设
> `0`**：那时转发头是调用方可伪造的，信任它等于让每个来访者自选限流桶。
> 取值次序是 `cf-connecting-ip` 优先、回退 `x-forwarded-for`——Cloudflare 把真实 IP
> 追加在 XFF 末尾，只看 XFF 会被调用方自带的伪造值带偏（web-front 的 `client_ip()`
> 同样是这个次序）。

## 四、运维

```bash
docker compose logs -f backend                        # 日志
curl -s localhost:48081/api/status                    # 在线房间/人数/转发计数/内存
docker compose pull && docker compose up -d           # 升级（现成镜像）
docker compose up -d --build                          # 升级（源码构建）
```

钉版本（可复现、可回滚）：把 compose 里 `image:` 那行的 `:latest` 换成
`:sha-<7位提交号>`，再 `up -d`。

安全模型速记：

- 排行榜条目自带 **Ed25519 签名**，服务器验签 + TOFU 公钥锁定 + LWW 时间戳，
  客户端拉取时还会再验一遍——服务器作恶只会被客户端丢弃数据；
- 组队消息在客户端设置共享口令后为 **端到端加密**，服务器零知识转发，
  只能看到房间名和 peerId；
- 双令牌 + 每 IP 限流（读 60/分、写 10/分、连接 30/分）+ 单连接限速，
  防止公网扫描和滥用。

## 五、扩展新模块

模块签名 `(cfg) => ({ name, routes?, onUpgrade?, status?, shutdown? })`，
在 `server/modules/` 加文件 + `server.js` 的 `MODULES` 数组加一行即可，
路由按 `/<module>/v1/…` 命名空间。测试跑 `npm test`（含与 App 逐字节
一致的 Dart 签名交叉验证向量）。

想自己从零写一个兼容的排行榜服务端，接口契约见
[leaderboard-server-api.md](leaderboard-server-api.md)。

---

# 第二部分：客户端接入

前提：你（或朋友）已经按上面跑起后端，拿到一个地址。

## 六、排行榜接入

1. 打开 **排行榜** 页 → 右上角 `⋮` 菜单 → **配置社区服务器**
2. `Base URL` 填服务器地址（不要带尾部斜杠以外的路径）
3. 服务器设置了 `LB_WRITE_TOKEN` 的话，把令牌填进 `Token`
4. 回到菜单点 **同步社区服务器**：
   - 先拉取全部远端条目并本地验签合并（假条目自动丢弃）
   - 再把自己的最新签名成绩推上去

之后每次手动点同步即可；本地与服务器都按「同一 peerId 取 `statsAt`
最新者」合并，多设备/多服务器混用不会乱。

> 提示：你的成绩由本机私钥签名，服务器和其他用户都改不了；换手机请先
> 用备份功能迁移，否则新私钥会被服务器按 TOFU 规则拒绝（需换 peerId）。
>
> 排行榜私钥是**刻意不参与备份脱敏**的——备份是把这个身份带到新手机的唯一途径。
> 其余凭据（WebDAV 口令、各家令牌、地图与 AI 的 API 密钥）则相反：它们会从设置里
> 被剔除，只在有钥匙时才以单独加密的成员随文件走。两条路各有各的钥匙：
>
> - **备份 zip** —— 导出时现场输入的口令。换手机时记得设，否则新机器上要手工重填。
> - **云同步** —— 备份页「凭据的旅行方式」里的**同步凭据口令**。同步是后台跑的、
>   没人能输口令，所以用这个设一次的值；两台设备填同一个，凭据就会加密后随同步
>   旅行。留空则同步不带凭据。
>
> 这个同步口令本身也算凭据：不随明文设置外传，但**会**被封进带口令的备份——所以
> 在新设备上恢复一次带口令的备份，等于把这把钥匙也带过去了，不用两边各输一遍。

## 七、组队（云中继）接入

1. **组队设置** → 联机方式选 **云中继服务器（自建后端）**
2. **服务器地址** 填同一个地址（App 自动转成 `wss://…/group/v1/ws`）
3. 服务器设置了 `GROUP_TOKEN` 的话，填 **中继令牌**
4. **强烈建议**设置 **共享口令**（所有成员填同一个）：
   - 消息端到端加密（AES-GCM，口令派生密钥）
   - 服务器只见密文——零知识转发
5. 所有成员填 **相同的群组 ID**，开启联机开关即可互见

连上后可用能力与局域网模式完全一致：

| 能力 | 说明 |
|---|---|
| 位置/路径共享 | 成员实时位置 + 彩色轨迹画在你的地图上 |
| 群聊 / 私聊 | 私聊走定向路由，不经过其他成员 |
| PTT 对讲 | 按住说话，语音只发给房间成员 |
| 音乐同步 | 广播正在播放的歌，成员端跟播 |
| 排行榜 gossip | 成员间自动互换签名成绩（无需社区服务器） |

连不上时：组队设置 → **诊断日志** 看中继连接 / 重连 / 解密记录。
常见原因：地址少了 `http(s)://`、令牌不一致、两端口令不一致（能连上
但看不到消息，日志会提示「解密失败」）。

## 八、Web 展示版（web-front）接入

这条链路的方向和上面两节相反：**手机是配置的权威，往服务端推**；浏览器只读。

1. **备份** 页 → 最下面的 **「Web 前端 · 配置推送」**
2. **服务器地址** 填 web-front 的地址（`http://<NAS>:48080`）
3. **用户名** 默认 `admin`；**密码**是服务端的 admin 口令（新部署是 `admin`）
4. 点 **「登录并推送当前配置」**

几件需要先知道的事：

- **密码不会存在手机上**，只有会话令牌会。换设备或重装要重新输入。
- 这个动作会**先与服务器上已有的配置合并**（服务器已有的值优先），再整份上传。
  所以刚在手机上改完还没推的值可能被服务器上的旧值覆盖——成功提示会告诉你有几项
  被改写了。想让手机侧的值赢，改完立刻推。
- **服务端仍是默认口令 `admin`/`admin` 时会显眼提醒你去改**。手机端没有改密入口，
  改密在浏览器打开 `http://<NAS>:48080/admin` 里做（顶部横幅内联了表单）。
- 会话是绑定到某一台服务器的。改了服务器地址，界面会自动要求重新登录——这是刻意的，
  否则凭据会被推到旧主机上还显示成功。
- **语音与音乐凭据刻意不参与漫游**（语音识别/合成密钥、音乐平台凭据）：只读 web 端
  不需要它们，上传只会扩大 admin 口令被攻破时的影响面。

推完之后刷新浏览器，web 端登录就能拉到这份配置。**WebDAV 用户**还需要在服务端打开
`EJ_PROXY_ENABLED=1`——浏览器无法直连 WebDAV（没有 CORS 头），要走服务端的只读代理。
web-front 的部署、排错、安全上下文限制详见 [web-display-deploy.md](web-display-deploy.md)。

## 九、流量与省电

- 空闲时每成员仅 ~25 秒一条心跳（~10 B/s），移动网络可长期挂着
- 位置广播频率跟随录制设置；纯挂机不录制时不发位置
- 断线自动重连（2→30 s 退避），息屏恢复后无需手动操作

## 十、多人共用一台服务器

- 不同群组之间完全隔离（按群组 ID 分房间）
- 一个服务器可同时服务排行榜与任意多个组队房间
- 单房间默认上限 32 人（服务器 `GROUP_MAX_ROOM_SIZE` 可调）
