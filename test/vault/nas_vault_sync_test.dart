import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/core/prefs.dart';
import 'package:explore_journal/services/vault/nas_token_store.dart';
import 'package:explore_journal/services/vault/nas_vault_client.dart';
import 'package:explore_journal/services/vault/settings_vault.dart';
import 'package:explore_journal/services/vault/vault_payload.dart';
import 'package:explore_journal/services/vault/vault_sync_controller.dart';

/// In-memory NAS — enough to exercise the auth + vault contract (salt, CAS,
/// 404) without a server. The server never sees the password, only authVerifier.
class FakeNasVaultClient implements NasVaultClient {
  final Map<String, _Acct> _byEmail = {};
  final Map<String, String> _tokenToEmail = {};

  bool hasVault(String email) => _byEmail[email]?.blob != null;

  @override
  Future<String> getSalt(String email) async {
    final a = _byEmail[email];
    // Real salt if known; deterministic pseudo-salt otherwise (anti-enum).
    return base64.encode(a?.salt ?? utf8.encode('pseudo:$email').sublist(0, 16));
  }

  @override
  Future<NasSession> register(
      String email, List<int> authVerifier, List<int> salt) async {
    if (_byEmail.containsKey(email)) {
      throw const NasAuthException(409, 'email taken');
    }
    _byEmail[email] = _Acct(Uint8List.fromList(salt), authVerifier);
    final tok = 'tok:$email';
    _tokenToEmail[tok] = email;
    return NasSession(tok, email, 0);
  }

  @override
  Future<NasSession> login(String email, List<int> authVerifier) async {
    final a = _byEmail[email];
    if (a == null || !_listEq(a.authVerifier, authVerifier)) {
      throw const NasAuthException(401, 'bad credentials');
    }
    final tok = 'tok:$email';
    _tokenToEmail[tok] = email;
    return NasSession(tok, email, a.version);
  }

  @override
  Future<VaultFetch?> getVault(String token) async {
    final a = _byEmail[_tokenToEmail[token]];
    if (a?.blob == null) return null;
    return VaultFetch(a!.blob!, a.version);
  }

  @override
  Future<int> putVault(String token, List<int> bytes,
      {required int ifMatch}) async {
    final a = _byEmail[_tokenToEmail[token]!]!;
    if (ifMatch != a.version) throw VaultConflict(a.version);
    a.blob = Uint8List.fromList(bytes);
    a.version += 1;
    return a.version;
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Acct {
  final Uint8List salt;
  final List<int> authVerifier;
  Uint8List? blob;
  int version = 0;
  _Acct(this.salt, this.authVerifier);
}

void main() {
  const pw = 'correct horse battery staple';
  const vault = SettingsVault();

  group('NAS vault contract + crypto (two-device, no server)', () {
    test('device B opens what device A sealed under the shared account salt',
        () async {
      final nas = FakeNasVaultClient();

      // ── Device A: register + push its settings ────────────────────────
      final salt = SettingsVault.randomSalt();
      final aKeys = await SettingsVault.derive(pw, salt: salt);
      final aSession = await nas.register('me@x.com', aKeys.authVerifier, salt);
      const aSettings = AppSettings(
        webdavUrl: 'https://dav.example.com',
        webdavPass: 'shared-secret',
        syncBackend: 'webdav',
      );
      final aBlob =
          await vault.encrypt(VaultPayload.extract(aSettings), aKeys.vaultKey, salt);
      await nas.putVault(aSession.token, aBlob.toBytes(), ifMatch: 0);

      // ── Device B: login (same pw) → derive same key → pull → apply ─────
      final bSaltB64 = await nas.getSalt('me@x.com');
      final bKeys =
          await SettingsVault.derive(pw, salt: base64.decode(bSaltB64));
      final bSession = await nas.login('me@x.com', bKeys.authVerifier);
      final fetched = await nas.getVault(bSession.token);
      expect(fetched, isNotNull);
      final bPayload =
          await vault.decrypt(VaultBlob.fromBytes(fetched!.bytes), bKeys.vaultKey);
      final bSettings = bPayload.applyTo(const AppSettings());

      expect(bSettings.webdavPass, 'shared-secret');
      expect(bSettings.webdavUrl, 'https://dav.example.com');
      expect(bSettings.syncBackend, 'webdav');
    });

    test('login with the wrong password is rejected by the server', () async {
      final nas = FakeNasVaultClient();
      final salt = SettingsVault.randomSalt();
      final k = await SettingsVault.derive(pw, salt: salt);
      await nas.register('me@x.com', k.authVerifier, salt);

      final wrong = await SettingsVault.derive('totally wrong password', salt: salt);
      await expectLater(
        nas.login('me@x.com', wrong.authVerifier),
        throwsA(isA<NasAuthException>()),
      );
    });

    test('stale If-Match raises VaultConflict (optimistic concurrency)',
        () async {
      final nas = FakeNasVaultClient();
      final salt = SettingsVault.randomSalt();
      final k = await SettingsVault.derive(pw, salt: salt);
      final s = await nas.register('me@x.com', k.authVerifier, salt);
      final blob =
          await vault.encrypt(const VaultPayload({'_schema': 1}), k.vaultKey, salt);
      await nas.putVault(s.token, blob.toBytes(), ifMatch: 0); // → v1
      await expectLater(
        nas.putVault(s.token, blob.toBytes(), ifMatch: 0), // stale base
        throwsA(isA<VaultConflict>()),
      );
    });
  });

  group('VaultSyncController (register → push → pull → apply)', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('register pushes a blob; pull restores a wiped local secret', () async {
      final nas = FakeNasVaultClient();
      final tokenStore = MemoryNasTokenStore();
      final container = ProviderContainer(overrides: [
        vaultSyncControllerProvider.overrideWith((ref) => VaultSyncController(
              ref,
              clientFactory: (_) => nas,
              tokenStore: tokenStore,
            )),
      ]);
      addTearDown(container.dispose);

      // Let SettingsNotifier finish its async load from (empty) mock prefs.
      container.read(settingsProvider);
      await pumpEventQueue();

      await container.read(settingsProvider.notifier).update((p) =>
          p.copyWith(webdavUrl: 'https://dav.x', webdavPass: 'devicesecret'));

      final ctrl = container.read(vaultSyncControllerProvider);
      await ctrl.register(
        serverUrl: 'http://nas.local:48080',
        email: 'a@b.c',
        password: pw,
      );

      expect(nas.hasVault('a@b.c'), isTrue, reason: 'register must push');
      expect(await tokenStore.read(), isNotNull, reason: 'token persisted');

      // Wipe the local secret, then pull it back from the remote vault.
      await container
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(webdavPass: ''));
      await ctrl.pullAndApply();
      expect(container.read(settingsProvider).webdavPass, 'devicesecret');

      // Logout clears the token but NOT local data.
      await ctrl.logout();
      expect(await tokenStore.read(), isNull);
      expect(container.read(settingsProvider).webdavPass, 'devicesecret');
    });
  });
}
