import 'package:dio/dio.dart';

/// Dio interceptor that **refuses cleartext HTTP to non-private hosts**.
///
/// Android's `network_security_config.xml` can't whitelist IP ranges,
/// so we keep cleartext globally permitted at the manifest level (the
/// user might plug in any LAN IP for WebDAV) and enforce the policy
/// here at request time:
///
///   ✓ `https://api.openai.com`        — fine
///   ✓ `http://192.168.1.50:5005`      — fine, RFC1918
///   ✓ `http://10.42.0.1`              — fine, RFC1918
///   ✓ `http://172.22.0.0/12`          — fine, RFC1918
///   ✓ `http://100.64.0.0/10`          — fine, Tailscale CGNAT
///   ✓ `http://localhost`              — fine
///   ✗ `http://api.example.com`        — REFUSED (would leak in plain text)
///
/// Why we don't just hard-fail on every cleartext request: WebDAV /
/// image hosts on a user's home LAN are legitimately HTTP-only and
/// asking everyone to provision TLS on their NAS is unrealistic.
///
/// Add this interceptor to every `Dio` instance the app uses for
/// outbound traffic. It's idempotent and side-effect-free.
class HttpGuardInterceptor extends Interceptor {
  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) {
    final uri = options.uri;
    if (uri.scheme == 'http' && !_isPrivate(uri.host)) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          error:
              'Refused: cleartext HTTP to public host "${uri.host}". '
              'Use https:// or point at a private LAN address.',
        ),
        true,
      );
      return;
    }
    handler.next(options);
  }

  /// True if [host] is a loopback, a RFC1918 IPv4, or Tailscale's
  /// 100.64.0.0/10 CGN range. `.local` mDNS names are also accepted —
  /// they only resolve on-LAN anyway.
  static bool _isPrivate(String host) {
    if (host.isEmpty) return false;
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final p = host.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]);
    final b = int.tryParse(p[1]);
    if (a == null || b == null) return false;
    if (a == 127) return true; // 127.0.0.0/8 loopback
    if (a == 10) return true; // 10.0.0.0/8
    if (a == 192 && b == 168) return true; // 192.168.0.0/16
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT (Tailscale)
    if (a == 169 && b == 254) return true; // 169.254.0.0/16 link-local
    return false;
  }
}
