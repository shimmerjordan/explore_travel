# Explore Journal

> A self-hosted, backendless travel & exploration app inspired by **Fog of World**.
> Track your trips, light up the world's fog of war, sync via WebDAV, plan trips with AI,
> share live routes with friends via ZeroTier, and build a rich travel journal — all
> while owning every byte of your data.
>
> The **same Flutter codebase** also ships a read-only **web "memory" version** for
> reminiscing in the browser, with optional per-user login backed by a tiny self-hosted
> **NAS backend** (Rust + Docker) that stores only your settings inside a
> **encrypted config store** on a service you run — never your raw travel data.

![flutter](https://img.shields.io/badge/Flutter-3.32+-02569B?logo=flutter)
![platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20Linux%20%7C%20Web-success)
![backend](https://img.shields.io/badge/optional%20backend-Rust%20%2B%20Docker-orange?logo=rust)
![license](https://img.shields.io/badge/license-CC%20BY--NC--SA%204.0-lightgrey)

[中文 README](README.zh.md)

---

## Features

| Area | What you get |
|------|--------------|
| 🗺️ Maps | OSM / 高德 / Google × standard / satellite / hybrid · live switching · GCJ-02 ↔ WGS-84 conversion · **offline tile cache** (100k tiles / 365 days) · opt-in rotation + compass chip · location dot grows a heading arrow when moving (>0.5 m/s) · **3D globe** (pinch past min zoom → textured day/night sphere with footprint heat-map) |
| 🌫️ Fog of war | Fog of World–compatible 64×64 bitmap tiles for storage / stats / sync · rendered as **baked map tiles** that pan/zoom pixel-for-pixel with the base imagery · **FoW-style smooth reveal**: z15–17 baked natively as anti-aliased disk unions with a gaussian feather (no pixel staircase at any zoom; z≤14 stays bit-exact) · live recording merges **incrementally** into the snapshot (no full-table re-reads) · optional coloured trail line honouring **per-point recorded width** · per-segment GPS-dropout split · brush radius / color / opacity tunable · per-layer |
| 👤 Profile & avatar | Tap right-top chip → bottom sheet with base64 avatar editor (256×256 / ≤30 KB) · nickname inline edit · peerId copy · avatar inlined into leaderboard entries + peer markers · M3 ripple + scale animations on home tiles |
| 🏆 Leaderboard | **Decentralised, append-only, signed** · Ed25519 keypair per device · LWW by `statsAt` per peerId · TOFU on publicKey · global km² + month-by-month tabs · auto-merge over the same P2P transport as chat/voice (`lb_hello / lb_pull / lb_batch`) · always-included in backup module · optional GitHub PR to a community registry repo · optional REST server backend ([API spec](docs/leaderboard-server-api.md)) |
| 📍 Tracking | Android foreground service (`flutter_foreground_task`) — survives screen-off / Doze / process-kill and auto-resumes · 3 power modes: **High 1 s / 2 m · Balanced 10 s / 15 m · Saver 30 s / 40 m** · dual-stream (live UI + on-disk JSONL buffer so background points aren't lost) · per-row UUID cross-device dedup · **camera auto-follows while recording** (manual pan opts out; locate FAB re-arms) · GPS signal chip keyed to fix + accuracy, not staleness · EXIF GPS auto-tagging |
| 🗂️ Layers | Color-coded, taggable, per-layer visibility · in-map dropdown chip · auto-fallback when active layer is hidden/missing |
| 🌐 Exploration | Real-area progress — revealed km² ÷ region km² (UN country areas) · 10-decimal precision · **smallest-bbox attribution** so a point in Shanghai doesn't double-count into Jiangsu/Zhejiang · global "incl. ocean" + per-country + per-province + learned-from-visits regions |
| ☁️ Export & Import (导出与导入) | Unified page · **12 modules** independently selectable (leaderboard + tombstones always included) · **chunked archive** (fog as **native Fog of World tile files**, per-month track points, per-peer chat) · WebDAV upload / restore · local export & share · **incremental cloud sync**: MD5 index so only changed shards upload, 3-wide parallel transfers, one continuous progress bar · **three-way incremental**: adds (union / per-row), edits (row-level LWW — they finally propagate), deletes (tombstones + erase masks — no resurrection) · cross-device **layer remap by uuid** · secret fields stripped from exports |
| 🌫️ FOW compat | **Two-way interop**: cloud/backup fog IS a set of native FoW tile files — copy either way between our `Sync/fow/` and a Fog of World "Sync" folder · manual **import** via the system file picker (**reaches OneDrive & other cloud providers**; zip vs raw tiles auto-detected by magic bytes) · **export** packs visible-layer fog into a zip handed to the system share sheet |
| 🖼️ Image host | Per-journal `public` / `private` level · GitHub direct (Contents API) + jsDelivr/Statically CDN · private repo via raw-with-PAT + in-app authenticated image loader · generic custom host (Chevereto/兰空/EasyImage…) via URL templates · async upload queue + retry · path hierarchy `traveler/yyyy/mm/continent/country/province/city/title-id/uuid.ext` |
| 🤖 AI | OpenAI-compatible (SiliconFlow / OpenAI / DeepSeek…) · streaming trip planning with manual cancel · 30-min timeout · persistent chat history (30-day retention) · mini-map + energy estimates from emitted JSON · context-aware music keyword generation |
| 🎵 Music | NetEase / Kuwo / JOOX direct backends + GD聚合 fallback · cookie capture via WebView · AI playlist (place + mood → songs) · favorites map |
| 🖋️ Journal | Quill rich text with inline image embed · view-first + edit-mode dialog · level / owner picker · map pins with per-pin & global hide · uses current display pin (simulator-aware) as creation location |
| 🌍 Geocoding | Layered: 0.01° grid cache → 高德 reverse (if key) → system `geocoding` → bbox fallback · learned-regions table grows bbox with every confirmed visit · optional **background prewarm** as map pans |
| 🎞️ Playback | Per-recording **session** list (auto-split on 10-min gap, ≥10 pts) · year/month filter · period summary · stitched multi-session playback · 1-16× speed · time-clipped peer trails (persisted) · journal bubbles (hideable) |
| 🛰️ P2P | **4 transports**: LAN UDP multicast + subnet TCP scan (`MulticastLock` on Android) · ZeroTier / virtual-LAN underlay · WebRTC (WebDAV signaling) · frp XTCP hole-punch · live route sharing · group + 1:1 private chat · push-to-talk voice · music broadcast · **AES-GCM-256 end-to-end** via PBKDF2-SHA256 (50k iters) · WebDAV mailbox for offline · group diagnostics |
| 🐞 Debug mode | Hidden — tap version label on home 10× · log buffer (ring of 1000) with filter/share · fog & recording diagnostics · simulator panel in release builds · "fire test reveal" button |
| 💾 Portability | Everything in one SQLite + a `journal_media/` folder. Schema v4 with UUIDs. Standard zip backups. No vendor lock-in. |
| 🔒 Security | Credentials (PATs, tokens, WebDAV password, p2p passphrase) live in **flutter_secure_storage** → Android Keystore / iOS Keychain · both backup exports and cloud sync **strip secret fields** from the settings, and can carry them in a **separately encrypted member** (random salt + 600k PBKDF2 + AES-GCM) — a typed password for a backup, a set-once sync passphrase for unattended sync. Without it a leaked archive still leaks nothing · runtime HTTP guard refuses **cleartext to non-private hosts** (LAN HTTP still works) · no analytics, no remote logging, no telemetry, no third-party SDK ad/analytics call |
| 🌐 Web 回忆版 | Same codebase built for the browser as a **read-only** display/reminiscing app · drift `WasmDatabase` (IndexedDB) · import a backup zip → relive your map, fog, journal, globe · optional **login** via a self-hosted Rust+Docker service (`web-front`) that stores *only settings*, encrypted at rest (your data stays on your own WebDAV/GitHub) · PWA-installable · debug-mode backdoor unlocks editing · [deploy guide](docs/web-display-deploy.md) |

---

## Features in depth

A few modules that don't fit in one table row:

### 🌫️ Fog engine & trail rendering
Fog is stored in **Fog of World's tile format** — a 512×512 global tile grid (zoom 9),
128×128 blocks per tile, each block a 64×64-bit bitmap (512 bytes, MSB-first), ≈9.55 m per
pixel at the equator. Reveal sweeps a disk pixel-by-pixel along each segment (capped at
8192 steps) to avoid scalloping on diagonals.

The explored area renders as **baked Web-Mercator tiles** drawn by flutter_map's own tile
pipeline, so the fog pans, pinches and zooms pixel-for-pixel with the base imagery — no
per-frame re-rasterisation, none of the gesture/thickness artifacts a dynamic painter had.
At the fog's native zoom (14, 1 fog cell = 1 px) and below, tiles are punched with an exact
integer pass that keeps FOW bit-parity. From z15 to z17 each tile is baked natively: every
explored cell becomes an anti-aliased disk and the union is feathered with a single gaussian
pass — the smooth, round-cornered **Fog of World look** instead of scaled-up pixel
staircases; past z17 the already-soft tiles overzoom gracefully. Live recording streams
changed fog rows **incrementally** into the tile snapshot (no full-table re-read per tick).

An optional translucent coloured line can be drawn along recorded trails, stroking each
point at its **own recorded width** (the brush size at record time — changing the slider
only affects future points). A new segment starts (so no false straight line is drawn)
whenever the gap exceeds 30 s, the implied speed is absurd, or accuracy is worse than 150 m.
Brush radius, colour, and opacity are tunable per layer.

### 📍 Recording reliability
A foreground `LocationService` feeds the live UI while a background isolate appends samples
to an on-disk `pending_track.jsonl` buffer — so screen-off, Doze, or a suspended main isolate
don't drop points. On cold start (or after a process kill / reboot while recording), the
service re-attaches and drains the buffer, de-duplicated (200 ms-rounded time + 6-decimal
lat/lng, plus per-row UUIDs for cross-device merges). The camera centres on you while
recording; a manual pan/rotate/zoom pauses follow (the locate icon switches to "searching"),
and the locate FAB — or starting a fresh recording — re-arms it. The signal chip reflects
only whether a fix exists and its accuracy, never how long since the last update.

### 🏆 Leaderboard trust model
Fully decentralised: each device holds an **Ed25519** keypair and signs every entry over
canonical JSON. Merges are **last-writer-wins** by `statsAt`, with **trust-on-first-use** per
peerId (a rotated key for the same id is rejected). Three sync paths: peer-to-peer gossip over
the same transport as chat (`lb_hello → lb_pull → lb_batch`), a GitHub PR to a community
registry, or an optional REST server ([API spec](docs/leaderboard-server-api.md)). Monthly
standings distribute cumulative km² across months in proportion to per-month track-point
counts.

### 🛰️ P2P transports
No central server — peers are discovered and connected over any of four interchangeable
transports, all speaking the same newline-framed JSON protocol: **LAN UDP multicast**
(`239.42.42.42:47829`) + subnet TCP scan (`MulticastLock` on Android); a **virtual-LAN
underlay** (ZeroTier / Tailscale / home Wi-Fi — peers are found the same way on all of them);
**WebRTC** with WebDAV-file SDP/ICE signaling; and **frp XTCP** hole-punching via an embedded
`frpc`. Messages are optionally sealed with **AES-GCM-256** using a key derived from the
shared passphrase via PBKDF2-SHA256 (50 000 iterations). Capabilities: live location/trail
sharing, group + 1:1 chat, push-to-talk (24 kHz AAC, 350 ms chunks), synchronised playback,
and a WebDAV mailbox for offline delivery.

### ☁️ Export & Import / FOW compat
The unified page packs everything into one **chunked zip**: 12 modules (journal, layers, fog
tiles, favorites, track points, chat, AI history, settings, image-host records, geocode cache,
learned regions, and leaderboard — leaderboard and tombstones always included). **Fog ships
as native Fog of World tile files** (`fow/<layerUuid>/<obfuscatedName>` — extract a backup
and drop them straight into a FoW Sync folder); tracks split per month, chat per peer. Local
files and WebDAV uploads are byte-identical and interchangeable. Import is a **compared,
incremental merge**: new rows insert; editable rows (journal, layers) merge by per-row
**last-writer-wins on `updatedAt`**, so edits genuinely propagate and an older cloud copy
never clobbers a newer local one; immutable rows (track points, chat) dedup by UUID; and
every row is **remapped to the uuid-matched layer** (autoincrement layer ids differ across
devices). Exports strip every secret field.

**Incremental cloud sync** (OneDrive / GitHub / WebDAV / NAS via one `SyncStorage`
interface) regroups those entries into shards: **fog travels as the native FoW files
themselves, raw and 1:1** (never zipped — the cloud `Sync/fow/` folder IS a valid Fog of
World tile set you can copy either way, and spatial locality means only tiles near
newly-explored areas re-upload); tracks per year, chat per peer, everything else in
`meta.zip`, with the metadata FoW's format can't carry (per-block timestamps, erase masks)
in `fogindex.zip`. Zip shards over 24 MB raw split into deterministic `.pN.zip` parts
(≈≤10 MB zipped each). A `.ej_index.json` maps shard → MD5, and **both directions are
diffed**: uploads send only changed shards (git-style), and pulls rebuild the local shard
hashes first and fetch only what differs — a routine pull is a handful of requests even
with hundreds of tile files ("restore" mode still fetches everything). Small files run
8-wide, multi-MB zips 3-wide, packing runs off the UI isolate, oversized OneDrive files
use resumable upload sessions, and one continuous progress bar spans export → pack →
diff → transfer → index.

**Deletes and erases propagate too（增量减）**: every local deletion (erased track points,
removed journals / layers / favorites) records a tombstone that always rides along in
exports; imports apply tombstones first and skip those uuids while merging. Fog merges by
**bitwise union + erase masks**: two devices exploring the same block converge to the
union of both pixel sets (neither side is lost), while erased pixels are recorded as
timestamped masks (`fog_erases`) that clear only copies OLDER than the erase — so erases
reach every device in any sync order, and re-exploring after an erase legitimately
brings the area back.
**Fog of World** interop is now two-way: the cloud/backup fog files ARE FoW tiles (copy
them into a FoW Sync folder, or drop FoW's tiles under `fow/` in an archive — layer-less
tiles land on the default layer). Manual import still multi-selects files via the system
picker (which reaches **OneDrive** and other cloud providers — unlike the SAF folder
picker), auto-detecting zip vs raw tiles by magic bytes; export bundles visible-layer fog
into a zip handed to the share sheet.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  UI · 20+ screens · go_router · Material 3                  │
├─────────────────────────────────────────────────────────────┤
│  State management: Riverpod 2                               │
├──────────┬─────────────┬─────────────┬──────────────────────┤
│ Location │  Database   │     P2P     │   External APIs      │
│ • bg svc │  • Drift    │  • mDNS     │  • OpenAI-compat AI  │
│ • EXIF   │  • (Wasm    │  • Sockets  │  • gdstudio music    │
│          │     on web) │  • AES-GCM  │  • Map tile servers  │
├──────────┴─────────────┴─────────────┴──────────────────────┤
│  Fog engine (custom): 64×64 bitmap tiles, RLE-friendly      │
├─────────────────────────────────────────────────────────────┤
│  SyncStorage (transport-agnostic): WebDAV · GitHub · OneDrive│
├─────────────────────────────────────────────────────────────┤
│  Persistence boundary: SQLite + files → backup .zip         │
└─────────────────────────────────────────────────────────────┘
        web build (read-only) ┄┄┄ optional ┄┄┄┐
┌─────────────────────────────────────────────────────────────┐
│  NAS backend (Rust + Docker, self-hosted, tiny)             │
│  • argon2 single-admin login  • stores ONLY an encrypted   │
│    config blob — never your travel data                    │
│  • SSRF-guarded WebDAV proxy   (never sees your raw data)    │
└─────────────────────────────────────────────────────────────┘
```

**Backendless by default.** On mobile/desktop the only "server" you talk to is the WebDAV
provider of your choice (Nextcloud, AList, Seafile, 坚果云, jianguoyun, infinicloud, your own
dav.sh, …). The **NAS backend is optional** and exists only so the web version can log users
in and remember *their settings* (sync URLs, keys), encrypted at rest — your actual
travel data never lives on it. See the [Web memory version](#web-memory-version-web-回忆版) below.

---

## Web memory version (web 回忆版)

The browser build is a **read-only "memory" face** of the same app — for reliving trips on a
big screen, not recording them. The Android phone stays the recording battlefield; the web is
import → display.

- **What works on web:** map · fog-of-war · 3D globe · journal · exploration stats · playback.
  Recording, the Android foreground service, and P2P chat are no-ops in the browser.
- **Storage:** drift runs on `WasmDatabase` (IndexedDB) — bundled `sqlite3.wasm` + `drift_worker.js`.
- **Getting data in:** import a backup `.zip` (same schema as mobile), or log in and let the
  app pull from your own sync target.
- **Read-only by design:** editing tools are hidden; turning on **debug mode** is the backdoor
  that re-enables them.
- **PWA:** installable to the home screen / desktop.

### Optional NAS backend (Rust + Docker)

Login is served by a tiny self-hosted service in [`web-front/`](web-front/)
(tiny_http + argon2 + chacha20poly1305 + ureq — no async runtime, no database). Its job is to
remember your *settings* — sync URLs, provider keys — **encrypted at rest**, and to serve the web
build plus an operator console:

- **One admin account, no signup.** Argon2id verifies the password; the session is a table in
  the server's memory (a restart invalidates every session), not a JWT.
- The phone pushes up the subset of settings needed to reach *your own* cloud. The server keeps
  that **encrypted at rest** (ChaCha20-Poly1305, key derived from the admin password) and hands
  it to the web client after login. It **never stores your raw travel data** — that stays on your
  WebDAV/GitHub/OneDrive.
- **The server can decrypt that config.** This is a deliberate change from the project's earlier
  zero-knowledge design: the confidentiality boundary is now the admin password, and what it buys
  is a browser that holds no cloud credential at all. Forgetting the admin password means the
  stored config is unrecoverable — push a fresh one from the phone.
- It also serves the Flutter web build, an operator console at `/admin`, and a **read-only,
  SSRF-guarded WebDAV proxy** so the browser can reach a WebDAV host that lacks CORS. Write verbs
  are refused outright: one XSS must not be able to wipe your cloud backup.

```bash
cd web-front
docker compose up -d          # listens on :48080 — no required env vars
```

The default password is `admin`/`admin` and **must be changed immediately**; the console shows a
banner with an inline change-password form until it is.

### Deploying the web build

`scripts/build-site.sh` assembles one static site — promo landing at `/`, the Flutter app at
`/app/` — into `./dist`. The `site` job in
[`.github/workflows/build.yml`](.github/workflows/build.yml) builds it and publishes the output
to a `web-build` branch, which Vercel / Cloudflare Pages deploy directly (no Flutter SDK needed
on the host). That workflow is **manual only** — Actions → 构建与发布 → Run workflow — so a push
never silently redeploys the public site.

📖 **Full deploy & test walkthrough:** [docs/web-display-deploy.md](docs/web-display-deploy.md)

---

## Quick Start (5 minutes)

### Prerequisites

| Tool | Min version | Install |
|------|-------------|---------|
| Flutter SDK | 3.32 stable | https://docs.flutter.dev/get-started/install |
| Dart | 3.5 | (bundled with Flutter) |
| Android SDK (cmdline-tools only) | 35 | https://developer.android.com/tools |
| Xcode | 15 | App Store (iOS only) |
| Ubuntu/Linux build deps | — | `sudo apt install xz-utils clang libgtk-3-dev ninja-build cmake` |

You **do not** need Android Studio; `cmdline-tools` is enough.

### 1. Get the source

```bash
git clone <your-fork-url> explore_journal
cd explore_journal
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter doctor   # everything should be ✓ except possibly "Android Studio (not installed)"
```

### 2. Run on a device

```bash
# Connect Android phone via USB, USB debugging on:
flutter devices                       # confirms phone shows up
flutter run                           # hot-reload mode

# Or build an APK and sideload:
flutter build apk --debug
adb install build/app/outputs/flutter-apk/app-debug.apk
```

iOS (Mac only):

```bash
cd ios && pod install && cd ..
open ios/Runner.xcworkspace            # set signing team, then ⌘R
```

Web (read-only memory version — see [Web memory version](#web-memory-version-web-回忆版)):

```bash
# Plain app build (served at site root):
flutter build web --release
cd build/web && python3 -m http.server 8000

# Or the integrated site (promo landing at /, app at /app/) → ./dist :
bash scripts/build-site.sh
cd dist && python3 -m http.server 8080   # open the ROOT path, not /app/
```

Linux desktop:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/explore_journal
```

### 3. First-run setup

Open the app → **设置** (Settings):

1. **AI** — paste your SiliconFlow / OpenAI API key & pick a model.
2. **WebDAV** — URL + user + password (test with "立即备份").
3. **P2P 共享口令** — any phrase shared with friends; messages get AES-GCM encrypted with a key derived from it.
4. **地图提供商** — switch between OSM / 高德 / Google as you like.
5. **记录模式** — High / Balanced / Saver. Saver is fine for daily commutes.

Then go to **地图** → tap **开始记录** → walk around → fog lights up.

---

## Build artefacts

| Target | Command | Output |
|--------|---------|--------|
| Android debug APK | `flutter build apk --debug` | `build/app/outputs/flutter-apk/app-debug.apk` (~160MB) |
| Android release APK | `flutter build apk --release` | smaller, signing required |
| Android AAB (Play Store) | `flutter build appbundle --release` | `build/app/outputs/bundle/release/app-release.aab` |
| iOS IPA | `flutter build ipa --release` | `build/ios/ipa/explore_journal.ipa` |
| Linux | `flutter build linux --release` | `build/linux/x64/release/bundle/` |
| Web | `flutter build web --release` | `build/web/` |

### Signing the Android release

Create `android/key.properties`:

```
storeFile=/absolute/path/to/your.keystore
storePassword=...
keyAlias=...
keyPassword=...
```

Then add to `android/app/build.gradle.kts` (or `.gradle`):

```kotlin
signingConfigs {
    create("release") {
        storeFile = file(keystoreProperties["storeFile"] as String)
        storePassword = keystoreProperties["storePassword"] as String
        keyAlias = keystoreProperties["keyAlias"] as String
        keyPassword = keystoreProperties["keyPassword"] as String
    }
}
buildTypes {
    release { signingConfig = signingConfigs.getByName("release") }
}
```

---

## Permissions

The app requests **only what's needed**:

| Permission | Why |
|------------|-----|
| `ACCESS_FINE_LOCATION` / `ACCESS_BACKGROUND_LOCATION` | Fog of war + journal GPS |
| `FOREGROUND_SERVICE_LOCATION` | Keeps GPS alive when screen is off |
| `POST_NOTIFICATIONS` | Persistent "正在记录" notification |
| `CAMERA` + `READ_MEDIA_*` | Journal photos / videos |
| `INTERNET` | Map tiles, AI / Music APIs, WebDAV |
| iOS `NSLocalNetworkUsageDescription` + `NSBonjourServices` | Peer discovery via mDNS |

---

## Data layout

```
<app support>/explore_journal.sqlite       # primary DB (Drift)
<app support>/pending_track.jsonl          # background GPS buffer
<app documents>/journal_media/*            # journal photos & videos (persistent)
<app documents>/exports/<layer>.{gpx,kml}  # exports
Android Keystore / iOS Keychain            # all credentials (PATs, passwords, API keys)
```

All of the above (except Keystore, which the OS restores separately) is inside
the auto-backup scope (`backup_rules.xml`), so data survives in-place upgrades
("覆盖安装") and device transfers.

WebDAV mirror:

```
/explore_journal/latest.zip               # always-current snapshot
/explore_journal/backup_<ISO date>.zip    # history (manual + auto)
/explore_journal/mailbox/<peer>/          # offline P2P messages
```

---

## Music API

By default `https://music-api.gdstudio.xyz/api.php` is queried. The endpoint accepts:

- `types=search&source={netease,tencent,kuwo,kugou,migu}&name=...`
- `types=url&source=...&id=...&br=320`
- `types=pic&source=...&id=...&size=300`

If the service is unavailable, change the base URL in **Settings → 音乐 API**. Any
endpoint speaking the same protocol works (self-host with the public source).

---

## ZeroTier setup (optional, for P2P live sharing)

1. Sign up at https://my.zerotier.com and create a network (you get a free tier).
2. Install ZeroTier on both phones and laptops you want to share with.
3. Join all devices to the same network ID, authorize them in the ZeroTier dashboard.
4. Set the same **P2P 共享口令** on each device (any phrase, e.g. "我们一起去川西").
5. Open "同行聊天" — peers should auto-appear via mDNS within ~15 seconds.

No central server is involved. All messages are AES-GCM-256 sealed with a key derived
via PBKDF2-SHA256 (50 000 iterations) from the passphrase + fixed salt.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Some Android licenses not accepted` | `flutter doctor --android-licenses`, answer `y` |
| Map tiles blank on 高德/Google | Some networks block these — switch to OSM in Settings |
| GPS not updating in background | Toggle "忽略电池优化" prompt that appears on first record |
| WebDAV "530" or InRelease errors | Verify URL ends with the WebDAV root (e.g. `https://dav.jianguoyun.com/dav/`) |
| `Could not find package _macros` during `pub get` | Remove `custom_lint` / `riverpod_lint` if you added them back |
| iOS build fails on `pod install` | `cd ios && pod repo update && pod install` |
| Web build hangs on `tree-shake-icons` | Add `--no-tree-shake-icons` flag |

---

## Project structure

```
lib/
├── main.dart                    Entry + go_router
├── app/
│   ├── providers.dart           Riverpod global services
│   └── recording_controller.dart
├── core/prefs.dart              AppSettings + SharedPreferences
├── models/models.dart           DTOs
├── data/db/
│   ├── database.dart            Drift schema + helpers
│   └── database.g.dart          GENERATED
├── services/
│   ├── ai/ai_service.dart       OpenAI-compatible client
│   ├── export/track_export.dart GPX / KML in & out
│   ├── fog/fog_engine.dart      Bitmap tile algorithm
│   ├── location/
│   │   ├── location_service.dart       Foreground geolocator
│   │   └── background_task.dart        Foreground service
│   ├── map/
│   │   ├── tile_providers.dart  OSM/AMap/Google × std/sat/hybrid
│   │   └── fog_layer.dart       CustomPainter overlay
│   ├── media/exif_service.dart  Photo GPS extraction
│   ├── music/music_service.dart gdstudio API
│   ├── p2p/
│   │   ├── p2p_service.dart     mDNS + sockets
│   │   └── crypto.dart          AES-GCM via cryptography pkg
│   └── webdav/webdav_service.dart
│   ├── leaderboard/   Ed25519-signed, LWW-merged standings
│   ├── imghost/        GitHub / custom host + upload queue
│   ├── group/          LAN / ZeroTier / WebRTC / frp + PTT + sync
│   ├── security/       Secure storage + cleartext-HTTP guard
│   └── backup/backup_service.dart  Chunked-zip export / import
└── ui/
    ├── home/         Grid launcher
    ├── map/          Map + fog + brush + recording
    ├── globe/        3D textured globe + footprint heat-map
    ├── layers/       CRUD + merge + export
    ├── journal/      Quill editor + media + FTS search
    ├── explore/      Country / region progress
    ├── leaderboard/  Global + monthly standings
    ├── playback/     Animated replay + stats
    ├── ai_planner/   AI trip generator
    ├── music/        Search · AI playlist · favorites map
    ├── chat/         P2P group + private chat + PTT
    ├── group_setup/  Transport picker + diagnostics
    ├── imghost/      Image-host settings
    ├── backup/       Export & import (导出与导入)
    ├── permissions/  Background-location walkthrough
    ├── settings/     Everything configurable
    ├── debug/        Hidden log buffer + simulator
    ├── auth/         Web admin login gate
    └── about/        Version, license, contributors

services/sync/      SyncStorage abstraction: WebDAV · GitHub · OneDrive
services/vault/     Admin login, roaming config payload, config sync controller
web-front/          Optional Rust + Docker service (admin login + encrypted config
                    + console + static hosting + read-only WebDAV proxy)
```

Organised so a single feature lives in one folder.

---

## Roadmap

- [x] Map-tile fog-of-war engine
- [x] Layers, tags, colors, merge, edit
- [x] WebDAV one-click backup + history restore
- [x] AI trip planning + music keyword generation
- [x] P2P live sharing with end-to-end encryption
- [x] EXIF GPS auto-tagging
- [x] GPX / KML export
- [x] Favorites map view
- [x] Web target: `WasmDatabase` + bundled `sqlite3.wasm` + `drift_worker.js`
- [x] 3D globe overview with footprint heat-map
- [x] Decentralised, signed leaderboard (P2P / GitHub PR / optional REST)
- [x] GitHub / custom image host + private-image loader
- [x] Multi-transport P2P: LAN multicast / WebRTC / frp hole-punch
- [x] Offline map-tile cache
- [x] Quill inline image embed
- [x] Read-only web "memory" version (import → display, PWA)
- [x] Encrypted config store + optional Rust/Docker `web-front` (console / export / read-only WebDAV proxy)
- [x] CI: build web on push → `web-build` branch → Vercel / Cloudflare Pages
- [ ] Mobile-side "push settings to NAS" UI (web pull loop is in place)
- [ ] Apple Watch / Wear OS companion
- [ ] Real-time peer cursors on shared map

---

## Going to production

Shipping a build to friends, putting it on a store, or running it under your own brand?
These docs are tailored for that journey:

- **[docs/security-data-safety.md](docs/security-data-safety.md)** — threat model, what lives in
  secure storage vs. SharedPreferences, what gets scrubbed from backups, the HTTPS-guard
  runtime check, and the privacy-policy clauses you'll want to copy when you publish.
- **[docs/publishing.md](docs/publishing.md)** — step-by-step for Google Play, Chinese Android
  stores (Xiaomi / OPPO / vivo / Huawei / 应用宝), Apple App Store + TestFlight, plus signing,
  ProGuard, version-bump checklist, and review-rejection playbook.
- **[docs/web-display-deploy.md](docs/web-display-deploy.md)** — deploying & testing the web
  memory version: building `./dist`, the GitHub Actions → `web-build` → Vercel/Cloudflare flow,
  running the NAS backend in Docker, and troubleshooting.

---

## License

[**CC BY-NC-SA 4.0**](https://creativecommons.org/licenses/by-nc-sa/4.0/) — see `LICENSE`.

You may use, modify, and share this code **for non-commercial purposes only**, and any derivative work must be released under the same license (share-alike). Commercial use requires separate permission from the author.

---

## Acknowledgements

- [flutter_map](https://docs.fleaflet.dev/) — base map widget
- [Drift](https://drift.simonbinder.eu/) — SQLite ORM + reactive queries
- [flutter_foreground_task](https://pub.dev/packages/flutter_foreground_task) — Android persistent location
- [flutter_quill](https://pub.dev/packages/flutter_quill) — rich text editor
- [cryptography](https://pub.dev/packages/cryptography) — pure-Dart AES-GCM
- gdstudio — public music API
- Fog of World (com.ollix.fogofworld) — original inspiration
