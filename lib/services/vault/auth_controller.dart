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
/// server's own answer at login and rendered by the app shell, NOT by the login
/// screen — the router navigates away the instant login succeeds, so anything
/// drawn there would flash past unread.
final defaultPasswordWarningProvider = StateProvider<bool>((ref) => false);

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
  Future<void> restore() async {
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
    await ref.read(configSyncControllerProvider).logout();
    ref.read(defaultPasswordWarningProvider.notifier).state = false;
    _set(const AuthState(AuthStatus.loggedOut));
  }

  void _set(AuthState s) {
    _state = s;
    notifyListeners();
  }
}

final authControllerProvider =
    ChangeNotifierProvider<AuthController>((ref) => AuthController(ref));

/// Routable snapshot of [AuthController.state].
final authStateProvider = Provider<AuthState>((ref) {
  return ref.watch(authControllerProvider).state;
});
