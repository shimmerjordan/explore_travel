// Web stub for ZeroTierHelper. The browser can't launch the ZT client,
// so everything degrades to "copy ID, show instructions".
import 'package:flutter/services.dart';

class ZeroTierHelper {
  static ZtCapability capability() => ZtCapability.copyOnly;

  static Future<String?> openClient({String? networkId}) async {
    if (networkId != null && networkId.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: networkId));
    }
    return '浏览器无法启动本地 ZeroTier 客户端，网络 ID 已复制到剪贴板。';
  }

  static Future<String> probeJoined(String networkId) async => 'no-cli';
  static Future<String?> cliJoin(String networkId) async =>
      '浏览器不支持 zerotier-cli';
}

enum ZtCapability { launchApp, cli, copyOnly }
