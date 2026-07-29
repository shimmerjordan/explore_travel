import 'dart:convert';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/services/sync/onedrive_service.dart';
import 'package:explore_journal/services/vault/admin_config_client.dart';
import 'package:explore_journal/services/vault/admin_session_store.dart';
import 'package:explore_journal/services/vault/config_sync_controller.dart';

/// AdminConfigClient stub: `fetch` either succeeds with "no config yet" (null)
/// or throws like an expired token would.
class _FakeClient implements AdminConfigClient {
  final Object? fetchError;
  int fetchCalls = 0;
  int logoutCalls = 0;
  _FakeClient({this.fetchError});

  @override
  Future<Map<String, dynamic>?> fetch(String token) async {
    fetchCalls++;
    final e = fetchError;
    if (e != null) throw e;
    return null; // session valid, server just has no config yet
  }

  @override
  Future<AdminLoginResult> login(String username, String password) =>
      throw UnimplementedError();

  @override
  Future<void> push(String token, Map<String, dynamic> cfg) async {}

  @override
  Future<void> logout(String token) async => logoutCalls++;
}

AdminSession _session() =>
    const AdminSession(baseUrl: 'http://nas.local:48080', token: 'session-token');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdminSession / PrefsAdminSessionStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips through prefs (localStorage on web)', () async {
      final store = PrefsAdminSessionStore();
      await store.write(_session());
      final back = await store.read();
      expect(back, isNotNull);
      expect(back!.baseUrl, 'http://nas.local:48080');
      expect(back.token, 'session-token');
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('a same-origin session (empty baseUrl) round-trips too', () async {
      final store = PrefsAdminSessionStore();
      await store.write(const AdminSession(baseUrl: '', token: 't'));
      final back = await store.read();
      expect(back!.baseUrl, isEmpty);
      expect(back.token, 't');
    });

    test('a corrupt/incomplete record reads as null, not a crash', () {
      expect(AdminSession.fromJson({'baseUrl': 'x'}), isNull);
      expect(AdminSession.fromJson({}), isNull);
    });

    test(
        'a pre-console record is DELETED on read, not resumed '
        '(it held a password-derived key)', () async {
      SharedPreferences.setMockInitialValues({
        'nas_web_session_v1': jsonEncode({
          'serverUrl': 'http://nas.local:48080',
          'email': 'me@x.com',
          'token': 'old-jwt',
          'salt': base64.encode(List.filled(16, 7)),
          'vaultKey': base64.encode(List.filled(32, 9)),
        }),
      });

      final restored = await PrefsAdminSessionStore().read();

      expect(restored, isNull, reason: 'the old record is not a valid session');
      final p = await SharedPreferences.getInstance();
      expect(p.containsKey('nas_web_session_v1'), isFalse,
          reason: 'the derived key must not be left in localStorage forever');
      expect(p.getString('nas_web_session_v1'), isNull);
    });

    // The purge lives on all THREE store operations, and the first thing a
    // fresh web login does is write() — a read()-only purge would leave the
    // derived key in place for anyone who logs in before they refresh.
    test('write() also DELETES the pre-console record', () async {
      SharedPreferences.setMockInitialValues({
        'nas_web_session_v1': jsonEncode({
          'token': 'old-jwt',
          'vaultKey': base64.encode(List.filled(32, 9)),
        }),
      });

      await PrefsAdminSessionStore().write(_session());

      final p = await SharedPreferences.getInstance();
      expect(p.containsKey('nas_web_session_v1'), isFalse);
      expect(p.containsKey('ej_admin_session_v1'), isTrue,
          reason: 'the new record must still have been written');
    });

    test('clear() also DELETES the pre-console record', () async {
      SharedPreferences.setMockInitialValues({
        'ej_admin_session_v1': jsonEncode(_session().toJson()),
        'nas_web_session_v1': jsonEncode({
          'token': 'old-jwt',
          'vaultKey': base64.encode(List.filled(32, 9)),
        }),
      });

      await PrefsAdminSessionStore().clear();

      final p = await SharedPreferences.getInstance();
      expect(p.containsKey('nas_web_session_v1'), isFalse);
      expect(p.containsKey('ej_admin_session_v1'), isFalse);
    });

    group('the retired NATIVE keychain token （F8）', () {
      test('is deleted on the first store operation, once per instance',
          () async {
        final deleted = <String>[];
        final store = PrefsAdminSessionStore(
            legacyKeychainDelete: (k) async => deleted.add(k));

        await store.read();
        await store.write(_session());
        await store.clear();

        expect(deleted, ['nas_session_token'],
            reason: 'the dead bearer token must go, but only one keychain '
                'round-trip per process');
      });

      test('a platform without secure_storage does not break the session store',
          () async {
        // `flutter test` has no secure_storage impl at all — the delete throws
        // MissingPluginException. Wiping waste paper must never fail a login.
        final store = PrefsAdminSessionStore(
            legacyKeychainDelete: (_) async =>
                throw MissingPluginException('no impl'));

        await store.write(_session());
        final back = await store.read();

        expect(back?.token, 'session-token');
      });
    });
  });

  group('ConfigSyncController.restoreSession（刷新后静默恢复）', () {
    late MemoryAdminSessionStore store;
    late _FakeClient client;
    late ProviderContainer container;
    late ConfigSyncController ctrl;

    Future<void> build() async {
      final provider = Provider<ConfigSyncController>((ref) =>
          ConfigSyncController(ref,
              clientFactory: (_) => client, sessionStore: store));
      container = ProviderContainer();
      ctrl = container.read(provider);
      // SettingsNotifier._load() completes asynchronously and REPLACES the
      // state when done — wait it out or it clobbers what the test writes.
      while (!container.read(settingsProvider).loaded) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      store = MemoryAdminSessionStore();
      client = _FakeClient();
    });

    tearDown(() {
      ctrl.dispose();
      container.dispose();
    });

    test('no stored session → false, no network call', () async {
      await build();
      expect(await ctrl.restoreSession(), isFalse);
      expect(client.fetchCalls, 0);
      expect(ctrl.isLoggedIn, isFalse);
    });

    test('valid stored session resumes: logged in + console address applied',
        () async {
      store.session = _session();
      await build();
      expect(await ctrl.restoreSession(), isTrue);
      expect(ctrl.isLoggedIn, isTrue);
      expect(client.fetchCalls, 1,
          reason: 'the token must be validated against the server');
      expect(container.read(settingsProvider).nasServerUrl,
          'http://nas.local:48080');
    });

    test('expired/rejected token → false AND the stored session is wiped',
        () async {
      store.session = _session();
      client = _FakeClient(
          fetchError: const AdminAuthException(401, 'token expired'));
      await build();
      expect(await ctrl.restoreSession(), isFalse);
      expect(ctrl.isLoggedIn, isFalse);
      expect(store.session, isNull,
          reason: 'a dead session must not retrigger on every refresh');
    });

    // ── F1：只有 401 才算「未登录」 ────────────────────────────────────
    // Reloading the page right after restarting the NAS container is the most
    // common way this request fails, and the token is perfectly good when it
    // does. Deleting the record there costs the user their password.
    for (final (label, err) in <(String, Object)>[
      ('an unreachable console (container restarting / wifi blip)',
          const AdminConfigException(0, '无法连接到服务器：连接被拒绝或网络不可达')),
      ('a server-side 500 (the password-change window)',
          const AdminConfigException(500, '读取配置失败（HTTP 500）')),
      ('a TLS/DNS style failure with no status at all',
          const AdminConfigException(0, '无法连接到服务器：证书不被信任')),
      ('anything unexpected on the way through', StateError('boom')),
    ]) {
      test('$label → false but the stored session SURVIVES', () async {
        store.session = _session();
        client = _FakeClient(fetchError: err);
        await build();

        expect(await ctrl.restoreSession(), isFalse,
            reason: 'we did not manage to resume');
        expect(ctrl.isLoggedIn, isFalse,
            reason: 'an unvalidated token must not count as a live session');
        expect(store.session, isNotNull,
            reason: 'the token is probably still valid — the NEXT refresh '
                'must be able to resume instead of demanding the password');
        expect(store.session!.token, 'session-token');
      });
    }

    test('a transient failure then a working server resumes on the retry',
        () async {
      // The whole point of keeping the record: the second attempt works.
      store.session = _session();
      client = _FakeClient(
          fetchError: const AdminConfigException(0, '无法连接到服务器'));
      await build();
      expect(await ctrl.restoreSession(), isFalse);

      client = _FakeClient(); // console is back
      expect(await ctrl.restoreSession(), isTrue);
      expect(ctrl.isLoggedIn, isTrue);
    });
  });

  group('OneDrive web redirect URI', () {
    test('hash-routed origin → <origin>/auth.html', () {
      expect(
        OneDriveService.redirectUriForBase(
            Uri.parse('http://localhost:48082/#/backup')),
        'http://localhost:48082/auth.html',
      );
    });

    test('sub-path deploy (/app/) keeps the base path', () {
      expect(
        OneDriveService.redirectUriForBase(
            Uri.parse('https://x.pages.dev/app/#/login')),
        'https://x.pages.dev/app/auth.html',
      );
    });

    test('query strings on the base never leak into the redirect', () {
      expect(
        OneDriveService.redirectUriForBase(
            Uri.parse('http://localhost:48082/?foo=1#/x')),
        'http://localhost:48082/auth.html',
      );
    });
  });
}
