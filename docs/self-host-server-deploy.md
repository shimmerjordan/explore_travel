# 自建服务器 · 部署指南

Explore Journal 的排行榜与组队（位置共享 / 聊天 / 对讲 / 音乐同步）默认走
去中心化方案（P2P gossip、局域网、frp 打洞），**不强制任何后端**。但自建一台
后端可以让「互不见面」的用户也能同步排行榜、让组队在任何网络下都能连通。

后端代码在仓库 `backends/` 目录：**一个 Node 进程、一个端口、零依赖**，
同时提供两个模块：

| 模块 | 协议 | 端点 | 开关 |
|---|---|---|---|
| 排行榜 | HTTP JSON | `/entries` `/monthly/{yyyy-MM}` `/index` | `EJ_MODULE_LEADERBOARD` |
| 组队中继 | WebSocket | `/group/v1/ws` | `EJ_MODULE_GROUP` |

> **另有一个服务 `web-front`（端口 48080）**，用于「在浏览器里回看足迹」：
> 它托管 web 产物、保管一份加密的配置、并替浏览器读 WebDAV。功能上与本文说的
> `ej-backend`（48081）**没有任何关系**。
>
> **2026-09-05 起两者合并进同一个镜像同一个容器**（仓库根的 `Dockerfile`，
> supervisord 带起两个进程，各自仍以 UID 1000 / 65532 运行、各写自己的数据
> 目录）。想两个一起要，用仓库根的 `docker-compose.yml` /
> `docker-compose.ghcr.yml` 一条命令起完，端口仍是 48080 + 48081。
>
> **只想要本文这一个**（例如 ECS 上只跑排行榜与中继）：本目录下这套流程仍然
> 有效——`backends/docker-compose.yml` 保留着，起出来就是一个只有后端的容器。
> 合并镜像里另一个服务闲着也几乎不占资源（Rust 常驻十几 MB），两条路都行。
>
> web-front 的部署见 [web-display-deploy.md](web-display-deploy.md) 与
> [web-front/README.md](../web-front/README.md)。

资源占用极小：常驻内存 ~40 MB、空闲 CPU≈0、闲时每成员带宽 ~10 B/s，
最低配 ECS（1核1G 甚至更小）即可长期运行。

## 一、准备

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

排行榜数据持久化在 Docker volume `ej-data`（`/data/leaderboard.json`，
防抖原子写，SIGTERM 时自动落盘）。备份它等于备份全部服务端状态。

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

免公网 IP、自动 HTTPS/WSS、自带 CDN 抗量：

1. Cloudflare Zero Trust → Networks → Tunnels → **Create tunnel**（选 Docker）
2. Public hostname：`ej.yourdomain.com` → `HTTP://localhost:48081`
   （WebSocket 默认放行，无需额外配置）
3. 复制 token 并启动：

```bash
export TUNNEL_TOKEN=eyJ...
docker compose --profile cloudflare up -d
```

客户端填 `https://ej.yourdomain.com`。

## 四、运维

```bash
docker compose logs -f backend        # 日志（合并镜像里两个服务的日志都在 ej-app 一个容器里）
curl -s localhost:48081/api/status     # 在线房间/人数/转发计数/内存
docker compose pull && docker compose up -d --build   # 升级
docker run --rm -v ej-backend_ej-data:/data alpine \
  cat /data/leaderboard.json > backup.json            # 备份榜单
```

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
