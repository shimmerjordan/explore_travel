import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../models/models.dart';

/// Standalone group setup. Intentionally minimal:
///   - run mode (auto-on toggle + live status)
///   - transport picker (LAN / WebRTC) — ZT is just LAN
///   - identity (nickname + shared passphrase) — peer id is auto
///   - transport-specific helpers (manual peer for LAN, signaling fields for
///     WebRTC)
///
/// The group ID lives on the group screen itself ("加入" button), since it's
/// the per-join knob, not a persistent setting.
class GroupSetupScreen extends ConsumerWidget {
  const GroupSetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final cs = Theme.of(context).colorScheme;
    final transport = s.groupTransport.canonical;

    return Scaffold(
      appBar: AppBar(
        title: const Text('组队配置',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _Banner(
            icon: Icons.lan_outlined,
            title: '怎么组队',
            body:
                '1) 选传输方式（默认局域网，含 ZT/Tailscale 这类虚拟局域网）\n'
                '2) 设昵称和共享口令（端到端加密用）\n'
                '3) 回群组页"加入"对应的群组 ID\n\n'
                '群组 ID 是按次输入的，不在这里。',
          ),
          const _SectionHeader('运行模式'),
          SwitchListTile(
            secondary: const Icon(Icons.flash_on_rounded),
            title: const Text('全程保持在线'),
            subtitle: const Text(
                '应用一启动就连上群组，离开聊天页也保持，地图持续显示成员轨迹'),
            value: s.groupAutoConnect,
            onChanged: (v) =>
                n.update((p) => p.copyWith(groupAutoConnect: v)),
          ),
          Consumer(
            builder: (_, r, __) {
              final running = r.watch(groupRunningProvider);
              return ListTile(
                leading: Icon(running ? Icons.cloud_done : Icons.cloud_off,
                    color: running ? Colors.greenAccent : null),
                title: Text(running ? '当前已在线' : '当前未连接'),
                subtitle: Text(running
                    ? '点击立即断开'
                    : ((s.groupId ?? '').isEmpty
                        ? '群组 ID 为空，去群组页"加入"一个'
                        : '点击立即连接（群组：${s.groupId}）')),
                onTap: () {
                  final ctrl = r.read(groupLifecycleProvider);
                  running ? ctrl.stop() : ctrl.start();
                },
              );
            },
          ),
          const _SectionHeader('传输方式'),
          _TransportPicker(
            value: transport,
            onChanged: (v) =>
                n.update((p) => p.copyWith(groupTransport: v)),
          ),
          const _SectionHeader('身份'),
          _TextSetting(Icons.badge_rounded, '显示昵称', s.displayName,
              (v) => n.update((p) => p.copyWith(displayName: v))),
          _TextSetting(
            Icons.enhanced_encryption_rounded,
            '共享口令（端到端加密）',
            s.p2pPassphrase,
            (v) => n.update((p) => p.copyWith(p2pPassphrase: v)),
            obscure: true,
            hint: '所有成员设同一个',
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint_rounded),
            title: const Text('我的 Peer ID'),
            subtitle: Text(s.selfPeerId ?? '尚未生成',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              icon: const Icon(Icons.copy_outlined),
              onPressed: s.selfPeerId == null
                  ? null
                  : () {
                      Clipboard.setData(
                          ClipboardData(text: s.selfPeerId!));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制')));
                    },
            ),
          ),
          if (transport == GroupTransport.lan) ...[
            const _SectionHeader('发现 / 手动连接'),
            _Banner(
              icon: Icons.wifi_rounded,
              title: '自动发现机制',
              body:
                  '两条腿一起跑：\n'
                  '① UDP 多播 239.42.42.42:47829 —— 同群组成员自动互见\n'
                  '② TCP 子网主动扫描 —— 找出本机每个私有网段（10.x / 172.x'
                  ' / 192.168.x / Tailscale 100.64.x）/24 下的 1-254，'
                  '在 47830-47834 上探测。每个 IP 只试一次，已连接的跳过，'
                  '每 5 分钟刷新。\n\n'
                  '通常你什么都不用配。'
                  '只在公司 AP 把多播和扫描都拦了的极端情况，'
                  '才需要"手动添加成员"。',
              tint: cs.secondary,
            ),
            Consumer(builder: (_, r, __) {
              r.watch(groupRunningProvider);
              final ips =
                  r.read(groupLifecycleProvider).service.localIps;
              final picked = s.lanScanIp;
              if (ips.isEmpty) {
                return const ListTile(
                  leading: Icon(Icons.wifi_tethering_rounded),
                  title: Text('我的 IP'),
                  subtitle: Text('服务未启动 / 未检测到私有网段'),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text('选要扫描的接口（也是给对方手填的 IP）',
                        style: TextStyle(fontSize: 12)),
                  ),
                  ...[
                    null, // "all" option
                    ...ips,
                  ].map((ip) {
                    final isAll = ip == null;
                    return RadioListTile<String?>(
                      value: ip,
                      groupValue: picked == null || picked.isEmpty
                          ? null
                          : picked,
                      onChanged: (v) => n.update(
                          (p) => p.copyWith(lanScanIp: v ?? '')),
                      dense: true,
                      title: Text(isAll ? '全部私有接口 (默认)' : ip),
                      subtitle: isAll
                          ? const Text('所有 10.x / 172.x / 192.168.x 都扫',
                              style: TextStyle(fontSize: 11))
                          : null,
                      secondary: isAll
                          ? const Icon(Icons.public)
                          : IconButton(
                              icon: const Icon(Icons.copy_outlined),
                              onPressed: () {
                                Clipboard.setData(
                                    ClipboardData(text: ip));
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(const SnackBar(
                                        content: Text('已复制')));
                              },
                            ),
                    );
                  }),
                ],
              );
            }),
            _CidrPicker(
              value: s.lanScanCidrBits,
              onChanged: (v) =>
                  n.update((p) => p.copyWith(lanScanCidrBits: v)),
            ),
            ListTile(
              leading: const Icon(Icons.radar_rounded),
              title: Text(_scanLabel(s.lanScanCidrBits)),
              subtitle: Text(_scanCostHint(s.lanScanCidrBits)),
              onTap: () => _scanNow(context, ref, big: false),
            ),
            ListTile(
              leading: const Icon(Icons.travel_explore_rounded),
              title: const Text('扫描 /16 大网（强制）'),
              subtitle:
                  const Text('忽略上面的 CIDR，把整个 /16 走一遍，~15-20 分钟'),
              onTap: () => _scanNow(context, ref, big: true),
            ),
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_rounded),
              title: const Text('手动添加成员'),
              subtitle: const Text(
                  '输入对方 IP（如 ZT 的 172.x.x.x；可选 IP:端口）'),
              onTap: () => _addManualPeer(context, ref),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('诊断日志'),
              subtitle: const Text(
                  '看握手到底成功没——decrypt 失败 / group id 对不上 / TCP 拒绝 全在这里'),
              onTap: () => context.push('/group/diag'),
            ),
          ],
          if (transport == GroupTransport.webrtc) ...[
            const _SectionHeader('WebRTC 信令'),
            _Banner(
              icon: Icons.cloud_sync_rounded,
              title: '工作方式',
              body:
                  '所有成员配置同一个 WebDAV 账户（在云端备份页设置）。\n'
                  'App 在 WebDAV 上一个共享目录里互投 SDP/ICE 信令文件，'
                  '握手后切换为 P2P 直连（UDP）。\n'
                  '注意：坚果云这类对短间隔请求有限制，把轮询间隔调到 10-15 秒。',
              tint: cs.tertiary,
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('WebDAV 账户'),
              subtitle: Text(
                (s.webdavUrl ?? '').isEmpty
                    ? '未配置 — 点这里去配置'
                    : s.webdavUrl!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/backup'),
            ),
            _TextSetting(
              Icons.folder_outlined,
              '信令目录',
              s.webrtcSignalingPath,
              (v) => n.update((p) => p.copyWith(
                  webrtcSignalingPath:
                      v.startsWith('/') ? v : '/$v')),
              hint: '/explore_journal/signaling',
            ),
            _SliderSetting(
              icon: Icons.timer_outlined,
              label: '轮询间隔',
              value: s.webrtcSignalingPollSec.toDouble(),
              min: 2,
              max: 30,
              divisions: 28,
              valueText: '${s.webrtcSignalingPollSec} 秒',
              onChanged: (v) => n.update((p) =>
                  p.copyWith(webrtcSignalingPollSec: v.round())),
            ),
            _TextSetting(
              Icons.dns_outlined,
              'ICE 服务器',
              s.webrtcIceServers,
              (v) =>
                  n.update((p) => p.copyWith(webrtcIceServers: v)),
              hint: 'stun:... 或 turn:user:pass@host:port',
            ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Future<void> _addManualPeer(BuildContext context, WidgetRef ref) async {
    if (!await _ensureRunning(context, ref)) return;
    if (!context.mounted) return;

    final ctrl = TextEditingController();
    final entry = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('手动添加成员'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '172.27.x.x  或  172.27.x.x:47830',
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('连接')),
        ],
      ),
    );
    if (entry == null || entry.isEmpty) return;
    String host = entry;
    int? port;
    final colon = entry.lastIndexOf(':');
    if (colon > 0 && colon < entry.length - 1) {
      host = entry.substring(0, colon);
      port = int.tryParse(entry.substring(colon + 1));
    }
    final svc = ref.read(groupServiceProvider);
    final status = await svc.addManualPeer(host, port: port);
    if (!context.mounted) return;
    if (status.startsWith('ok')) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已连接（$status）—— 等待对方握手')));
    } else if (status.startsWith('service-not-running')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('组队服务未启动 —— 检查群组 ID 是否填好')),
      );
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(status)));
    }
  }

  Future<void> _scanNow(BuildContext context, WidgetRef ref,
      {required bool big}) async {
    if (!await _ensureRunning(context, ref)) return;
    if (!context.mounted) return;
    if (big) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('/16 全扫描？'),
          content: const Text(
              '会试 6 万多个 IP，~15-20 分钟，期间持续吃带宽。继续？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('算了')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('开始')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(big ? '/16 大扫描进行中…' : '扫描中…')));
    final n = await ref
        .read(groupLifecycleProvider)
        .service
        .scanNow(big: big);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('试了 $n 个新 IP；去成员页看谁上线')));
  }

  String _scanLabel(int bits) {
    return bits >= 24 ? '立即扫描 /$bits 子网' : '立即扫描 /$bits 子网（较慢）';
  }

  String _scanCostHint(int bits) {
    final hosts = bits >= 32 ? 0 : (1 << (32 - bits)) - 2;
    final secs = (hosts / 32 * 0.7).round();
    if (secs < 60) return '~$hosts 个 IP，约 $secs 秒';
    return '~$hosts 个 IP，约 ${(secs / 60).round()} 分钟';
  }

  /// Make sure the lifecycle is actually running, prompting for a group ID
  /// if needed. Returns false if the user cancelled or the service refused
  /// to come up.
  Future<bool> _ensureRunning(BuildContext context, WidgetRef ref) async {
    if (ref.read(groupRunningProvider)) return true;
    final s = ref.read(settingsProvider);
    if ((s.groupId ?? '').isEmpty) {
      final id = await _promptGroupId(context);
      if (id == null || id.isEmpty) return false;
      // Update settings AND turn auto-connect on in one shot. Lifecycle's
      // listener will pick it up and start.
      await ref.read(settingsProvider.notifier).update(
          (p) => p.copyWith(groupId: id, groupAutoConnect: true));
    } else if (!s.groupAutoConnect) {
      await ref
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(groupAutoConnect: true));
    }
    // Wait up to 3s for the lifecycle's microtask listener to fire and
    // start the service. The polling is gross but it sidesteps a race
    // between settings-update and the listen() callback.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!ref.read(groupRunningProvider) &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (!ref.read(groupRunningProvider)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('启动组队服务失败 — 看终端日志')));
      }
      return false;
    }
    return true;
  }

  Future<String?> _promptGroupId(BuildContext context) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('先填群组 ID'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '比如：川西自驾2026',
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
  }
}

