import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../app/providers.dart';

/// Embedded WebView that opens a music platform's login page and lets the
/// user grab their session cookie without leaving the app.
///
/// Flow:
///   1) Load the platform's home/login URL.
///   2) User logs in manually (扫码 / 手机号 / 邮箱 / 三方).
///   3) The "保存当前 Cookie"按钮 reads document.cookie via JS runtime,
///      filters to the keys this backend actually needs, and stores the
///      result in AppSettings.musicCredentials[source].
///
/// We deliberately don't auto-detect login success — different platforms
/// signal it differently, and a manual "Save" gives the user agency to
/// re-grab cookies after they expire too.
class CookieWebViewScreen extends ConsumerStatefulWidget {
  final String source;
  final String platformLabel;
  final String startUrl;
  /// Cookie keys we keep. Anything else gets stripped before saving so the
  /// stored credential string stays focused.
  final List<String> keepKeys;
  const CookieWebViewScreen({
    super.key,
    required this.source,
    required this.platformLabel,
    required this.startUrl,
    required this.keepKeys,
  });

  @override
  ConsumerState<CookieWebViewScreen> createState() =>
      _CookieWebViewScreenState();
}

class _CookieWebViewScreenState
    extends ConsumerState<CookieWebViewScreen> {
  late final WebViewController _ctl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36')
      ..loadRequest(Uri.parse(widget.startUrl));
  }

  Future<void> _saveCookies() async {
    setState(() => _saving = true);
    try {
      // document.cookie returns the page-visible (non-HttpOnly) cookies as
      // a single string "k1=v1; k2=v2; ...". HttpOnly cookies (网易云的
      // MUSIC_U is one) are NOT visible here — for those the user should
      // hand-paste them via the regular "填写" button in the previous
      // screen. We capture what we can.
      final raw = await _ctl.runJavaScriptReturningResult('document.cookie');
      var s = raw.toString();
      if (s.startsWith('"') && s.endsWith('"')) {
        s = s.substring(1, s.length - 1);
      }
      // Filter to only the keys this backend uses.
      final keep = <String>[];
      for (final pair in s.split(';')) {
        final p = pair.trim();
        final eq = p.indexOf('=');
        if (eq <= 0) continue;
        final k = p.substring(0, eq);
        if (widget.keepKeys.contains(k)) keep.add(p);
      }
      if (keep.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '没拿到 ${widget.keepKeys.join("/")} 这几个 cookie——'
                '可能尚未登录，或这些是 HttpOnly（脚本读不到，需要手动复制）')));
        return;
      }
      final cookie = keep.join('; ');
      final s2 = ref.read(settingsProvider);
      final updated = {...s2.musicCredentials, widget.source: cookie};
      await ref
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(musicCredentials: updated));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已保存 ${keep.length} 个 cookie 字段')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读取失败：$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.platformLabel} · 登录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新加载',
            onPressed: () => _ctl.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.all(10),
            child: Text(
              '在下方完成登录后，点底部"保存当前 Cookie"。'
              '只保存：${widget.keepKeys.join(", ")}。',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _ctl)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white))
                      : const Icon(Icons.save_alt_rounded),
                  onPressed: _saving ? null : _saveCookies,
                  label: const Text('保存当前 Cookie'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
