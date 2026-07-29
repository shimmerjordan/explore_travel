import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../sync/onedrive_sync_engine.dart';

/// Auth status for the web login gate. `unknown` is the pre-restore state so
/// the router doesn't bounce to /login before we've checked for a session.
enum AuthStatus { unknown, loggedOut, loggedIn }

@immutable
class AuthState {
  final AuthStatus status;
  const AuthState(this.status);
}

/// True while the console still accepts the shipped `admin/admin`. Set from the
/// server's own answer at login, and NOT rendered by the login screen — the
/// router navigates away the instant login succeeds, so anything drawn there
/// would flash past unread.
///
/// **Two renderers, deliberately different ones.** On web the app shell's
/// `builder:` draws it as a notice bar above the router. On native there is no
/// such shell and no router gate to hang one on, so it is rendered in place by
/// the 「Web 前端 · 配置推送」section of the backup screen — the same widget that
/// performs the native login and therefore the only thing that can set this flag
/// on a phone. Wrapping the native `MaterialApp` in the web branch's `builder:`
/// was considered and rejected: a global bar would outlive the section that
/// produced it and duplicate a warning the user is already looking at.
final defaultPasswordWarningProvider = StateProvider<bool>((ref) => false);

/// Non-null while the last logout could NOT be confirmed by the server.
///
/// Set from [LogoutOutcome.serverNotified]; rendered by the app shell next to
/// the default-password warning. Without it the user reads "back at the login
/// page" as "logged out", while the server-side session — and the browser's
/// `ej_session` cookie, which the server accepts in place of a bearer token —
/// stays alive on a possibly shared machine.
final logoutNoticeProvider = StateProvider<String?>((ref) => null);

/// The text of that notice, for the WEB shell. A constant so a test can pin it
/// without copying a string that would then drift.
const kLogoutNotNotifiedNotice =
    '已在本机退出，但没能通知服务器：服务端会话可能仍然有效。'
    '若这是公用设备，请清理浏览器数据（Cookie）。';

/// The same fact for the NATIVE renderer (the backup screen's console section).
///
/// Kept beside [kLogoutNotNotifiedNotice] on purpose: they are one decision in
/// two dialects, and when they lived in different files nobody could see that
/// only the *advice* differs. It has to differ — "clear your browser cookies" is
/// meaningless on a phone (this client sends a bearer token and keeps no cookie
/// jar), while "restart the container" actually works, because console sessions
/// live in the server's memory.
const kConsoleLogoutNotNotifiedNotice =
    '已在本机退出，但没能通知服务器：服务端会话可能仍然有效，要等它自己到期。'
    '若这台服务对外可达且你在意，重启 web-front 容器会立刻作废全部会话。';

/// Thin controller over [ConfigSyncController] that exposes a routable auth
/// state. The web router gates on this; native ignores it (viewOnly handling
/// only kicks in on web).
class AuthController extends ChangeNotifier {
  final Ref ref;
  AuthState _state = const AuthState(AuthStatus.unknown);
  AuthController(this.ref);

  AuthState get state => _state;

  /// Resolve the initial state — the single async seam the router waits on.
  /// On web this silently resumes the session token persisted in localStorage,
  /// so a page refresh no longer bounces to the login page; an expired/invalid
  /// session falls back to loggedOut.
  ///
  /// Anything thrown on this path resolves to [AuthStatus.loggedOut], never to
  /// "still resolving". The gate closes on [AuthStatus.unknown], so a throw that
  /// left the state there would leave it open forever — a security gate's
  /// failure direction has to be "deny", regardless of how well guarded the
  /// call chain below currently is.
  Future<void> restore() async {
    try {
      final ctrl = ref.read(configSyncControllerProvider);
      if (ctrl.isLoggedIn) {
        _set(const AuthState(AuthStatus.loggedIn));
        return;
      }
      final resumed = await ctrl.restoreSession();
      if (resumed) {
        _set(const AuthState(AuthStatus.loggedIn));
        // Same background content pull as an interactive login.
        unawaited(_syncDownData());
      } else {
        _set(const AuthState(AuthStatus.loggedOut));
      }
    } catch (e) {
      debugPrint('[Auth] restore failed, treating as logged out: $e');
      _set(const AuthState(AuthStatus.loggedOut));
    }
  }

