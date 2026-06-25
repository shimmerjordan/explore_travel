import '../../core/prefs.dart';
import '../backup/backup_service.dart' show kVaultSecretKeys;

/// The plaintext content of the zero-knowledge settings vault: the subset of
/// [AppSettings] needed to reach the user's own cloud and render their data on
/// another device (notably the read-only web client).
///
/// Two halves, both drawn from a single authoritative key set:
///   * **secrets** — exactly [kVaultSecretKeys] (the same constant the backup
///     scrubber uses), so a credential field is covered by both the scrubber
///     and the vault, never one and not the other. A unit test pins the
///     superset relationship.
///   * **locators** — non-secret config (URLs, owners, repos, CDN templates)
///     that's useless to an attacker alone but required to *use* the secrets.
///
/// **Deliberately excluded**: `leaderboardPrivateKey` / `leaderboardPublicKey`
/// — the device's Ed25519 leaderboard identity is per-device by design (each
/// install signs as itself). Roaming the private key would let a single
/// cracked vault password forge leaderboard entries as every one of the user's
/// devices, and the read-only web client has no leaderboard-signing role at
/// all. So the identity stays on the device that made it. (Plan §7 Q2.)
///
/// NOTE: this reads/writes [AppSettings] directly because the app currently
/// keeps secrets in plaintext prefs (the platform-keystore [SecureCredentials]
/// path is dead code). If that migration is ever activated, `extract`/`applyTo`
/// must additionally bridge those keystore values.
class VaultPayload {
  /// Schema version of the *plaintext* payload (independent of the encrypted
  /// blob frame version). Bumped when key names change so a future reader can
  /// migrate rather than silently drop secrets.
  static const schemaVersion = 1;

  /// Non-secret config without which the secrets are unusable.
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

  /// The single authoritative set of [AppSettings] keys the vault carries.
  /// `secrets ∪ locators`. Producers and consumers import THIS — never their
  /// own copy.
  static Set<String> get kVaultPayloadKeys => {...kVaultSecretKeys, ...locatorKeys};

  /// The raw payload map. Always carries `_schema`.
  final Map<String, dynamic> fields;
  const VaultPayload(this.fields);

  int get schema => (fields['_schema'] as num?)?.toInt() ?? 0;

  /// Pull the vault subset out of a full [AppSettings].
  factory VaultPayload.extract(AppSettings s) {
    final j = s.toJson();
    final out = <String, dynamic>{'_schema': schemaVersion};
    for (final k in kVaultPayloadKeys) {
      if (j.containsKey(k)) out[k] = j[k];
    }
    return VaultPayload(out);
  }

  Map<String, dynamic> toJson() => fields;
  factory VaultPayload.fromJson(Map<String, dynamic> j) => VaultPayload(j);

  /// Overlay this payload onto [current], returning a new [AppSettings].
  ///
  /// Skips null / empty values so a vault that lacks a field (or an empty
  /// remote value) never clobbers a locally-set secret — local-first. Only the
  /// keys in [kVaultPayloadKeys] are ever touched; everything else in
  /// [current] is preserved.
  AppSettings applyTo(AppSettings current) {
    final m = current.toJson();
    fields.forEach((k, v) {
      if (k == '_schema') return;
      if (!kVaultPayloadKeys.contains(k)) return; // ignore unknown/stale keys
      if (v == null) return;
      if (v is String && v.isEmpty) return;
      if (v is Map && v.isEmpty) return;
      m[k] = v;
    });
    return AppSettings.fromJson(m);
  }
}
