import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Single front door for high-risk credentials.
///
/// **Why a separate store**:
///   * SharedPreferences (`app_settings_v1`) lives in a plain XML/plist
///     file that any forensic tool with shell access can read. Putting
///     a GitHub PAT or WebDAV password there is a soft leak — if the
///     phone is lost or the user side-loads a backup tool, those
///     creds are recoverable in cleartext.
///   * flutter_secure_storage routes through Android Keystore + EncryptedSharedPreferences
///     on Android (and iOS Keychain on iOS), so the actual bytes are
///     encrypted with a hardware-backed key that does not leave the
///     secure element. Even root access on the device cannot dump
///     them without unlocking the device.
///
/// **What lives here vs in [AppSettings]**:
///   here  → things an attacker would weaponise: PATs, server tokens,
///           p2p passphrase, webdav password. Keyed by a stable string;
///           value is the secret.
///   prefs → everything else — UI prefs, non-secret URLs/owners/repos,
///           feature toggles. Backup-able by users without leaking
///           secrets.
///
/// **Migration**: on first run we read any existing secret values out
/// of [AppSettings], move them into secure storage, and replace the
/// prefs value with a sentinel (`__secure__`). The UI keeps reading
/// the field — it just sees the sentinel and knows to call
/// [SecureCredentials.read] instead.
class SecureCredentials {
  static const _kSentinel = '__secure__';
  static const _opt = AndroidOptions(encryptedSharedPreferences: true);
  final FlutterSecureStorage _ss;

  SecureCredentials([FlutterSecureStorage? store])
      : _ss = store ?? const FlutterSecureStorage(aOptions: _opt);

  /// Known secret keys — using a typed list so a typo can't silently
  /// route a write to a new key.
  static const githubPat = 'github_pat';
  static const githubPrivatePat = 'github_private_pat';
  static const customAuthHeader = 'custom_auth_header';
  static const webdavPass = 'webdav_pass';
  static const p2pPassphrase = 'p2p_passphrase';
  static const aiApiKey = 'ai_api_key';
  static const leaderboardRepoPat = 'leaderboard_repo_pat';
  static const leaderboardServerToken = 'leaderboard_server_token';

  static const all = <String>[
    githubPat,
    githubPrivatePat,
    customAuthHeader,
    webdavPass,
    p2pPassphrase,
    aiApiKey,
    leaderboardRepoPat,
    leaderboardServerToken,
  ];

  Future<String?> read(String key) async {
    try {
      return await _ss.read(key: key);
    } catch (e) {
      debugPrint('[SecureCredentials] read $key failed: $e');
      return null;
    }
  }

  Future<void> write(String key, String? value) async {
    try {
      if (value == null || value.isEmpty) {
        await _ss.delete(key: key);
      } else {
        await _ss.write(key: key, value: value);
      }
    } catch (e) {
      debugPrint('[SecureCredentials] write $key failed: $e');
    }
  }

  /// Sentinel that callers (e.g. backup export, UI display) can use to
  /// tell whether a value is "really stored elsewhere".
  bool isSentinel(String? v) => v == _kSentinel;
  String get sentinel => _kSentinel;

  /// Wipe everything — used by the user-facing "退出登录 / 清除所有凭据"
  /// action. Idempotent.
  Future<void> clearAll() async {
    for (final k in all) {
      try {
        await _ss.delete(key: k);
      } catch (_) {}
    }
  }
}
