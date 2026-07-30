import 'package:flutter/foundation.dart';

import '../../core/prefs.dart';
import '../backup/backup_service.dart' show kVaultSecretKeys;

/// The roaming settings config: the subset of [AppSettings] needed to reach the
/// user's own cloud and render their data on another device (notably the
/// read-only web client).
///
/// This travels as plaintext JSON over an authenticated session. The console
/// server keeps it encrypted at rest under a key derived from the admin
/// password and decrypts it for any caller holding a valid session — so the
/// server CAN read these fields. The confidentiality boundary is the admin
/// credential, not the transport.
///
/// Two halves:
///   * **secrets** — [kVaultSecretKeys] (the constant the backup scrubber
///     uses) minus [deviceOnlySecretKeys]. Sharing the scrubber's set is
///     deliberate: a credential that gets scrubbed from backups is a
///     credential worth thinking about here too, so the two can't silently
///     drift apart as fields are added.
///   * **locators** — non-secret config (URLs, owners, repos, CDN templates)
///     that's useless to an attacker alone but required to *use* the secrets.
///
/// **Deliberately excluded**: `leaderboardPrivateKey` / `leaderboardPublicKey`
/// — the device's Ed25519 leaderboard identity is per-device by design (each
/// install signs as itself). Roaming the private key would let a single
/// cracked password forge leaderboard entries as every one of the user's
/// devices, and the read-only web client has no leaderboard-signing role at
/// all. So the identity stays on the device that made it.
///
/// Also excluded, for a different reason: see [deviceOnlySecretKeys].
///
/// NOTE: this reads/writes the in-memory [AppSettings], which always carries
/// the REAL secret values — PrefsStore overlays them from platform secure
/// storage on load and moves them back on save. No keystore bridge is needed
/// here.
class ConfigPayload {
  /// Schema version of the payload. Bumped when key names change.
  ///
  /// [applyTo] does not migrate anything (there is only one version so far) —
  /// what it does do is LOG when the remote stamp is newer than this constant,
  /// so "the web build ignored half my config" leaves a breadcrumb instead of
  /// being silent. Actual migrations go in [applyTo] when v2 exists.
  static const schemaVersion = 1;

  /// Credentials the backup scrubber covers but that deliberately do NOT roam.
  ///
  /// [kVaultSecretKeys] answers "would leaking this hurt?", which is the right
  /// question for a backup file. It is NOT the same question as "does another
  /// device need this?", and these keys are where the two answers diverge: the
  /// speech and music credentials are consumed only by the AI-companion voice
  /// link and the music player, both phone-only features. The read-only web
  /// client never calls either, so uploading them buys nothing and widens the
  /// blast radius of a cracked admin password.
  ///
  /// They rode along until now purely because the payload was defined as
  /// `scrubber-set ∪ locators` — an inheritance, not a decision.
  ///
  /// The companion locators (`sttBaseUrl`, `ttsEngine`, `ttsVoice`,
  /// `volcTtsAppId`, `musicApiBase`, …) are absent from [locatorKeys] for the
  /// same reason, which is why roaming the keys alone was useless anyway: a
  /// second device got a key with no endpoint, model, or voice to use it
  /// against. If multi-device voice is ever wanted, both halves move together.
  static const deviceOnlySecretKeys = <String>{
    'sttApiKey',
    'ttsApiKey',
    'volcTtsToken',
    'musicCredentials',
    // Group / P2P networking. `group_service_stub.dart` is what the web build
    // gets — there is no relay, no frp tunnel and no P2P on that platform, so
    // these could only ever sit unused in the browser's memory.
    'frpToken',
    'frpDashboardPass',
    'relayToken',
  };

  /// Config keys whose [AppSettings] field is a `Map`, not a `String`.
  ///
  /// Every other key in [kConfigPayloadKeys] is string-typed — [applyTo] uses
  /// that split to reject a value of the wrong shape before
  /// `AppSettings.fromJson` hard-casts it. A test walks the whole key set with
  /// deliberately wrong types, so adding a non-string key without listing it
  /// here fails the suite rather than shipping a crash.
  ///
  /// Empty today: `musicCredentials` was the only Map-typed roaming key and it
  /// now stays on the device (see [deviceOnlySecretKeys]). The mechanism stays
  /// because the failure it prevents is a hard crash on the receiving device,
  /// and the next Map-typed field to roam must not have to rediscover that.
  static const mapKeys = <String>{};

