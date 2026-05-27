# Explore Journal — Publishing Guide

> End-to-end checklist for shipping a release of this codebase to
> Google Play, the major Chinese Android stores, and the Apple App
> Store. Assumes you can already run `flutter build apk` /
> `flutter build ipa` against your own signing identities.

---

## 0. Prerequisites (one-time)

- Flutter `3.32+`, Dart `3.5+`.
- Android: Android Studio + JDK 17, accepted SDK licenses
  (`flutter doctor --android-licenses`), `keystore` file created.
- iOS: macOS + Xcode `15+`, Apple Developer Program enrolment
  ($99 / yr personal · $299 / yr enterprise · ¥688 / yr 中国),
  a Bundle Identifier registered in App Store Connect.
- A reviewed-and-signed-off **privacy policy URL** (see
  [security-data-safety.md](security-data-safety.md) for boilerplate).
- App icon set + screenshots in every required size — generate from
  `assets/icon.png` once with `flutter_launcher_icons` and save.

---

## 1. Pre-release hardening (do once per release)

1. **Bump versions**
   ```yaml
   # pubspec.yaml
   version: 0.2.0+5      # ↑ both name AND build code
   ```
   ```dart
   // lib/ui/about/about_screen.dart
   const String _kAppVersion = '0.2.0';
   ```
   Android version code increments by 1 every upload; Apple uses the
   `+5` part of `0.2.0+5` as `CFBundleVersion`.

2. **Run the security checklist** at the bottom of
   [`security-data-safety.md`](security-data-safety.md).

3. **Smoke-test the release flavor**
   ```bash
   flutter build apk --release && \
     adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```
   Repeat the most-touched paths: launch → grant permissions → start
   recording → close & reopen → restore from a backup → group chat
   handshake. Anything that broke in release-vs-debug almost always
   relates to R8 / ProGuard.

4. **Smoke-test airplane mode**. The geolocator, fog rendering,
   journal save, and backup-to-local should all work offline. Map tiles
   gracefully show grey.

5. **Strip embedded test creds** from `core/prefs.dart`. The default
   constants in `AppSettings` must NOT contain real GitHub PATs,
   WebDAV passwords, or AI keys. Grep:
   ```bash
   grep -E "(github_pat|ghp_|sk-|api_key.*=.*[A-Za-z0-9]{10,})" lib/
   ```

---

## 2. Android — Google Play

### 2.1 Build

