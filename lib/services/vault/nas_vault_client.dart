import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A NAS auth session. The token is bearer-equivalent and short-lived (TTL set
/// by the server, ~1h); callers re-login (cheap) rather than persisting a
/// long-lived credential.
class NasSession {
  final String token;
  final String userId;

  /// Server's current vault version (ETag), or 0 if the account has no vault
  /// yet. Used as the `If-Match` base for the next PUT.
  final int vaultVersion;

  const NasSession(this.token, this.userId, this.vaultVersion);
}

/// A successful `GET /vault`.
class VaultFetch {
  final Uint8List bytes;
  final int version;
  const VaultFetch(this.bytes, this.version);
}

/// `PUT /vault` lost the optimistic-concurrency race — another device wrote a
/// newer version. Caller should pull, merge, and retry against [currentVersion].
class VaultConflict implements Exception {
  final int currentVersion;
  const VaultConflict(this.currentVersion);
  @override
  String toString() => 'VaultConflict(server at v$currentVersion)';
}

/// Auth/registration failure (bad credentials, email taken, registration
/// closed, etc.).
class NasAuthException implements Exception {
  final int statusCode;
  final String message;
  const NasAuthException(this.statusCode, this.message);
  @override
  String toString() => 'NasAuthException($statusCode): $message';
}

/// Client for the NAS zero-knowledge vault backend (plan §3.2). The server
/// only ever sees the `authVerifier` (a password-derived value, never the
/// password) and opaque vault ciphertext.
abstract class NasVaultClient {
  /// b64 KDF salt for [email]. The server returns a deterministic pseudo-salt
  /// for unknown emails (enumeration resistance), so a non-null result does
  /// NOT confirm the account exists.
  Future<String> getSalt(String email);

  Future<NasSession> register(
      String email, List<int> authVerifier, List<int> salt);

  Future<NasSession> login(String email, List<int> authVerifier);

  /// Current vault, or null if the account has none yet (404).
  Future<VaultFetch?> getVault(String token);

  /// Store [bytes]; [ifMatch] is the version last seen (0 = expect none).
  /// Returns the new version. Throws [VaultConflict] on a stale base.
  Future<int> putVault(String token, List<int> bytes, {required int ifMatch});
}

/// dio-backed [NasVaultClient]. [baseUrl] is the user-configured NAS URL
/// (validated https-only / non-private by the caller before construction).
class HttpNasVaultClient implements NasVaultClient {
  final Dio _dio;

  HttpNasVaultClient(String baseUrl, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
            ));

  Options _bearer(String token) => Options(headers: {
        'Authorization': 'Bearer $token',
      });

  NasSession _session(Map<String, dynamic> j) => NasSession(
        j['token'] as String,
        (j['user_id'] ?? '').toString(),
        (j['vault_version'] as num?)?.toInt() ?? 0,
      );

  @override
  Future<String> getSalt(String email) async {
    final r = await _dio.get('/auth/salt', queryParameters: {'email': email});
    return (r.data as Map)['salt'] as String;
  }

  @override
  Future<NasSession> register(
      String email, List<int> authVerifier, List<int> salt) async {
    try {
      final r = await _dio.post('/auth/register', data: {
        'email': email,
        'authVerifier': base64.encode(authVerifier),
        'salt': base64.encode(salt),
      });
      return _session(r.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw NasAuthException(
          e.response?.statusCode ?? 0, _msg(e, '注册失败'));
    }
  }

  @override
  Future<NasSession> login(String email, List<int> authVerifier) async {
    try {
      final r = await _dio.post('/auth/login', data: {
        'email': email,
        'authVerifier': base64.encode(authVerifier),
      });
      return _session(r.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw NasAuthException(e.response?.statusCode ?? 0, _msg(e, '登录失败'));
    }
  }

  @override
  Future<VaultFetch?> getVault(String token) async {
    final r = await _dio.get<List<int>>(
      '/vault',
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        responseType: ResponseType.bytes,
        validateStatus: (s) => s != null && (s == 200 || s == 404),
      ),
    );
    if (r.statusCode == 404 || r.data == null) return null;
    final etag = r.headers.value('etag');
    return VaultFetch(
      Uint8List.fromList(r.data!),
      _parseEtag(etag),
    );
  }

  @override
  Future<int> putVault(String token, List<int> bytes,
      {required int ifMatch}) async {
    final r = await _dio.put(
      '/vault',
      data: Stream.fromIterable([bytes]),
      options: Options(
        headers: {
          ..._bearer(token).headers!,
          'If-Match': '"$ifMatch"',
          'Content-Length': bytes.length,
        },
        contentType: 'application/octet-stream',
        validateStatus: (s) => s != null && (s == 200 || s == 409),
      ),
    );
    if (r.statusCode == 409) {
      final cur = (r.data as Map?)?['current_version'];
      throw VaultConflict((cur as num?)?.toInt() ?? 0);
    }
    return (r.data as Map?)?['version'] as int? ?? (ifMatch + 1);
  }

  int _parseEtag(String? etag) {
    if (etag == null) return 0;
    return int.tryParse(etag.replaceAll('"', '')) ?? 0;
  }

  String _msg(DioException e, String fallback) {
    final d = e.response?.data;
    if (d is Map && d['reason'] != null) return d['reason'].toString();
    if (d is Map && d['error'] != null) return d['error'].toString();
    return e.message ?? fallback;
  }
}
