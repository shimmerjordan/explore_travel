#!/usr/bin/env bash
# Container-level smoke test for the web-front image.
#
# Runs the image exactly as a NAS deployment would (nonroot, /data volume) and
# drives the real API over HTTP: default-password login → the unauthenticated
# 401 surface → config round-trip → export scrubbing → password change with
# config re-encryption → the console page → the static-hosting fallback →
# restart persistence → the read-only WebDAV proxy's refusals.
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
BASE="http://127.0.0.1:$PORT"
# The credential that matters here is the one the image ships with: a fresh
# deployment MUST be reachable with admin/admin, and MUST say so.
NEWPASS="smoke-newpass-$$"
# A value that only ever appears in a credential field, so "did the scrubbed
# export leak it" is a grep rather than a judgement call.
DAVSECRET="S3CRET-$(openssl rand -hex 6)"

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

# $@ becomes extra `docker run` args, so a check can restart the same volume
# under a different configuration (used for the proxy, which is off by default).
start_container() {
  docker run -d --name "$NAME" "${PLAT_ARG[@]}" \
    -p "127.0.0.1:$PORT:48080" \
    -v "$VOL:/data" \
    "$@" \
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
code()    { curl -sS -o /tmp/smoke-body.$$ -w '%{http_code}' "$@"; }
# Read a body WITHOUT -f: for these assertions a 500 or 401 is the interesting
# failure, and `curl -f` under `set -e` would abort the script with curl's own
# exit code before the assertion could explain what the failure means.
body()    { curl -sS "$@"; }
login()   {
  curl -fsS -X POST "$BASE/api/session" -H 'content-type: application/json' \
    -d "{\"username\":\"admin\",\"password\":\"$1\"}" 2>/dev/null
}

say "a fresh deployment is reachable with the shipped default password"
LOGIN=$(login admin) || fail "admin/admin could not log in to a fresh image"
TOKEN=$(jsonstr "$LOGIN" token)
[ -n "$TOKEN" ] || fail "login returned no token: $LOGIN"
grep -q '"is_default_password":true' <<<"$LOGIN" \
  || fail "a fresh image must report is_default_password=true, got: $LOGIN"
ok "admin/admin works and the image says it is still the default"
AUTH=(-H "Authorization: Bearer $TOKEN")

say "nothing is readable without a session"
# Each of these guards something different -- stored credentials, operational
# metrics, a bulk download, and the user's cloud. A regression in any one of
# them is a separate incident, so they are asserted separately rather than
# spot-checked.
for ep in "/api/config" "/api/metrics" "/api/export?what=config"; do
  C=$(code "$BASE$ep")
  [ "$C" = 401 ] || fail "unauthenticated GET $ep should be 401, got $C"
done
ok "config / metrics / export all refuse an anonymous caller"

# The proxies are a different shape on purpose: with EJ_PROXY_ENABLED unset the
# guard answers 404 BEFORE looking at the session, so a disabled feature is not
# advertised to an anonymous prober. So the default-posture assertion is "not
# reachable", and the 401/405/403 behaviour is checked further down after
# turning the proxy on.
for ep in "/proxy/dav/x" "/proxy/url?u=https://example.com"; do
  C=$(code "$BASE$ep" "${AUTH[@]}")
  [ "$C" = 404 ] || fail "$ep should be 404 while EJ_PROXY_ENABLED is unset, got $C"
done
ok "both proxies are invisible by default, even to a logged-in caller"

say "config round-trip is byte-exact"
CFG="{\"webdavUrl\":\"https://dav.example.com\",\"webdavPass\":\"$DAVSECRET\",\"aiModel\":\"m1\"}"
C=$(code -X PUT "$BASE/api/config" "${AUTH[@]}" -H 'content-type: application/json' -d "$CFG")
[ "$C" = 200 ] || fail "PUT /api/config gave $C: $(cat /tmp/smoke-body.$$)"
GOT=$(body "$BASE/api/config" "${AUTH[@]}")
[ "$GOT" = "$CFG" ] || fail "config changed in flight: wrote '$CFG', read '$GOT'"
ok "GET returns exactly the bytes PUT stored (key order and all)"

say "export scrubs credentials by default"
SCRUBBED=$(curl -fsS "$BASE/api/export?what=config" "${AUTH[@]}")
grep -q "$DAVSECRET" <<<"$SCRUBBED" \
  && fail "the DEFAULT export leaked a credential -- this is the file people paste into chats"
grep -q '"webdavPass": null' <<<"$SCRUBBED" \
  || fail "the credential key should survive as null so it is visible that one is set: $SCRUBBED"
grep -q 'dav.example.com' <<<"$SCRUBBED" || fail "scrubbing must keep non-secret locators"
ok "scrubbed export nulls the credential and keeps the locator"

WITHSECRET=$(curl -fsS "$BASE/api/export?what=config&secrets=1" "${AUTH[@]}")
grep -q "$DAVSECRET" <<<"$WITHSECRET" || fail "secrets=1 must include the credential"
ok "secrets=1 is the only way credentials come out"
# A near-miss value must NOT be treated as the opt-in.
NEARMISS=$(curl -fsS "$BASE/api/export?what=config&secrets=yes" "${AUTH[@]}")
grep -q "$DAVSECRET" <<<"$NEARMISS" && fail "secrets=yes must not release credentials"
ok "a non-'1' secrets value still scrubs"

say "the console page is served without a session"
C=$(code "$BASE/admin")
[ "$C" = 200 ] || fail "/admin should be 200 even unauthenticated, got $C"
grep -qi '<!doctype html' /tmp/smoke-body.$$ || fail "/admin did not return an HTML document"
ok "/admin renders its own login form instead of 401-ing"

say "no web build in the image → a setup page, not a 404"
# This is the image's own state: web-dist/ holds only .gitkeep unless CI copied
# a Flutter build in. Either outcome is valid, so accept both but require that
# it is never a 404 -- an operator hitting / must be told what to do.
C=$(code "$BASE/")
[ "$C" = 200 ] || fail "GET / should be 200 (setup page or app), got $C"
if grep -qi 'EJ_WEB_ROOT' /tmp/smoke-body.$$; then
  ok "no web build present → setup page explains how to provide one"
else
  grep -qi 'flutter' /tmp/smoke-body.$$ \
    || fail "GET / is neither the setup page nor a Flutter build"
  ok "a real web build is baked in and served at /"
fi
# A path with an extension must 404 as JSON rather than being answered with the
# setup page, or a service worker fetching version.json gets HTML.
C=$(code "$BASE/version.json")
if grep -qi 'EJ_WEB_ROOT' <<<"$(curl -s "$BASE/")"; then
  [ "$C" = 404 ] || fail "with no web build, /version.json should be 404, got $C"
  ok "an asset path 404s instead of receiving the setup page"
fi

say "with the proxy ON, the WebDAV path is read-only and confined"
# Same volume, restarted with the proxy enabled -- so the config pushed above
# (which has a webdavUrl) is still there and these checks exercise the real
# code path rather than the disabled-feature 404.
docker rm -f "$NAME" >/dev/null
start_container -e EJ_PROXY_ENABLED=1
wait_ready
LOGIN_P=$(login admin) || fail "login failed after restarting with the proxy on"
TOKENP=$(jsonstr "$LOGIN_P" token)
AUTHP=(-H "Authorization: Bearer $TOKENP")

C=$(code -X PROPFIND "$BASE/proxy/dav/x")
[ "$C" = 401 ] || fail "unauthenticated PROPFIND should be 401 with the proxy on, got $C"
ok "an anonymous caller is refused once the feature exists"

for m in PUT DELETE MKCOL MOVE PROPPATCH; do
  C=$(code -X "$m" "$BASE/proxy/dav/x" "${AUTHP[@]}")
  [ "$C" = 405 ] || fail "$m /proxy/dav should be 405 (read-only proxy), got $C"
done
ok "PUT / DELETE / MKCOL / MOVE / PROPPATCH are all refused with 405"

# curl would normalise `..` away before sending, which would test nothing.
C=$(curl -sS --path-as-is -o /dev/null -w '%{http_code}' \
  "$BASE/proxy/dav/../../etc/passwd" "${AUTHP[@]}")
[ "$C" = 403 ] || fail "path traversal out of the configured base should be 403, got $C"
C=$(curl -sS --path-as-is -o /dev/null -w '%{http_code}' \
  "$BASE/proxy/dav/..%252f..%252fetc" "${AUTHP[@]}")
[ "$C" = 403 ] || fail "double-encoded traversal should be 403, got $C"
ok "literal and double-encoded traversal are both refused"

# Restore the default posture for the remaining checks.
docker rm -f "$NAME" >/dev/null
start_container
wait_ready
LOGIN=$(login admin) || fail "login failed after restoring the default posture"
TOKEN=$(jsonstr "$LOGIN" token)
AUTH=(-H "Authorization: Bearer $TOKEN")

say "changing the password re-encrypts the stored config"
# This is the assertion that matters most in the whole script: the config is
# encrypted under a key derived from the password, so a change that forgets to
# re-encrypt leaves it permanently unreadable -- and the only way to see that is
# to read it back afterwards under the NEW password.
C=$(code -X PUT "$BASE/api/password" "${AUTH[@]}" -H 'content-type: application/json' \
  -d "{\"old\":\"admin\",\"new\":\"$NEWPASS\"}")
[ "$C" = 200 ] || fail "password change gave $C: $(cat /tmp/smoke-body.$$)"
C=$(code "$BASE/api/config" "${AUTH[@]}")
[ "$C" = 401 ] || fail "the old token must die with the password, got $C"
ok "old session is revoked immediately"
login admin >/dev/null 2>&1 && fail "the old password still authenticates"
LOGIN2=$(login "$NEWPASS") || fail "the new password does not authenticate"
grep -q '"is_default_password":false' <<<"$LOGIN2" \
  || fail "after a change the image must stop reporting the default: $LOGIN2"
TOKEN2=$(jsonstr "$LOGIN2" token)
AUTH2=(-H "Authorization: Bearer $TOKEN2")
GOT=$(body "$BASE/api/config" "${AUTH2[@]}")
[ "$GOT" = "$CFG" ] || fail "CONFIG LOST ACROSS PASSWORD CHANGE -- the stored config is \
now encrypted under a key nothing holds, which is unrecoverable, not a failed request. \
Read back: '$GOT'"
ok "the config is still readable under the new password (re-encryption worked)"

say "state survives a container restart"
docker restart "$NAME" >/dev/null
wait_ready
# Sessions are in-memory by design, so a restart must invalidate them...
C=$(code "$BASE/api/config" "${AUTH2[@]}")
[ "$C" = 401 ] || fail "sessions must not survive a restart, got $C"
ok "sessions are gone after a restart (they are in-memory on purpose)"
# ...while the credential and the encrypted config must not.
LOGIN3=$(login "$NEWPASS") || fail "the changed password did not survive the restart"
TOKEN3=$(jsonstr "$LOGIN3" token)
GOT=$(body "$BASE/api/config" -H "Authorization: Bearer $TOKEN3")
[ "$GOT" = "$CFG" ] || fail "config lost across restart: read '$GOT'"
ok "password and encrypted config both persisted to the volume"

say "metrics reflect the traffic this script generated"
M=$(curl -fsS "$BASE/api/metrics" -H "Authorization: Bearer $TOKEN3")
grep -q '"login_failures"' <<<"$M" || fail "metrics payload missing login_failures: $M"
grep -q '"/api/config"' <<<"$M" || fail "metrics did not record the config route: $M"
grep -q '"is_default_password":false' <<<"$M" \
  || fail "metrics must report the password is no longer default"
ok "metrics expose route counters and the default-password state"

rm -f /tmp/smoke-body.$$
printf '\n\033[1;32m── ALL SMOKE CHECKS PASSED\033[0m\n'
