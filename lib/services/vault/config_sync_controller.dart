import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/prefs.dart';
import 'admin_config_client.dart';
import 'admin_session_store.dart';
import 'config_payload.dart';

/// Keeps the roaming settings config in step with the console server: log in,
/// pull the stored config down onto local settings (local-first overlay), and —
/// on the phone — push local edits back up.
///
/// **Session lifetime**: the bearer token is all there is, and on WEB it's
/// persisted via [AdminSessionStore] so a page refresh silently resumes instead
/// of bouncing to the login page (see [restoreSession]); logout wipes it.
class ConfigSyncController {
  final Ref ref;
  final AdminConfigClient Function(String baseUrl) _clientFactory;
  final AdminSessionStore _sessionStore;
  final Duration _debounceWindow;

  /// Whether local settings edits are pushed back to the server on their own.
  ///
  /// OFF on web, and that asymmetry is the point: the browser build is a
  /// viewer, and [pullAndApply] itself mutates local settings — with auto-push
  /// armed it would echo the config straight back, and worse, any incidental
  /// local change in the browser would overwrite the authoritative config the
  /// phone pushed. Injectable so a VM test can exercise both sides.
  final bool _autoPush;

  ConfigSyncController(
    this.ref, {
    AdminConfigClient Function(String baseUrl)? clientFactory,
    AdminSessionStore? sessionStore,
    bool autoPush = !kIsWeb,
    Duration pushDebounce = const Duration(seconds: 5),
  })  : _clientFactory = clientFactory ?? HttpAdminConfigClient.new,
        _sessionStore = sessionStore ?? PrefsAdminSessionStore(),
        _autoPush = autoPush,
        _debounceWindow = pushDebounce {
    if (_autoPush) {
      // Debounced auto-push on any settings change, once we hold a token.
      ref.listen<AppSettings>(settingsProvider, (_, __) => _schedulePush());
    }
  }

  AdminConfigClient? _client;
  String? _token;
  String? _lastPushedHash;
  bool _applyingRemote = false;
  Timer? _debounce;

  bool get isLoggedIn => _token != null;

  /// Validate + normalize the console base URL. The user's own NAS is
  /// frequently a LAN host (http://192.168.x.x:48080), so — unlike proxy
  /// targets — private addresses and plain http are ALLOWED here (this is the
  /// server the user explicitly trusts); we only require a parseable absolute
  /// http(s) URL.
  static String normalizeServerUrl(String raw) {
    final s = raw.trim();
    final u = Uri.tryParse(s);
    if (u == null || !u.hasScheme || (u.scheme != 'http' && u.scheme != 'https') ||
        u.host.isEmpty) {
      throw ArgumentError('后端地址需为 http(s):// 开头的完整 URL');
    }
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  /// Log into the console and pull its config down (local-first merge).
  ///
  /// An empty [serverUrl] means same-origin — the browser build has no address
  /// to ask for, since the console serves the page and sends no CORS headers.
  /// Returns the server's own report of whether the admin password is still
  /// the shipped default.
  Future<bool> login({
    String serverUrl = '',
    required String username,
    required String password,
  }) async {
    final url = serverUrl.trim().isEmpty ? '' : normalizeServerUrl(serverUrl);
    final client = _clientFactory(url);
    final result = await client.login(username, password);
    await _adoptSession(client, url, result.token);
    await pullAndApply();
    return result.isDefaultPassword;
  }

  Future<void> _adoptSession(
      AdminConfigClient client, String url, String token) async {
    _client = client;
    _token = token;
    // Web: persist the resumable session so a page refresh doesn't log the
    // user out.
    if (kIsWeb) {
      await _sessionStore.write(AdminSession(baseUrl: url, token: token));
    }
    // Remember where the console is (never the token) so the next login on
    // this device prefills.
    if (url.isNotEmpty) {
      await ref
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(nasServerUrl: url));
    }
  }

  /// Silently resume a previously persisted session (web refresh). Returns
  /// true when the stored token is still accepted by the server; any failure
  /// (expired token, unreachable server, corrupt record) clears the session and
  /// returns false so the router falls back to the login page.
  Future<bool> restoreSession() async {
    final s = await _sessionStore.read();
    if (s == null) return false;
    try {
      _client = _clientFactory(s.baseUrl);
      _token = s.token;
      // Validates the token AND applies the stored sync config in one go
      // (an expired/revoked token throws here).
      await pullAndApply();
      if (s.baseUrl.isNotEmpty) {
        await ref
            .read(settingsProvider.notifier)
            .update((p) => p.copyWith(nasServerUrl: s.baseUrl));
      }
      return true;
    } catch (e) {
      debugPrint('[ConfigSync] session restore failed: $e');
      await logout();
      return false;
    }
  }

  /// PUT the current settings subset. No-op if not logged in, or if the config
  /// is byte-identical to the last push.
  Future<bool> pushNow({bool force = false}) async {
    final client = _client;
    final token = _token;
    if (client == null || token == null) return false;
    final cfg = ConfigPayload.extract(ref.read(settingsProvider)).toJson();
    final hash = _hash(cfg);
    if (!force && hash == _lastPushedHash) return false;
    await client.push(token, cfg);
    _lastPushedHash = hash;
    return true;
  }

  /// Pull the stored config and overlay it onto local settings (local-first:
  /// empty/absent remote values never clobber a local secret).
  Future<void> pullAndApply() async {
    final client = _client;
    final token = _token;
    if (client == null || token == null) return;
    final cfg = await client.fetch(token);
    if (cfg == null) return; // server has no config yet
    final payload = ConfigPayload.fromJson(cfg);
    _applyingRemote = true;
    try {
      await ref.read(settingsProvider.notifier).update(payload.applyTo);
    } finally {
      _applyingRemote = false;
    }
    // Reflect what the server holds so the apply-triggered listener doesn't
    // immediately push the same content back.
    _lastPushedHash = _hash(cfg);
  }

  /// Clear the session. Does NOT touch local data (local-first) — only the
  /// token and the persisted web session record. The server-side session is
  /// dropped too, best-effort: a console we can't reach expires it on its own
  /// TTL, and that must not make logging out fail.
  Future<void> logout() async {
    final client = _client;
    final token = _token;
    _debounce?.cancel();
    _token = null;
    _lastPushedHash = null;
    _client = null;
    await _sessionStore.clear();
    if (client != null && token != null) {
      try {
        await client.logout(token);
      } catch (e) {
        debugPrint('[ConfigSync] server-side logout failed: $e');
      }
    }
  }

  void _schedulePush() {
    if (_applyingRemote || !isLoggedIn) return;
    _debounce?.cancel();
    _debounce = Timer(_debounceWindow, () {
      pushNow().catchError((e) {
        debugPrint('[ConfigSync] auto-push failed: $e');
        return false;
      });
    });
  }

  void dispose() => _debounce?.cancel();

  /// Key-order-independent digest, so a pull followed by an identical
  /// re-extract dedupes instead of round-tripping the same config forever.
  static String _hash(Map<String, dynamic> cfg) {
    final keys = cfg.keys.toList()..sort();
    final canonical = jsonEncode({for (final k in keys) k: cfg[k]});
    return md5.convert(utf8.encode(canonical)).toString();
  }
}