  /// Non-secret config without which the secrets are unusable.
  ///
  /// Note what is NOT here but still roams: the map provider API keys
  /// (`amapApiKey` / `googleMapKey`). They are credentials, so they live in
  /// `kVaultSecretKeys` and reach the payload through the union — and they have
  /// to reach it, because the web build renders the same maps, journals and
  /// location pickers the phone does. That is the difference from the group /
  /// P2P tokens above: those have no consumer in the browser at all.
  static const locatorKeys = <String>{
    // WebDAV
    'webdavUrl', 'webdavUser',
    // GitHub public image host
    'githubOwner', 'githubRepo', 'githubBranch', 'githubPathPrefix',
    'githubCdnTemplate',
    // GitHub private image host
    'githubPrivateOwner', 'githubPrivateRepo', 'githubPrivateBranch',
    'githubPrivatePathPrefix',
    // OneDrive
    'oneDriveClientId', 'oneDriveAccount',
    // Custom image host
    'customUploadUrl', 'customFileField', 'customResponseUrlPath',
    'customDisplayUrlTemplate', 'customDeleteUrlTemplate',
    // AI
    'aiBaseUrl', 'aiModel',
    // Leaderboard server / repo (public, non-key)
    'leaderboardRepoOwner', 'leaderboardRepoName', 'leaderboardRepoBranch',
    'leaderboardServerUrl',
    // Which transport the web/other device should drive.
    'syncBackend',
  };

  /// The single authoritative set of [AppSettings] keys the config carries.
  /// `(secrets − device-only) ∪ locators`. Producers and consumers import
  /// THIS — never their own copy.
  static Set<String> get kConfigPayloadKeys =>
      {...kVaultSecretKeys, ...locatorKeys}
          .difference(deviceOnlySecretKeys);

  /// The raw payload map. Always carries `_schema`.
  final Map<String, dynamic> fields;
  const ConfigPayload(this.fields);

  int get schema => (fields['_schema'] as num?)?.toInt() ?? 0;

  /// Pull the roaming subset out of a full [AppSettings].
  factory ConfigPayload.extract(AppSettings s) {
    final j = s.toJson();
    final out = <String, dynamic>{'_schema': schemaVersion};
    for (final k in kConfigPayloadKeys) {
      if (j.containsKey(k)) out[k] = j[k];
    }
    return ConfigPayload(out);
  }

  Map<String, dynamic> toJson() => fields;
  factory ConfigPayload.fromJson(Map<String, dynamic> j) => ConfigPayload(j);

  /// Overlay this payload onto [current], returning a new [AppSettings].
  ///
  /// Skips null / empty values so a config that lacks a field (or an empty
  /// remote value) never clobbers a locally-set secret — local-first. Only the
  /// keys in [kConfigPayloadKeys] are ever touched; everything else in
  /// [current] is preserved.
  ///
  /// **Also skips values of the wrong TYPE.** The console stores whatever JSON
  /// object it is given (`PUT /api/config` only checks that it *is* an object),
  /// so one hand-edited or half-corrupted field — `"musicCredentials": "oops"`,
  /// `"webdavUrl": 7` — used to reach `AppSettings.fromJson`'s hard casts and
  /// throw. That throw landed on the login path with a valid session already
  /// established, which locked the web client out permanently with a Dart type
  /// error on screen and no client-side way to repair the stored config. A
  /// malformed field is now dropped (with a log line) and everything else
  /// still applies.
  AppSettings applyTo(AppSettings current) {
    if (schema > schemaVersion) {
      debugPrint('[ConfigPayload] 远端配置 schema v$schema 高于本端已知的 '
          'v$schemaVersion：本端只会应用它认得的字段，其余原样保留在服务端');
    }
    final m = current.toJson();
    fields.forEach((k, v) {
      if (k == '_schema') return;
      if (!kConfigPayloadKeys.contains(k)) return; // ignore unknown/stale keys
      if (v == null) return;
      if (!_typeMatches(k, v)) {
        debugPrint('[ConfigPayload] 跳过 $k：远端值类型 ${v.runtimeType} 与本端字段不符');
        return;
      }
      if (v is String && v.isEmpty) return;
      if (v is Map && v.isEmpty) return;
      m[k] = v;
    });
    return AppSettings.fromJson(m);
  }

  /// Whether [v] is shaped like the [AppSettings] field named [key].
  static bool _typeMatches(String key, Object v) {
    if (mapKeys.contains(key)) {
      // `fromJson` does `(v as Map?)?.map((k, _) => MapEntry(k as String, ...))`
      // — a non-String key throws just as loudly as a non-Map value.
      return v is Map && v.keys.every((k) => k is String);
    }
    return v is String;
  }
}
