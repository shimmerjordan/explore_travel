import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart'
    show configSyncControllerProvider, settingsProvider;
import 'package:explore_journal/services/vault/admin_config_client.dart';
import 'package:explore_journal/services/vault/admin_session_store.dart';
import 'package:explore_journal/services/vault/auth_controller.dart'
    show defaultPasswordWarningProvider, kConsoleLogoutNotNotifiedNotice;
import 'package:explore_journal/services/vault/config_payload.dart';
import 'package:explore_journal/services/vault/config_sync_controller.dart';
import 'package:explore_journal/ui/backup/backup_screen.dart'
    show BackupScreen, ConsolePushSection;

/// The address the user types. Also the POSITIVE CONTROL for the
/// "password never lands on disk" test: it must be findable in prefs, which is
/// what proves the absence of the password there is a real absence and not a
/// harness that simply can't see writes.
const _serverUrl = 'http://192.168.1.9:48080';

/// Two consoles, for the tests about which one the held session belongs to.
const _hostA = 'http://host-a:48080';
const _hostB = 'http://host-b:48080';

/// Deliberately distinctive so a substring search can't collide with anything
/// else in the settings JSON.
const _password = 'n0t-on-disk-please-7f3a';

/// Never called — every method the section touches is overridden on the
/// controller below, so the transport is never reached.
class _UnusedClient implements AdminConfigClient {
  @override
  Future<Map<String, dynamic>?> fetch(String token) =>
      throw UnimplementedError();
  @override
  Future<AdminLoginResult> login(String u, String p) =>
      throw UnimplementedError();
  @override
  Future<void> push(String t, Map<String, dynamic> c) =>
      throw UnimplementedError();
  @override
  Future<void> logout(String t) => throw UnimplementedError();
}

/// Records exactly what the section asked the controller to do.
///
/// Subclasses the real controller because [configSyncControllerProvider] is
/// typed on it; `autoPush: false` keeps the base constructor from installing the
/// settings listener, and every method used by the UI is overridden, so no base
/// implementation runs.
///
/// **What that costs**, stated here so it isn't rediscovered later: nothing in
/// this file exercises the real `login` → `_adoptSession` → `pullAndApply`
/// chain, the real `pushNow`'s digest dedupe, the settings listener behind
/// `_schedulePush`, or `logout`'s retry/backoff. The real chain is covered in
/// `config_sync_test.dart` (see the group about the merge-then-republish
/// behaviour this screen's wording had to disclose). The one production
/// behaviour reproduced here rather than stubbed away is the remote-wins merge:
/// [applyOnLogin] runs the genuine [ConfigPayload.applyTo].
class _RecordingSync extends ConfigSyncController {
  // Dart forbids mixing a `super.ref` parameter with an explicit super
  // initializer, and the three arguments below are non-const, so they can't be
  // super-parameter defaults either.
  // ignore: use_super_parameters
  _RecordingSync(Ref ref)
      : super(ref,
            clientFactory: (_) => _UnusedClient(),
            sessionStore: MemoryAdminSessionStore(),
            autoPush: false);

  bool loggedIn = false;

  /// Which console the held session belongs to, mirroring what the real
  /// `_adoptSession` records. Null whenever [loggedIn] is false.
  String? sessionUrl;

  bool isDefaultPassword = false;
  Object? loginError;
  Object? pushError;

  /// Holds `login` (resp. `logout`) open so a test can act while the request is
  /// still in flight.
  Completer<void>? loginGate;
  Completer<void>? logoutGate;

  /// The stored config the server hands back at login, as
  /// `ConfigPayload` fields. Applied through the REAL
  /// [ConfigPayload.applyTo] — the point of these tests is the remote-wins
  /// merge, so faking the merge would fake away the thing under test.
  Map<String, Object?> applyOnLogin = const {};

  /// The real `pushNow` forgets the session on a 401 before it rethrows; this
  /// mirrors that so the UI sees the same state it will see in production.
  bool dropSessionOnPushError = false;

