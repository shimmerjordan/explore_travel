# 自建服务器 · 部署指南

Explore Journal 的排行榜与组队（位置共享 / 聊天 / 对讲 / 音乐同步）默认走
去中心化方案（P2P gossip、局域网、frp 打洞），**不强制任何后端**。但自建一台
后端可以让「互不见面」的用户也能同步排行榜、让组队在任何网络下都能连通。

后端代码在仓库 `backends/` 目录：**一个 Node 进程、一个端口、零依赖**，
同时提供两个模块：

| 模块 | 协议 | 端点 |
|---|---|---|
| 排行榜 | HTTP JSON | `/entries` `/monthly/{yyyy-MM}` `/index` |
| 组队中继 | WebSocket | `/group/v1/ws` |

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
curl http://localhost:8080/healthz      # → ok
curl http://localhost:8080/api/status   # 模块状态 / 内存 / 在线人数
```

排行榜数据持久化在 Docker volume `ej-data`（`/data/leaderboard.json`，
防抖原子写，SIGTERM 时自动落盘）。备份它等于备份全部服务端状态。

### 主要环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `LB_WRITE_TOKEN` | 空 | 设置后提交成绩需令牌；读取始终公开 |
| `GROUP_TOKEN` | 空 | 设置后组队连接需令牌 |
| `GROUP_MAX_ROOM_SIZE` | 32 | 单房间人数上限 |
| `TRUST_PROXY` | `1`（compose 内） | 经 frp/CF 暴露时信任转发头做限流分桶 |
| `LOG_LEVEL` | info | trace / info / warn / error |

## 三、暴露到公网（三选一，可叠加）

### 方式 1：直接放行端口

安全组放行 `8080/tcp`，客户端填 `http://ECS公网IP:8080`。
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
2. Public hostname：`ej.yourdomain.com` → `HTTP://localhost:8080`
   （WebSocket 默认放行，无需额外配置）
3. 复制 token 并启动：

```bash
export TUNNEL_TOKEN=eyJ...
docker compose --profile cloudflare up -d
```

客户端填 `https://ej.yourdomain.com`。

## 四、运维

```bash
docker compose logs -f backend        # 日志
curl -s localhost:8080/api/status     # 在线房间/人数/转发计数/内存
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
