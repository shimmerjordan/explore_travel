import '../../models/models.dart';
import 'group_probe.dart';

/// Web build: `relay` and `webrtc` are reachable from the browser, but LAN
/// multicast and the embedded frpc need `dart:io` / a native library. Those two
/// report `skip` with the reason instead of pretending to fail.
///
/// Current stage: every transport still routes through [_UnsupportedProbe]
/// below — the relay/webrtc-capable web probes described above are future
/// work, not yet implemented, so don't read this file as reflecting today's
/// behavior for those two.
GroupProbe createProbe(
        GroupTransport transport, ProbeConfig config, ProbeDeps deps) =>
    _UnsupportedProbe(transport);

class _UnsupportedProbe implements GroupProbe {
  final GroupTransport transport;
  _UnsupportedProbe(this.transport);

  @override
  Stream<ProbeStep> run() async* {
    yield ProbeStep(
      title: '当前平台不支持',
      outcome: ProbeOutcome.skip,
      detail: 'Web 版无法探测 ${transport.label}，请在手机上测试',
      elapsed: Duration.zero,
    );
  }

  @override
  Future<void> cancel() async {}
}