  /// Models the real digest dedupe: a config identical to the last push is
  /// skipped unless `force` is set. The whole point of the manual button is that
  /// it must not be at the mercy of this.
  bool dedupeWouldSkip = true;

  bool logoutServerNotified = true;

  /// Throw from `logout()` — its doc says it never does, but `_forgetSession`
  /// reaches the platform keychain, which can.
  Object? logoutError;

  final List<({String url, String username, String password})> logins = [];
  final List<bool> pushForce = [];
  int logouts = 0;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  String? get sessionBaseUrl => sessionUrl;

  /// A session this device already held when the page opened, as it would look
  /// after a login to [url].
  void assumeSession(String url) {
    loggedIn = true;
    sessionUrl = url;
  }

  @override
  Future<bool> login({
    String serverUrl = '',
    required String username,
    required String password,
  }) async {
    logins.add((url: serverUrl, username: username, password: password));
    final gate = loginGate;
    if (gate != null) await gate.future;
    final e = loginError;
    if (e != null) throw e;
    loggedIn = true;
    sessionUrl = serverUrl;
    if (applyOnLogin.isNotEmpty) {
      // What the real `login` does after adopting the session: pull the stored
      // config and overlay it — non-empty remote values win.
      final payload = ConfigPayload({
        '_schema': ConfigPayload.schemaVersion,
        ...applyOnLogin,
      });
      await ref.read(settingsProvider.notifier).update(payload.applyTo);
    }
    return isDefaultPassword;
  }

  @override
  Future<bool> pushNow({bool force = false}) async {
    pushForce.add(force);
    final e = pushError;
    if (e != null) {
      if (dropSessionOnPushError) {
        loggedIn = false;
        sessionUrl = null;
      }
      throw e;
    }
    if (!loggedIn) return false;
    if (!force && dedupeWouldSkip) return false;
    return true;
  }

