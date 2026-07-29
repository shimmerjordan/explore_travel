import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart'
    show configSyncControllerProvider;
import 'package:explore_journal/main.dart' show ShrunkMediaQuery;
import 'package:explore_journal/services/vault/admin_config_client.dart';
import 'package:explore_journal/services/vault/admin_session_store.dart';
import 'package:explore_journal/services/vault/auth_controller.dart';
import 'package:explore_journal/services/vault/config_sync_controller.dart';
import 'package:explore_journal/ui/auth/login_screen.dart'
    show humanizeLoginError, validateLoginInput;

/// Blows up on the first thing `restoreSession()` does — and `read()` sits
/// OUTSIDE its try, which is exactly why a throw here used to leave the gate
/// stuck open on [AuthStatus.unknown].
class _ThrowingStore implements AdminSessionStore {
  @override
  Future<AdminSession?> read() async => throw StateError('storage unavailable');
  @override
  Future<void> write(AdminSession s) async {}
  @override
  Future<void> clear() async {}
}

class _UnusedClient implements AdminConfigClient {
  @override
  Future<Map<String, dynamic>?> fetch(String token) => throw UnimplementedError();
  @override
  Future<AdminLoginResult> login(String u, String p) => throw UnimplementedError();
  @override
  Future<void> push(String t, Map<String, dynamic> c) => throw UnimplementedError();
  @override
  Future<void> logout(String t) => throw UnimplementedError();
}

