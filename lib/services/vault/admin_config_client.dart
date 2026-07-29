import 'dart:convert';

import 'package:dio/dio.dart';
import '../security/http_guard.dart';

/// A successful `POST /api/session`.
///
/// [isDefaultPassword] is the server telling us the admin credential is still
/// the shipped `admin/admin`. It's surfaced as a standing warning rather than
/// swallowed — a console reachable with the default password is the single most
/// likely way one of these deployments gets owned.
class AdminLoginResult {
  final String token;
  final bool isDefaultPassword;
  const AdminLoginResult(this.token, this.isDefaultPassword);
}

/// The session is missing, wrong, or expired (HTTP 401).
///
/// The server answers "unknown username" and "wrong password" with the very
/// same 401 so the response can't be used to enumerate the admin account —
/// [message] must not pretend to tell them apart either.
class AdminAuthException implements Exception {
  final int statusCode;
  final String message;
  const AdminAuthException(this.statusCode, this.message);
  @override
  String toString() => 'AdminAuthException($statusCode): $message';
}

/// Any other console-API failure. [message] is already user-presentable.
class AdminConfigException implements Exception {
  final int statusCode;
  final String message;
  const AdminConfigException(this.statusCode, this.message);
  @override
  String toString() => 'AdminConfigException($statusCode): $message';
}

/// Client for the console's admin API: log in, read the roaming settings
/// config, write it back.
abstract class AdminConfigClient {
  Future<AdminLoginResult> login(String username, String password);

  /// The stored config, or null when the server has none yet (it answers
  /// `200 {}` in that case — an empty config is not an error).
  Future<Map<String, dynamic>?> fetch(String token);

  Future<void> push(String token, Map<String, dynamic> cfg);

  /// Drop the server-side session. Best-effort: the caller has already
  /// forgotten the token locally by the time this matters.
  Future<void> logout(String token);
}

/// dio-backed [AdminConfigClient].
///
/// [baseUrl] is EMPTY for the browser build and an absolute `http(s)://host:port`
/// on native. That asymmetry is forced: the console serves the Flutter web
/// bundle itself and sends no CORS headers at all, so from the browser the only
/// reachable API is the same origin — a relative `/api/...` path. Dart's HTTP
/// client on native has no such restriction but also no page to be relative to,
/// so it needs the full address the user typed.
class HttpAdminConfigClient implements AdminConfigClient {
  final Dio _dio;

  HttpAdminConfigClient([String baseUrl = '', Dio? dio])
      : _dio = dio ??
            guardedDio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
            ));

  Options _bearer(String token) => Options(headers: {
        'Authorization': 'Bearer $token',
      });

  @override
  Future<AdminLoginResult> login(String username, String password) async {
    try {
      final r = await _dio.post('/api/session', data: {
        'username': username,
        'password': password,
      });
      final j = _asMap(r.data) ?? const {};
      final token = j['token']?.toString() ?? '';
      if (token.isEmpty) {
        throw const AdminConfigException(200, '服务端未返回会话令牌');
      }
      return AdminLoginResult(token, j['is_default_password'] == true);
    } on DioException catch (e) {
      throw _mapError(e, '登录失败', authMessage: '用户名或密码错误');
    }
  }

  @override
  Future<Map<String, dynamic>?> fetch(String token) async {
    try {
      final r = await _dio.get('/api/config', options: _bearer(token));
      final j = _asMap(r.data);
      if (j == null || j.isEmpty) return null;
      return j;
    } on DioException catch (e) {
      throw _mapError(e, '读取配置失败');
    }
  }

  @override
  Future<void> push(String token, Map<String, dynamic> cfg) async {
    try {
      await _dio.put('/api/config', data: cfg, options: _bearer(token));
    } on DioException catch (e) {
      throw _mapError(e, '上传配置失败');
    }
  }

  @override
  Future<void> logout(String token) async {
    try {
      await _dio.delete('/api/session', options: _bearer(token));
    } on DioException catch (_) {
      // Logging out locally already succeeded; a server that can't be reached
      // will expire the session on its own TTL.
    }
  }

  Map<String, dynamic>? _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is List<int>) return _asMap(utf8.decode(data));
    if (data is String) {
      final s = data.trim();
      if (s.isEmpty) return null;
      try {
        return _asMap(jsonDecode(s));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Exception _mapError(DioException e, String fallback,
      {String authMessage = '会话已过期，请重新登录'}) {
    final code = e.response?.statusCode ?? 0;
    if (code == 401) return AdminAuthException(401, authMessage);
    // The server caps PUT /api/config at 256 KiB. Reporting that as a generic
    // failure would send the user hunting for a network problem that isn't
    // there.
    if (code == 413) {
      return const AdminConfigException(413, '配置过大，服务端上限为 256 KiB');
    }
    if (code == 0) {
      return AdminConfigException(0, '无法连接到服务器：${e.message ?? fallback}');
    }
    return AdminConfigException(code, '$fallback（HTTP $code）${_reason(e)}');
  }

  String _reason(DioException e) {
    final d = _asMap(e.response?.data);
    final r = d?['error'] ?? d?['reason'];
    return r == null ? '' : '：$r';
  }
}
