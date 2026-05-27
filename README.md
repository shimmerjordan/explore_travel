# Explore Journal

> A self-hosted, backendless travel & exploration app inspired by **Fog of World**.
> Track your trips, light up the world's fog of war, sync via WebDAV, plan trips with AI,
> share live routes with friends via ZeroTier, and build a rich travel journal — all
> while owning every byte of your data.

![flutter](https://img.shields.io/badge/Flutter-3.32+-02569B?logo=flutter)
![platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20Linux%20%7C%20Web-success)
![license](https://img.shields.io/badge/license-CC%20BY--NC--SA%204.0-lightgrey)

[中文 README](README.zh.md)

---

## Features

| Area | What you get |
|------|--------------|
| 🗺️ Maps | OSM / 高德 / Google · standard / satellite · live switching · GCJ-02 ↔ WGS-84 conversion · heading-aware location dot |
| 🌫️ Fog of war | Fog of World–compatible 64×64 bitmap tiles for storage / stats / sync · **vector swept-disk trail rendering**: anti-aliased canvas stroke through actual GPS samples → silky diagonals and curves with no raster aliasing · per-segment GPS-dropout split (no false straight lines across drops) · single-pass gaussian-feathered clear with continuous alpha gradient · brush radius / color / opacity tunable · per-layer |
| 👤 Profile & avatar | Tap right-top chip → bottom sheet with base64 avatar editor (256×256 / ≤30 KB) · nickname inline edit · peerId copy · avatar inlined into leaderboard entries + peer markers · M3 ripple + scale animations on home tiles |
| 🏆 Leaderboard | **Decentralised, append-only, signed** · Ed25519 keypair per device · LWW by `statsAt` per peerId · TOFU on publicKey · global km² + month-by-month tabs · auto-merge over the same P2P transport as chat/voice (`lb_hello / lb_pull / lb_batch`) · always-included in backup module · optional GitHub PR to a community registry repo · optional REST server backend ([API spec](docs/leaderboard-server-api.md)) |
| 📍 Tracking | Android foreground service (`flutter_foreground_task`) · 3 power modes · per-row UUID for cross-device dedup · EXIF GPS auto-tagging |
| 🗂️ Layers | Color-coded, taggable, per-layer visibility · in-map dropdown chip · auto-fallback when active layer is hidden/missing |
| 🌐 Exploration | Real-area progress — revealed km² ÷ region km² (UN country areas) · 10-decimal precision · **smallest-bbox attribution** so a point in Shanghai doesn't double-count into Jiangsu/Zhejiang · global "incl. ocean" + per-country + per-province + learned-from-visits regions |
| ☁️ Backup | Unified backup page · 11 modules independently selectable · **chunked zip archive** (per-tile fog like Fog of World, per-month track points, per-peer chat) · WebDAV upload / restore · local export & share · all paths share one zip schema · **UUID-based incremental import** |
| 🖼️ Image host | Per-journal `public` / `private` level · GitHub direct (Contents API) + jsDelivr/Statically CDN · private repo via raw-with-PAT + in-app authenticated image loader · generic custom host (Chevereto/兰空/EasyImage…) via URL templates · async upload queue + retry · path hierarchy `traveler/yyyy/mm/continent/country/province/city/title-id/uuid.ext` |
| 🤖 AI | OpenAI-compatible (SiliconFlow / OpenAI / DeepSeek…) · streaming trip planning with manual cancel · 30-min timeout · persistent chat history (30-day retention) · mini-map + energy estimates from emitted JSON · context-aware music keyword generation |
| 🎵 Music | NetEase / Kuwo / JOOX direct backends + GD聚合 fallback · cookie capture via WebView · AI playlist (place + mood → songs) · favorites map |
| 🖋️ Journal | Quill rich text with inline image embed · view-first + edit-mode dialog · level / owner picker · map pins with per-pin & global hide · uses current display pin (simulator-aware) as creation location |
| 🌍 Geocoding | Layered: 0.01° grid cache → 高德 reverse (if key) → system `geocoding` → bbox fallback · learned-regions table grows bbox with every confirmed visit · optional **background prewarm** as map pans |
| 🎞️ Playback | Per-recording **session** list (auto-split on 10-min gap, ≥10 pts) · year/month filter · period summary · stitched multi-session playback · 1-16× speed · time-clipped peer trails (persisted) · journal bubbles (hideable) |
| 🛰️ P2P | UDP multicast LAN discovery (`MulticastLock` on Android) + manual peer add · live route sharing · text chat · push-to-talk · music broadcast · **AES-GCM-256 end-to-end** via PBKDF2 · WebDAV mailbox for offline · WebRTC fallback transport |
| 🐞 Debug mode | Hidden — tap version label on home 10× · log buffer (ring of 1000) with filter/share · fog & recording diagnostics · simulator panel in release builds · "fire test reveal" button |
| 💾 Portability | Everything in one SQLite + a `media/` folder. Schema v4 with UUIDs. Standard zip backups. No vendor lock-in. |
| 🔒 Security | Credentials (PATs, tokens, WebDAV password, p2p passphrase) live in **flutter_secure_storage** → Android Keystore / iOS Keychain · backup exports **strip secret fields** so leaked archives don't leak creds · runtime HTTP guard refuses **cleartext to non-private hosts** (LAN HTTP still works) · no analytics, no remote logging, no telemetry, no third-party SDK ad/analytics call |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  UI · 11 screens · go_router · Material 3                   │
├─────────────────────────────────────────────────────────────┤
│  State management: Riverpod 2                               │
├──────────┬─────────────┬─────────────┬──────────────────────┤
│ Location │  Database   │     P2P     │   External APIs      │
│ • bg svc │  • Drift    │  • mDNS     │  • OpenAI-compat AI  │
│ • EXIF   │  • FTS5     │  • Sockets  │  • gdstudio music    │
│          │             │  • AES-GCM  │  • Map tile servers  │
├──────────┴─────────────┴─────────────┴──────────────────────┤
│  Fog engine (custom): 64×64 bitmap tiles, RLE-friendly      │
├─────────────────────────────────────────────────────────────┤
│  Persistence boundary: SQLite + files → WebDAV (.zip)       │
└─────────────────────────────────────────────────────────────┘
```

**No backend.** The only true "server" you talk to is the WebDAV provider of your choice
(Nextcloud, AList, Seafile, 坚果云, jianguoyun, infinicloud, your own dav.sh, …).

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

Web:

```bash
# Drift uses sqlite3.wasm on web (bundled under web/). P2P chat and the
# Android foreground service are no-ops in the browser; everything else
# (map, fog, journal, AI, music, WebDAV, exports) works.
flutter build web --release
# Serve build/web/ with any static host:
cd build/web && python3 -m http.server 8000
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
<app support>/explore_journal.sqlite      # primary DB (Drift)
<app documents>/media/<uuid>.{jpg,mp4}    # photos & videos
<app documents>/exports/<layer>.{gpx,kml} # exports
<cache>/restore.zip                       # transient
```

WebDAV mirror:

```
/explore_journal/latest.zip               # always-current snapshot
/explore_journal/backup_<ISO date>.zip    # history (manual + auto)
/explore_journal/mailbox/<peer>/          # offline P2P messages
```

---

## Optional: real GeoJSON boundaries

Out of the box, country / region progress uses rectangular bounding boxes — fast and tiny,
but slightly approximate. To use precise polygons:

1. Grab a country polygon file (e.g. from
   [datasets/geo-countries](https://github.com/datasets/geo-countries) or
   [Natural Earth](https://www.naturalearthdata.com/)) and split per country.
2. Save each as `assets/boundaries/<country>.geojson` (must match the country name in
   `countries.json` exactly — e.g. `assets/boundaries/中国.geojson`).
3. Re-run `flutter pub get` (the asset glob picks up new files automatically).

`GeoJsonLoader.tryLoad()` will be called for every country at app startup. Polygon files
take precedence over bbox; if no polygon is found, bbox grid is used.

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
│   ├── geo/geojson_loader.dart  Polygon point-in-polygon
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
└── ui/
    ├── home/         Grid launcher
    ├── map/          Map + fog + brush
    ├── layers/       CRUD + merge + export
    ├── settings/     Everything configurable
    ├── journal/      Quill editor + media
    ├── playback/     Animated replay + stats
    ├── explore/      Country / region progress
    ├── ai_planner/   Random trip generator
    ├── music/        Search · AI playlist · favorites map
    └── chat/         P2P live chat
```

Total: ~8 000 lines of Dart, organised so a single feature lives in one folder.

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
- [ ] GeoJSON polygon support for **all** bundled countries (currently bbox + optional polygon)
- [ ] Full Quill toolbar with image embed (currently text + side-attached media)
- [ ] Offline tile cache for maps
- [ ] Apple Watch / Wear OS companion
- [ ] Real-time peer cursors on shared map

---

## Going to production

Shipping a build to friends, putting it on a store, or running it under your own brand?
Two docs are tailored for that journey:

- **[docs/security-data-safety.md](docs/security-data-safety.md)** — threat model, what lives in
  secure storage vs. SharedPreferences, what gets scrubbed from backups, the HTTPS-guard
  runtime check, and the privacy-policy clauses you'll want to copy when you publish.
- **[docs/publishing.md](docs/publishing.md)** — step-by-step for Google Play, Chinese Android
  stores (Xiaomi / OPPO / vivo / Huawei / 应用宝), Apple App Store + TestFlight, plus signing,
  ProGuard, version-bump checklist, and review-rejection playbook.

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
