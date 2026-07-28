import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/services/sync/onedrive_service.dart';
import 'package:explore_journal/services/vault/nas_session_store.dart';
import 'package:explore_journal/services/vault/nas_token_store.dart';
import 'package:explore_journal/services/vault/nas_vault_client.dart';
import 'package:explore_journal/services/vault/vault_sync_controller.dart';

/// NasVaultClient stub: getVault either succeeds with "no vault yet" (null)
/// or throws like an expired token would.
class _FakeClient implements NasVaultClient {
  final Object? getVaultError;
  int getVaultCalls = 0;
  _FakeClient({this.getVaultError});

  @override
  Future<VaultFetch?> getVault(String token) async {
    getVaultCalls++;
    final e = getVaultError;
    if (e != null) throw e;
    return null; // account exists, no vault blob yet — a valid session
  }

  @override
  Future<String> getSalt(String email) async => base64.encode(List.filled(16, 1));
  @override
  Future<NasSession> login(String email, List<int> authVerifier) =>
      throw UnimplementedError();
  @override
  Future<NasSession> register(
          String email, List<int> authVerifier, List<int> salt) =>
      throw UnimplementedError();
  @override
  Future<int> putVault(String token, List<int> bytes,
          {required int ifMatch}) async =>
      1;
}

NasWebSession _session() => NasWebSession(
      serverUrl: 'http://nas.local:48080',
      email: 'me@x.com',
      token: 'jwt-token',
      saltB64: base64.encode(List.filled(16, 7)),
      vaultKeyB64: base64.encode(Uint8List(32)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NasWebSession / PrefsNasSessionStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips through prefs (localStorage on web)', () async {
      final store = PrefsNasSessionStore();
      await store.write(_session());
      final back = await store.read();
      expect(back, isNotNull);
      expect(back!.serverUrl, 'http://nas.local:48080');
      expect(back.email, 'me@x.com');
      expect(back.token, 'jwt-token');
      expect(back.vaultKeyB64, base64.encode(Uint8List(32)));
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('a corrupt/incomplete record reads as null, not a crash', () {
      expect(NasWebSession.fromJson({'serverUrl': 'x'}), isNull);
      expect(NasWebSession.fromJson({}), isNull);
    });
  });

  group('VaultSyncController.restoreSession（刷新后静默恢复）', () {
    late MemoryNasSessionStore store;
    late _FakeClient client;
    late ProviderContainer container;
    late VaultSyncController ctrl;

    Future<void> build() async {
      final provider = Provider<VaultSyncController>((ref) =>
          VaultSyncController(ref,
              clientFactory: (_) => client,
              tokenStore: MemoryNasTokenStore(),
              sessionStore: store));
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
      store = MemoryNasSessionStore();
      client = _FakeClient();
    });

    tearDown(() {
      ctrl.dispose();
      container.dispose();
    });

    test('no stored session → false, no network call', () async {
      await build();
      expect(await ctrl.restoreSession(), isFalse);
      expect(client.getVaultCalls, 0);
      expect(ctrl.isLoggedIn, isFalse);
    });

    test('valid stored session resumes: logged in + NAS config applied',
        () async {
      store.session = _session();
      await build();
      expect(await ctrl.restoreSession(), isTrue);
      expect(ctrl.isLoggedIn, isTrue);
      expect(client.getVaultCalls, 1,
          reason: 'the token must be validated against the server');
      final s = container.read(settingsProvider);
      expect(s.nasServerUrl, 'http://nas.local:48080');
      expect(s.nasAccountEmail, 'me@x.com');
    });

    test('expired/rejected token → false AND the stored session is wiped',
        () async {
      store.session = _session();
      client = _FakeClient(
          getVaultError: const NasAuthException(401, 'token expired'));
      await build();
      expect(await ctrl.restoreSession(), isFalse);
      expect(ctrl.isLoggedIn, isFalse);
      expect(store.session, isNull,
          reason: 'a dead session must not retrigger on every refresh');
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
