# ---------------------------------------------------------------------------
# 单镜像：web-front（Rust，48080）+ ej-backend（Node，48081），supervisord 一起带起。
#
# 合并前是 web-front + ej-backend 两个镜像、两条 CI、两次 pull。对外端口不变
# （48080 / 48081），所以反代与防火墙规则不用动；**容器内的数据目录变了**：
# 原来两个服务各自用 /data，现在分成 /data/web 与 /data/backend，宿主仍然只挂
# 一个 /data。entrypoint 会把旧布局幂等地迁进子目录，见 deploy/entrypoint.sh。
#
# 两个进程保留各自的 UID（web-front 65532 / backend 1000），各自只写得动自己的
# 数据目录——前端被攻破也读不到排行榜库。这一点比 distroless 的"无 shell"更值钱：
# 合并必然要引入 shell 与进程管理器，那层收益本来就保不住了。
# ---------------------------------------------------------------------------

# ── web-front（Rust）─────────────────────────────────────────────────────────
# `--platform=$BUILDPLATFORM` 把这一阶段钉在构建机架构上交叉编译，而不是让
# buildx 把整个 Rust 编译放进 QEMU（模拟下每个架构 40 分钟以上，交叉编译几分钟）。
# 用完整 `rust` 而不是 -slim：ureq 的 rustls/ring 依赖会编 C 与汇编，需要可用的 gcc。
FROM --platform=$BUILDPLATFORM rust:1-bookworm AS rustbuild
ARG TARGETARCH
WORKDIR /src

# 解析目标三元组；跨架构时装交叉工具链。遇到没教过的架构直接失败，而不是悄悄
# 产出一个宿主架构的二进制。
#
# libc6-dev-arm64-cross 是**必须**的，别删：它提供 /usr/aarch64-linux-gnu 下的
# aarch64 glibc 头与库。Debian 只把它标成 gcc-aarch64-linux-gnu 的 Recommends，
# 所以加了 --no-install-recommends 之后交叉 gcc 会悄悄回落到宿主的 /usr/include，
# 在编 ring 的 C 源码时死在 `bits/libc-header-start.h: No such file`。
#
# 这个 RUN 体里别写 `#` 注释：注释行没有行尾反斜杠，一旦它被当成 shell 输入
# 而不是被 Dockerfile 剥掉，RUN 就会提前结束，下一行会被解析成 Dockerfile 指令。
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) TRIPLE=x86_64-unknown-linux-gnu ;; \
      arm64) TRIPLE=aarch64-unknown-linux-gnu; \
             apt-get update; \
             apt-get install -y --no-install-recommends \
               gcc-aarch64-linux-gnu libc6-dev-arm64-cross; \
             rm -rf /var/lib/apt/lists/* ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    echo "$TRIPLE" > /triple; \
    rustup target add "$TRIPLE"

# 交叉链接器（cargo）+ 交叉 C 编译器（ring 的 build script 用 cc crate 编它的
# C/汇编源码）。构建 amd64 时这两个变量会被忽略。
ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc

# --locked：严格按 Cargo.lock 里记录的依赖集构建，同一个提交永远得出同样的镜像内容。
COPY web-front/Cargo.toml web-front/Cargo.lock ./
COPY web-front/src ./src
# 控制台页面是 include_str! 进二进制的，所以它必须在**构建阶段**的 context 里，
# 不是只在运行阶段。少了它编译会报 `couldn't read src/../assets/dashboard.html`，
# 而这个错只在镜像构建时出现，在检出目录里跑 cargo build 永远看不到。
COPY web-front/assets ./assets
RUN set -eux; \
    TRIPLE="$(cat /triple)"; \
    cargo build --release --locked --target "$TRIPLE"; \
    cp "target/$TRIPLE/release/web-front" /web-front

# ── 运行阶段 ────────────────────────────────────────────────────────────────
# node:22-bookworm-slim 而不是 alpine：Rust 二进制是动态链接 glibc 的（原先跑在
# distroless/cc 上），alpine 的 musl 跑不了它。换成 musl 目标能省 ~150 MB，但那
# 会把已经验证过的交叉编译链整条重做，不值得。
FROM node:22-bookworm-slim

# supervisor 带两个常驻进程；curl 只给 HEALTHCHECK 用（Debian slim 里 curl 和
# wget 都没有）；gosu 让 entrypoint 以 root 建目录、改属主之后仍能把进程降权。
RUN apt-get update && apt-get install -y --no-install-recommends \
      supervisor curl tzdata \
    && rm -rf /var/lib/apt/lists/*

# web-front 原本在 distroless 里跑 nonroot（UID 65532）。这里显式建同一个 UID，
# 迁移过来的数据属主才对得上，宿主 bind mount 的 chown 指引也不用改。
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g 65532 -M -s /usr/sbin/nologin nonroot

WORKDIR /app

# 后端零 npm 依赖，拷进来就能跑（没有 npm install / node_modules / lock 漂移）。
COPY backends/server/ ./server/
COPY backends/package.json ./

COPY --from=rustbuild /web-front /usr/local/bin/web-front

# Flutter web 产物。CI 在 Docker 之外构建（web 产物与架构无关，放进镜像构建
# 只会把 Flutter SDK 也拖进来），再拷到 web-front/web-dist/ 供这里 COPY。
# 仓库里用 .gitkeep 保住这个目录：没有 web 产物时镜像也必须能构建，服务会为
# 一个只有占位文件的目录提供安装引导页。
#
# 刻意**不** --chown 给 nonroot：默认 COPY 留 root:root，运行期读它的服务
# （web-front 以 65532 跑）对自己的静态资源没有写权限。万一服务被攻破，可写的
# /web 就能被塞一个改过的 main.dart.js 去钓下一个登录的管理员；这里只读没有任何
# 代价，运行期本来就不需要往 /web 写东西。
#
# 也刻意**不**加 --chmod=0644：那个标志对目录同样生效，而丢了执行位的目录再也
# 无法遍历，assets/、canvaskit/ 等嵌套资源会整片打不开。
COPY web-front/web-dist/ /web/

COPY deploy/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY deploy/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 容器内数据目录。宿主只挂一个 /data，两个服务各用一个子目录，属主分开。
# entrypoint 每次启动都会补建并纠正属主（named volume 首次使用会继承镜像里的
# 属主，bind mount 不会——所以不能只靠这里的 chown）。
ENV EJ_LISTEN=0.0.0.0:48080 \
    EJ_DATA_DIR=/data/web \
    EJ_WEB_ROOT=/web \
    PORT=48081 \
    DATA_DIR=/data/backend \
    NODE_ENV=production
RUN mkdir -p /data/web /data/backend \
    && chown 65532:65532 /data/web \
    && chown node:node /data/backend /app

VOLUME ["/data"]
EXPOSE 48080 48081

# 探**两个**服务：合并前每个镜像各有自己的健康检查，任一个不可用对用户来说就是
# 功能缺失（前端在、榜单挂了，或反过来），所以这里两个都探，任一失败即不健康。
# 这与 repo_git 那次"只探后端"的取舍不同：那边 nginx 挂了 supervisord 会自己
# 重拉，静态页短暂 502 不算不可用；这里两个都是独立的对外服务。
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${EJ_LISTEN##*:}/healthz" >/dev/null \
     && curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null || exit 1

# entrypoint 以 root 跑（要建目录、改属主、迁旧数据），最后 exec 给 supervisord，
# 由它按 program 把两个进程分别降到 65532 / 1000。
ENTRYPOINT ["/entrypoint.sh"]
