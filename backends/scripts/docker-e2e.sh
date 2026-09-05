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

# 启动等待预算。原值是 100 × 0.2s = 20 秒，在 QEMU 下不够：CI 的 arm64 冒烟
# 2026-09-05 与 09-06 两次都恰好挂在这一步，而**同一个容器**在 web-front 那套
# 冒烟里却过了 —— 唯一的差别就是它等 150 × 0.4s = 60 秒。合并成单镜像之后启动
# 要做的事更多（entrypoint 建目录 / 改属主 / 迁旧数据 → supervisord 拉起 Rust
# 与 Node 两个进程），模拟执行下慢一个数量级。
#
# 本机原生启动 1-2 秒就绪，所以放宽上限是纯保险、不影响本地速度：轮询 0.2 秒
# 一次的粒度没变，就绪即返回。
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

say "round 1: open mode (full API + data correctness + relay + docker-restart persistence)"
docker volume create "$VOL" >/dev/null
docker run -d --name "$NAME" \
  -p "127.0.0.1:$PORT:48081" \
  -v "$VOL:/data" \
  -e TRUST_PROXY=1 -e LOG_LEVEL=warn \
  "$IMG" >/dev/null
wait_healthy
E2E_BASE_URL="http://127.0.0.1:$PORT" E2E_CONTAINER="$NAME" \
  node --test --test-force-exit test/docker-e2e.test.js

say "round 2: auth mode (LB_WRITE_TOKEN + GROUP_TOKEN enforced)"
docker rm -f "$NAME" >/dev/null
docker run -d --name "$NAME" \
  -p "127.0.0.1:$PORT:48081" \
  -v "$VOL:/data" \
  -e TRUST_PROXY=1 -e LOG_LEVEL=warn \
  -e LB_WRITE_TOKEN=e2e-lb-secret -e GROUP_TOKEN=e2e-group-secret \
  "$IMG" >/dev/null
wait_healthy
E2E_BASE_URL="http://127.0.0.1:$PORT" \
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
