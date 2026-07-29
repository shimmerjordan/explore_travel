import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/core/prefs.dart' show AppSettings;
import 'package:explore_journal/services/vault/admin_config_client.dart';
import 'package:explore_journal/services/vault/admin_session_store.dart';
import 'package:explore_journal/services/vault/config_sync_controller.dart';

/// In-memory console: one stored config, one token, and a record of every call.
class _FakeClient implements AdminConfigClient {
  Map<String, dynamic>? stored;
  final bool isDefaultPassword;
  bool failLogoutCall;

  /// Thrown by [push] instead of storing, to model a session the server has
  /// forgotten (idle past the sliding TTL, or a console restart).
  Object? pushError;

  final List<Map<String, dynamic>> pushes = [];
  int fetchCalls = 0;
  int logoutCalls = 0;
  final List<String> tokensSeen = [];

  _FakeClient({
    this.isDefaultPassword = false,
    this.failLogoutCall = false,
    this.pushError,
  });

  @override
  Future<AdminLoginResult> login(String username, String password) async {
    if (username != 'admin' || password != 'pw') {
      throw const AdminAuthException(401, '用户名或密码错误');
    }
    return AdminLoginResult('tok-1', isDefaultPassword);
  }

  @override
  Future<Map<String, dynamic>?> fetch(String token) async {
    fetchCalls++;
    tokensSeen.add(token);
    return stored;
  }

  @override
  Future<void> push(String token, Map<String, dynamic> cfg) async {
    tokensSeen.add(token);
    final e = pushError;
    if (e != null) throw e;
    pushes.add(Map<String, dynamic>.from(cfg));
    stored = Map<String, dynamic>.from(cfg);
  }

  @override
  Future<void> logout(String token) async {
    logoutCalls++;
    if (failLogoutCall) throw const AdminConfigException(0, '无法连接到服务器');
  }
}

/// A settings notifier whose writes always fail — the stand-in for "anything at
/// all went wrong while applying the remote config", which is precisely what
/// pullAndApply's backstop exists for.
class _ExplodingSettings extends SettingsNotifier {
  _ExplodingSettings(super.store);
  @override
  Future<void> update(AppSettings Function(AppSettings) f) async =>
      throw StateError('settings write blew up');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeClient client;
  late MemoryAdminSessionStore store;
  late ProviderContainer container;
  late ConfigSyncController ctrl;

  /// [autoPush] null = leave the default (`!kIsWeb`) in place, which is what a
  /// VM/native run gets. Pass false to model the browser build.
  Future<void> build({
    bool? autoPush,
    Duration debounce = const Duration(milliseconds: 20),
  }) async {
    final provider = Provider<ConfigSyncController>((ref) => autoPush == null
        ? ConfigSyncController(ref,
            clientFactory: (_) => client,
            sessionStore: store,
            pushDebounce: debounce)
        : ConfigSyncController(ref,
            clientFactory: (_) => client,
            sessionStore: store,
            autoPush: autoPush,
            pushDebounce: debounce));
    container = ProviderContainer();
    ctrl = container.read(provider);
    while (!container.read(settingsProvider).loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    client = _FakeClient();
    store = MemoryAdminSessionStore();
  });

  tearDown(() {
    ctrl.dispose();
    container.dispose();
  });

  group('login / pull / push', () {
    test('login pulls the stored config onto local settings', () async {
      client.stored = {
        '_schema': 1,
        'webdavUrl': 'https://dav.example.com',
        'webdavPass': 'from-server',
        'syncBackend': 'webdav',
      };
      await build(autoPush: false);

      expect(await ctrl.login(username: 'admin', password: 'pw'), isFalse);
      expect(ctrl.isLoggedIn, isTrue);
      final s = container.read(settingsProvider);
      expect(s.webdavUrl, 'https://dav.example.com');
      expect(s.webdavPass, 'from-server');
      expect(s.syncBackend, 'webdav');
      expect(client.tokensSeen, everyElement('tok-1'));
    });

    test('login reports the server\'s default-password flag', () async {
      client = _FakeClient(isDefaultPassword: true);
      await build(autoPush: false);
      expect(await ctrl.login(username: 'admin', password: 'pw'), isTrue);
    });

    test('wrong credentials leave the controller logged out', () async {
      await build(autoPush: false);
      await expectLater(ctrl.login(username: 'admin', password: 'nope'),
          throwsA(isA<AdminAuthException>()));
      expect(ctrl.isLoggedIn, isFalse);
    });

    test('an empty server config is not an error and applies nothing',
        () async {
      await build(autoPush: false);
      await ctrl.login(username: 'admin', password: 'pw');
      expect(container.read(settingsProvider).webdavUrl, isNull);
    });

    test('pushNow uploads the config subset and dedupes an unchanged repush',
        () async {
      await build(autoPush: false);
      await ctrl.login(username: 'admin', password: 'pw');
      await container
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(webdavUrl: 'https://dav.x', webdavPass: 'p'));

      expect(await ctrl.pushNow(), isTrue);
      expect(client.pushes.single['webdavUrl'], 'https://dav.x');
      expect(client.pushes.single['webdavPass'], 'p');
      expect(client.pushes.single.containsKey('fogColor'), isFalse,
          reason: 'non-credential prefs must not enter the config');

      expect(await ctrl.pushNow(), isFalse,
          reason: 'identical content must not be re-uploaded');
      expect(client.pushes, hasLength(1));
      expect(await ctrl.pushNow(force: true), isTrue);
      expect(client.pushes, hasLength(2));
    });

    test('pushNow without a session is a no-op, not a crash', () async {
      await build(autoPush: false);
      expect(await ctrl.pushNow(), isFalse);
      expect(client.pushes, isEmpty);
    });

    test('logout drops the local session and the server one, keeps local data',
        () async {
      await build(autoPush: false);
      await ctrl.login(username: 'admin', password: 'pw');
      await container
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(webdavPass: 'keepme'));

      await ctrl.logout();

      expect(ctrl.isLoggedIn, isFalse);
      expect(store.session, isNull);
      expect(client.logoutCalls, 1);
      expect(container.read(settingsProvider).webdavPass, 'keepme');
    });