- `android/app/build.gradle` (or `.kts`): confirm `minSdkVersion >= 21`,
  `targetSdkVersion = 34` (Google Play requirement as of late 2024;
  bump per Play's annual deadline), `versionCode` matches pubspec build
  number.
- Signing config — put the keystore path & alias in
  `android/key.properties` (gitignored). NEVER commit a keystore.
  ```properties
  storePassword=...
  keyPassword=...
  keyAlias=upload
  storeFile=/abs/path/to/upload-keystore.jks
  ```
- Generate the AAB (Play requires AAB for new apps since 2021):
  ```bash
  flutter build appbundle --release
  # → build/app/outputs/bundle/release/app-release.aab
  ```

### 2.2 ProGuard / R8

Enabled by default in Flutter release. If anything reflective breaks
(common with `drift`, `flutter_quill`, `cryptography`), add rules at
`android/app/proguard-rules.pro`:

```
# Drift uses generated classes that R8 might consider dead.
-keep class drift.** { *; }
-keep class * extends drift.GeneratedDatabase { *; }

# cryptography (pointycastle fallback) uses reflective lookups.
-keep class org.bouncycastle.** { *; }
-keep class org.pointycastle.** { *; }
```

Wire into `build.gradle`:
```groovy
buildTypes {
    release {
        minifyEnabled true
        shrinkResources true
        proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'),
                      'proguard-rules.pro'
        signingConfig signingConfigs.release
    }
}
```

### 2.3 Play Console listing

Required fields (the dropdowns will block you until each is filled):

- **App name** + **short description** (80 chars) + **full description**
  (4 000 chars). Mention what GPS / background location / camera are
  actually used for; Google's reviewers DO read this.
- **Screenshots** — 2–8 phone shots, optionally tablet (16:9 or 9:16,
  ≥1080 px short edge). The 雾 / 轨迹 / playback shots are the
  highest-converting; lead with those.
- **Feature graphic** 1024×500.
- **Privacy Policy URL** — non-negotiable for apps that ask for
  location. Host the doc from
  [security-data-safety.md](security-data-safety.md) on GitHub
  Pages or your own site.
- **Data Safety form** — declare these flags (matches what the app
  actually does):
  - *Location:* collected, not shared, optional, used for App
    functionality. Encrypted in transit (TLS for any upload).
    Deletable by the user (uninstall or "clear data").
  - *Personal info — name:* (the display name) collected,
    not shared, optional.
  - *Photos:* collected, not shared, optional, journal feature.
  - *App activity:* none.
  - *Crash logs:* none (no Crashlytics integration).
- **Target audience** — Adults / Everyone. Travel apps usually map
  to "Everyone".
- **Ads** — None.
- **Government app** — No.

### 2.4 Common rejections

| Reason                                        | Fix                                                                              |
| --------------------------------------------- | -------------------------------------------------------------------------------- |
| Background location without justification     | Add a paragraph in the listing AND in the in-app permission rationale dialog.    |
| "Sensitive permissions" without explanation   | Same — every requested permission needs a sentence in the store description.    |
| Privacy policy missing or mismatched          | Use the boilerplate; make sure the URL actually loads (not a 404).               |
| AAB unsigned / signed with debug key          | Re-build with `--release` and key.properties pointing to your real keystore.    |
| `targetSdkVersion` too old                    | Bump to whatever Play requires this year.                                        |

### 2.5 Phased rollout

Start at 5 % staged rollout; bump to 20 % / 50 % / 100 % over 3–5 days
once you've watched crash-free sessions on the Play Console vitals
page. Don't 100% on day one — `flutter_secure_storage` sometimes
fails on weird OEM ROMs (older Vivo / Realme) and you want time to
notice.

---

## 3. Chinese Android stores

The Chinese ecosystem requires extra paperwork (ICP filing / 备案 for
any associated backend, real-name developer cert, and increasingly an
"App-net备案" 工信部 record for the app itself). Each store has a
separate console, but the AAB → APK conversion + listing fields are
basically the same.

| Store              | Console URL                          | Notes                                                                                |
| ------------------ | ------------------------------------ | ------------------------------------------------------------------------------------ |
| 小米 Mi Apps       | dev.mi.com                           | Faster review (~24h). Requires real-name + business license for paid features.       |
| OPPO 软件商店      | open.oppomobile.com                  | Similar to Mi. Background location triggers a manual review (~3 days).               |
| vivo 应用商店      | dev.vivo.com.cn                      | Ditto. They sometimes require a video demo of background location use.               |
| 华为 AppGallery    | developer.huawei.com/consumer        | Strictest. **App-net备案** mandatory. Will reject if you use Google Maps tiles.      |
| 应用宝 (Tencent)   | open.tencent.com / qq.com            | Largest reach. Bundles 加固 (anti-tamper) automatically — review for any false-positives. |
| 酷安               | developer.coolapk.com                | Hobbyist-friendly; lighter requirements. Great place to soft-launch.                 |

**Build differences from Play**: distribute an **APK** (not AAB —
Chinese stores don't ingest Play's split-APK format). Build with:
```bash
flutter build apk --release --split-per-abi
```
This gives three APKs (armeabi-v7a / arm64-v8a / x86_64); upload all
three (or just `arm64-v8a` for modern devices to keep the listing under
the 100 MB free tier).

**Permissions justification**: every store requires a 用途说明 for
every permission. Reuse what you put in the Play description; the
text doesn't need to be identical but the listed permissions must
match what `AndroidManifest.xml` actually requests.

**ICP filing** (only required for hosted backends): if you stand up a
leaderboard server or custom image host on a domain pointed at a
mainland-China-hosted IP, you'll need 工信部 ICP备案 before you can
ship the URL in your app. Apps that talk only to the user's own
WebDAV server don't need ICP because no shared backend exists.

---

## 4. Apple App Store

### 4.1 Build

- Open `ios/Runner.xcworkspace` in Xcode.
- `Runner` → Signing & Capabilities → tick **Automatically manage
  signing**, set your **Team** + **Bundle Identifier**.
- Set deployment target to `iOS 13.0` minimum (most Flutter packages
  drop iOS 12 in 2024).
- `Info.plist`: every permission used needs a usage string. Required:
  ```xml
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Used to record your travel trail on the map.</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
  <string>Recording continues when the screen is locked.</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Attach photos to your travel journal.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Push-to-talk voice messages to group members.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Discover other Explore Journal devices on the same Wi-Fi to share live trails.</string>
  <key>NSBonjourServices</key>
  <array>
      <string>_explorejournal._tcp</string>
  </array>
  ```
  (Skip Bonjour entry if you don't ship the LAN transport.)

- Background modes (Signing & Capabilities → + Capability):
  - **Location updates**
  - **Background processing** (optional, only if you re-enable
    BGTaskScheduler).
  - Do NOT enable "Background fetch" or "Audio" if you don't actually
    use them — Apple's review is pickier than Play's about declared
    but unused capabilities.

- Build the archive:
  ```bash
  flutter build ipa --release
  # → build/ios/ipa/explore_journal.ipa
  open build/ios/archive/Runner.xcarchive   # opens Organizer
  ```
  In Organizer: Distribute App → App Store Connect → Upload.

### 4.2 App Store Connect listing

- **App Name** (30 chars) + **Subtitle** (30 chars).
- **Description** — Apple's reviewers explicitly look for any
  mention of features that DON'T exist in the binary (placeholder
  marketing text → rejection).
- **Keywords** (100 chars total, comma-separated).
- **Support URL** + **Marketing URL** + **Privacy Policy URL**.
- **App Privacy** (similar to Play's Data Safety):
  - *Location → Coarse + Precise:* Linked to user (only if user
    sets a display name; if peerId-only, choose "Not Linked").
  - *Contacts:* not collected.
  - *Identifiers:* the device peerId is a random UUID generated
    on-device — declare as "Other Identifier", linked to user.
  - *Diagnostics:* not collected.
- **Age rating** — 4+ (no objectionable content).
- **App Review Information** — leave a demo group-id / passphrase
  so the reviewer can actually exercise group chat.
- **Export Compliance** — you use AES-GCM-256 + Ed25519 (via
  `cryptography` and `flutter_secure_storage`). Tick "Uses standard
  encryption exempt under Note 4 / TSU exception" — both Ed25519 and
  AES-GCM are in the published standards. File a one-time CCATS only
  if you ship custom crypto, which this app does not.

### 4.3 TestFlight first

ALWAYS push to TestFlight before submitting to the store. Internal
test (≤100 testers, no review needed) catches issues in hours; external
test goes through "Beta App Review" (~24h) but accepts up to 10 000
testers. Run for at least 3 days before submitting to App Review.

### 4.4 Common rejections

| Reason                                                              | Fix                                                                                                 |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| 5.1.1 Data Collection & Storage                                     | Mention every category in the App Privacy declaration. Even peerId counts as an "identifier".       |
| 4.5.3 Spam / 1.5 Developer Information                              | Make sure marketing URL ≠ privacy URL; both must load with substantive content.                     |
| 2.1 Performance — App Completeness                                  | Reviewer hit a crash. Run on physical iPhone 8 / SE (low-spec) before submitting.                   |
| 5.1.2 Data Use & Sharing                                            | The app sends data to user-configured endpoints (AI, WebDAV) → declare in App Privacy as "user-configured" and explain in the review notes that these are user-owned servers. |
| Background location not justified                                   | Add a screenshot / paragraph showing the on-screen banner "正在后台记录轨迹" so the reviewer sees the affordance. |

---

## 5. Versioning & changelog discipline

- Use semantic versioning: `MAJOR.MINOR.PATCH+BUILD`.
- Bump `MAJOR` for any backup/database schema break that requires a
  migration path.
- Maintain `CHANGELOG.md` per release; the App Store / Play store
  "What's New" copy is literally just the latest section.
- Tag the release in git: `git tag -a v0.2.0 -m "..." && git push --tags`.
- Keep a GitHub Releases entry with the AAB attached as an asset (so
  Chinese stores can also pick it up without rebuilding).

---

## 6. Post-launch

- Monitor Play Console **vitals** (crash-free sessions, ANR rate)
  for 7 days. If crash-free dips below 99.5 %, halt rollout.
- Apple's **Xcode Organizer → Crashes** equivalent.
- Both stores let users email feedback; route that to a real inbox.
- Plan one release per 4–8 weeks; users associate silence with
  abandonment.