  Future<void> login({
    String serverUrl = '',
    required String username,
    required String password,
  }) async {
    // Pulls the config and applies the sync settings into in-memory settings
    // (local-first: never persisted on web).
    final isDefaultPassword =
        await ref.read(configSyncControllerProvider).login(
              serverUrl: serverUrl,
              username: username,
              password: password,
            );
    ref.read(defaultPasswordWarningProvider.notifier).state = isDefaultPassword;
    // A fresh session makes the previous logout's warning moot.
    ref.read(logoutNoticeProvider.notifier).state = null;
    _set(const AuthState(AuthStatus.loggedIn));
    // Now that the transport is configured, pull the actual content in the
    // background — the UI is already navigable against whatever's local.
    unawaited(_syncDownData());
  }

  /// Content modules only — NOT `settings` (would overwrite in-memory config)
  /// nor device-local conveniences (imghost queue, geocode cache, …).
  static const _contentModules = <String>{
    'journal', 'layers', 'fog_tiles', 'track_points', 'chat_messages',
    'song_favorites',
  };

  /// Background pull of the user's data from their own cloud (via the transport
  /// the config names) into the local WASM DB. Failures are non-fatal
  /// (local-first): the user still sees whatever is already local, plus the
  /// manual zip import.
  Future<void> _syncDownData() async {
    try {
      await ref.read(syncEngineProvider).syncDown(
            modules: _contentModules,
            clearBeforeImport: false,
          );
      ref.read(journalRefreshProvider.notifier).state++;
      ref.read(fogRefreshProvider.notifier).state++;
    } catch (e) {
      debugPrint('[Auth] background data syncDown failed (non-fatal): $e');
    }
  }

  /// Clears the session token but NOT local data — that stays for local-first
  /// re-login. A separate "clear this device" action (web) handles wiping local
  /// IndexedDB.
  Future<void> logout() async {
    final outcome = await ref.read(configSyncControllerProvider).logout();
    ref.read(defaultPasswordWarningProvider.notifier).state = false;
    ref.read(logoutNoticeProvider.notifier).state =
        outcome.serverNotified ? null : kLogoutNotNotifiedNotice;
    _set(const AuthState(AuthStatus.loggedOut));
  }

  void _set(AuthState s) {
    _state = s;
    notifyListeners();
  }
}

/// Where the router should send a request, given the auth state — the whole web
/// gate policy as one pure function so it can be tested without pumping the app.
///
/// Three things it fixes over the inline version it replaced:
///
///  * **`unknown` redirects to `/splash`, it does not fall through.** Falling
///    through rendered the real target for one frame before bouncing to
///    `/login`: a visible flash, plus a wasted round of DB queries and tile
///    rendering on every cold start. A gate whose "still resolving" state
///    admits traffic is not a gate.
///  * **The intercepted location survives.** It rides along as `?from=`, so a
///    deep link (`/journal`) comes back after login instead of being replaced
///    by `/`.
///  * `from` is never allowed to point back at `/splash` or `/login`, which
///    would be a redirect loop.
String? webAuthRedirect({required AuthStatus status, required Uri uri}) {
  final loc = uri.path;
  const splash = '/splash';
  const login = '/login';

  // Where to return to once we know who the user is.
  String intended() {
    if (loc == splash || loc == login) {
      final f = uri.queryParameters['from'];
      return (f == null || f.isEmpty) ? '/' : f;
    }
    return uri.toString();
  }

  String safeTarget() {
    final t = intended();
    final u = Uri.tryParse(t);
    // `from` arrives from the address bar, so it is untrusted input: anything
    // with a scheme or authority (`https://evil`, `//evil`) would be an open
    // redirect, and the two gate routes would be a loop.
    if (u == null || u.hasScheme || u.hasAuthority) return '/';
    if (!u.path.startsWith('/') || u.path == splash || u.path == login) {
      return '/';
    }
    return t;
  }

  switch (status) {
    case AuthStatus.unknown:
      if (loc == splash) return null;
      return Uri(path: splash, queryParameters: {'from': intended()}).toString();
    case AuthStatus.loggedOut:
      if (loc == login) return null;
      return Uri(path: login, queryParameters: {'from': intended()}).toString();
    case AuthStatus.loggedIn:
      if (loc == splash || loc == login) return safeTarget();
      return null;
  }
}

final authControllerProvider =
    ChangeNotifierProvider<AuthController>((ref) => AuthController(ref));

/// Routable snapshot of [AuthController.state].
final authStateProvider = Provider<AuthState>((ref) {
  return ref.watch(authControllerProvider).state;
});
