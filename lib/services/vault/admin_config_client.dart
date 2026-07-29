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
///
/// [retryAfterSeconds] is only ever set for 429: the server sends
/// `Retry-After: 60` alongside its rate-limit refusal, and a user who is only
/// told "too many requests" retries immediately — which is exactly what keeps
/// the bucket full. Carrying the number lets the UI say *when* to try again.
class AdminConfigException implements Exception {
  final int statusCode;
  final String message;
  final int? retryAfterSeconds;
  const AdminConfigException(this.statusCode, this.message,
      {this.retryAfterSeconds});
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

  /// Drop the server-side session.
  ///
  /// THROWS when the console never confirmed it. The caller has already
  /// forgotten the token locally by then, so it must not fail the logout — but
  /// it does have to know: the server treats its `ej_session` cookie as
  /// bearer-equivalent, and `DELETE /api/session` is the only thing that
  /// expires it. Swallowing the failure here (as this used to) left a live
  /// session on a shared browser with nothing on screen to say so.
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
    } on DioException catch (e) {
      // A 401 means the session is already gone — that IS the outcome we
      // wanted, so it isn't a failure.
      if (e.response?.statusCode == 401) return;
      throw _mapError(e, '注销会话失败');
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
    // The login bucket is only 10/min. "rate limited" alone reads as "retry
    // now", which refills the bucket — say how long to wait instead.
    if (code == 429) {
      final wait = _retryAfter(e) ?? 60;
      return AdminConfigException(429, '操作过于频繁，请 $wait 秒后再试',
          retryAfterSeconds: wait);
    }
    if (code == 0) {
      return AdminConfigException(0, '无法连接到服务器：${_transportReason(e, fallback)}');
    }
    return AdminConfigException(code, '$fallback（HTTP $code）${_reason(e)}');
  }

  int? _retryAfter(DioException e) {
    final raw = e.response?.headers.value('retry-after');
    final n = raw == null ? null : int.tryParse(raw.trim());
    return (n != null && n > 0) ? n : null;
  }

  /// Why we never reached the server, in words a user can act on.
  ///
  /// dio's own `message` is written for the developer who set the timeout
  /// ("try raising RequestOptions.connectTimeout above ..."), so it must not
  /// reach the UI. And for a rejection from an interceptor `message` is null
  /// altogether while the real reason sits in `error` — reading only `message`
  /// (as this used to) turned the cleartext guard's actionable advice into a
  /// bare "登录失败".
  String _transportReason(DioException e, String fallback) {
    final err = e.error;
    // A malformed/empty base URL surfaces as dio wrapping an ArgumentError
    // ("No host specified in URI /api/session"). The login form rejects that
    // before it gets here (see validateLoginInput), so this is the backstop —
    // typed, not matched on the wording.
    if (err is ArgumentError) {
      return '后端地址无效：${err.message ?? err}';
    }
    if (err is CleartextRefusedError) {
      return '出于安全考虑，拒绝以明文 HTTP 连接公网主机「${err.host}」。'
          '请改用 https://，或填写局域网地址（如 http://192.168.x.x:48080）';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时，请确认地址与端口正确、设备与服务在同一网络';
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '服务器响应超时，请稍后重试';
      case DioExceptionType.badCertificate:
        return '服务器的 HTTPS 证书不被信任（自签证书请改用 http:// 或先安装证书）';
      case DioExceptionType.connectionError:
        return '连接被拒绝或网络不可达，请确认服务已启动';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        // `message ?? error ?? fallback`: whichever layer actually knows.
        // Never drop the whole reason on the floor.
        return e.message ?? err?.toString() ?? fallback;
    }
  }

  String _reason(DioException e) {
    final d = _asMap(e.response?.data);
    final r = d?['error'] ?? d?['reason'];
    return r == null ? '' : '：$r';
  }
}
