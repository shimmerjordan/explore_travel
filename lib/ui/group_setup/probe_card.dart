import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../models/models.dart';
import '../../services/group/group_diagnostics.dart';
import '../../services/group/group_probe.dart';

class ProbeUiState {
  final bool running;
  final List<ProbeStep> steps;
  final GroupTransport? transport;
  const ProbeUiState({this.running = false, this.steps = const [], this.transport});

  ProbeReport? get report => transport == null
      ? null
      : ProbeReport(transport: transport!, steps: steps);
}

class ProbeController extends StateNotifier<ProbeUiState> {
  final Ref ref;
  StreamSubscription<ProbeStep>? _sub;
  GroupProbe? _probe;

  ProbeController(this.ref) : super(const ProbeUiState());

  Future<void> start(GroupTransport transport) async {
    await cancel();
    final s = ref.read(settingsProvider);
    final cfg = ProbeConfig(
      groupId: s.groupId ?? '',
      selfId: 'probe-${DateTime.now().millisecondsSinceEpoch % 100000}',
      passphrase: s.p2pPassphrase,
      relayServerUrl: s.relayServerUrl,
      relayToken: s.relayToken,
      webdavUrl: s.webdavUrl,
      webdavUser: s.webdavUser,
      webdavPass: s.webdavPass,
      signalingPath: s.webrtcSignalingPath,
      frpServerAddr: s.frpServerAddr,
      frpServerPort: s.frpServerPort,
      frpToken: s.frpToken,
      frpDashboardUrl: s.frpDashboardUrl,
      frpDashboardUser: s.frpDashboardUser,
      frpDashboardPass: s.frpDashboardPass,
      groupRunning: ref.read(groupRunningProvider),
    );
    state = ProbeUiState(running: true, steps: const [], transport: transport);
    final probe = _probe = GroupProbe.forTransport(transport, cfg);
    _sub = probe.run().listen(
      (step) {
        // 同步进诊断日志：诊断页天然就有记录，不需要第二套持久化。
        final line = '${step.title} — ${step.outcome.name} — ${step.detail}';
        switch (step.outcome) {
          case ProbeOutcome.fail:
            groupDiagnostics.error('probe', line);
          case ProbeOutcome.pass:
          case ProbeOutcome.info:
            groupDiagnostics.info('probe', line);
          case ProbeOutcome.skip:
            groupDiagnostics.trace('probe', line);
        }
        state = ProbeUiState(
            running: true, steps: [...state.steps, step], transport: transport);
      },
      onDone: () => state = ProbeUiState(
          running: false, steps: state.steps, transport: transport),
      onError: (Object e) {
        state = ProbeUiState(
          running: false,
          transport: transport,
          steps: [
            ...state.steps,
            ProbeStep(
              title: '探测中断',
              outcome: ProbeOutcome.fail,
              detail: '$e',
              elapsed: Duration.zero,
            ),
          ],
        );
      },
    );
  }

  Future<void> cancel() async {
    await _sub?.cancel();
    _sub = null;
    await _probe?.cancel();
    _probe = null;
    if (state.running) {
      state = ProbeUiState(
          running: false, steps: state.steps, transport: state.transport);
    }
  }

  @override
  void dispose() {
    // autoDispose：离开页面即取消，临时 frpc 与 socket 都在探针的 cleanUp 里释放。
    _sub?.cancel();
    _probe?.cancel();
    super.dispose();
  }
}

final probeStateProvider =
    StateNotifierProvider.autoDispose<ProbeController, ProbeUiState>(
        (ref) => ProbeController(ref));

class ProbeCard extends ConsumerWidget {
  const ProbeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).colorScheme;
    final transport =
        ref.watch(settingsProvider.select((s) => s.groupTransport)).canonical;
    final st = ref.watch(probeStateProvider);
    final report = st.report;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('测试连接',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(_subtitleFor(transport),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: c.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(
                  onPressed: st.running
                      ? () => ref.read(probeStateProvider.notifier).cancel()
                      : () => ref
                          .read(probeStateProvider.notifier)
                          .start(transport),
                  child: Text(st.running ? '停止' : '测试连接'),
                ),
              ],
            ),
            if (st.steps.isNotEmpty) ...[
              const SizedBox(height: 12),
              if (report != null && !st.running)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(report.passed ? Icons.check_circle : Icons.error,
                          size: 18,
                          color: report.passed ? Colors.green : c.error),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(report.summary,
                              style: Theme.of(context).textTheme.bodyMedium)),
                      TextButton(
                        onPressed: () => _copy(context, transport, st.steps),
                        child: const Text('复制诊断信息'),
                      ),
                    ],
                  ),
                ),
              ...st.steps.map((s) => _StepRow(step: s)),
              if (st.running)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Row(children: [
                    SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 8),
                    Text('测试中…'),
                  ]),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _subtitleFor(GroupTransport t) => switch (t) {
        GroupTransport.relay => '检查服务可达、组队模块是否启用、WebSocket 能否升级',
        GroupTransport.webrtc => '检查 WebDAV 信令目录能否读写（会写一个探针文件再删掉）',
        GroupTransport.frp => '检查 frps 可达、frpc 能否登录并注册 xtcp proxy',
        _ => '检查本机多播与 mesh 端口，并统计能发现几个成员',
      };

  static void _copy(
      BuildContext context, GroupTransport t, List<ProbeStep> steps) {
    final text = StringBuffer('组队连通性测试 · ${t.label}\n');
    for (final s in steps) {
      text.writeln('[${s.outcome.name}] ${s.title} — ${s.detail}'
          '${s.hint == null ? '' : '\n    → ${s.hint}'}');
    }
    Clipboard.setData(ClipboardData(text: text.toString()));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
  }
}

class _StepRow extends StatelessWidget {
  final ProbeStep step;
  const _StepRow({required this.step});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (icon, color) = switch (step.outcome) {
      ProbeOutcome.pass => (Icons.check, Colors.green),
      ProbeOutcome.fail => (Icons.close, c.error),
      ProbeOutcome.skip => (Icons.remove, c.onSurfaceVariant),
      ProbeOutcome.info => (Icons.info_outline, c.primary),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(step.title)),
                  if (step.elapsed > Duration.zero)
                    Text('${step.elapsed.inMilliseconds} ms',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: c.onSurfaceVariant)),
                ]),
                if (step.detail.isNotEmpty)
                  Text(step.detail,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: c.onSurfaceVariant)),
                // 失败时 hint 直接展开 —— 失败的人要看的就是这个。
                if (step.hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('→ ${step.hint}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: c.error)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
