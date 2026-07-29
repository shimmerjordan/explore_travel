#!/usr/bin/env bash
# Container-level smoke test for the web-front image.
#
# Runs the image exactly as a NAS deployment would (nonroot, /data volume) and
# drives the real API over HTTP: register → session → vault round-trip →
# optimistic concurrency → restart persistence → registration lockout.
#
#   ./scripts/docker-smoke.sh                        # build locally, full run
#   IMAGE=ghcr.io/o/r/web-front:latest ./scripts/docker-smoke.sh
#   LEVEL=boot PLATFORM=linux/arm64 ./scripts/docker-smoke.sh   # foreign arch
#
# LEVEL=full (default) exercises the whole API, and that is what CI runs for
# BOTH architectures: ring ships aarch64-specific assembly, Argon2 has
# arch-dependent paths and bundled SQLite is cross-compiled C, so "it links" is
# not "it computes correctly". Emulation is not a reason to skip it — measured on
# the same cross-compiled binary under qemu-aarch64: register 0.115 s, one Argon2
# verify 0.096 s.
#
# LEVEL=boot is kept for the rare case where you only want to prove the binary
# starts and serves /healthz (e.g. probing a new arch before wiring it up).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=${IMAGE:-web-front:smoke}
PORT=${PORT:-18991}
LEVEL=${LEVEL:-full}
PLATFORM=${PLATFORM:-}
NAME="web-front-smoke-$$"
VOL="${NAME}-data"
SECRET=$(openssl rand -base64 48)
# One verifier reused across register and login, so the login assertion is
# meaningful (same credential must authenticate).
VERIFIER=$(openssl rand 32 | openssl base64 -A)
SALT=$(openssl rand 16 | openssl base64 -A)
EMAIL="smoke@example.com"
BASE="http://127.0.0.1:$PORT"

say()  { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; docker logs "$NAME" 2>&1 | tail -30 >&2 || true; exit 1; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

PLAT_ARG=()
[ -n "$PLATFORM" ] && PLAT_ARG=(--platform "$PLATFORM")

if [ "${BUILD:-0}" = 1 ]; then
  say "build image $IMAGE"
  docker build -t "$IMAGE" "${PLAT_ARG[@]}" .
fi

start_container() {
  docker run -d --name "$NAME" "${PLAT_ARG[@]}" \
    -p "127.0.0.1:$PORT:48080" \
    -v "$VOL:/data" \
    -e EJ_JWT_SECRET="$SECRET" \
    -e EJ_ALLOW_REGISTRATION="${ALLOW_REG:-true}" \
    "$IMAGE" >/dev/null
}

wait_ready() {
  for _ in $(seq 1 150); do
    if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 0.4
  done
  fail "container never answered /healthz"
}

# --- boot ---------------------------------------------------------------------
say "boot the image ($IMAGE${PLATFORM:+ on $PLATFORM})"
docker volume create "$VOL" >/dev/null
start_container
wait_ready
curl -fsS "$BASE/healthz" | grep -q '"status":"ok"' || fail "/healthz payload unexpected"
ok "container runs nonroot and serves /healthz"

# Proves the binary is actually the arch we asked for, not a silently
# host-arch artifact slipping through cross-compilation.
if [ -n "$PLATFORM" ]; then
  GOT=$(docker inspect --format '{{.Architecture}}' "$IMAGE")
  WANT=${PLATFORM##*/}
  [ "$GOT" = "$WANT" ] || fail "image arch is $GOT, expected $WANT"
  ok "image architecture is $GOT"
fi

if [ "$LEVEL" = boot ]; then
  say "LEVEL=boot — skipping API assertions"
  echo "SMOKE OK (boot)"
  exit 0
fi

# --- API ----------------------------------------------------------------------
jsonstr() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" <<<"$1"; }

say "register → session"
REG=$(curl -fsS -X POST "$BASE/auth/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"authVerifier\":\"$VERIFIER\",\"salt\":\"$SALT\"}") \
  || fail "register failed"
TOKEN=$(jsonstr "$REG" token)
[ -n "$TOKEN" ] || fail "register returned no token: $REG"
ok "registered, got a session token"

curl -fsS "$BASE/auth/me" -H "Authorization: Bearer $TOKEN" | grep -q '"vault_version":0' \
  || fail "/auth/me should report vault_version 0 for a fresh account"
ok "/auth/me reports a fresh vault"

say "vault round-trip + optimistic concurrency"
CIPHER="ciphertext-$(openssl rand -hex 8)"
PUT=$(curl -fsS -X PUT "$BASE/vault" -H "Authorization: Bearer $TOKEN" \
  --data-binary "$CIPHER") || fail "first vault PUT failed"
grep -q '"version":1' <<<"$PUT" || fail "first PUT should return version 1, got: $PUT"
ok "PUT /vault stored v1"

GOT=$(curl -fsS "$BASE/vault" -H "Authorization: Bearer $TOKEN")
[ "$GOT" = "$CIPHER" ] || fail "vault content changed: wrote '$CIPHER', read '$GOT'"
ok "GET /vault returns the exact bytes written"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/vault" \
  -H "Authorization: Bearer $TOKEN" -H 'If-None-Match: "1"')
[ "$CODE" = 304 ] || fail "If-None-Match should give 304, got $CODE"
ok "ETag revalidation returns 304"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$BASE/vault" \
  -H "Authorization: Bearer $TOKEN" -H 'If-Match: "0"' --data-binary 'stale')
[ "$CODE" = 409 ] || fail "stale If-Match should give 409, got $CODE"
ok "stale If-Match is rejected with 409 (no lost update)"

say "login with the same credential"
LOGIN=$(curl -fsS -X POST "$BASE/auth/login" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"authVerifier\":\"$VERIFIER\"}") || fail "login failed"
[ -n "$(jsonstr "$LOGIN" token)" ] || fail "login returned no token: $LOGIN"
ok "login issues a session"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/auth/login" \
  -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"authVerifier\":\"$(openssl rand 32 | openssl base64 -A)\"}")
[ "$CODE" = 401 ] || fail "wrong verifier should give 401, got $CODE"
ok "a wrong verifier is refused"

say "data survives a container restart"
docker restart "$NAME" >/dev/null
wait_ready
GOT=$(curl -fsS "$BASE/vault" -H "Authorization: Bearer $TOKEN")
[ "$GOT" = "$CIPHER" ] || fail "vault lost across restart: read '$GOT'"
ok "vault ciphertext intact after restart (SQLite WAL flushed to the volume)"

say "registration lockout (EJ_ALLOW_REGISTRATION=false)"
docker rm -f "$NAME" >/dev/null
ALLOW_REG=false start_container
wait_ready
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/auth/register" \
  -H 'content-type: application/json' \
  -d "{\"email\":\"other@example.com\",\"authVerifier\":\"$VERIFIER\",\"salt\":\"$SALT\"}")
[ "$CODE" = 403 ] || fail "registration should be closed (403), got $CODE"
ok "closed registration refuses new accounts"

# The proxy is the largest residual attack surface, so verify it is off unless
# explicitly enabled (see the threat model in README.md).
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/proxy/url?u=https://example.com" \
  -H "Authorization: Bearer $TOKEN")
[ "$CODE" != 200 ] || fail "read proxy answered 200 while EJ_PROXY_ENABLED is unset"
ok "read proxy stays disabled by default (got $CODE)"

printf '\n\033[1;32m── ALL SMOKE CHECKS PASSED\033[0m\n'
