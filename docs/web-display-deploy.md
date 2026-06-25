# 部署与测试：Web 展示版 + NAS 后端

本文教你把"web 回忆版"跑起来并验证。分三块：
**A. 部署 Rust 后端（Docker）** → **B. 构建+托管 Flutter Web** → **C. 端到端测试**。

> 现状（截至 P5 主干）：后端、web 登录门、登录→拉保险库→后台同步、本地优先渲染都已就绪并通过测试。**移动端"推送保险库"的 UI 还没做**，所以"手机自动把数据同步给 web"这条全自动链路要等那块 UI；但 web 端**手动导入备份 zip** 这条数据通路现在就能用，足以验证整套展示价值。

---

## A. 部署 NAS 后端（Rust + Docker）

```bash
cd explore_journal/nas-backend

# 1) 生成密钥 + 配置 CORS（CORS 必须精确等于你 web 的访问源，见 B）
cat > .env <<EOF
EJ_JWT_SECRET=$(openssl rand -base64 48)
EJ_CORS_ORIGINS=http://localhost:8080
EJ_ALLOW_REGISTRATION=true
EOF

# 2) 起服务（首次会编译镜像，几分钟）
docker compose up -d --build

# 3) 冒烟
curl http://localhost:48080/healthz          # {"status":"ok"}
```

部署到 NAS（Synology/QNAP 等）时把 `EJ_CORS_ORIGINS` 改成 web 实际域名（如 `https://ej.yourdomain.com`），端口 `48080` 可在 `docker-compose.yml` 左侧改。

**数据存储**：默认用 Docker **命名卷 `ejdata`**（开箱即用、无需改权限——镜像里的 `/data` 已属 nonroot）。备份：
```bash
docker run --rm -v ejnas_ejdata:/data -v "$PWD":/backup busybox \
  tar czf /backup/ejdata.tgz -C /data .
```
若你更想把数据库直接放在宿主机目录里（方便查看/备份），改用 bind mount——但 distroless 的 nonroot(UID 65532) 写不了 root 拥有的目录，**必须先改权限**：
```bash
mkdir -p data && sudo chown -R 65532:65532 data
# 然后在 docker-compose.yml 把 `- ejdata:/data` 换成 `- ./data:/data`
```
（无论哪种，都放本地盘、别用 NFS/SMB。）

**安全收尾**：注册完你自己的账号后，把 `.env` 里 `EJ_ALLOW_REGISTRATION=false` 再 `docker compose up -d` 重启，关闭注册。

### 查看后端日志（排错第一步）

后端对**每个请求**打一行日志，含来源 `origin` 和它是否命中 CORS 白名单（`corsOk`）——这是排"注册失败"最有用的信息。

```bash
docker compose logs -f ejnas          # 实时跟随（推荐边操作边看）
docker compose logs --tail=50 ejnas   # 最近 50 行
# 或用容器名：
docker logs -f ejnas
```

日志样例（一次成功 vs 一次源不匹配）：
```
172.18.0.1 POST /auth/register   -> 200 (origin=http://localhost:8080,  corsOk=true)
172.18.0.1 OPTIONS /auth/register -> 204 (origin=http://127.0.0.1:8080, corsOk=false)   ← 源不匹配！
```

> ⚠️ 镜像是 **distroless（无 shell）**，所以 `docker exec -it ejnas sh` **进不去**。排错就靠 `docker logs`；要看数据库文件直接在宿主机看挂载卷 `./data/`（如 `sqlite3 ./data/ej.db`）。改完日志相关代码记得 `docker compose up -d --build` 重新构建镜像。

### 不带 web、直接用 curl 验证后端（推荐先做一遍）

后端是零知识的：它只收 `authVerifier`（口令派生值，不是口令）和**不透明密文**。手算 authVerifier 不方便，所以最快的后端验证是：

```bash
cd explore_journal/nas-backend
cargo test         # 6 个：CAS/冲突、唯一邮箱、JWT 往返+错密钥拒绝、Argon2、SSRF IP 表
```

