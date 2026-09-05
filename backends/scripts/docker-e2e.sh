#!/usr/bin/env bash
# Full Docker E2E: build the production image, run it like production
# (volume + healthcheck), then drive the complete API / data-correctness /
# relay / persistence suite against the container — twice: once open, once
# with tokens enforced.
#
#   cd backends && ./scripts/docker-e2e.sh
#
# Exit code 0 = everything passed. Requires docker + node >= 20.
set -euo pipefail
cd "$(dirname "$0")/.."

IMG=${E2E_IMAGE:-explore-journal-backend:e2e}
NAME="ej-e2e-$$"
PORT=${E2E_PORT:-18990}
VOL="${NAME}-data"

# 跑外来架构的镜像时传 PLATFORM（与 web-front/scripts/docker-smoke.sh 同一个约定）：
#
#   PLATFORM=linux/arm64 SKIP_BUILD=1 E2E_IMAGE=ej-app:smoke-arm64 ./scripts/docker-e2e.sh
#
# 不传的后果不只是 docker 那句 "no specific platform was requested" 的警告 ——
# 这套用例从来没核对过跑起来的到底是哪个架构，交叉编译静默产出宿主架构的产物
# 也能一路绿灯过去（web-front 那套一直是核对的，这边缺了）。
PLATFORM=${PLATFORM:-}
PLAT_ARG=()
if [ -n "$PLATFORM" ]; then
  PLAT_ARG=(--platform "$PLATFORM")
fi

say() { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# SKIP_BUILD=1 让这套用例跑在一个**外部已经构建好**的镜像上——合并成单镜像
# （根 Dockerfile：web-front + 本服务）之后，CI 与本地都是先构建那个合并镜像，
# 再把这里和 web-front 的冒烟脚本分别指过来，而不是各自再 build 一次。
if [ "${SKIP_BUILD:-0}" = 1 ]; then
  say "reuse prebuilt image $IMG"
else
  say "build image $IMG"
  docker build -q -t "$IMG" . >/dev/null
fi

# 启动等待预算。原值是 100 × 0.2s = 20 秒，放宽到 150 秒纯粹是保险：
#
# 合并成单镜像之后启动要做的事更多（entrypoint 建目录 / 改属主 / 迁旧数据 →
# supervisord 拉起 Rust 与 Node 两个进程），而模拟执行慢一个数量级；web-front
# 那套冒烟一直给 60 秒，这边只给 20 秒，差得不合理。本机原生 1-2 秒就绪，
# 轮询粒度仍是 0.2 秒、就绪即返回，所以放宽不影响本地速度。
#
# **但它不是当初那两次 arm64 失败的原因** —— 那是 /api/status 的 rssMb 断言，
# 见下面 EMULATED 那段。别因为这个上限大就以为启动很慢：真慢的时候日志里每
# 10 秒会打一行。
BOOT_TIMEOUT=${E2E_BOOT_TIMEOUT:-150}

wait_healthy() {
  local tries=$(( BOOT_TIMEOUT * 5 ))   # 每次 sleep 0.2s
  local i=0
  while [ "$i" -lt "$tries" ]; do
    if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
      if [ "$i" -gt 25 ]; then echo "  (容器就绪，等了 $(( i / 5 )) 秒)"; fi
      return 0
    fi
    i=$(( i + 1 ))
    # 每 10 秒打一行：CI 日志上要能看出是在等，而不是卡死了。
    if [ $(( i % 50 )) -eq 0 ]; then
      echo "  等待容器就绪… $(( i / 5 ))s / ${BOOT_TIMEOUT}s"
    fi
    sleep 0.2
  done
  echo "container never became healthy after ${BOOT_TIMEOUT}s"
  docker logs "$NAME" 2>&1 | tail -40
  return 1
}

# 镜像架构核对。放在起容器之前：不对就没必要再跑几分钟用例。
# 与 web-front/scripts/docker-smoke.sh 同一条断言 —— 证明产物真是要的那个架构，
# 而不是交叉编译静默塞过来的宿主架构。
EMULATED=0
if [ -n "$PLATFORM" ]; then
  GOT=$(docker inspect --format '{{.Architecture}}' "$IMG")
  WANT=${PLATFORM##*/}
  if [ "$GOT" != "$WANT" ]; then
    echo "image arch is $GOT, expected $WANT" >&2
    exit 1
  fi
  say "image architecture is $GOT"
  HOST_ARCH=$(docker version -f '{{.Server.Arch}}' 2>/dev/null || echo unknown)
  if [ "$GOT" != "$HOST_ARCH" ]; then
    EMULATED=1
    say "foreign arch ($GOT on $HOST_ARCH host) — 走 QEMU，放宽依赖宿主内核的断言"
  fi
fi

say "round 1: open mode (full API + data correctness + relay + docker-restart persistence)"
docker volume create "$VOL" >/dev/null
docker run -d --name "$NAME" "${PLAT_ARG[@]}" \
  -p "127.0.0.1:$PORT:48081" \
  -v "$VOL:/data" \
  -e TRUST_PROXY=1 -e LOG_LEVEL=warn \
  "$IMG" >/dev/null
wait_healthy
E2E_BASE_URL="http://127.0.0.1:$PORT" E2E_CONTAINER="$NAME" E2E_EMULATED="$EMULATED" \
  node --test --test-force-exit test/docker-e2e.test.js

say "round 2: auth mode (LB_WRITE_TOKEN + GROUP_TOKEN enforced)"
docker rm -f "$NAME" >/dev/null
docker run -d --name "$NAME" "${PLAT_ARG[@]}" \
  -p "127.0.0.1:$PORT:48081" \
  -v "$VOL:/data" \
  -e TRUST_PROXY=1 -e LOG_LEVEL=warn \
  -e LB_WRITE_TOKEN=e2e-lb-secret -e GROUP_TOKEN=e2e-group-secret \
  "$IMG" >/dev/null
wait_healthy
E2E_BASE_URL="http://127.0.0.1:$PORT" E2E_EMULATED="$EMULATED" \
E2E_LB_TOKEN=e2e-lb-secret E2E_GROUP_TOKEN=e2e-group-secret \
  node --test --test-force-exit test/docker-e2e.test.js

# 同样放宽。镜像的 HEALTHCHECK 是 --interval=30s，而且要**同时**探两个服务
# （web-front 48080 + 本服务 48081），所以探测点落在 30 / 60 / 90… 秒；QEMU 下
# 前一两次很可能还没就绪，原来的 60 秒上限只够两次探测。
for _ in $(seq 1 "$BOOT_TIMEOUT"); do
  H=$(docker inspect -f '{{.State.Health.Status}}' "$NAME")
  [ "$H" = healthy ] && break
  sleep 1
done
[ "$H" = healthy ] || { echo "healthcheck stuck at: $H"; docker logs "$NAME" 2>&1 | tail -40; exit 1; }
echo "healthcheck: $H"

say "ALL DOCKER E2E PASSED"