/// Path + decoded `from`, so assertions don't depend on percent-encoding.
({String path, String? from}) _parse(String? redirect) {
  expect(redirect, isNotNull);
  final u = Uri.parse(redirect!);
  return (path: u.path, from: u.queryParameters['from']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('webAuthRedirect （F5：门禁失效方向必须是「拒绝」）', () {
    test('unknown never renders the real target — it parks on /splash', () {
      // Falling through on `unknown` painted MapScreen (or the deep-link
      // target) for one frame on EVERY cold start, then bounced to /login:
      // a visible flash plus a wasted round of DB queries and tile renders.
      final r = _parse(webAuthRedirect(
          status: AuthStatus.unknown, uri: Uri.parse('/journal')));
      expect(r.path, '/splash');
      expect(r.from, '/journal', reason: 'the deep link has to survive');
    });

    test('unknown at the root also parks on /splash', () {
      expect(
          _parse(webAuthRedirect(
                  status: AuthStatus.unknown, uri: Uri.parse('/')))
              .path,
          '/splash');
    });

    test('unknown already on /splash stays put (no redirect loop)', () {
      expect(
          webAuthRedirect(
              status: AuthStatus.unknown,
              uri: Uri.parse('/splash?from=%2Fjournal')),
          isNull);
    });

    test('loggedOut carries the intercepted location into /login', () {
      final r = _parse(webAuthRedirect(
          status: AuthStatus.loggedOut, uri: Uri.parse('/journal')));
      expect(r.path, '/login');
      expect(r.from, '/journal');
    });

    test('loggedOut hands the /splash detour its ?from= onwards', () {
      final r = _parse(webAuthRedirect(
          status: AuthStatus.loggedOut,
          uri: Uri.parse('/splash?from=%2Fjournal')));
      expect(r.path, '/login');
      expect(r.from, '/journal');
    });

    test('loggedOut on /login stays put', () {
      expect(
          webAuthRedirect(
              status: AuthStatus.loggedOut, uri: Uri.parse('/login')),
          isNull);
    });

    test('login success returns to the DEEP LINK, not to /', () {
      // The old gate hard-coded '/', so a shared /journal link was lost for
      // good — there was no path back to where the user was headed.
      expect(
          webAuthRedirect(
              status: AuthStatus.loggedIn,
              uri: Uri.parse('/login?from=%2Fjournal')),
          '/journal');
    });

    test('query strings on the deep link survive the round trip', () {
      final r = _parse(webAuthRedirect(
          status: AuthStatus.loggedOut, uri: Uri.parse('/journal?id=7')));
      expect(r.from, '/journal?id=7');
      expect(
          webAuthRedirect(
              status: AuthStatus.loggedIn,
              uri: Uri.parse('/login?from=${Uri.encodeComponent('/journal?id=7')}')),
          '/journal?id=7');
    });

    test('resolving on /splash sends a logged-in user to the deep link', () {
      expect(
          webAuthRedirect(
              status: AuthStatus.loggedIn,
              uri: Uri.parse('/splash?from=%2Fmusic')),
          '/music');
    });

    test('no ?from= falls back to /', () {
      expect(
          webAuthRedirect(
              status: AuthStatus.loggedIn, uri: Uri.parse('/login')),
          '/');
    });

    test('a ?from= pointing back at the gate is refused (loop / open redirect)',
        () {
      for (final hostile in [
        '/login',
        '/splash',
        'https://evil.example.com/',
        '//evil.example.com/',
        'javascript:alert(1)',
      ]) {
        expect(
            webAuthRedirect(
                status: AuthStatus.loggedIn,
                uri: Uri.parse('/login?from=${Uri.encodeComponent(hostile)}')),
            '/',
            reason: 'from=$hostile must not be honoured');
      }
    });

    test('a logged-in user on a normal route is left alone', () {
      expect(
          webAuthRedirect(
              status: AuthStatus.loggedIn, uri: Uri.parse('/journal')),
          isNull);
    });
  });

  group('AuthController.restore （F5：抛错必须落到 loggedOut）', () {
    test('a throwing session store resolves to loggedOut, not unknown',
        () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(overrides: [
        configSyncControllerProvider.overrideWith((ref) => ConfigSyncController(
              ref,
              clientFactory: (_) => _UnusedClient(),
              sessionStore: _ThrowingStore(),
              autoPush: false,
            )),
      ]);
      addTearDown(container.dispose);
      final auth = container.read(authControllerProvider);
      expect(auth.state.status, AuthStatus.unknown);

      await auth.restore();

      expect(auth.state.status, AuthStatus.loggedOut,
          reason: 'stuck on unknown = the gate never closes');
      // And the gate agrees.
      expect(
          _parse(webAuthRedirect(status: auth.state.status, uri: Uri.parse('/')))
              .path,
          '/login');
    });
  });

  group('ShrunkMediaQuery （F11：builder 缩了 Navigator 也要缩 MediaQuery）', () {
    /// Pumps [barHeight] of notice bar above the child and reports what the
    /// child's MediaQuery says. The default test surface is 800×600 logical, so
    /// the Column's constraints and the MediaQuery size agree.
    Future<({Size size, EdgeInsets padding, EdgeInsets viewPadding})> run(
        WidgetTester tester, double barHeight,
        {double statusBar = 24}) async {
      late MediaQueryData seen;
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          padding: EdgeInsets.only(top: statusBar),
          viewPadding: EdgeInsets.only(top: statusBar),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [
            SizedBox(height: barHeight, width: 800),
            Expanded(
              child: ShrunkMediaQuery(
                child: Builder(builder: (ctx) {
                  seen = MediaQuery.of(ctx);
                  return const SizedBox.shrink();
                }),
              ),
            ),
          ]),
        ),
      ));
      return (
        size: seen.size,
        padding: seen.padding,
        viewPadding: seen.viewPadding
      );
    }

    testWidgets('the child is told the height it actually got', (t) async {
      final m = await run(t, 61); // 24px status bar + a 37px notice row
      expect(m.size.height, 539,
          reason: 'reporting 600 is how the companion card overflowed by ~37px');
      expect(m.size.width, 800, reason: 'width is untouched');
    });

    testWidgets('the top inset the bar already consumed is not handed on again',
        (t) async {
      final m = await run(t, 61);
      expect(m.padding.top, 0);
      expect(m.viewPadding.top, 0);
    });

    testWidgets('a bar shorter than the status bar leaves the remainder',
        (t) async {
      final m = await run(t, 10, statusBar: 24);
      expect(m.size.height, 590);
      expect(m.padding.top, 14, reason: 'clamped, never negative');
    });

    testWidgets('with no bar above it, nothing is rewritten', (t) async {
      late MediaQueryData seen;
      await t.pumpWidget(MediaQuery(
        data: const MediaQueryData(
          size: Size(800, 600),
          padding: EdgeInsets.only(top: 24),
        ),
        child: ShrunkMediaQuery(
          child: Builder(builder: (ctx) {
            seen = MediaQuery.of(ctx);
            return const SizedBox.shrink();
          }),
        ),
      ));
      expect(seen.size.height, 600);
      expect(seen.padding.top, 24);
    });
  });

  group('validateLoginInput （F12：别拿限流桶试错）', () {
    test('native: an empty address is rejected before any request', () {
      // Empty means "same origin", which on a phone is nowhere at all — the
      // old code silently sent the request anyway.
      final msg = validateLoginInput(
          needsServer: true, server: '  ', username: 'admin', password: 'pw');
      expect(msg, '请填写后端地址，例如 http://192.168.1.9:48080');
    });

    test('native: a non-URL address is rejected with the reason', () {
      expect(
          validateLoginInput(
              needsServer: true,
              server: '192.168.1.9:48080', // no scheme
              username: 'admin',
              password: 'pw'),
          '后端地址需为 http(s):// 开头的完整 URL');
    });

    test('an empty username or password never spends a login attempt', () {
      expect(
          validateLoginInput(
              needsServer: false, server: '', username: ' ', password: 'pw'),
          '请填写用户名');
      expect(
          validateLoginInput(
              needsServer: false, server: '', username: 'admin', password: ''),
          '请填写密码');
    });

    test('web needs no address at all (same-origin)', () {
      expect(
          validateLoginInput(
              needsServer: false, server: '', username: 'admin', password: 'pw'),
          isNull);
    });

    test('a well-formed native form passes', () {
      expect(
          validateLoginInput(
              needsServer: true,
              server: 'http://192.168.1.9:48080/',
              username: 'admin',
              password: 'pw'),
          isNull);
    });
  });

  group('humanizeLoginError （F4：用户读得懂的中文）', () {
    test('429 says how long to wait, and reads the server Retry-After', () {
      expect(
        humanizeLoginError(const AdminConfigException(429, '操作过于频繁，请 60 秒后再试',
            retryAfterSeconds: 60)),
        '登录过于频繁，请 60 秒后再试（服务端每分钟只接受 10 次登录）',
      );
      expect(
        humanizeLoginError(const AdminConfigException(429, 'x')),
        contains('60 秒后再试'),
        reason: 'a missing Retry-After still gets a concrete number',
      );
    });

    test('a 401 still refuses to say WHICH field was wrong', () {
      final s = humanizeLoginError(const AdminAuthException(401, 'whatever'));
      expect(s, '用户名或密码错误');
      expect(s, isNot(contains('不存在')));
    });
  });
}
