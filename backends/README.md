# explore_journal backends

自建后端，一个进程、一个端口，承载两个模块：

| 模块 | 协议 | 作用 |
|---|---|---|
| **leaderboard** | HTTP JSON | 社区排行榜服务器，实现 [`docs/leaderboard-server-api.md`](../docs/leaderboard-server-api.md) v1 全部端点（Ed25519 验签 / TOFU / LWW / 未来时钟防御 / ETag / 限流） |
| **group** | WebSocket | 组队消息中继（位置轨迹共享、聊天、PTT 语音、音乐同步、排行榜 gossip 的云端房间），零知识转发 |

**零运行时依赖**（纯 Node ≥20 标准库，含手写 RFC6455 WebSocket），无 node_modules。
常驻内存 ~40 MB、空闲 CPU≈0，适合最小规格 ECS。

## 目录

```
backends/
├─ server/
│  ├─ server.js            入口：HTTP 路由 + WS upgrade + 模块注册
│  ├─ lib/                 router / ws / store / ratelimit / canonical / log
│  └─ modules/
│     ├─ leaderboard.js    排行榜（HTTP）
│     └─ group.js          组队中继（WebSocket）
├─ test/                   node --test 套件（含 Dart 签名跨语言向量）
├─ deploy/                 frpc / cloudflared 配置样例
├─ Dockerfile
├─ docker-compose.yml         从源码现编
├─ docker-compose.ghcr.yml    用 GHCR 上编好的镜像部署（NAS/服务器推荐）
```

## 快速开始

```bash
# 本地跑（开发）
node server/server.js                      # http://localhost:48081

# 测试
npm test                                   # 单元/集成 23 用例，含 Dart 交叉验签
./scripts/docker-e2e.sh                    # 容器级 E2E：构建镜像→全 API/数据正确性/
                                           # 中继/重启持久化（开放+鉴权两轮）

# Docker（生产）
docker compose up -d --build
curl http://localhost:48081/healthz         # → ok
curl http://localhost:48081/api/status      # 模块状态/内存/在线人数
```

## 配置项（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` / `HOST` | `48081` / `0.0.0.0` | 监听地址 |
| `DATA_DIR` | `/data` | 排行榜持久化目录（compose 已挂 volume） |
| `EJ_MODULE_LEADERBOARD` / `EJ_MODULE_GROUP` | 都开 | 只想跑其中一半时设 `0`（也接受 `false`/`no`/`off`）。关掉的模块**不会被构造**，不占内存也不注册路由：排行榜关了 `/entries` `/monthly` `/index` 返回 404，组队关了 WS 升级被拒。两个都关会**拒绝启动并以非零码退出**——带零个模块占着端口会通过健康检查却对一切真实请求返回 404，那是最难排查的一种故障。值拼错时保持启用并告警，因为「你想关的还在跑」比「你想要的悄悄没了」容易发现 |
| `TRUST_PROXY` | 关 | `1`=信任 `CF-Connecting-IP`/`X-Forwarded-For` 做限流分桶；**经 frp/CF 暴露时必须开**，否则所有用户共享一个限流桶 |
| `LB_WRITE_TOKEN` | 空 | 设置后 `POST /entries` 需 `Authorization: Bearer`；读接口始终公开 |
| `LB_READS_PER_MIN` / `LB_WRITES_PER_MIN` | 60 / 10 | 每 IP 限流 |
| `GROUP_TOKEN` | 空 | 设置后组队连接需带 token（客户端「中继令牌」填同值） |
| `GROUP_MAX_ROOM_SIZE` | 32 | 单房间人数上限 |
| `GROUP_MSGS_PER_SEC` / `GROUP_BYTES_PER_SEC` | 50 / 512K | 单连接限速（PTT 语音 ~4 条/秒也远够用） |
| `LOG_LEVEL` | info | trace/info/warn/error |

## 部署

