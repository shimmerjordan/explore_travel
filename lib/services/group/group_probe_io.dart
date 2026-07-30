import '../../models/models.dart';
import 'group_probe.dart';

GroupProbe createProbe(
    GroupTransport transport, ProbeConfig config, ProbeDeps deps) {
  switch (transport) {
    case GroupTransport.relay:
      return RelayProbe(config, deps);
    case GroupTransport.webrtc:
      return WebDavProbe(config, deps);
    case GroupTransport.frp:
      return FrpProbe(config, deps);
    case GroupTransport.lan:
    case GroupTransport.zerotier:
      return LanProbe(config, deps);
  }
}

/// Shared plumbing: elapsed-time stamping and the total-budget guard. Each
/// concrete probe is a sequence of named steps; this base runs them in order,
/// stops feeding new ones once the budget is spent, and guarantees `cleanUp`
/// runs even when the consumer cancels mid-run.
abstract class _BaseProbe implements GroupProbe {
  final ProbeConfig cfg;
  final ProbeDeps deps;
  bool _cancelled = false;
  _BaseProbe(this.cfg, this.deps);

  /// The steps to run, in order. Each returns the step it produced.
  List<Future<ProbeStep> Function()> steps();

  /// Best-effort teardown (stop a temporary frpc, delete a probe file, close
  /// sockets). Always awaited, even on cancel.
  Future<void> cleanUp() async {}

  @override
  Stream<ProbeStep> run() async* {
    final sw = Stopwatch()..start();
    try {
      for (final make in steps()) {
        if (_cancelled) return;
        if (sw.elapsed > deps.timeouts.total) {
          yield ProbeStep(
            title: '其余步骤已跳过',
            outcome: ProbeOutcome.skip,
            detail: '总时长超限（${deps.timeouts.total.inSeconds}s）',
            elapsed: Duration.zero,
          );
          return;
        }
        yield await make();
      }
    } finally {
      await cleanUp();
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await cleanUp();
  }

  /// Times a step body and turns any exception into a `fail` step rather than
  /// letting it escape into the UI. Not yet called by any concrete probe —
  /// the four `steps()` lists below are still empty and get filled in by the
  /// per-transport tasks that follow this one.
  // ignore: unused_element
  static Future<ProbeStep> timed(
    String title,
    Future<ProbeStep> Function() body, {
    String? failHint,
  }) async {
    final sw = Stopwatch()..start();
    try {
      return await body();
    } catch (e) {
      return ProbeStep(
        title: title,
        outcome: ProbeOutcome.fail,
        detail: '${e.runtimeType}: $e',
        elapsed: sw.elapsed,
        hint: failHint,
      );
    }
  }
}

class RelayProbe extends _BaseProbe {
  RelayProbe(super.cfg, super.deps);
  @override
  List<Future<ProbeStep> Function()> steps() => [];
}

class WebDavProbe extends _BaseProbe {
  WebDavProbe(super.cfg, super.deps);
  @override
  List<Future<ProbeStep> Function()> steps() => [];
}

class FrpProbe extends _BaseProbe {
  FrpProbe(super.cfg, super.deps);
  @override
  List<Future<ProbeStep> Function()> steps() => [];
}

class LanProbe extends _BaseProbe {
  LanProbe(super.cfg, super.deps);
  @override
  List<Future<ProbeStep> Function()> steps() => [];
}
