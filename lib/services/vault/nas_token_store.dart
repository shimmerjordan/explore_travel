import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Clearable store for the NAS session bearer token. Deliberately NOT an
/// [AppSettings] field — `AppSettings.copyWith` merges with `?? this.x` and so
/// can't write null, i.e. it could never CLEAR the token on logout.
abstract class NasTokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

/// Mobile/desktop impl over the platform keychain. (Web gets its own
/// localStorage-based store in the web phase — flutter_secure_storage is not
/// secure on web.)
class SecureNasTokenStore implements NasTokenStore {
  static const _key = 'nas_session_token';
  static const _opt = AndroidOptions(encryptedSharedPreferences: true);
  final FlutterSecureStorage _ss;

  SecureNasTokenStore([FlutterSecureStorage? store])
      : _ss = store ?? const FlutterSecureStorage(aOptions: _opt);

  @override
  Future<String?> read() async {
    try {
      return await _ss.read(key: _key);
    } catch (e) {
      debugPrint('[NasTokenStore] read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(String token) async {
    try {
      await _ss.write(key: _key, value: token);
    } catch (e) {
      debugPrint('[NasTokenStore] write failed: $e');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _ss.delete(key: _key);
    } catch (e) {
      debugPrint('[NasTokenStore] clear failed: $e');
    }
  }
}

/// In-memory store — used by tests and as a safe default before a
/// platform-specific store is wired.
class MemoryNasTokenStore implements NasTokenStore {
  String? _t;
  @override
  Future<String?> read() async => _t;
  @override
  Future<void> write(String token) async => _t = token;
  @override
  Future<void> clear() async => _t = null;
}