要手测 HTTP 契约（salt 是 b64、authVerifier 任意 b64≥16B 即可走通注册/登录流程）：

```bash
B=http://localhost:48080
SALT=$(printf 'somesalt16bytes!' | base64)        # 客户端 KDF 盐（演示用）
AV=$(printf 'any-verifier-32-bytes-padding!!' | base64)  # 演示用 authVerifier

# 注册 → 拿 token
TOK=$(curl -s -X POST $B/auth/register -H 'Content-Type: application/json' \
  -d "{\"email\":\"me@x.com\",\"authVerifier\":\"$AV\",\"salt\":\"$SALT\"}" | tee /dev/stderr | sed 's/.*"token":"//;s/".*//')

# 首次写保险库（If-Match:"0" = 期望还没有）
curl -s -X PUT $B/vault -H "Authorization: Bearer $TOK" -H 'If-Match: "0"' \
  --data-binary 'ciphertext-bytes' -i | grep -i 'etag\|version'   # → version:1, ETag:"1"

# 读回
curl -s $B/vault -H "Authorization: Bearer $TOK"                  # → ciphertext-bytes

# 旧版本号再写 → 409 冲突（乐观并发）
curl -s -X PUT $B/vault -H "Authorization: Bearer $TOK" -H 'If-Match: "0"' \
  --data-binary 'x' -w '\n%{http_code}\n'                         # → 409

# 未知邮箱也返回伪盐（防枚举）：两个不同邮箱的 salt 都像真盐
curl -s "$B/auth/salt?email=nobody@x.com"
```

> 注意：上面 curl 的 `authVerifier`/`salt` 是演示值；真实流程里它们由 App 端 `SettingsVault.derive(口令)` 算出。curl 只是验证后端**契约**。

---

## B. 构建并托管 Flutter Web

```bash
cd explore_journal
flutter build web --release        # 产物在 build/web/

# 本地起一个静态服务器测试（端口要和 EJ_CORS_ORIGINS 一致）
cd build/web && python3 -m http.server 8080
# 打开 http://localhost:8080
```

**两个必须对齐的点**：
1. **CORS 源**：浏览器访问 web 的源（`http://localhost:8080`）必须**精确**出现在后端 `EJ_CORS_ORIGINS`（scheme+host+port 完全一致，结尾不要带 `/`）。不一致 → 浏览器控制台报 CORS、登录失败。
2. **NAS 地址**：登录页里填的 NAS 地址必须是**浏览器能访问到**的。本机测试时后端和 web 同机 → 填 `http://localhost:48080`。注意：若 web 用 https 而 NAS 用 http，浏览器会拦截混合内容——本地 http+http 测试最省事。

生产部署：把 `build/web/` 丢到任意静态托管（Nginx / Cloudflare Pages / NAS 自带 web 服务），`EJ_CORS_ORIGINS` 填该域名。

---

## C. 端到端测试

### C1. 登录门 + 保险库往返（现在就能测）
1. 打开 `http://localhost:8080` → 应被重定向到**登录页**（web 默认只读、需登录）。
2. 填 NAS 地址 `http://localhost:48080`、邮箱、口令（≥8 位）→ 点"**注册并同步**"。
   - 客户端用口令派生 `vaultKey`(留本机) + `authVerifier`(发后端)；后端建账号、存空保险库；前端进入地图页。
3. 刷新页面 → 又回到登录页（web 是无状态查看器，刷新后需重新登录；这是零知识的固有特性：`vaultKey` 只在内存）。用刚才的邮箱+口令点"**登录**"→ 应能进去。
   - ✅ 这验证了：后端在线、CORS 通、注册/登录、保险库加解密往返、路由门。
4. 反向验证零知识：去 NAS 上 `sqlite3 data/ej.db 'select email,length(blob) from users join vaults using(... )'`——只能看到密文长度，看不到任何明文凭据。

