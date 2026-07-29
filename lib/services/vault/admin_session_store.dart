import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A resumable console login: just where the server is and the bearer token it
/// handed out. Persisting it means a browser refresh resumes instead of
/// bouncing to the login page; the token is short-lived and the server can
/// revoke it, which is the same trust boundary as staying logged in to any web
/// app on that device.
///
/// [baseUrl] is the empty string on web — the API is same-origin there, so
/// there is no address to remember.
class AdminSession {
  final String baseUrl;
  final String token;

  const AdminSession({required this.baseUrl, required this.token});

  Map<String, String> toJson() => {
        'baseUrl': baseUrl,
        'token': token,
      };

  static AdminSession? fromJson(Map<String, dynamic> j) {
    final token = j['token']?.toString() ?? '';
    if (token.isEmpty) return null;
    return AdminSession(
      baseUrl: j['baseUrl']?.toString() ?? '',
      token: token,
    );
  }
}

/// Clearable store for [AdminSession]. Only the web build ever WRITES it
/// (native has no login gate); the read path is platform-neutral so it can be
/// unit-tested on the VM.
abstract class AdminSessionStore {
  Future<AdminSession?> read();
  Future<void> write(AdminSession s);
  Future<void> clear();
}

/// SharedPreferences-backed impl (== localStorage on web).
class PrefsAdminSessionStore implements AdminSessionStore {
  static const _key = 'ej_admin_session_v1';

  /// The pre-console session record. It carried `vaultKey` — a key derived
  /// from the user's password back when the client did its own encryption.
  /// Nothing derives keys client-side any more, but an already-upgraded
  /// browser still has that record sitting in localStorage, so every read
  /// deletes it. The new record uses a different key name so a stale one can
  /// never be half-parsed into a session either.
  static const _legacyKey = 'nas_web_session_v1';

  /// The pre-console NATIVE token, written by the retired
  /// `SecureNasTokenStore` into the platform keychain. The `/auth/*` endpoints
  /// it authenticated no longer exist, so the value is waste paper — but it is
  /// still bearer-equivalent material sitting in a store nobody reads any
  /// more, and the same reasoning that wipes [_legacyKey] applies. Deleted
  /// once per process on the first store operation.
  static const _legacyKeychainKey = 'nas_session_token';

  /// Matches the retired store's options, so the delete lands in the same
  /// EncryptedSharedPreferences file the token was written to.
  static const _keychainOpts = AndroidOptions(encryptedSharedPreferences: true);

  /// Injectable so a test can observe the purge; production deletes from the
  /// platform keychain.
  final Future<void> Function(String key) _legacyKeychainDelete;

  PrefsAdminSessionStore({Future<void> Function(String key)? legacyKeychainDelete})
      : _legacyKeychainDelete = legacyKeychainDelete ?? _deleteFromKeychain;

  static Future<void> _deleteFromKeychain(String key) =>
      const FlutterSecureStorage(aOptions: _keychainOpts).delete(key: key);

  /// Once per process — the keychain round-trip is not free and the value can
  /// only come back if an old build writes it again.
  bool _keychainPurged = false;

  @override
  Future<AdminSession?> read() async {
    try {
      final p = await SharedPreferences.getInstance();
      await _purgeLegacy(p);
      final raw = p.getString(_key);
      if (raw == null) return null;
      return AdminSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[AdminSessionStore] read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(AdminSession s) async {
    try {
      final p = await SharedPreferences.getInstance();
      await _purgeLegacy(p);
      await p.setString(_key, jsonEncode(s.toJson()));
    } catch (e) {
      debugPrint('[AdminSessionStore] write failed: $e');
    }
  }

  @override
  Future<void> clear() async {
    try {
      final p = await SharedPreferences.getInstance();
      await _purgeLegacy(p);
      await p.remove(_key);
    } catch (e) {
      debugPrint('[AdminSessionStore] clear failed: $e');
    }
  }

  Future<void> _purgeLegacy(SharedPreferences p) async {
    if (p.containsKey(_legacyKey)) await p.remove(_legacyKey);
    if (_keychainPurged) return;
    _keychainPurged = true;
    try {
      await _legacyKeychainDelete(_legacyKeychainKey);
    } catch (e) {
      // No secure_storage platform impl under `flutter test` (and none on some
      // desktop targets) — that throws MissingPluginException. Wiping a dead
      // token is housekeeping; it must never break a login or a refresh.
      debugPrint('[AdminSessionStore] legacy keychain purge skipped: $e');
    }
  }
}

/// In-memory store for tests.
class MemoryAdminSessionStore implements AdminSessionStore {
  AdminSession? session;
  @override
  Future<AdminSession?> read() async => session;
  @override
  Future<void> write(AdminSession s) async => session = s;
  @override
  Future<void> clear() async => session = null;
}
