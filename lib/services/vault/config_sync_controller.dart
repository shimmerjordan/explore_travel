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

/// What [ConfigSyncController.logout] actually managed to do.
///
/// Logging out never fails locally, so this is not an error channel — it is the
/// one bit of truth the UI needs in order to stop lying to the user.
class LogoutOutcome {
  /// True when the console confirmed `DELETE /api/session`.
  ///
  /// False means the server-side session is still alive until its sliding TTL
  /// expires — and in a browser so is the `ej_session` cookie, which the server
  /// treats as bearer-equivalent. On a shared machine that is the difference
  /// between "logged out" and "the next person can GET /api/config and read
  /// every credential in it", so it has to be surfaced, not just logged.
  final bool serverNotified;
  const LogoutOutcome({required this.serverNotified});
}

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
  String? _sessionBaseUrl;
  String? _lastPushedHash;
  bool _applyingRemote = false;
  Timer? _debounce;

  bool get isLoggedIn => _token != null;

  /// Which console the CURRENT session belongs to — the normalized base URL the
  /// token was issued by (empty string = same-origin web). Null when logged out.
  ///
  /// Read-only, and it exists because the obvious substitute is wrong: a UI
  /// asking "is the session I hold for the host in the address box?" used to
  /// compare against `AppSettings.nasServerUrl`, which is a *persisted settings
  /// field* — every restore path (OneDrive, local folder, zip import) overwrites
  /// the whole settings map and reloads, so a restore taken on another device
  /// silently rewrites the yardstick. The check then answers about the wrong
  /// host, and the next push ships every credential to the console the session
  /// was actually opened against while reporting success. This value is the
  /// session's own property; nothing outside [_adoptSession] can rewrite it.
  String? get sessionBaseUrl => _token == null ? null : _sessionBaseUrl;

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
    _sessionBaseUrl = url;
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
  /// true when the stored token is still accepted by the server.
  ///
  /// **Only a 401 discards the stored record.** Everything else — a NAS
  /// container mid-restart, a dropped wifi association, a DNS or TLS hiccup,
  /// even a server-side 500 — leaves the record in place and just reports "not
  /// resumed", so the very next refresh can try again. Treating those as "not
  /// logged in" (which is what a bare `catch` did) deleted a perfectly valid
  /// token at the single most likely moment for the request to fail: the user
  /// reloading the page right after restarting the console.
  Future<bool> restoreSession() async {
    final s = await _sessionStore.read();
    if (s == null) return false;
    try {
      _client = _clientFactory(s.baseUrl);
      _token = s.token;
      _sessionBaseUrl = s.baseUrl;
      // Validates the token AND applies the stored sync config in one go
      // (an expired/revoked token throws here).
      await pullAndApply();
      if (s.baseUrl.isNotEmpty) {
        await ref
            .read(settingsProvider.notifier)
            .update((p) => p.copyWith(nasServerUrl: s.baseUrl));
      }
      return true;
    } on AdminAuthException catch (e) {
      debugPrint('[ConfigSync] stored session rejected (401), dropping it: $e');
      await _forgetSession();
      return false;
    } catch (e) {
      // Transport-level: the token may well still be good. Drop the in-memory
      // half only, KEEP the persisted record.
      debugPrint('[ConfigSync] session restore deferred, record kept: $e');
      _debounce?.cancel();
      _token = null;
      _sessionBaseUrl = null;
      _client = null;
      _lastPushedHash = null;
      return false;
    }
  }

  /// PUT the current settings subset. No-op if not logged in, or if the config
  /// is byte-identical to the last push.
  ///
  /// A 401 here means the session died while nothing was using it (the TTL
  /// slides only on use, and a console restart invalidates every session), so
  /// it drops the session instead of logging and carrying on. The phone only
  /// touches the API when a config field actually changes, so "log it and keep
  /// `isLoggedIn` true" meant one idle day turned the device into a client that
  /// silently never published again. The exception is still rethrown — the
  /// caller decides whether that is worth showing.
  Future<bool> pushNow({bool force = false}) async {
    final client = _client;
    final token = _token;
    if (client == null || token == null) return false;
    final cfg = ConfigPayload.extract(ref.read(settingsProvider)).toJson();
    final hash = configDigest(cfg);
    if (!force && hash == _lastPushedHash) return false;
    try {
      await client.push(token, cfg);
    } on AdminAuthException catch (e) {
      debugPrint('[ConfigSync] push rejected (401) — session dropped, '
          're-login required: $e');
      await _forgetSession();
      rethrow;
    }
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
    } catch (e) {
      // A config we can't read must not be a config we can't LOG IN past.
      // [ConfigPayload.applyTo] already type-filters the fields it knows; this
      // is the backstop for whatever it doesn't — the alternative is a Dart
      // type error on the login screen with correct credentials and no
      // client-side way to repair the stored config.
      debugPrint('[ConfigSync] stored config could not be applied, '
          'continuing with local settings: $e');
    } finally {
      _applyingRemote = false;
    }
    // Reflect what the server holds so the apply-triggered listener doesn't
    // immediately push the same content back.
    _lastPushedHash = configDigest(cfg);
  }

  /// Clear the session. Does NOT touch local data (local-first) — only the
  /// token and the persisted web session record.
  ///
  /// Never throws: the local half has already happened by the time the network
  /// call runs, and a console we can't reach expires the session on its own
  /// TTL. But the caller is told whether the server was actually notified (see
  /// [LogoutOutcome.serverNotified]) — one retry first, because the common
  /// cause is a single dropped request rather than a down server.
  Future<LogoutOutcome> logout() async {
    final client = _client;
    final token = _token;
    await _forgetSession();
    if (client == null || token == null) {
      return const LogoutOutcome(serverNotified: true); // nothing to notify
    }
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await client.logout(token);
        return const LogoutOutcome(serverNotified: true);
      } catch (e) {
        debugPrint('[ConfigSync] server-side logout failed '
            '(attempt $attempt/2): $e');
        if (attempt == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    }
    return const LogoutOutcome(serverNotified: false);
  }

  /// Forget everything that makes this controller "logged in", including the
  /// persisted web record. Local-only — never talks to the server.
  Future<void> _forgetSession() async {
    _debounce?.cancel();
    _token = null;
    _sessionBaseUrl = null;
    _lastPushedHash = null;
    _client = null;
    await _sessionStore.clear();
  }

  void _schedulePush() {
    if (_applyingRemote || !isLoggedIn) return;
    _debounce?.cancel();
    _debounce = Timer(_debounceWindow, () {
      // A 401 has already dropped the session inside pushNow, so this logs the
      // last failure rather than the first of an endless silent series.
      pushNow().catchError((e) {
        debugPrint('[ConfigSync] auto-push failed: $e');
        return false;
      });
    });
  }

  void dispose() => _debounce?.cancel();

  /// Key-order-independent digest, so a pull followed by an identical
  /// re-extract dedupes instead of round-tripping the same config forever.
  ///
  /// Canonicalization is RECURSIVE. Sorting only the top level was enough by
  /// accident — the console stores the raw request bytes and hands them back
  /// verbatim, so nested key order round-trips today. The moment it parses into
  /// a `serde_json::Value` and re-serializes (which sorts keys), a nested
  /// reorder would change the digest and the dedupe would quietly stop working:
  /// every launch re-uploading a byte-identical config forever.
  static String configDigest(Map<String, dynamic> cfg) =>
      md5.convert(utf8.encode(jsonEncode(_canonical(cfg)))).toString();

  /// Maps sorted by key at every depth; lists keep their order (in a JSON
  /// config, list order IS content).
  static Object? _canonical(Object? v) {
    if (v is Map) {
      final entries = v.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return <String, Object?>{
        for (final e in entries) e.key.toString(): _canonical(e.value),
      };
    }
    if (v is List) return v.map(_canonical).toList();
    return v;
  }
}