class _CidrPicker extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _CidrPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.crop_free_rounded),
          const SizedBox(width: 16),
          const Expanded(child: Text('自动扫描的子网大小')),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 24, label: Text('/24')),
              ButtonSegment(value: 22, label: Text('/22')),
              ButtonSegment(value: 20, label: Text('/20')),
            ],
            selected: {value.clamp(20, 24)},
            onSelectionChanged: (s) => onChanged(s.first),
            showSelectedIcon: false,
          ),
        ],
      ),
    );
  }
}

class _TransportPicker extends StatelessWidget {
  final GroupTransport value;
  final ValueChanged<GroupTransport> onChanged;
  const _TransportPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const options = [GroupTransport.lan, GroupTransport.webrtc];
    return Column(
      children: options.map((t) {
        return RadioListTile<GroupTransport>(
          value: t,
          groupValue: value,
          onChanged: (v) => v == null ? null : onChanged(v),
          title: Text(t.label,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(t.description,
              style: const TextStyle(fontSize: 12, height: 1.4)),
        );
      }).toList(),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color? tint;
  const _Banner({
    required this.icon,
    required this.title,
    required this.body,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = tint ?? cs.primary;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(fontSize: 12, height: 1.6)),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700)),
    );
  }
}

class _TextSetting extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final Function(String) onSubmit;
  final bool obscure;
  final String? hint;
  const _TextSetting(this.icon, this.label, this.value, this.onSubmit,
      {this.obscure = false, this.hint});

  @override
  Widget build(BuildContext context) {
    final shown = value == null || value!.isEmpty
        ? (hint ?? '未设置')
        : (obscure ? '••••••' : value!);
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () async {
        final ctrl = TextEditingController(text: value ?? '');
        final r = await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(label),
            content: TextField(
              controller: ctrl,
              obscureText: obscure,
              autofocus: true,
              decoration: InputDecoration(hintText: hint, isDense: true),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(context, ctrl.text),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        if (r != null) onSubmit(r);
      },
    );
  }
}

class _SliderSetting extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueText;
  final ValueChanged<double> onChanged;
  const _SliderSetting({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueText,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(label),
                      Text(valueText,
                          style: TextStyle(
                              color:
                                  Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                Slider(
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
