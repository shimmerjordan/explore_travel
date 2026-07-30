import '../../models/models.dart';
import 'frp_engine.dart';
import 'group_probe_stub.dart'
    if (dart.library.io) 'group_probe_io.dart' as impl;

/// One line of a connectivity probe run.
///
/// `info` and `skip` deliberately do NOT count towards pass/fail: the LAN probe
/// reports how many peers answered as information (nobody else being online is
/// not a configuration error), and steps that can't run on this platform — or
/// can't be verified from one device at all, like "is the shared passphrase the
/// same as everyone else's" — are honestly marked as unverified instead of
/// silently omitted. A report that only shows green ticks for things it actually
/// checked is worth more than one that looks complete.
enum ProbeOutcome { pass, fail, skip, info }

class ProbeStep {
  final String title;
  final ProbeOutcome outcome;
  final String detail;
  final Duration elapsed;

  /// What to do about it. Only set for [ProbeOutcome.fail].
  final String? hint;

  const ProbeStep({
    required this.title,
    required this.outcome,
    required this.detail,
    required this.elapsed,
    this.hint,
  });
}

class ProbeReport {
  final GroupTransport transport;
  final List<ProbeStep> steps;
  const ProbeReport({required this.transport, required this.steps});

  bool get passed => steps.every((s) => s.outcome != ProbeOutcome.fail);

  String get summary {
    final failed = steps.where((s) => s.outcome == ProbeOutcome.fail);
    if (failed.isNotEmpty) return '失败于：${failed.first.title}';
    final checked =
        steps.where((s) => s.outcome == ProbeOutcome.pass).length;
    return '通过 · $checked 步';
  }
}

/// Snapshot of everything the probes read out of settings. Plain data so tests
/// can construct one without touching prefs or riverpod.
class ProbeConfig {
  final String groupId;
  final String selfId;
  final String? passphrase;

  // relay
  final String? relayServerUrl;
  final String? relayToken;

  // webrtc / WebDAV signaling
  final String? webdavUrl;
  final String? webdavUser;
  final String? webdavPass;
  final String signalingPath;

  // frp
  final String? frpServerAddr;
  final int frpServerPort;
  final String? frpToken;
  final String? frpDashboardUrl;
  final String? frpDashboardUser;
  final String? frpDashboardPass;

  /// True when the real group service is currently running — the frp probe
  /// reads the live engine instead of starting its own frpc, and the LAN probe
  /// treats an already-bound mesh port as success rather than failure.
  final bool groupRunning;

  const ProbeConfig({
    required this.groupId,
    this.selfId = 'probe',
    this.passphrase,
    this.relayServerUrl,
    this.relayToken,
    this.webdavUrl,
    this.webdavUser,
    this.webdavPass,
    this.signalingPath = '/explore_journal/signaling',
    this.frpServerAddr,
    this.frpServerPort = 7000,
    this.frpToken,
    this.frpDashboardUrl,
    this.frpDashboardUser,
    this.frpDashboardPass,
    this.groupRunning = false,
  });
}

/// Per-step timeouts. Total budget is enforced by the probe itself: once it's
/// spent, remaining steps are emitted as `skip` with 「总时长超限」 rather than
/// leaving the user staring at a spinner.
class ProbeTimeouts {
  final Duration net;         // TCP connect / plain HTTP
  final Duration webdav;      // one WebDAV request
  final Duration multicast;   // waiting for peer answers
  final Duration frpLogin;    // frpc login + proxy registration
  final Duration total;
  const ProbeTimeouts({
    this.net = const Duration(seconds: 5),
    this.webdav = const Duration(seconds: 8),
    this.multicast = const Duration(seconds: 3),
    this.frpLogin = const Duration(seconds: 12),
    this.total = const Duration(seconds: 45),
  });
}

class ProbeHttpResponse {
  final int status;
  final String body;
  const ProbeHttpResponse(this.status, this.body);
}

/// Minimal WebSocket surface the relay probe needs. Real impl wraps
/// `dart:io`'s `WebSocket`; tests supply a fake.
abstract class ProbeSocket {
  /// First inbound frame, or null if the socket closed / nothing arrived.
  Future<String?> firstFrame(Duration timeout);
  int? get closeCode;
  Future<void> close();
}

/// The relay refused the upgrade. `code` is the WebSocket close code (4401 =
/// bad token in `backends/server/modules/group.js`).
class WebSocketRejected implements Exception {
  final int? code;
  const WebSocketRejected(this.code);
  @override
  String toString() => 'WebSocketRejected(code: $code)';
}

/// The slice of WebDAV the signaling probe needs. Real impl wraps the same
/// `webdav_client` package `WebRtcGroupService` uses.
abstract class ProbeDav {
  Future<void> ensureDir(String path);
  Future<void> write(String path, List<int> bytes);
  Future<List<int>> read(String path);
  Future<void> remove(String path);
}

/// A WebDAV request came back with a non-2xx status.
class DavStatus implements Exception {
  final int status;
  const DavStatus(this.status);
  @override
  String toString() => 'DavStatus($status)';
}

/// Injectable dependencies. Defaults are the production ones; tests pass fakes.
class ProbeDeps {
  final ProbeTimeouts timeouts;

  /// Defaults to `guardedDio()`-backed GET in the io impl. Injected so tests
  /// don't need a server, and so the probe uses the SAME HTTP stack (including
  /// the plaintext-to-public-internet guard) the app uses everywhere else.
  final Future<ProbeHttpResponse> Function(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout,
  })? httpGet;

  final Future<ProbeSocket> Function(Uri url, Duration timeout)? wsConnect;

  /// Defaults to a `webdav_client` `Client`-backed adapter in the io impl —
  /// the SAME client class [WebRtcGroupService] uses for real signaling, so a
  /// pass here means the real transport can actually reach its mailbox.
  final ProbeDav Function(ProbeConfig cfg)? davClient;

  /// Defaults to `FrpEngine.create` in the io impl. Injected so tests don't
  /// need the native gomobile frpc plugin, and so the probe uses the SAME
  /// engine class the real frp transport does.
  final FrpEngine Function()? frpEngine;

  /// Defaults to a plain `Socket.connect` in the io impl.
  final Future<void> Function(String host, int port, Duration timeout)?
      tcpConnect;

  const ProbeDeps({
    this.timeouts = const ProbeTimeouts(),
    this.httpGet,
    this.wsConnect,
    this.davClient,
    this.frpEngine,
    this.tcpConnect,
  });
}

abstract class GroupProbe {
  /// Emits steps as they complete. Closing the subscription cancels the run.
  Stream<ProbeStep> run();

  Future<void> cancel();

  static GroupProbe forTransport(
    GroupTransport transport,
    ProbeConfig config, {
    ProbeDeps? deps,
  }) =>
      impl.createProbe(
        transport.canonical,
        config,
        deps ?? const ProbeDeps(),
      );
}
