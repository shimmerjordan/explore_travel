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
  final String? email;
  const AuthState(this.status, [this.email]);
}

/// Thin controller over [VaultSyncController] that exposes a routable auth
/// state. The web router gates on this; native ignores it (viewOnly handling
/// only kicks in on web).
///
/// v1 session model (see plan §3.4): the `vaultKey` lives only in memory, so
/// after an app restart there's no key even if a token is cached — we therefore
/// start `loggedOut` and require a fresh login (which re-derives the key). The
/// session persists across navigation within one run.
class AuthController extends ChangeNotifier {
  final Ref ref;
  AuthState _state = const AuthState(AuthStatus.unknown);
  AuthController(this.ref);

  AuthState get state => _state;

  /// Resolve the initial state — the single async seam the router waits on.
  /// On web this silently resumes the persisted session (token + derived key
  /// in localStorage), so a page refresh no longer bounces to the login page;
  /// an expired/invalid session falls back to loggedOut.
  Future<void> restore() async {
    final ctrl = ref.read(vaultSyncControllerProvider);
    if (ctrl.isLoggedIn) {
      _set(const AuthState(AuthStatus.loggedIn));
      return;
    }
    final resumed = await ctrl.restoreSession();
    if (resumed) {
      _set(AuthState(
          AuthStatus.loggedIn, ref.read(settingsProvider).nasAccountEmail));
      // Same background content pull as an interactive login.
      unawaited(_syncDownData());
    } else {
      _set(const AuthState(AuthStatus.loggedOut));
    }
  }

  Future<void> register({
    required String serverUrl,
    required String email,
    required String password,
  }) async {
    await ref.read(vaultSyncControllerProvider).register(
          serverUrl: serverUrl,
          email: email,
          password: password,
        );
    _set(AuthState(AuthStatus.loggedIn, email));
  }

  Future<void> login({
    required String serverUrl,
    required String email,
    required String password,
  }) async {
    // Pulls + decrypts the vault and applies the sync config into in-memory
    // settings (local-first: never persisted on web).
    await ref.read(vaultSyncControllerProvider).login(
          serverUrl: serverUrl,
          email: email,
          password: password,
        );
    _set(AuthState(AuthStatus.loggedIn, email));
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

  /// Background pull of the user's data from their own cloud (via the vault's
  /// transport) into the local WASM DB. Failures are non-fatal (local-first):
  /// the user still sees whatever is already local, plus the manual zip import.
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

  /// Clears the session (token + in-memory key) but NOT local data — that
  /// stays for local-first re-login. A separate "clear this device" action
  /// (web) handles wiping local IndexedDB.
  Future<void> logout() async {
    await ref.read(vaultSyncControllerProvider).logout();
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