### C2. 看到数据：手动导入备份（现在就能测）
web 端默认没有数据。最快看到足迹/日记的方式是导入一份手机导出的备份：
1. 手机 App → 备份页 → 导出备份 zip，传到电脑。
2. web 端登录后 → 访问 `http://localhost:8080/#/backup`（备份页）→ "导入备份" → 选那个 zip。
   - 数据按 UUID 去重导入进浏览器的 IndexedDB（持久化，刷新不丢）。
3. 回到地图（`/`）/ 日记（`/journal`）→ 应看到迷雾、轨迹、日记。
   - 公开图（http/https CDN）正常显示；**本地路径的图**显示"碎图"占位（预期：web 没有本地文件，需 P5 后续的私有图代理/图床）。
   - ✅ 这验证了整套"展示/回忆"的核心价值：同一份 Flutter UI 在 web 上渲染你的数据。

### C3. 自动云同步（需补一步才能端到端）
代码已就绪：登录后会自动 `syncDown(journal/layers/fog_tiles/track_points/chat_messages/song_favorites)`。但要真正拉到数据，保险库里得有**同步后端配置**（如 GitHub 的 PAT/owner/repo + `syncBackend=github`），而往保险库写这些目前需要**移动端的 NAS 推送 UI**（尚未做）。补上那块 UI 后，链路就是：
> 手机配置 GitHub 同步 + 登录 NAS 推送保险库 → web 登录 → 自动从 GitHub 拉数据渲染。
（GitHub 的 API 带 CORS，PAT 只在 web 内存、绝不落 localStorage，所以这条 web 直连可行；WebDAV 因 CORS 需走 NAS 代理，属后续。）

---

## D. 整合宣传站 + 自动部署（GitHub → Vercel / Cloudflare）

### D1. 一个站点，两张脸
部署产物把两者合到一起：
- **`/`** → 宣传落地页（`website/`，原生 JS）。
- **`/app/`** → Flutter web 回忆版（`flutter build web --base-href /app/`）。
- 落地页 hero 上新增按钮「**打开 Web 回忆版**」→ 链到 `/app/`（`website/config.js` 的 `appUrl`）。

本地一键组装 + 预览：
```bash
bash scripts/build-site.sh          # 产出 ./dist （/=落地页，/app/=应用）
cd dist && python3 -m http.server 8080
# http://localhost:8080 看落地页 → 点"打开 Web 回忆版" → http://localhost:8080/app/
```
> 应用用 **hash 路由**（`/app/#/login`），所以静态托管**不需要** SPA 重写规则。除非以后改用 path 路由（`usePathUrlStrategy()`），那才需要把 `/app/*` 回退到 `/app/index.html`。

### D2. 每次 push 自动构建 + 部署
已附 [.github/workflows/deploy-web.yml](../.github/workflows/deploy-web.yml)：push 到 `main` 时装 Flutter → `scripts/build-site.sh` → 部署 `dist`。**二选一**保留一个 deploy job，删掉另一个（缺密钥的会让流水线失败）。

**A) Cloudflare Pages**（推荐，自带全球 CDN + 免费 https）
1. CF 控制台 → Workers & Pages → 创建 Pages 项目（Direct Upload），命名 `explore-journal`。
2. 建 API Token（权限：`Cloudflare Pages: Edit`），拿 Account ID。
3. GitHub 仓库 → Settings → Secrets and variables → Actions 加：`CLOUDFLARE_API_TOKEN`、`CLOUDFLARE_ACCOUNT_ID`。
4. push → 几分钟后 `https://explore-journal.pages.dev` 上线（含 `/app/`）。

**B) Vercel**
1. `npm i -g vercel && vercel link`（在仓库里跑一次）拿到 org/project ID。
2. GitHub Secrets 加：`VERCEL_TOKEN`、`VERCEL_ORG_ID`、`VERCEL_PROJECT_ID`。
3. push → Vercel 上线。

