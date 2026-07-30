import 'package:flutter/foundation.dart' show visibleForTesting;

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
/// runs exactly once — whether the run finishes normally, throws, or the
/// consumer calls `cancel()` mid-run.
abstract class _BaseProbe implements GroupProbe {
  final ProbeConfig cfg;
  final ProbeDeps deps;
  bool _cancelled = false;

  /// Guards [cleanUp]: both the normal end-of-`run()` `finally` block and an
  /// in-flight `cancel()` reach for teardown, and there's no ordering
  /// guarantee between them (cancel can land just before or after the loop
  /// notices `_cancelled` on its own). A concrete `cleanUp` that stops a
  /// temporary frpc or deletes a probe file is not safe to run twice, so the
  /// dedup lives here once rather than being a convention every subclass has
  /// to remember.
  bool _cleanedUp = false;

  _BaseProbe(this.cfg, this.deps);

  /// The steps to run, in order. Each returns the step it produced.
  List<Future<ProbeStep> Function()> steps();

  /// Best-effort teardown (stop a temporary frpc, delete a probe file, close
  /// sockets). Always awaited, even on cancel. Subclasses override this —
  /// not [_cleanUpOnce] — the once-only guarantee is enforced by the caller.
  Future<void> cleanUp() async {}

  Future<void> _cleanUpOnce() async {
    if (_cleanedUp) return;
    _cleanedUp = true;
    await cleanUp();
  }

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
      await _cleanUpOnce();
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await _cleanUpOnce();
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

/// Test-only harness for [_BaseProbe]'s shared plumbing — step sequencing,
/// the total-budget guard, and the cleanup-runs-once guarantee. `_BaseProbe`
/// is library-private on purpose (it's an implementation detail of the four
/// concrete probes below, not something outside code should depend on), so a
/// test file in a different library can't subclass it directly; this is the
/// narrow, `@visibleForTesting` door for that instead of making `_BaseProbe`
/// public just to satisfy a test.
@visibleForTesting
class DebugProbe extends _BaseProbe {
  final List<Future<ProbeStep> Function()> Function() stepsBuilder;
  final Future<void> Function()? onCleanUp;

  DebugProbe(
    super.cfg,
    super.deps, {
    required this.stepsBuilder,
    this.onCleanUp,
  });

  @override
  List<Future<ProbeStep> Function()> steps() => stepsBuilder();

  @override
  Future<void> cleanUp() async {
    final cb = onCleanUp;
    if (cb != null) await cb();
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
