import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// External ZeroTier integration. We don't embed libzt — that would need
/// per-arch NDK builds + platform VPN permissions. Instead we help the user
/// drive the official ZT One client.
///
/// Capabilities by platform:
///   - Android: launch ZT One via package name, fall back to Play Store.
///   - iOS:     ZT has no URL scheme as of 2026; we copy the network ID and
///              show guidance text only.
///   - Linux:   shell out to `zerotier-cli` if installed.
///   - macOS:   open the GUI app via `open -a ZeroTier One`.
///   - Web:     copy ID only.
class ZeroTierHelper {
  static const String _pkg = 'com.zerotier.one';

  /// What this platform can do; the UI uses this to enable/disable buttons.
  static ZtCapability capability() {
    if (kIsAndroid) return ZtCapability.launchApp;
    if (kIsLinux) return ZtCapability.cli;
    if (kIsMacOS) return ZtCapability.launchApp;
    if (kIsIOS) return ZtCapability.copyOnly;
    return ZtCapability.copyOnly;
  }

  /// Try to launch the ZT client. Returns null on success; an error message
  /// describing what to do next on failure.
  static Future<String?> openClient({String? networkId}) async {
    if (networkId != null && networkId.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: networkId));
    }
    try {
      if (kIsAndroid) {
        const intent = AndroidIntent(
          action: 'android.intent.action.MAIN',
          package: _pkg,
          componentName: '$_pkg/.NetworkListActivity',
        );
        try {
          await intent.launch();
          return null;
        } catch (_) {
          // Fall back to Play Store.
          final uri = Uri.parse('market://details?id=$_pkg');
          if (await launchUrl(uri,
              mode: LaunchMode.externalApplication)) {
            return '已跳转到应用商店：装好 ZeroTier One 后回来';
          }
          return '未安装 ZeroTier One，且无法打开应用商店';
        }
      }
      if (kIsMacOS) {
        final r = await Process.run('open', ['-a', 'ZeroTier One']);
        if (r.exitCode == 0) return null;
        return 'macOS 未检测到 ZeroTier One，请到 zerotier.com 下载';
      }
      if (kIsLinux) {
        // Best-effort: try a few common entry points.
        for (final cmd in const ['zerotier-gui', 'zerotier-desktop-ui']) {
          try {
            final r = await Process.start(cmd, const []);
            // ignore: unawaited_futures
            r.exitCode;
            return null;
          } catch (_) {}
        }
        return 'Linux 未检测到 GUI；可用 zerotier-cli 命令行加入网络';
      }
      if (kIsIOS) {
        return 'iOS 上 ZeroTier 没有 URL scheme，请手动打开 App。'
            '网络 ID 已复制到剪贴板。';
      }
      return '当前平台不支持自动启动 ZeroTier';
    } catch (e) {
      return '启动失败：$e';
    }
  }

  /// On Linux/macOS, try `zerotier-cli listnetworks` and tell the user
  /// whether the given network ID is currently joined and OK.
  ///
  /// Returns one of:
  ///   "joined"     — the network is joined and status OK
  ///   "not-joined" — ZT is running but you haven't joined this network
  ///   "no-cli"     — zerotier-cli isn't on PATH
  ///   "error: ..." — something else went wrong
  static Future<String> probeJoined(String networkId) async {
    if (!(kIsLinux || kIsMacOS)) return 'no-cli';
    try {
      final r = await Process.run('zerotier-cli', ['listnetworks']);
      if (r.exitCode != 0) return 'error: ${r.stderr}';
      final out = r.stdout.toString();
      final id = networkId.toLowerCase();
      for (final line in out.split('\n')) {
        if (line.toLowerCase().contains(id)) {
          if (line.contains(' OK ')) return 'joined';
          return 'joining';
        }
      }
      return 'not-joined';
    } catch (e) {
      if (e is ProcessException) return 'no-cli';
      return 'error: $e';
    }
  }

  /// Try `zerotier-cli join <id>` (Linux/macOS only, needs sudo on many
  /// distros — we report stderr verbatim so the user can see the hint).
  static Future<String?> cliJoin(String networkId) async {
    if (!(kIsLinux || kIsMacOS)) {
      return '当前平台不支持 zerotier-cli';
    }
    try {
      final r = await Process.run('zerotier-cli', ['join', networkId]);
      if (r.exitCode == 0) return null;
      return r.stderr.toString().trim();
    } on ProcessException {
      return 'zerotier-cli 不在 PATH 上';
    }
  }
}

enum ZtCapability {
  /// Can launch the GUI client by intent/URL (Android, macOS).
  launchApp,

  /// Can talk to a CLI (Linux primarily).
  cli,

  /// Can only put the network ID on the clipboard (iOS, Web).
  copyOnly,
}

bool get kIsAndroid => Platform.isAndroid;
bool get kIsIOS => Platform.isIOS;
bool get kIsLinux => Platform.isLinux;
bool get kIsMacOS => Platform.isMacOS;