> workflow 里 `flutter-version: '3.32.1'` 与你本地保持一致；要升级一起改。

### D3. ⚠️ 生产环境的关键：让 web 能连到 NAS
线上 web 是 **https**（`*.pages.dev` / `*.vercel.app`）。浏览器**禁止 https 页面请求 http 接口**（混合内容）。所以登录页填的 NAS 地址必须是 **https 且证书有效**，否则连不上。两条常见路子：
- **Cloudflare Tunnel（最省事）**：在 NAS 上跑 `cloudflared`，把 `48080` 暴露成 `https://ej.yourdomain.com`，无需公网 IP / 开端口 / 自己搞证书。
- **反代 + Let's Encrypt**：NAS 自带的反向代理（群晖/威联通都有）或 Caddy/Nginx，给 `48080` 套个域名 + 证书。

然后两件事对齐：
1. 后端 `EJ_CORS_ORIGINS` 加上你的**线上 web 源**（如 `https://explore-journal.pages.dev`，精确、带协议、无尾斜杠）。
2. 登录页 NAS 地址填 `https://ej.yourdomain.com`。

（纯内网自用、不走公网时，也可以只在局域网用 `http://localhost` / 给内网域名配证书；核心约束就是"https 页面要连 https 接口"。）

## 验证清单速查

| 测什么 | 怎么测 | 现状 |
|--------|--------|------|
| 后端逻辑 | `cd nas-backend && cargo test` | ✅ 6 通过 |
| 后端契约 | 上面 curl 流程 | ✅ |
| web 能编译 | `flutter build web` | ✅ 32.4s |
| 登录门/注册/登录/保险库往返 | C1 | ✅ |
| web 渲染数据 | C2 手动导入 zip | ✅ |
| 零知识（NAS 看不到明文） | C1 第 4 步查 ej.db | ✅ |
| 手机→web 全自动同步 | C3 | ⏳ 待移动端 NAS 推送 UI |

## 排错

### 后端起不来：`open db: unable to open database file: /data/ej.db`（循环刷屏）
容器在 crash-loop，后端没监听 → 任何请求都会 `ERR_CONNECTION_REFUSED`。原因：distroless 的 nonroot 用户写不了你 bind-mount 的 `./data`。**修复**：用默认的命名卷（见"数据存储"）并 `docker compose up -d --build` 重建镜像即可；若坚持用 bind mount，先 `sudo chown -R 65532:65532 data`。

### 注册 `ERR_CONNECTION_REFUSED`（如 `POST https://localhost:48080/...`）
两件事一起查：
1. **后端是否在跑**：`docker compose ps` + `curl http://localhost:48080/healthz`。若没起，多半是上面的 DB 权限问题。
2. **协议/地址**：后端是 **http**，不是 https。登录页"NAS 地址"要填 **`http://localhost:48080`**（别写 `https://`，那个端口没有 TLS → 连接被拒）。本地测试浏览器也用 `http://localhost:8080` 打开，保证 http→http 不触发混合内容拦截。

### 前端 404：`GET /app/flutter_bootstrap.js 404`（或 manifest.json 404）
你在服务**错误的目录**。`build-site.sh` 会把 `build/web` 重建成 **base-href=`/app/`** 的版本——如果你 `cd build/web && http.server` 再开根路径，index.html 里的 `<base href="/app/">` 会把所有资源请求到 `/app/...`，而该目录下没有 `/app/` → 404。
**修复**：服务组装好的 `dist/` 并开根路径：`cd dist && python3 -m http.server 8080` → `http://localhost:8080/`。
（只想单独测应用：重新 `flutter build web`**不带** `--base-href`，再服务 `build/web` 开 `/`。两种 base-href 别混用。）
> 控制台里 `index.js ... siteHostMap` 之类报错通常是**浏览器扩展**，与本项目无关。

### 注册/登录其它报错（按此顺序）

