import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show md5;
import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/prefs.dart';
import 'nas_token_store.dart';
import 'nas_vault_client.dart';
import 'settings_vault.dart';
import 'vault_payload.dart';

/// Drives the mobile side of the zero-knowledge vault: derive keys from the
/// login password, push the encrypted settings blob to the NAS, and pull a
/// peer device's blob down (local-first merge).
///
/// **Salt model**: the KDF salt is per-ACCOUNT (created once at register,
/// returned by `GET /auth/salt`), NOT per-blob-random — so every device with
/// the same password derives the *same* `vaultKey`/`authVerifier`. Hence this
/// controller uses [SettingsVault.derive]/`encrypt`/`decrypt` with that fixed
/// salt rather than `seal`/`open` (which mint a fresh random salt).
///
/// **Session lifetime**: `vaultKey` lives only in memory. After an app restart
/// the token may still be valid but the key is gone, so vault writes are
/// skipped until the user logs in again (re-enters the password). v1 limitation.
class VaultSyncController {
  final Ref ref;
  final NasVaultClient Function(String baseUrl) _clientFactory;
  final NasTokenStore _tokenStore;
  final SettingsVault _vault;

  VaultSyncController(
    this.ref, {
    NasVaultClient Function(String baseUrl)? clientFactory,
    NasTokenStore? tokenStore,
    SettingsVault vault = const SettingsVault(),
  })  : _clientFactory = clientFactory ?? HttpNasVaultClient.new,
        _tokenStore = tokenStore ?? SecureNasTokenStore(),
        _vault = vault {
    // Debounced auto-push on any settings change, once we hold a key.
    ref.listen<AppSettings>(settingsProvider, (_, __) => _schedulePush());
  }

  NasVaultClient? _client;
  String? _token;
  SecretKey? _vaultKey;
  Uint8List? _salt; // account salt
  int _version = 0;
  String? _lastPushedHash;
  bool _applyingRemote = false;
  Timer? _debounce;

  bool get isLoggedIn => _token != null && _vaultKey != null;

  static const _debounceWindow = Duration(seconds: 5);

  /// Validate + normalize the NAS base URL. The user's own NAS is frequently a
  /// LAN host (http://192.168.x.x:48080), so — unlike proxy targets — private
  /// addresses and plain http are ALLOWED here (this is the server the user
  /// explicitly trusts); we only require a parseable absolute http(s) URL.
  static String normalizeServerUrl(String raw) {
    final s = raw.trim();
    final u = Uri.tryParse(s);
    if (u == null || !u.hasScheme || (u.scheme != 'http' && u.scheme != 'https') ||
        u.host.isEmpty) {
      throw ArgumentError('NAS 地址需为 http(s):// 开头的完整 URL');
    }
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  /// Create a brand-new NAS account, then push the current local settings up.
  Future<void> register({
    required String serverUrl,
    required String email,
    required String password,
  }) async {
    if (password.length < SettingsVault.minPasswordLength) {
      throw VaultWeakPasswordException(
          '口令至少需要 ${SettingsVault.minPasswordLength} 个字符');
    }
    final url = normalizeServerUrl(serverUrl);
    final client = _clientFactory(url);
    final salt = _randomSalt();
    final keys = await SettingsVault.derive(password, salt: salt);
    final session = await client.register(email, keys.authVerifier, salt);
    await _adoptSession(client, url, email, salt, keys.vaultKey, session);
    await pushNow(force: true);
  }

  /// Log into an existing account and pull its vault down (local-first merge).
  Future<void> login({
    required String serverUrl,
    required String email,
    required String password,
  }) async {
    final url = normalizeServerUrl(serverUrl);
    final client = _clientFactory(url);
    final saltB64 = await client.getSalt(email);
    final salt = base64.decode(saltB64);
    final keys = await SettingsVault.derive(password, salt: salt);
    final session = await client.login(email, keys.authVerifier);
    await _adoptSession(client, url, email, salt, keys.vaultKey, session);
    await pullAndApply();
  }

  Future<void> _adoptSession(NasVaultClient client, String url, String email,
      Uint8List salt, SecretKey vaultKey, NasSession session) async {
    _client = client;
    _token = session.token;
    _vaultKey = vaultKey;
    _salt = salt;
    _version = session.vaultVersion;
    await _tokenStore.write(session.token);
    // Persist non-secret NAS config (never the token).
    await ref.read(settingsProvider.notifier).update((p) => p.copyWith(
          nasServerUrl: url,
          nasAccountEmail: email,
          nasKdfSalt: base64.encode(salt),
        ));
  }

  /// Encrypt the current settings subset and PUT it. No-op if not logged in or
  /// if the blob is byte-identical to the last push.
  Future<bool> pushNow({bool force = false}) async {
    final client = _client;
    final key = _vaultKey;
    final salt = _salt;
    final token = _token;
    if (client == null || key == null || salt == null || token == null) {
      return false;
    }
    final payload = VaultPayload.extract(ref.read(settingsProvider));
    final blob = await _vault.encrypt(payload, key, salt);
    final bytes = blob.toBytes();
    final hash = md5.convert(bytes).toString();
    if (!force && hash == _lastPushedHash) return false;

    try {
      _version = await client.putVault(token, bytes, ifMatch: _version);
      _lastPushedHash = hash;
      return true;
    } on VaultConflict catch (c) {
      // Another device wrote a newer blob. Pull it, merge (local-first), repush
      // once against the server's version. v1 is last-writer-wins at field
      // granularity (we don't track per-field timestamps yet — see TODO).
      _version = c.currentVersion;
      await pullAndApply();
      final merged = VaultPayload.extract(ref.read(settingsProvider));
      final mergedBytes = (await _vault.encrypt(merged, key, salt)).toBytes();
      _version = await client.putVault(token, mergedBytes, ifMatch: _version);
      _lastPushedHash = md5.convert(mergedBytes).toString();
      return true;
    }
  }

  /// Pull the remote vault and overlay it onto local settings (local-first:
  /// empty/absent remote values never clobber a local secret).
  Future<void> pullAndApply() async {
    final client = _client;
    final key = _vaultKey;
    final token = _token;
    if (client == null || key == null || token == null) return;
    final fetch = await client.getVault(token);
    if (fetch == null) return; // no remote vault yet
    _version = fetch.version;
    final blob = VaultBlob.fromBytes(fetch.bytes);
    final payload = await _vault.decrypt(blob, key);
    _applyingRemote = true;
    try {
      await ref.read(settingsProvider.notifier).update(payload.applyTo);
    } finally {
      _applyingRemote = false;
    }
    // Reflect what we just stored so the apply-triggered listener doesn't
    // immediately re-push the same content.
    _lastPushedHash = md5.convert(blob.toBytes()).toString();
  }

  /// Clear the session. Does NOT touch local data (local-first) — only the
  /// token and the in-memory key.
  Future<void> logout() async {
    _debounce?.cancel();
    _token = null;
    _vaultKey = null;
    _salt = null;
    _version = 0;
    _lastPushedHash = null;
    _client = null;
    await _tokenStore.clear();
  }

  void _schedulePush() {
    if (_applyingRemote || !isLoggedIn) return;
    _debounce?.cancel();
    _debounce = Timer(_debounceWindow, () {
      pushNow().catchError((e) {
        debugPrint('[VaultSync] auto-push failed: $e');
        return false;
      });
    });
  }

  void dispose() => _debounce?.cancel();

  static Uint8List _randomSalt() => SettingsVault.randomSalt();
}
