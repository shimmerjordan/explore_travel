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

wait_healthy() {
  for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "container never became healthy"; docker logs "$NAME" | tail -20; return 1
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

say "docker healthcheck turns healthy"
for _ in $(seq 1 60); do
  H=$(docker inspect -f '{{.State.Health.Status}}' "$NAME")
  [ "$H" = healthy ] && break
  sleep 1
done
[ "$H" = healthy ] || { echo "healthcheck stuck at: $H"; exit 1; }
echo "healthcheck: $H"

say "ALL DOCKER E2E PASSED"
