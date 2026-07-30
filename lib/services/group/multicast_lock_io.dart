import 'dart:io';
import 'package:flutter/services.dart';
import 'group_diagnostics.dart';

/// Thin wrapper around [WifiManager.MulticastLock] via a platform channel.
/// No-op on non-Android (other platforms don't need this — Wi-Fi multicast
/// just works on iOS/macOS/Linux/Windows).
///
/// The native side keeps ONE process-wide lock with `setReferenceCounted(false)`,
/// so [release] drops it for everyone regardless of who called [acquire]. Any
/// caller that isn't the owner of the group session — the connectivity probe,
/// notably — must consult [isHeld] first and leave the lock alone when someone
/// else is already holding it.
class MulticastLock {
  static const _ch =
      MethodChannel('explorejournal/multicast_lock');

  /// Whether the process-wide lock is held right now. Always false off Android
  /// (where there is no lock to hold).
  static Future<bool> isHeld() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('status') == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    try {
      final held = await _ch.invokeMethod<bool>('acquire');
      groupDiagnostics.info('mcast',
          held == true
              ? 'MulticastLock acquired'
              : 'MulticastLock.acquire returned false');
    } catch (e) {
      groupDiagnostics.error('mcast', 'MulticastLock acquire failed: $e');
    }
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('release');
      groupDiagnostics.info('mcast', 'MulticastLock released');
    } catch (_) {}
  }
}
