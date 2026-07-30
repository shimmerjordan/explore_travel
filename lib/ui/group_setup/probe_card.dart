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
  const ProbeUiState(
      {this.running = false, this.steps = const [], this.transport});

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
            final line =
                '${step.title} — ${step.outcome.name} — ${step.detail}';
            switch (step.outcome) {
              case ProbeOutcome.fail:
                groupDiagnostics.error('probe', line);
              case ProbeOutcome.pass:
              case ProbeOutcome.info:
                groupDiagnostics.info('probe', line);
              case ProbeOutcome.skip:
                groupDiagnostics.trace('probe', line);
            }
            // running 沿用当前值，不要硬写 true：`cancel()` 先把 running 翻成
            // false，之后那个还在飞的步骤仍会把结果送到这里（生成器要先跑完当前
            // 步骤才停），硬写 true 会把「测试中…」和「停止」按钮又点亮回来。
            // 这一步的结果照常追加 —— 它是真测出来的，该给用户看。
            state = ProbeUiState(
                running: state.running,
                steps: [...state.steps, step],
                transport: transport);
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
    // UI first, teardown second — the button and the 「测试中…」 spinner are both
    // bound to `st.running`, and teardown is not bounded by anything the user can
    // see. Some steps have no cancellation point inside them: `await done.future
    // .timeout(frpLogin)` in the frp login step keeps waiting for up to 12s, and
    // `await _sub.cancel()` cannot return until the generator finishes the step
    // it is inside. So as long as the state flip sat after these two awaits,
    // pressing 「停止」 during frp login changed nothing on screen for up to 12
    // seconds — indistinguishable from a frozen page. Acknowledging the press
    // immediately is the honest thing to render: the run IS over as far as the
    // user is concerned, and nothing below will emit another step into the UI.
    if (state.running) {
      state = ProbeUiState(
          running: false, steps: state.steps, transport: state.transport);
    }

    // Teardown still runs in exactly the order finding 10 established, just
    // without the UI waiting on it. Probe first, subscription second:
    // `_sub.cancel()` waits out the current step, so awaiting it first threw
    // away the early teardown `_probe.cancel()` exists to provide. This order
    // lets the probe see `_cancelled` and bail at the next opportunity.
    // Safe because the probe's `cleanUp` is idempotent: running it here and
    // again from `run()`'s `finally` releases each resource exactly once, and
    // anything acquired by an await still in flight is caught by that second
    // pass.
    await _probe?.cancel();
    _probe = null;
    await _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    // autoDispose：离开页面即取消，临时 frpc 与 socket 都在探针的 cleanUp 里释放。
    // 这里不能 await（dispose 是同步的），所以「取消落在某个 await 还在飞的时候」
    // 是常态 —— 探针的 cleanUp 因此必须幂等：cancel() 与 run() 的 finally 各跑一遍，
    // 后一遍才是真正释放「取消之后才拿到手的资源」的那一遍。
    _probe?.cancel();
    _sub?.cancel();
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
                          size: 18, color: report.passed ? c.primary : c.error),
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
        // 局域网只测「本机是否就绪」：对端在不在线单机测不出来（探测用临时端口，
        // 收不到对端的常规信标），别在副标题里承诺做不到的事。
        _ => '检查本机的网络接口、多播与 mesh 端口是否就绪',
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
      // pass 用品牌青绿 primary（DESIGN.md：primary 就是「点睛/成功」色）；
      // info 换成 secondary，跟 pass 的 primary 区分开——它是附带信息，不是结果，
      // 视觉权重要比「通过」低；skip 维持最低权重的 onSurfaceVariant。
      ProbeOutcome.pass => (Icons.check, c.primary),
      ProbeOutcome.fail => (Icons.close, c.error),
      ProbeOutcome.skip => (Icons.remove, c.onSurfaceVariant),
      ProbeOutcome.info => (Icons.info_outline, c.secondary),
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
                // hint 直接展开 —— 失败的人要看的就是这个。但颜色跟着 outcome 走：
                // skip / info 也会带 hint（说明「这项测不出来，该看什么」），一律
                // 涂红会让每次通过的报告底下都挂一条看着像错误的红字。
                if (step.hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('→ ${step.hint}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: step.outcome == ProbeOutcome.fail
                                ? c.error
                                : c.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
