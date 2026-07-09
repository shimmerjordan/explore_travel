import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A resumable web login session. Persisting the (password-DERIVED, never the
/// password) `vaultKey` is a deliberate zero-knowledge trade-off so a browser
/// refresh doesn't log the user out — the key otherwise lives only in memory
/// and a refresh drops it. Logout wipes the record; anyone who can read this
/// device's localStorage could read the key, which is the same trust boundary
/// as staying logged in to any web app on that device.
class NasWebSession {
  final String serverUrl;
  final String email;
  final String token;
  final String saltB64;
  final String vaultKeyB64;

  const NasWebSession({
    required this.serverUrl,
    required this.email,
    required this.token,
    required this.saltB64,
    required this.vaultKeyB64,
  });

  Map<String, String> toJson() => {
        'serverUrl': serverUrl,
        'email': email,
        'token': token,
        'salt': saltB64,
        'vaultKey': vaultKeyB64,
      };

  static NasWebSession? fromJson(Map<String, dynamic> j) {
    final url = j['serverUrl']?.toString() ?? '';
    final email = j['email']?.toString() ?? '';
    final token = j['token']?.toString() ?? '';
    final salt = j['salt']?.toString() ?? '';
    final key = j['vaultKey']?.toString() ?? '';
    if (url.isEmpty || token.isEmpty || salt.isEmpty || key.isEmpty) {
      return null;
    }
    return NasWebSession(
      serverUrl: url,
      email: email,
      token: token,
      saltB64: salt,
      vaultKeyB64: key,
    );
  }
}

/// Clearable store for [NasWebSession]. Only the web build ever WRITES it
/// (native has no login gate); the read path is platform-neutral so it can be
/// unit-tested on the VM.
abstract class NasSessionStore {
  Future<NasWebSession?> read();
  Future<void> write(NasWebSession s);
  Future<void> clear();
}

/// SharedPreferences-backed impl (== localStorage on web).
class PrefsNasSessionStore implements NasSessionStore {
  static const _key = 'nas_web_session_v1';

  @override
  Future<NasWebSession?> read() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null) return null;
      return NasWebSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[NasSessionStore] read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(NasWebSession s) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(s.toJson()));
    } catch (e) {
      debugPrint('[NasSessionStore] write failed: $e');
    }
  }

  @override
  Future<void> clear() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_key);
    } catch (e) {
      debugPrint('[NasSessionStore] clear failed: $e');
    }
  }
}

/// In-memory store for tests.
class MemoryNasSessionStore implements NasSessionStore {
  NasWebSession? session;
  @override
  Future<NasWebSession?> read() async => session;
  @override
  Future<void> write(NasWebSession s) async => session = s;
  @override
  Future<void> clear() async => session = null;
}
