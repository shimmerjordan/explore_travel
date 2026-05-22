import 'dart:io';
import 'package:flutter/services.dart';
import 'group_diagnostics.dart';

/// Thin wrapper around [WifiManager.MulticastLock] via a platform channel.
/// No-op on non-Android (other platforms don't need this — Wi-Fi multicast
/// just works on iOS/macOS/Linux/Windows).
class MulticastLock {
  static const _ch =
      MethodChannel('explorejournal/multicast_lock');

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
