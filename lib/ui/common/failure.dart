/// 失败提示的统一出口。
///
/// 全应用有三十多处 `'播放失败：$e'` 这样的写法，屏幕上会出现
/// `SocketException: Failed host lookup: 'x.y' (OS Error: No address
/// associated with hostname, errno = 7)`——对用户毫无用处，还挤掉了真正
/// 有用的东西：**这是什么毛病、我能不能重试**。
///
/// 这里的分工是：
///   * [describeFailure] 把异常归到一句人话（纯函数，可测）；
///   * [failureMessage] 拼成「<动作>失败 · <原因>」；
///   * [showFailure] 弹 SnackBar，可带「重试」；
///   * 技术细节一律走 `debugPrint`，由 `LogBuffer` 收进调试面板 —— 信息不丢，
///     只是不糊在用户脸上。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

/// 只有写给用户的文案才透出：含中日韩文字即视为用户向，纯英文视为开发者向。
/// 不完美，但比"全透"（会把 `Bad state: No element` 糊上屏）和"全不透"
/// （会把「未配置 frp 服务器地址」这类唯一有用的指引吞掉）都好。
String? _userFacing(String? message) {
  if (message == null || message.trim().isEmpty) return null;
  final hasCjk = RegExp(r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]')
      .hasMatch(message);
  return hasCjk ? message.trim() : null;
}

/// 把异常归成一句用户能据此行动的话。认不出来就回 null，让调用方只说
/// 「<动作>失败」——含糊也好过糊一屏堆栈。
String? describeFailure(Object? error) {
  if (error == null) return null;
  // 本仓的 service 层用 StateError / ArgumentError 携带**写给用户看的**中文
  // 提示（「未配置 frp 服务器地址」「GitHub 同步未配置（缺少 PAT / owner /
  // repo）」…）。这类"缺了什么配置"的具体指引比任何归类都有用，直接透出。
  // 判据是文案里有没有中日韩文字：同样两个异常类型也承载着大量开发者向的
  // 英文断言（'WebDAV not configured'、'empty tile'、'zoom past native'），
  // 那些不该上屏。
  if (error is StateError) return _userFacing(error.message);
  if (error is ArgumentError) {
    final m = error.message;
    if (m is String) return _userFacing(m);
  }
  if (error is SocketException) return '网络连不上';
  if (error is HttpException) return '服务器没有正常响应';
  if (error is TimeoutException) return '等太久了，超时';
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    if (code == 28) return '设备存储空间不足'; // ENOSPC
    if (code == 13 || code == 1) return '没有访问这个文件的权限'; // EACCES/EPERM
    if (code == 2) return '文件已经不在了'; // ENOENT
    return '读写文件出错';
  }
  if (error is FormatException) return '内容格式不对，解析不了';
  // dio / platform 通道等第三方异常按类型名认，避免为一句提示语去 import 它们。
  final name = error.runtimeType.toString();
  if (name == 'DioException') {
    final s = error.toString();
    if (s.contains('connection error') || s.contains('SocketException')) {
      return '网络连不上';
    }
    if (s.contains('timeout')) return '等太久了，超时';
    if (s.contains('401') || s.contains('403')) return '凭据无效或已过期';
    if (s.contains('404')) return '服务器上没有这个东西';
    if (s.contains('5')) return '服务器出错了';
    return '请求没成功';
  }
  if (name == 'PlatformException' || name == 'MissingPluginException') {
    return '这台设备上用不了这个功能';
  }
  return null;
}

/// 「<动作>失败 · <原因>」。[action] 用动词短语，例如 `'播放'`、`'导出视频'`。
String failureMessage(String action, Object? error) {
  final why = describeFailure(error);
  return why == null ? '$action失败' : '$action失败 · $why';
}

/// 弹一条失败提示。[onRetry] 给了就带「重试」按钮——**能重试的操作一定要给**，
/// 否则用户只能退出去重来。完整异常写进日志，不上屏。
void showFailure(
  BuildContext context, {
  required String action,
  Object? error,
  StackTrace? stack,
  VoidCallback? onRetry,
}) {
  debugPrint('[UI] $action 失败: $error${stack == null ? '' : '\n$stack'}');
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(SnackBar(
    content: Text(failureMessage(action, error)),
    duration: onRetry == null
        ? const Duration(seconds: 4)
        : const Duration(seconds: 6),
    action: onRetry == null
        ? null
        : SnackBarAction(label: '重试', onPressed: onRetry),
  ));
}
