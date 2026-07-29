import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/services/security/http_guard.dart';
import 'package:explore_journal/services/vault/admin_config_client.dart';

/// Records what the client actually put on the wire and answers with a canned
/// response. Installed on a real [guardedDio] so the cleartext guard is in the
/// chain exactly as it is in production.
class _RecordingAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions o) respond;
  _RecordingAdapter(this.respond);

  final List<String> uris = [];
  final List<String> methods = [];
  final List<Object?> bodies = [];
  final List<String?> auth = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    uris.add(options.uri.toString());
    methods.add(options.method);
    bodies.add(options.data);
    auth.add(options.headers['Authorization'] as String?);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );

class _Rig {
  final AdminConfigClient client;
  final _RecordingAdapter adapter;
  _Rig(this.client, this.adapter);
}

_Rig _rig(String baseUrl, ResponseBody Function(RequestOptions o) respond) {
  final dio = guardedDio(BaseOptions(baseUrl: baseUrl));
  final adapter = _RecordingAdapter(respond);
  dio.httpClientAdapter = adapter;
  return _Rig(HttpAdminConfigClient(baseUrl, dio), adapter);
}

void main() {
  group('same-origin mode (the browser build)', () {
    test('login/fetch/push/logout hit bare /api/... paths, no host at all',
        () async {
      final rig = _rig('', (o) {
        if (o.path == '/api/session' && o.method == 'POST') {
          return _json(200, {
            'ok': true,
            'is_default_password': false,
            'token': 'tok-1',
          });
        }
        return _json(200, {'webdavUrl': 'https://dav.example.com'});
      });

      await rig.client.login('admin', 'pw');
      await rig.client.fetch('tok-1');
      await rig.client.push('tok-1', {'webdavUser': 'u'});
      await rig.client.logout('tok-1');

      expect(rig.adapter.uris, [
        '/api/session',
        '/api/config',
        '/api/config',
        '/api/session',
      ]);
      expect(rig.adapter.methods, ['POST', 'GET', 'PUT', 'DELETE']);
      // The failure modes worth naming: a stringified null or empty host from
      // pasting a base URL together, either of which the browser would refuse.
      for (final u in rig.adapter.uris) {
        expect(u.startsWith('/api/'), isTrue, reason: 'not same-origin: $u');
        expect(u, isNot(contains('null')));
        expect(u, isNot(startsWith('//')));
      }
    });

    test('the cleartext HTTP guard lets a relative path through', () async {
      // guardedDio refuses plain http to public hosts. A relative path has no
      // scheme and no host, so it must not be caught by that rule — if it were,
      // the web build could never reach its own API.
      final rig = _rig('', (_) => _json(200, {}));
      await rig.client.fetch('tok');
      expect(rig.adapter.uris, ['/api/config']);
    });
  });

  group('absolute baseUrl mode (the phone)', () {
    test('paths are appended to the configured host', () async {
      final rig = _rig(
          'http://192.168.1.9:48080',
          (_) => _json(
              200, {'ok': true, 'is_default_password': true, 'token': 't'}));
      await rig.client.login('admin', 'admin');
      expect(rig.adapter.uris, ['http://192.168.1.9:48080/api/session']);
    });
  });

  group('login', () {
    test('parses the token and the default-password flag', () async {
      final rig = _rig(
          '',
          (_) => _json(200,
              {'ok': true, 'is_default_password': true, 'token': 'tok-xyz'}));
      final r = await rig.client.login('admin', 'admin');
      expect(r.token, 'tok-xyz');
      expect(r.isDefaultPassword, isTrue);
      expect(jsonDecode(jsonEncode(rig.adapter.bodies.single)),
          {'username': 'admin', 'password': 'admin'});
    });

    test('401 is an AdminAuthException that does not say WHICH field was wrong',
        () async {
      final rig = _rig('', (_) => _json(401, {'error': 'unauthorized'}));
      await expectLater(
        rig.client.login('nope', 'nope'),
        throwsA(isA<AdminAuthException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', isNot(contains('用户名不存在')))),
      );
    });
  });

  group('fetch', () {
    test('an empty object means "no config yet", not an error', () async {
      final rig = _rig('', (_) => _json(200, <String, dynamic>{}));
      expect(await rig.client.fetch('tok'), isNull);
    });

    test('sends the bearer token and returns the config map', () async {
      final rig = _rig('', (_) => _json(200, {'webdavUser': 'u'}));
      expect(await rig.client.fetch('tok-9'), {'webdavUser': 'u'});
      expect(rig.adapter.auth.single, 'Bearer tok-9');
    });

    test('401 clears the way for the caller to drop the session', () async {
      final rig = _rig('', (_) => _json(401, {'error': 'unauthorized'}));
      await expectLater(
          rig.client.fetch('stale'), throwsA(isA<AdminAuthException>()));
    });
  });

  group('push', () {
    test('413 reports the size cap instead of a generic failure', () async {
      final rig = _rig('', (_) => _json(413, {'error': 'too large'}));
      await expectLater(
        rig.client.push('tok', {'a': 'b'}),
        throwsA(isA<AdminConfigException>()
            .having((e) => e.statusCode, 'statusCode', 413)
            .having((e) => e.message, 'message', contains('配置过大'))),
      );
    });

    test('an unreachable server reads as a connection problem', () async {
      final rig = _rig('', (o) {
        throw DioException.connectionError(
            requestOptions: o, reason: 'refused');
      });
      await expectLater(
        rig.client.push('tok', {'a': 'b'}),
        throwsA(isA<AdminConfigException>()
            .having((e) => e.message, 'message', contains('无法连接到服务器'))),
      );
    });
  });

  group('logout', () {
    test('a failing DELETE SURFACES so the caller can warn （F7）', () async {
      // The server treats its ej_session cookie as bearer-equivalent and this
      // DELETE is the only thing that expires it. Swallowing the failure here
      // (as this used to) is what left a live session on a shared browser with
      // nothing on screen to say so. ConfigSyncController.logout still doesn't
      // FAIL — it catches this and reports serverNotified: false.
      final rig = _rig('', (o) {
        throw DioException.connectionError(requestOptions: o, reason: 'down');
      });
      await expectLater(
        rig.client.logout('tok'),
        throwsA(isA<AdminConfigException>()
            .having((e) => e.message, 'message', contains('无法连接到服务器'))),
      );
      expect(rig.adapter.uris, ['/api/session']);
    });

    test('a 401 is NOT a failure — the session is already gone', () async {
      final rig = _rig('', (_) => _json(401, {'error': 'unauthorized'}));
      await rig.client.logout('stale'); // must not throw
    });
  });

  group('error copy the user actually reads', () {
    test('the cleartext guard\'s reason reaches the user, translated （F3）',
        () async {
      // `http://synology:5000` — a bare hostname is not private, so the guard
      // rejects it with the diagnostic in DioException.error and a NULL
      // message. Reading only `message` turned all of this into
      // "无法连接到服务器：登录失败".
      final rig = _rig('http://synology:5000', (_) => _json(200, {}));
      Object? caught;
      try {
        await rig.client.login('admin', 'pw');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<AdminConfigException>());
      final msg = (caught! as AdminConfigException).message;
      expect(msg, contains('synology'), reason: 'name the host at fault');
      expect(msg, contains('https://'));
      expect(msg, contains('局域网'), reason: 'and what to do instead');
      expect(msg, isNot(contains('登录失败')),
          reason: 'the real reason must not be replaced by the fallback');
      expect(msg, isNot(contains('Refused')), reason: 'no English at the user');
      // ignore: avoid_print
      print('CLEARTEXT → $msg');
    });

    test('429 becomes a wait instruction and carries Retry-After （F4）',
        () async {
      final rig = _rig(
          '',
          (_) => ResponseBody.fromString(
                jsonEncode({'error': 'rate limited'}),
                429,
                headers: {
                  Headers.contentTypeHeader: ['application/json'],
                  'retry-after': ['60'],
                },
              ));
      Object? caught;
      try {
        await rig.client.login('admin', 'pw');
      } catch (e) {
        caught = e;
      }
      final e = caught! as AdminConfigException;
      expect(e.statusCode, 429);
      expect(e.retryAfterSeconds, 60);
      expect(e.message, '操作过于频繁，请 60 秒后再试');
      expect(e.message, isNot(contains('rate limited')),
          reason: 'English + no wait time is what made users keep retrying');
      // ignore: avoid_print
      print('429 → ${e.message}');
    });

    test('a connect timeout does not hand dio\'s tuning advice to the user',
        () async {
      final rig = _rig('http://192.168.1.9:48080', (o) {
        throw DioException.connectionTimeout(
            timeout: const Duration(seconds: 15), requestOptions: o);
      });
      Object? caught;
      try {
        await rig.client.login('admin', 'pw');
      } catch (e) {
        caught = e;
      }
      final msg = (caught! as AdminConfigException).message;
      expect(msg, '无法连接到服务器：连接超时，请确认地址与端口正确、设备与服务在同一网络');
      expect(msg, isNot(contains('connectTimeout')));
      expect(msg, isNot(contains('RequestOptions')));
      // ignore: avoid_print
      print('TIMEOUT → $msg');
    });

    test('a self-signed certificate reads as a certificate problem', () async {
      final rig = _rig('https://nas.example.com', (o) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.badCertificate,
          message: 'The certificate of the response is not approved.',
        );
      });
      Object? caught;
      try {
        await rig.client.fetch('tok');
      } catch (e) {
        caught = e;
      }
      final msg = (caught! as AdminConfigException).message;
      expect(msg, contains('证书'));
      expect(msg, isNot(contains('certificate')));
      // ignore: avoid_print
      print('BAD CERT → $msg');
    });

    test('a reason that only exists in `error` is not dropped', () async {
      // dio leaves `message` null whenever it wraps a non-Dio throw, so
      // `e.message ?? e.error ?? fallback` is the whole point.
      final rig = _rig('', (o) {
        throw DioException(
            requestOptions: o,
            type: DioExceptionType.unknown,
            error: 'SocketException: host lookup failed');
      });
      Object? caught;
      try {
        await rig.client.fetch('tok');
      } catch (e) {
        caught = e;
      }
      expect((caught! as AdminConfigException).message,
          contains('host lookup failed'));
    });
  });
}
