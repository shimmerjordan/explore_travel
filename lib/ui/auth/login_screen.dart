import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/vault/auth_controller.dart';

/// Web login gate. Collects the NAS server URL + account + password, derives
/// the vault key client-side, and (on success) the router redirect moves on to
/// the app. The password never leaves the device in the clear — only the
/// derived `authVerifier` is sent.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _registering = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Prefill: last-used backend first, else the same-machine default (the
    // docker-compose backend listens on 48080).
    final s = ref.read(settingsProvider);
    _server.text = (s.nasServerUrl?.isNotEmpty ?? false)
        ? s.nasServerUrl!
        : 'http://localhost:48080';
    if (s.nasAccountEmail?.isNotEmpty ?? false) {
      _email.text = s.nasAccountEmail!;
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = ref.read(authControllerProvider);
    try {
      final args = (
        serverUrl: _server.text.trim(),
        email: _email.text.trim(),
        password: _password.text,
      );
      if (_registering) {
        await auth.register(
            serverUrl: args.serverUrl, email: args.email, password: args.password);
      } else {
        await auth.login(
            serverUrl: args.serverUrl, email: args.email, password: args.password);
      }
      // On success the router's refreshListenable + redirect navigates away.
    } catch (e) {
      if (mounted) setState(() => _error = _humanize(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('VaultDecrypt')) return '口令错误，或保险库已损坏';
    if (s.contains('Weak')) return '口令太短（至少 8 位）';
    if (s.contains('401') || s.contains('invalid credentials')) return '邮箱或口令错误';
    if (s.contains('409') || s.contains('already registered')) return '该邮箱已注册，请改为登录';
    if (s.contains('后端地址') || s.contains('NAS 地址')) {
      return '后端地址需为 http(s):// 开头的完整 URL';
    }
    return '失败：$s';
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
                Text(_registering ? '创建账户' : '登录以查看你的足迹',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 24),
                TextField(
                  controller: _server,
                  decoration: const InputDecoration(
                    labelText: '后端地址',
                    hintText: 'http://localhost:48080（NAS 部署则填其地址）',
                    prefixIcon: Icon(Icons.dns),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _email,
                  decoration: const InputDecoration(
                    labelText: '邮箱',
                    prefixIcon: Icon(Icons.mail_outline),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  decoration: const InputDecoration(
                    labelText: '口令（也是保险库解密口令）',
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
                        : Text(_registering ? '注册并同步' : '登录'),
                  ),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _registering = !_registering),
                  child: Text(_registering ? '已有账户？去登录' : '没有账户？去注册'),
                ),
                const SizedBox(height: 8),
                Text(
                  '口令仅用于在本机派生密钥，绝不上传；服务器只保存你无法被解密的加密配置。',
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
