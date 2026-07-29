# explore_journal — web-front (Rust)

Thin **Rust** service for the web-display feature (plan §3.2 / §3.7). It does
three things and **stores no user content**:

1. **Auth** — register / login. The client sends an `authVerifier` (a
   password-derived value, *never* the password); the server re-hashes it with
   **Argon2id** + a per-record salt and mints a short-lived **HS256 JWT**
   (algorithm pinned, so `none`/RS256 confusion is rejected).
2. **Vault** — `GET`/`PUT /vault` store one **opaque encrypted blob** per user
   (the client-side zero-knowledge settings vault). The server can't decrypt it.
   Optimistic concurrency via `ETag` / `If-Match`.
3. **Read proxy** *(optional, off by default)* — `GET /proxy/gh/…` and
   `GET /proxy/url?u=…` fetch private images / CORS-less resources for the
   browser behind an SSRF guard. The upstream credential is **supplied by the
   client per request** (`X-Upstream-Authorization`) and never stored — the
   server is zero-knowledge and cannot read the vault to obtain it.

Stack: `tiny_http` (sync, threaded) + `rusqlite` (bundled SQLite, no system
deps) + `argon2` + `jsonwebtoken` + `ureq` (proxy). No async runtime.

> ✅ **Verified**: compiled with Rust 1.95 and `cargo test` passes (6 tests:
> vault CAS + conflict, unique-email, JWT roundtrip + wrong-secret rejection,
> Argon2 verify, SSRF safe-IP table). Run `cargo test` / `cargo clippy` yourself
> before deploying.

## Deploy on a NAS from the prebuilt image (recommended)

CI publishes a multi-arch (amd64 + arm64) image to GHCR on every push to
`main`, after the container-level smoke test passes. No source checkout and no
compiler needed on the NAS:

```bash
sudo mkdir -p /volume1/docker/web-front/data && cd /volume1/docker/web-front
# grab docker-compose.ghcr.yml from this directory, then:
cat > .env <<EOF
EJ_JWT_SECRET=$(openssl rand -base64 48)
EJ_DATA_PATH=/volume1/docker/web-front/data
EJ_CORS_ORIGINS=http://localhost:48082
EOF
sudo chown -R 65532:65532 /volume1/docker/web-front/data   # container runs as UID 65532
sudo docker compose up -d
curl localhost:48080/healthz    # {"status":"ok"}
```

The **run summary** of the「NAS 后端镜像（GHCR）」workflow prints this same
sequence with the compose file inlined and the exact image tag for that commit —
copy-paste from there and it is a genuine one-shot deploy.

## Build from source instead

```bash
cd web-front
echo "EJ_JWT_SECRET=$(openssl rand -base64 48)" > .env
echo "EJ_CORS_ORIGINS=https://your-web-host.example" >> .env
docker compose up -d            # builds the image, listens on :48080

# ...or without Docker
cargo build --release           # needs a C compiler for the bundled SQLite
EJ_JWT_SECRET=$(openssl rand -base64 48) ./target/release/web-front
```

## Where the data lives

`EJ_DATA_PATH` picks the storage location, and it is the same variable in both
compose files:

| `EJ_DATA_PATH` | Result |
|---|---|
| unset (default) | Docker **named volume** — zero host setup, inherits the image's nonroot-owned `/data` |
| absolute path | **bind mount** — data in your own directory; run `chown -R 65532:65532 <path>` once first, or the container exits with `unable to open database file` |

Either way it holds `ej.db`, i.e. **every user's vault ciphertext** — back it
up, and keep it on a **local** filesystem. Never NFS/SMB: SQLite's WAL and
POSIX locks are unreliable there and will corrupt the DB.

```bash
# verify the image end to end (registration → vault round-trip → restart
# persistence → registration lockout), against a local build:
BUILD=1 ./scripts/docker-smoke.sh
```

## Configuration

Two channels: env **overrides** an optional JSON file (`EJ_CONFIG`, default
`/data/config.json`). Edit the file + `docker compose restart` — no rebuild.

| Env | File key | Default | Notes |
|-----|----------|---------|-------|
| `EJ_JWT_SECRET` | `jwt_secret` | — | **required**, ≥ 32 bytes |
| `EJ_LISTEN` | `listen` | `0.0.0.0:48080` | high port; change freely |
| `EJ_DB_PATH` | `db_path` | `/data/ej.db` | local volume only |
| `EJ_CORS_ORIGINS` | `cors_origins` | — | exact origins (csv); never `*` |
| `EJ_ALLOW_REGISTRATION` | `allow_registration` | `true` | close after first signup |
| `EJ_PROXY_ENABLED` | `proxy_enabled` | `false` | enable the read proxy |
| `EJ_PROXY_ALLOW_HOSTS` | `proxy_allow_hosts` | — | exact host allowlist for `/proxy/url` |
| `EJ_TOKEN_TTL_SECS` | `token_ttl_secs` | `3600` | JWT lifetime (cheap re-login) |
| `EJ_TRUST_PROXY` | `trust_proxy_header` | `false` | honour `X-Forwarded-For` (only behind your own reverse proxy) |

`config.json` example:
```json
{ "listen": "0.0.0.0:48080", "cors_origins": ["https://ej.example.com"],
  "allow_registration": false, "proxy_enabled": true,
  "proxy_allow_hosts": ["dav.jianguoyun.com"], "token_ttl_secs": 3600 }
```

## Endpoints

```
GET  /healthz
POST /auth/register   {email, authVerifier(b64), salt(b64)} → {token, user_id, vault_version}
POST /auth/login      {email, authVerifier(b64)}            → {token, ...}
GET  /auth/salt?email=…  → {salt}            # pseudo-salt for unknown emails (anti-enum)
GET  /auth/me  (Bearer)  → {user_id, vault_version}
GET  /vault    (Bearer)  → octet-stream + ETag | 304 (If-None-Match) | 404
PUT  /vault    (Bearer, If-Match:"<v>", ≤256 KiB) → {version} | 409 {current_version}
GET  /proxy/gh/{owner}/{repo}/{branch}/{path...}  (Bearer, +X-Upstream-Authorization)
GET  /proxy/url?u=<abs-url>                        (Bearer, host allowlisted)
OPTIONS *  → 204 + CORS preflight
```

## Threat model (zero-knowledge)

A breach of `ej.db` + the JWT secret exposes (a) Argon2id hashes of
`authVerifier` (only weak passwords are then offline-crackable) and (b) vault
**ciphertext** (undecryptable without the password — HKDF domain separation
means `authVerifier` does not yield the `vaultKey`). It exposes **no** plaintext
secret and **no** journal/track/fog/media content (never stored here).

The proxy is the largest residual surface: a single allowlist shared across
users makes it an open relay to allowlisted hosts — **do not expose it
multi-tenant**; it targets a single-user / family deployment. The SSRF guard
(`proxy.rs`) uses a custom `ureq` resolver that returns only validated public
IPs (rejects loopback / RFC1918 / link-local / ULA / IPv4-mapped / metadata,
IPv4 **and** IPv6) and pins the connection to a checked IP (defeats DNS
rebinding); redirects are disabled.

## Notes / deviations from the original plan

- **Backend is Rust** (was specced as Go) — same API contract.
- **Upstream proxy credential is client-supplied** per request
  (`X-Upstream-Authorization`), not read from the vault: the server is
  zero-knowledge and cannot decrypt the vault, so it can't hold the PAT.
- **Config is JSON** (`/data/config.json`), not YAML — no extra dependency.
