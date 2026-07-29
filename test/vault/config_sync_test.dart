import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/services/vault/admin_config_client.dart';
import 'package:explore_journal/services/vault/admin_session_store.dart';
import 'package:explore_journal/services/vault/config_sync_controller.dart';

/// In-memory console: one stored config, one token, and a record of every call.
class _FakeClient implements AdminConfigClient {
  Map<String, dynamic>? stored;
  final bool isDefaultPassword;
  bool failLogoutCall;

  final List<Map<String, dynamic>> pushes = [];
  int fetchCalls = 0;
  int logoutCalls = 0;
  final List<String> tokensSeen = [];

  _FakeClient({
    this.isDefaultPassword = false,
    this.failLogoutCall = false,
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
    pushes.add(Map<String, dynamic>.from(cfg));
    stored = Map<String, dynamic>.from(cfg);
  }

  @override
  Future<void> logout(String token) async {
    logoutCalls++;
    if (failLogoutCall) throw const AdminConfigException(0, '无法连接到服务器');
  }
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