后端逻辑本身已通过 `cargo test` + 真实 curl（注册返回 200）验证，所以**报错几乎都在浏览器侧或环境**。两步定位：

**第 1 步：边点注册边看后端日志** `docker compose logs -f ejnas`，看有没有出现 `/auth/register` 那一行：

- **看到 `... corsOk=false`** → CORS 源不匹配（最常见）。日志里的 `origin=` 就是你浏览器的**真实源**；把 `EJ_CORS_ORIGINS` 改成**和它一字不差**的值，重启后端。注意三个坑：
  - `http://localhost:8080` 与 `http://127.0.0.1:8080` 是**不同的源**——用哪个开网页就填哪个。
  - 必须带**端口**；结尾**不要**带 `/`。
  - 多个源用逗号分隔：`EJ_CORS_ORIGINS=http://localhost:8080,http://127.0.0.1:8080`。
- **看到 `POST /auth/register -> 200` 但网页仍报错** → 请求成功了，问题在前端之后的步骤；看浏览器 Console 的具体红字（多半是随后的后台同步，非致命）。
- **日志里完全没有 `/auth/register`** → 请求根本没离开浏览器，是**客户端侧**：
  1. **口令派生需要安全上下文**：若你用 `http://<局域网IP>:8080`（既非 `localhost` 也非 https）打开网页，浏览器的 `crypto.subtle` 不可用，派生密钥会直接抛错——这是 NAS/局域网场景最易踩的坑。**解法：用 `http://localhost:8080` 打开，或给 web 配 https。**
  2. NAS 地址填错/不可达：浏览器能直接打开 `http://<NAS>:48080/healthz` 吗？
  3. 混合内容：https 的网页连 http 的 NAS 会被浏览器拦截。

**第 2 步：开浏览器开发者工具（F12）** → Console 看红字、Network 看 `/auth/register` 这条请求是 CORS 被拦、网络失败、还是返回了错误码。

> 把这三样发我就能精确定位：① `docker compose logs --tail=20 ejnas`（点注册那一下的输出）② 浏览器 Console 红字 ③ Network 里 `/auth/register` 的状态。

**其它**：
- **报"该邮箱已注册"** → 改用"登录"，或换邮箱（注册只需一次）。
- **数据导入后地图空白** → 确认导入选了含 `fog_tiles/layers/journal` 的备份；检查右上角图层可见性。

## E. Web 端特性与已知行为（2026-06-25 新增）

1. **PWA 安装**：`web/manifest.json` 已配 `display:standalone` + `scope/start_url: ./` + 192/512 + maskable 图标 + `theme_color`，`index.html` 加了 `theme-color` meta。在 **https（或 localhost）** 下，Chrome/Edge 地址栏会出现"安装"按钮，可把 `/app/` 装到桌面/主屏，独立窗口运行。（http LAN-IP 不会提示安装——PWA 要求安全上下文。）
2. **定位**：浏览器 Geolocation **只在安全上下文可用**（https 或 `http://localhost`）。在 `http://<局域网IP>` 下定位会失败，地图右上给一次性提示「Web 定位失败：需用 HTTPS 或 localhost…」。生产环境给 NAS/web 配 https 即可正常显示位置。
3. **进入 3D 地球**：桌面没有双指捏合——把地图**滚轮缩到最小后，再向下滚 3 次**即进入 3D 地球（底部有「再向下滚动 N 次」提示）。手机仍是捏合 3 次。
4. **只读 / 展示模式**：web 默认只读，地图顶部居中有「只读 · 展示模式」徽标，记录/编辑入口隐藏。**后门**：在菜单页连点版本号 10 次开启调试模式 → 自动解除只读（可在 web 上记录/编辑，用于调试）。
5. **桌面排版**：设置页、备份页在宽窗口（>800px）会把内容居中限宽到 720px（`ResponsiveContent`），不再拉满整行；手机宽度不变。其它页面可按需复用 `lib/ui/widgets/responsive_content.dart`。
