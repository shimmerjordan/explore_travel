import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/vault/admin_config_client.dart';
import '../../services/vault/auth_controller.dart';
import '../../services/vault/config_sync_controller.dart';

/// Pre-flight check on what the user typed, or null when it's worth sending.
///
/// The login bucket is 10 requests per minute for the whole console, so an empty
/// password or a typo'd address must not spend one: a few blank submits and the
/// user is rate-limited out of their own server. On native an empty address is
/// worse than useless — it silently means "same origin", which on a phone is
/// nothing at all.
///
/// Pure and top-level so it can be tested without a widget tree.
String? validateLoginInput({
  required bool needsServer,
  required String server,
  required String username,
  required String password,
}) {
  if (needsServer) {
    if (server.trim().isEmpty) {
      return '请填写后端地址，例如 http://192.168.1.9:48080';
    }
    try {
      ConfigSyncController.normalizeServerUrl(server);
    } on ArgumentError catch (e) {
      return e.message?.toString() ?? '后端地址无效';
    }
  }
  if (username.trim().isEmpty) return '请填写用户名';
  if (password.isEmpty) return '请填写密码';
  return null;
}

/// The one line shown under the login form for a failed attempt.
///
/// Pure and top-level so the exact strings a user reads are pinned by tests
/// rather than discovered in production.
String humanizeLoginError(Object e) {
  // The server answers "no such user" and "wrong password" identically on
  // purpose, so neither may this.
  if (e is AdminAuthException) return '用户名或密码错误';
  if (e is AdminConfigException) {
    // 429 is the one status a login screen must phrase itself. The bucket is
    // 10/min, so trying three passwords hits it — and a bare "rate limited"
    // reads as "try again", which is exactly what keeps the bucket full.
    if (e.statusCode == 429) {
      return '登录过于频繁，请 ${e.retryAfterSeconds ?? 60} 秒后再试'
          '（服务端每分钟只接受 10 次登录）';
    }
    return e.message;
  }
  if (e is ArgumentError) return e.message?.toString() ?? '输入有误';
  return '失败：$e';
}

/// Console login gate. The credential is the console's single admin account;
/// the server verifies it and hands back a session token.
///
/// The address field only exists on native. In the browser the console serves
/// this very page and sends no CORS headers, so the API is reachable at exactly
/// one place — the same origin — and offering a box to type another one would
/// only invite a request the browser blocks.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _server = TextEditingController();
  final _username = TextEditingController(text: 'admin');
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      final s = ref.read(settingsProvider);
      if (s.nasServerUrl?.isNotEmpty ?? false) _server.text = s.nasServerUrl!;
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final bad = validateLoginInput(
      needsServer: !kIsWeb,
      server: _server.text,
      username: _username.text,
      password: _password.text,
    );
    if (bad != null) {
      setState(() => _error = bad);
      return; // don't spend one of the 10 login attempts per minute
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider).login(
            serverUrl: kIsWeb ? '' : _server.text.trim(),
            username: _username.text.trim(),
            password: _password.text,
          );
      // On success the router's refreshListenable + redirect navigates away;
      // the default-password warning (if any) is rendered by the app shell.
    } catch (e) {
      if (mounted) setState(() => _error = humanizeLoginError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.travel_explore, size: 56),
                const SizedBox(height: 12),
                Text('Explore Journal · 回忆',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text('登录以查看你的足迹',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 24),
                if (!kIsWeb) ...[
                  TextField(
                    controller: _server,
                    decoration: const InputDecoration(
                      labelText: '后端地址',
                      hintText: 'http://<NAS>:48080',
                      prefixIcon: Icon(Icons.dns),
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  obscureText: true,
                  onSubmitted: (_) => _busy ? null : _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('登录'),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '账户由部署这台服务的人管理，初始为 admin / admin。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