  @override
  Future<LogoutOutcome> logout() async {
    logouts++;
    final gate = logoutGate;
    if (gate != null) await gate.future;
    loggedIn = false;
    sessionUrl = null;
    final e = logoutError;
    if (e != null) throw e;
    return LogoutOutcome(serverNotified: logoutServerNotified);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Pump the section on its own. [BackupScreen] itself is a long ListView whose
  /// bottom half is never laid out on a test surface, so nothing in this section
  /// would be findable through the page.
  Future<({ProviderContainer container, _RecordingSync sync})> pump(
    WidgetTester t, {
    void Function(_RecordingSync)? configure,
  }) async {
    late _RecordingSync sync;
    final container = ProviderContainer(overrides: [
      configSyncControllerProvider.overrideWith((ref) {
        sync = _RecordingSync(ref);
        configure?.call(sync);
        return sync;
      }),
    ]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ConsolePushSection()),
        ),
      ),
    ));
    // Settings load from disk asynchronously.
    for (var i = 0; i < 60 && !container.read(settingsProvider).loaded; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(container.read(settingsProvider).loaded, isTrue);
    return (container: container, sync: sync);
  }

  /// Frames enough for login → settings save → push to complete. Not
  /// `pumpAndSettle`: the busy tile shows a CircularProgressIndicator, whose
  /// animation never settles.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }
  }

  Finder addressField() => find.byType(TextField).at(0);
  Finder passwordField() => find.byType(TextField).at(2);

  /// Fill the three fields. Order is build order: address, username, password.
  Future<void> fillForm(WidgetTester t,
      {String server = _serverUrl, String password = _password}) async {
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await t.enterText(fields.at(0), server);
    await t.enterText(fields.at(1), 'admin');
    await t.enterText(fields.at(2), password);
    await t.pump();
  }

  group('手动推送', () {
    testWidgets('用的是 force: true —— 否则「没改过」会被当成推送成功', (t) async {
      final h = await pump(t);
      await fillForm(t);

      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);

      expect(h.sync.logins, hasLength(1));
      expect(h.sync.logins.single.url, _serverUrl);
      expect(h.sync.logins.single.username, 'admin');
      // The flag itself, so dropping `force:` from the call site fails here
      // regardless of what the fake does with it.
      expect(h.sync.pushForce, [true],
          reason: '手动点推送的语义是「无条件推一次」，不是「我没改过就什么都不做」');
      // And the user-visible half: with the dedupe armed (dedupeWouldSkip), a
      // non-forced push returns false and this line becomes the failure line.
      expect(find.textContaining('已推送配置到服务器'), findsOneWidget);
      expect(find.text('当前状态：已登录'), findsOneWidget);
    });

    testWidgets('请求在飞时又点一次，不会再登录一次（禁用 tile 挡不住它）', (t) async {
      // The login is held open, which is the real device: two network
      // round-trips plus a prefs write. NO pump between the taps, so no rebuild
      // happens in between — `setState(_busy = true)` only marks this element
      // dirty, and the tile the second tap hits is still the one built while
      // `_busy` was false, with a live `onTap`. Pointer events queued during a
      // dropped frame arrive exactly like this, and so does TalkBack's
      // double-tap-to-activate. Without a guard inside `_run` it costs two of
      // the console's ten logins per minute and two full credential uploads.
      final gate = Completer<void>();
      final h = await pump(t, configure: (s) => s.loginGate = gate);
      await fillForm(t);

      final tile = find.text('登录并推送当前配置');
      await t.tap(tile);
      expect(h.sync.logins, hasLength(1), reason: '第一次点击已经把请求发出去了');
      await t.tap(tile, warnIfMissed: false);

      expect(h.sync.logins, hasLength(1),
          reason: '登录桶是 10 次/分钟，飞行中的第二次点击不能再花掉一次');
      gate.complete();
      await settle(t);
      expect(h.sync.logins, hasLength(1));
      expect(h.sync.pushForce, [true], reason: '也不该推两遍');
    });

    testWidgets('已登录后再推送不再花掉一次登录（限流桶是 10 次/分钟）', (t) async {
      final h = await pump(t, configure: (s) => s.assumeSession(_serverUrl));
      // No password typed at all — an existing session needs none.
      expect(find.text('推送当前配置'), findsOneWidget);

      await t.tap(find.text('推送当前配置'));
      await settle(t);

      expect(h.sync.logins, isEmpty);
      expect(h.sync.pushForce, [true]);
    });

    testWidgets('尾部斜杠不算换了服务器（否则每次都白花一次登录）', (t) async {
      final h = await pump(t, configure: (s) => s.assumeSession(_serverUrl));
      await t.enterText(addressField(), '$_serverUrl/');
      await t.pump();

      expect(find.text('推送当前配置'), findsOneWidget);
      await t.tap(find.text('推送当前配置'));
      await settle(t);
      expect(h.sync.logins, isEmpty);
    });

    testWidgets('大小写不同的同一主机也不算换了服务器（RFC 3986）', (t) async {
      // scheme and host are case-insensitive, so reading these as two servers
      // would force a re-login — and spend one of the ten.
      final h = await pump(t, configure: (s) => s.assumeSession(_hostA));
      await t.enterText(addressField(), 'HTTP://HOST-A:48080');
      await t.pump();

      expect(find.text('推送当前配置'), findsOneWidget);
      await t.tap(find.text('推送当前配置'));
      await settle(t);
      expect(h.sync.logins, isEmpty);
      expect(h.sync.pushForce, [true]);
    });

    testWidgets('改了服务器地址后，握着旧地址的会话不会被拿去推新地址', (t) async {
      // The controller keeps the client it logged in with, so pushing on an old
      // session publishes to the old host — and reports success while the form
      // on screen names a different one.
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({'nasServerUrl': 'http://old-nas:48080'}),
      });
      final h =
          await pump(t, configure: (s) => s.assumeSession('http://old-nas:48080'));
      expect(find.text('推送当前配置'), findsOneWidget,
          reason: '地址没动过时不该逼着重新登录');

      await fillForm(t); // retypes the address to _serverUrl

      expect(find.text('登录并推送当前配置'), findsOneWidget);
      expect(find.textContaining('现有会话属于旧地址'), findsOneWidget);

      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);

      expect(h.sync.logins, hasLength(1));
      expect(h.sync.logins.single.url, _serverUrl,
          reason: '必须登录到界面上写着的那个地址');
      expect(h.sync.pushForce, [true]);
    });
  });

  // The yardstick for "does my session belong to the host on screen" must be
  // the SESSION's own base URL. `AppSettings.nasServerUrl` cannot serve: all
  // four restore actions on this same screen overwrite the whole settings map
  // and reload, and a backup taken on another device carries ITS nasServerUrl.
  group('会话归属不能拿持久化设置当基准', () {
    /// A restore (「从 OneDrive 恢复」/「从本地文件夹导入」/zip 导入) replacing the
    /// settings map with a backup from another device, which named host B.
    Future<void> restoreOverwritesSettings(
        WidgetTester t, ProviderContainer c, String url) async {
      await c
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(nasServerUrl: url));
      await t.pump();
    }

    testWidgets('设置被别的动作改写后，仍认得出会话属于旧主机（假阴性）', (t) async {
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({'nasServerUrl': _hostA}),
      });
      final h = await pump(t, configure: (s) => s.assumeSession(_hostA));
      expect(find.text('推送当前配置'), findsOneWidget);

      await restoreOverwritesSettings(t, h.container, _hostB);
      // The user then points the form at B — matching the just-restored setting.
      await t.enterText(addressField(), _hostB);
      await t.enterText(passwordField(), _password);
      await t.pump();

      expect(find.text('登录并推送当前配置'), findsOneWidget,
          reason: '会话是 A 的，界面写着 B —— 不重新登录就会把全部凭据推给 A 并报成功');
      expect(find.textContaining('现有会话属于旧地址'), findsOneWidget);

      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);
      expect(h.sync.logins, hasLength(1));
      expect(h.sync.logins.single.url, _hostB,
          reason: '要登录到界面上那台，而不是沿用 A 的会话');
    });

    testWidgets('设置被别的动作改写、但地址框没动时，不诬告改过地址（假阳性）', (t) async {
      SharedPreferences.setMockInitialValues({
        'app_settings_v1': jsonEncode({'nasServerUrl': _hostA}),
      });
      final h = await pump(t, configure: (s) => s.assumeSession(_hostA));

      await restoreOverwritesSettings(t, h.container, _hostB);

      expect(find.text('推送当前配置'), findsOneWidget,
          reason: '用户什么都没动，会话仍然属于地址框里的那台 A');
      expect(find.textContaining('服务器地址改过了'), findsNothing);

      await t.tap(find.text('推送当前配置'));
      await settle(t);
      expect(h.sync.logins, isEmpty, reason: '不该白花一次登录桶');
      expect(h.sync.pushForce, [true]);
    });
  });

  group('密码不落盘', () {
    testWidgets('SharedPreferences 与 AppSettings.toJson 里都找不到密码串',
        (t) async {
      // The log channel is checked too: `debugPrint` is the only output this
      // code has, and a password in `adb logcat` is a password on disk on any
      // device with a crash reporter. Restored inside the body — the test
      // framework asserts foundation debug vars are unset before tearDowns run.
      //
      // Scope of this assertion: the WIDGET layer. It proves this screen never
      // hands the password to anything that persists, not that the controller
      // beneath it couldn't — see the note on [_RecordingSync].
      final logs = <String>[];
      final realDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
      try {
        final h = await pump(t);
        await fillForm(t);

        await t.tap(find.text('登录并推送当前配置'));
        await settle(t);

        // Positive control 1: the password really did travel through the code
        // under test, so the absences below are absences and not a no-op test.
        expect(h.sync.logins.single.password, _password);

        final prefs = (await t.runAsync(SharedPreferences.getInstance))!;
        final dump = StringBuffer();
        for (final k in prefs.getKeys()) {
          dump.writeln('$k = ${prefs.get(k)}');
        }
        // Positive control 2: this dump CAN see what the action wrote.
        expect(dump.toString(), contains(_serverUrl),
            reason: '地址应当持久化，否则这份 dump 根本看不见写入，下面的断言就是恒真的');
        expect(dump.toString(), isNot(contains(_password)),
            reason: '密码是配置密文的解密密钥来源，落盘等于把钥匙和保险箱放一起');

        final settingsJson =
            jsonEncode(h.container.read(settingsProvider).toJson());
        expect(settingsJson, contains(_serverUrl));
        expect(settingsJson, isNot(contains(_password)),
            reason: 'toJson 会进备份 zip 与漫游配置，密码不能出现在里面');

        // Positive control 3: the capture really is installed — this flow
        // happens to print nothing, so without a probe the assertion below
        // would pass on an empty list no matter what the code did.
        debugPrint('capture-probe');
        expect(logs, contains('capture-probe'));
        expect(logs.join('\n'), isNot(contains(_password)),
            reason: '密码不得进入任何日志，debugPrint 也不行');
      } finally {
        debugPrint = realDebugPrint;
      }
    });

    testWidgets('推送成功后连输入框里的那份也清掉', (t) async {
      final h = await pump(t);
      await fillForm(t);
      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);

      expect(h.sync.logins.single.password, _password, reason: '确实用过它');
      expect(find.textContaining('已推送配置到服务器'), findsOneWidget);
      expect(t.widget<TextField>(passwordField()).controller!.text, isEmpty,
          reason: '会话令牌已经拿到，明文密码没有任何理由继续留在页面上');
    });

    testWidgets('本地校验拦住空密码，一次请求都不发', (t) async {
      final h = await pump(t);
      await fillForm(t, password: '');

      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);

      expect(h.sync.logins, isEmpty, reason: '空密码不该花掉限流桶里的一次登录');
      expect(h.sync.pushForce, isEmpty);
      expect(find.text('请填写密码'), findsOneWidget);
    });
  });

  group('推送遇 401', () {
    testWidgets('UI 回到「未登录」并给出重新登录入口', (t) async {
      final h = await pump(t, configure: (s) {
        s.pushError = const AdminAuthException(401, 'session expired');
        s.dropSessionOnPushError = true;
      });
      await fillForm(t);

      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);

      // The credential was accepted; it's the session that died.
      expect(h.sync.logins, hasLength(1));
      expect(h.sync.pushForce, [true]);

      expect(find.text('当前状态：未登录'), findsOneWidget,
          reason: 'pushNow 的 401 已经丢弃了会话，界面不能还宣称已登录');
      expect(find.text('重新登录并推送'), findsOneWidget,
          reason: '401 是重新登录入口的挂载点');
      expect(find.text('退出登录'), findsNothing);
      expect(find.textContaining('会话已过期'), findsOneWidget);
      // The login-screen wording for a 401 would send the user hunting for a
      // typo that isn't in the form.
      expect(find.textContaining('用户名或密码错误'), findsNothing);
      // The password is only cleared on a COMPLETED push, so the retry below
      // works without a retype — which is what the 401 line now says.
      expect(t.widget<TextField>(passwordField()).controller!.text, _password);

      // And that entry point actually re-logs-in.
      h.sync.pushError = null;
      await t.tap(find.text('重新登录并推送'));
      await settle(t);
      expect(h.sync.logins, hasLength(2));
      expect(h.sync.pushForce, [true, true]);
      expect(find.text('当前状态：已登录'), findsOneWidget);
    });

    testWidgets('登录本身的 401 仍然说「用户名或密码错误」', (t) async {
      final h = await pump(t, configure: (s) {
        s.loginError = const AdminAuthException(401, 'bad credential');
      });
      await fillForm(t);

      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);

      expect(h.sync.pushForce, isEmpty);
      expect(find.text('用户名或密码错误'), findsOneWidget);
      expect(find.text('重新登录并推送'), findsNothing,
          reason: '密码打错不是会话过期，不该冒出「重新登录」这个说法');
    });
  });

  group('状态显示', () {
    testWidgets('默认密码警告就地显示，并说清去哪儿改', (t) async {
      await pump(t, configure: (s) => s.isDefaultPassword = true);
      await fillForm(t);

      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);

      expect(find.textContaining('admin / admin'), findsOneWidget);
      // Native has no password-change screen, so the notice has to name the
      // place that does.
      expect(find.textContaining('请在浏览器打开 $_serverUrl'), findsOneWidget);
    });

    testWidgets('请求在飞时离开页面，默认密码警告仍然会置位', (t) async {
      final gate = Completer<void>();
      final h = await pump(t, configure: (s) {
        s.isDefaultPassword = true;
        s.loginGate = gate;
      });
      await fillForm(t);
      await t.tap(find.text('登录并推送当前配置'));
      await t.pump();
      expect(h.sync.logins, hasLength(1), reason: '登录请求已经发出去了');
      expect(h.container.read(defaultPasswordWarningProvider), isFalse);

      // Back button while the request is in flight. Server-side the login
      // SUCCEEDS and the session is adopted; this section is the only thing on
      // native that reads the flag, and re-entering the page does not recompute
      // it — so a `mounted` guard here would silently delete the sentence
      // 「你的服务端还是默认口令，任何人都能读走你刚上传的全部凭据」forever.
      await t.pumpWidget(UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      ));
      gate.complete();
      await settle(t);

      expect(h.container.read(defaultPasswordWarningProvider), isTrue);
    });

    testWidgets('登录被远端值覆盖了几项，成功文案要如实报出来', (t) async {
      // Locator keys, not credentials: `PrefsStore.save` routes anything in
      // kVaultSecretKeys through flutter_secure_storage, whose method channel
      // has no implementation under `flutter test` and never completes inside a
      // widget test's fake-async clock. The behaviour under test — remote wins,
      // then the merged result is republished — is identical either way.
      final h = await pump(t,
          configure: (s) => s.applyOnLogin = {
                'webdavUrl': 'https://dav.old.example.com',
                'webdavUser': 'old-user',
              });
      // The phone holds NEWER config that was never published.
      await h.container.read(settingsProvider.notifier).update((p) => p.copyWith(
          webdavUrl: 'https://dav.new.example.com', webdavUser: 'new-user'));
      await t.pump();
      await fillForm(t);

      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);

      // `login` pulled and applied first: remote won, and the push that follows
      // re-uploads the merged result. The button's own subtitle says so; this is
      // the after-the-fact half.
      expect(h.container.read(settingsProvider).webdavUrl,
          'https://dav.old.example.com');
      expect(find.textContaining('2 项'), findsOneWidget,
          reason: '两项本机改动被服务端旧值覆盖后上传，用户必须被告知');
    });

    testWidgets('地址一改，上一次的成功状态行就撤掉', (t) async {
      await pump(t);
      await fillForm(t);
      await t.tap(find.text('登录并推送当前配置'));
      await settle(t);
      expect(find.textContaining('已推送配置到服务器'), findsOneWidget);

      await t.enterText(addressField(), '$_serverUrl/other');
      await t.pump();
      expect(find.textContaining('已推送配置到服务器'), findsNothing,
          reason: '那句话说的是改地址之前那台服务器，不能继续挂着');
    });

    testWidgets('退出登录没能通知服务器时，就地告知（原生不共用 web 的告警条）',
        (t) async {
      final h = await pump(t, configure: (s) {
        s.assumeSession(_serverUrl);
        s.logoutServerNotified = false;
      });

      await t.tap(find.text('退出登录'));
      await settle(t);

      expect(h.sync.logouts, 1);
      // Status line + snackbar: the native shell has no notice bar to reuse.
      expect(find.text(kConsoleLogoutNotNotifiedNotice), findsWidgets);
      expect(find.text('当前状态：未登录'), findsOneWidget);

      // Let the snackbar expire so no timer outlives the test.
      await t.pump(const Duration(seconds: 9));
      await t.pumpAndSettle();
    });

    testWidgets('退出登录也一样：飞行中再点一次不会退两次', (t) async {
      // Same closure-captured `_busy` as the primary action. A second DELETE
      // /api/session is harmless server-side, but it is a request nobody asked
      // for and the second one reports on a session that is already gone.
      final gate = Completer<void>();
      final h = await pump(t, configure: (s) {
        s.assumeSession(_serverUrl);
        s.logoutGate = gate;
      });

      final tile = find.text('退出登录');
      await t.tap(tile);
      expect(h.sync.logouts, 1);
      await t.tap(tile, warnIfMissed: false);
      expect(h.sync.logouts, 1, reason: '飞行中的第二次点击不该再发一次注销');

      gate.complete();
      await settle(t);
      expect(h.sync.logouts, 1);
    });

    testWidgets('退出登录抛异常时也要说话，并清掉默认密码警告', (t) async {
      // `logout()` promises not to throw, but its local half clears the
      // platform keychain through AdminSessionStore — a PlatformException there
      // used to leave the tile blinking once and saying nothing, which reads
      // exactly like success.
      final h = await pump(t, configure: (s) {
        s.assumeSession(_serverUrl);
        s.logoutError = StateError('keychain unavailable');
      });
      h.container.read(defaultPasswordWarningProvider.notifier).state = true;
      await t.pump();

      await t.tap(find.text('退出登录'));
      await settle(t);

      expect(h.sync.logouts, 1);
      expect(find.textContaining('已在本机退出'), findsOneWidget);
      expect(find.text('当前状态：未登录'), findsOneWidget);
      expect(h.container.read(defaultPasswordWarningProvider), isFalse,
          reason: '会话令牌在 logout() 的第一步就丢了，警告不再属于本机');
    });
  });

  testWidgets('分区真的挂在备份页上（而不是只有测试能把它 pump 起来）', (t) async {
    // The section renders fine on its own; this is the other half — that the
    // page actually contains it, below the three sibling sync sections.
    final container = ProviderContainer(overrides: [
      configSyncControllerProvider.overrideWith((ref) => _RecordingSync(ref)),
    ]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: BackupScreen()),
    ));
    for (var i = 0; i < 60 && !container.read(settingsProvider).loaded; i++) {
      await t.pump(const Duration(milliseconds: 10));
    }

    final list = find.byType(Scrollable).first;
    final position = t.state<ScrollableState>(list).position;

    // Compared as SCROLL-ABSOLUTE offsets (scroll offset + on-screen y), one
    // scroll at a time. Reading both dys after a single scroll only worked
    // while the previous section happened to still be inside the ListView's
    // 250px default cacheExtent — a taller section or a different test surface
    // turns that into "Found 0 widgets".
    await t.scrollUntilVisible(find.text('从本地文件夹导入'), 400, scrollable: list);
    final localFolderY =
        position.pixels + t.getTopLeft(find.text('从本地文件夹导入')).dy;

    await t.scrollUntilVisible(find.text('Web 前端 · 配置推送'), 400,
        scrollable: list);
    final consoleY =
        position.pixels + t.getTopLeft(find.text('Web 前端 · 配置推送')).dy;

    expect(find.text('登录并推送当前配置'), findsOneWidget);
    // Order matters: it belongs after the existing sync destinations.
    expect(consoleY, greaterThan(localFolderY));
  });
}