**推荐：用 GHCR 上编好的镜像**（不需要源码，不需要在目标机器上编译）。CI 每次
推 `main` 都会在容器级 E2E 通过后发布 amd64 + arm64 双架构镜像，
`docker-compose.ghcr.yml` 就是给这种部署用的：

```bash
sudo mkdir -p /volume1/docker/ej-backend/data && cd /volume1/docker/ej-backend
# 放好 docker-compose.ghcr.yml（改名 docker-compose.yml），然后：
cat > .env <<EOF
EJ_BACKEND_DATA_PATH=/volume1/docker/ej-backend/data
LB_WRITE_TOKEN=$(openssl rand -hex 24)
GROUP_TOKEN=$(openssl rand -hex 24)
EOF
sudo chown -R 1000:1000 /volume1/docker/ej-backend/data   # 容器以 node（UID 1000）运行
sudo docker compose up -d
curl localhost:48081/healthz
```

「Docker 后端编译」流水线的**运行摘要页**会把上面这套命令连同 compose 文件内容
和本次提交对应的镜像标签一起打印出来，直接复制粘贴即可。

**数据存哪**由 `EJ_BACKEND_DATA_PATH` 决定：留空是 Docker 命名卷（零宿主配置），
填绝对路径就是 bind mount（备份方便，NAS 推荐；需先 `chown` 到 UID 1000）。
别指向 NFS/SMB。

**或者从源码现编**：

```bash
scp -r backends/ user@ecs:/opt/ej-backend
ssh user@ecs 'cd /opt/ej-backend && docker compose up -d --build'
```

三种公网暴露方式（可叠加，详见应用内「自建服务器指南」页）：

1. **直接开安全组**：放行 48081/tcp，客户端填 `http://ECS公网IP:48081`。
2. **frpc**：填 `deploy/frpc.toml` 后 `docker compose --profile frp up -d`。
3. **Cloudflare Tunnel**（推荐，免公网 IP + 自动 HTTPS/WSS）：
   `export TUNNEL_TOKEN=... && docker compose --profile cloudflare up -d`。

## 客户端对接

- **排行榜**：排行榜页 → 右上菜单 → 「配置社区服务器」→ Base URL 填
  `https://ej.yourdomain.com`（有 `LB_WRITE_TOKEN` 时把 token 也填上）→
  「同步社区服务器」。
- **组队**：组队设置 → 联机方式选「云中继服务器」→ 服务器地址填同一个
  URL（自动转成 `wss://…/group/v1/ws`）→ 建议同时设置共享口令
  （端到端加密，服务器只见密文）。

## 架构与扩展

模块签名：`(cfg) => ({ name, routes?, onUpgrade?, status?, shutdown? })`。
加新模块 = 在 `server/modules/` 放一个文件 + 在 `server.js` 的 `MODULES`
数组里加一行；路由按 `/<module>/v1/…` 命名空间（排行榜因协议文档要求
保留根路径）。

CI：`.github/workflows/backend.yml`（Actions 页显示为「**Docker 后端编译**」）
在 backends/ 任何改动时自动跑 `npm test` + 完整 Docker E2E（构建生产镜像并
驱动全 API/数据正确性/中继/重启持久化验证），**通过后**才把 amd64 + arm64
双架构 manifest 推到 GHCR（`ghcr.io/<owner>/<repo>/ej-backend`）。没有任何
未经真容器验证的镜像会进 registry。PR 只验证不发布。每次运行的摘要页会列出
镜像标签、digest、验证项和可直接复制的部署命令。

带宽/资源取向的取舍：

- 排行榜全量响应缓存为单个 Buffer + ETag，轮询客户端命中 304 只花 ~200 B；
- 组队定向消息（1:1 聊天/语音）走 `@peerId|` 路由前缀，不广播全房间；
- 中继对负载零解析零重编码（Buffer 直转），端到端加密不增加任何服务器成本；
- 慢消费者（发送缓冲 >4 MB）直接断开由客户端重连，杜绝内存放大；
- JSON 文件持久化（防抖 2 s + 原子改名），不引入数据库进程。