    test('a console that refuses DELETE /api/session still logs us out',
        () async {
      client = _FakeClient(failLogoutCall: true);
      await build(autoPush: false);
      await ctrl.login(username: 'admin', password: 'pw');
      await ctrl.logout(); // must not throw
      expect(ctrl.isLoggedIn, isFalse);
    });

    test('…but REPORTS that the server was never notified （F7）', () async {
      // The server treats its ej_session cookie as bearer-equivalent and
      // DELETE /api/session is the only thing that expires it. On a shared
      // browser "silently swallowed" means the next person can read every
      // credential in the config while the user believes they logged out.
      client = _FakeClient(failLogoutCall: true);
      await build(autoPush: false);
      await ctrl.login(username: 'admin', password: 'pw');

      final outcome = await ctrl.logout();

      expect(outcome.serverNotified, isFalse);
      expect(client.logoutCalls, 2, reason: 'one short retry before reporting');
    });

    test('a successful DELETE reports serverNotified （no false alarm）',
        () async {
      await build(autoPush: false);
      await ctrl.login(username: 'admin', password: 'pw');
      expect((await ctrl.logout()).serverNotified, isTrue);
      expect(client.logoutCalls, 1, reason: 'no retry when the first call works');
    });
  });

  group('a session the server forgot （F2：推送 401 必须清会话）', () {
    test('pushNow 401 → logged OUT and the stored record is wiped', () async {
      // The phone only touches the API when a config field actually changes,
      // and the TTL only slides when it is used — so an idle day kills the
      // token. Logging the 401 and keeping isLoggedIn true meant the device
      // never published again, with nothing to say so and no re-login hook.
      client = _FakeClient(
          pushError: const AdminAuthException(401, 'session expired'));
      await build(autoPush: false);
      // login() itself doesn't push, so we still get a session first.
      await ctrl.login(username: 'admin', password: 'pw');
      store.session = const AdminSession(baseUrl: '', token: 'tok-1');
      await container
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(webdavUrl: 'https://dav.x'));

      await expectLater(
          ctrl.pushNow(), throwsA(isA<AdminAuthException>()));

      expect(ctrl.isLoggedIn, isFalse,
          reason: 'a rejected token is not a session');
      expect(store.session, isNull,
          reason: 'the persisted record must not resurrect a dead token');
    });

    test('a NON-auth push failure keeps the session （网络抖动不等于登出）',
        () async {
      client = _FakeClient(
          pushError: const AdminConfigException(0, '无法连接到服务器'));
      await build(autoPush: false);
      await ctrl.login(username: 'admin', password: 'pw');
      store.session = const AdminSession(baseUrl: '', token: 'tok-1');
      await container
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(webdavUrl: 'https://dav.x'));

      await expectLater(
          ctrl.pushNow(), throwsA(isA<AdminConfigException>()));

      expect(ctrl.isLoggedIn, isTrue);
      expect(store.session, isNotNull);
    });

    test('auto-push 401 stops the device silently retrying forever', () async {
      client = _FakeClient(
          pushError: const AdminAuthException(401, 'session expired'));
      await build();
      await ctrl.login(username: 'admin', password: 'pw');
      await container
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(webdavUrl: 'https://dav.phone'));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(ctrl.isLoggedIn, isFalse);
      // A second edit must not even schedule a push now.
      await container
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(webdavUser: 'u2'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(client.tokensSeen.where((t) => t == 'tok-1').length, 2,
          reason: 'one fetch at login + exactly one rejected push');
    });
  });

  group('a config we can\'t apply （F6 第二层：兜底）', () {
    test('login still SUCCEEDS when applying the remote config throws',
        () async {
      // ConfigPayload.applyTo type-filters the keys it knows about; this is the
      // backstop for whatever it doesn't. The failure it prevents is the nasty
      // one: the session is already established, so the user has typed the
      // right password — and then gets a raw Dart error and can never get in,
      // with no client-side way to repair the stored config.
      client.stored = {'_schema': 1, 'webdavUrl': 'https://dav.example.com'};
      final provider = Provider<ConfigSyncController>((ref) =>
          ConfigSyncController(ref,
              clientFactory: (_) => client,
              sessionStore: store,
              autoPush: false));
      container = ProviderContainer(overrides: [
        settingsProvider.overrideWith(
            (ref) => _ExplodingSettings(ref.read(prefsStoreProvider))),
      ]);
      ctrl = container.read(provider);
      while (!container.read(settingsProvider).loaded) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // Must not throw, and must leave us logged in.
      expect(await ctrl.login(username: 'admin', password: 'pw'), isFalse);
      expect(ctrl.isLoggedIn, isTrue,
          reason: 'an unreadable config is not a failed login');
      expect(client.fetchCalls, 1);
    });
  });

  group('configDigest （F9：键序无关必须是真的）', () {
    // configDigest is static and needs nothing, but the file-level tearDown
    // disposes `ctrl`/`container` — so give it something to dispose.
    setUp(() => build(autoPush: false));

    test('only the NESTED key order differs → same digest', () {
      // musicCredentials is the payload's one nested value. Sorting just the
      // top level was enough only because the console hands the raw request
      // bytes back verbatim; the day it round-trips through a JSON value type
      // (which sorts keys) the dedupe would silently stop working and every
      // launch would re-upload a byte-identical config.
      final a = <String, dynamic>{
        '_schema': 1,
        'webdavUrl': 'https://dav.x',
        'musicCredentials': {'netease': 'n', 'spotify': 's', 'joox': 'j'},
      };
      final b = <String, dynamic>{
        'musicCredentials': {'spotify': 's', 'joox': 'j', 'netease': 'n'},
        'webdavUrl': 'https://dav.x',
        '_schema': 1,
      };
      expect(ConfigSyncController.configDigest(a),
          ConfigSyncController.configDigest(b));
    });

    test('nested CONTENT still changes the digest', () {
      expect(
        ConfigSyncController.configDigest({
          '_schema': 1,
          'musicCredentials': {'netease': 'n'},
        }),
        isNot(ConfigSyncController.configDigest({
          '_schema': 1,
          'musicCredentials': {'netease': 'CHANGED'},
        })),
      );
    });

    test('list ORDER is content and must change the digest', () {
      expect(
        ConfigSyncController.configDigest({'k': ['a', 'b']}),
        isNot(ConfigSyncController.configDigest({'k': ['b', 'a']})),
      );
    });
  });

  group('auto-push is native-only', () {
    test('web (autoPush off): a local settings edit is NEVER pushed', () async {
      // The browser build is a viewer. It applies the config it pulled, which
      // is itself a settings change — echoing that back would let any
      // incidental local edit overwrite what the phone published.
      await build(autoPush: false);
      await ctrl.login(username: 'admin', password: 'pw');

      await container
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(webdavUrl: 'https://changed-in-browser'));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(client.pushes, isEmpty,
          reason: 'the read-only build must not write the config back');
    });

    test('native (default): a local settings edit is pushed after the debounce',
        () async {
      await build(); // default autoPush == !kIsWeb, i.e. on for this VM run
      await ctrl.login(username: 'admin', password: 'pw');

      await container
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(webdavUrl: 'https://dav.phone'));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(client.pushes, hasLength(1));
      expect(client.pushes.single['webdavUrl'], 'https://dav.phone');
    });

    test('rapid edits coalesce into ONE push (the debounce still holds)',
        () async {
      await build();
      await ctrl.login(username: 'admin', password: 'pw');

      for (final v in ['a', 'ab', 'abc', 'abcd']) {
        await container
            .read(settingsProvider.notifier)
            .update((p) => p.copyWith(webdavUser: v));
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(client.pushes, hasLength(1));
      expect(client.pushes.single['webdavUser'], 'abcd');
    });

    test('applying a pulled config does not bounce it straight back up',
        () async {
      client.stored = {'_schema': 1, 'webdavUrl': 'https://dav.example.com'};
      await build();
      await ctrl.login(username: 'admin', password: 'pw');
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(client.pushes, isEmpty,
          reason: 'the pull itself must not look like a local edit');
    });
  });
}
