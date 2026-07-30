import '../../models/models.dart';
import 'frp_engine.dart';
import 'group_probe_stub.dart'
    if (dart.library.io) 'group_probe_io.dart' as impl;

/// One line of a connectivity probe run.
///
/// `info` and `skip` deliberately do NOT count towards pass/fail: `info` carries
/// context that isn't a verdict (the LAN probe's interface list), and `skip`
/// covers steps that can't run on this platform — or can't be verified from one
/// device at all, like "is the shared passphrase the same as everyone else's" and
/// "how many members are online". Those are honestly marked as unverified rather
/// than silently omitted, and never reported as a zero the probe could not have
/// beaten. A report that only shows green ticks for things it actually checked is
/// worth more than one that looks complete.
enum ProbeOutcome { pass, fail, skip, info }

class ProbeStep {
  final String title;
  final ProbeOutcome outcome;
  final String detail;
  final Duration elapsed;

  /// What to do about it, or — on a non-`fail` step — what this step could NOT
  /// establish and what to watch for instead. Set on `fail`, `skip` and `info`
  /// alike, so a renderer MUST colour it by [outcome] rather than assuming a
  /// hint means something went wrong: a red line under a passing report reads
  /// as a failure the user then goes looking for.
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
  final Duration frpLogin;    // frpc login + proxy registration
  final Duration total;
  const ProbeTimeouts({
    this.net = const Duration(seconds: 5),
    this.webdav = const Duration(seconds: 8),
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

/// The relay refused the upgrade.
///
/// `code` is null in every path the io implementation can currently produce:
/// `dart:io`'s `WebSocketException` carries only the text
/// `Connection to '<uri>' was not upgraded to websocket` — no status code, and
/// no close code either (the socket never became a WebSocket, so there is
/// nothing to close). Our own relay answers a bad token with a bare
/// `HTTP/1.1 401 Unauthorized` (see `backends/server/modules/group.js`), which
/// is exactly the information that gets thrown away. Reading it back would take
/// a hand-written upgrade handshake over `HttpClient` so the response
/// `statusCode` survives; the field stays here for that day, and the probe
/// reports "reason unavailable" rather than guessing.
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

  /// Defaults to `NetworkInterface.list` in the io impl. Just enumerates
  /// local IPv4 addresses — informational, never fails the probe on its own.
  final Future<List<ProbeIface>> Function()? listInterfaces;

  /// Defaults to trying `ServerSocket.bind` across the mesh port range in the
  /// io impl. Returns the bound port; throws [MeshPortUnavailable] if every
  /// port in the range is taken. Injected so tests don't need a real socket
  /// and don't fight over ports with whatever's running on the machine.
  final Future<int> Function(int base, int count)? bindMesh;

  /// Defaults to a `RawDatagramSocket` bound to port 0 (an ephemeral port) in
  /// the io impl — deliberately NOT the discovery port, since that one may
  /// already be held by a running LAN group service and stealing it would
  /// break real peer discovery mid-session. That choice is also why the probe
  /// can only verify the SEND direction; see [ProbeDatagram].
  final Future<ProbeDatagram> Function()? openDatagram;

  /// Defaults to the Android `MulticastLock` platform channel in the io impl.
  /// See [ProbeMulticastLock] for why this is injectable.
  final ProbeMulticastLock? multicastLock;

  const ProbeDeps({
    this.timeouts = const ProbeTimeouts(),
    this.httpGet,
    this.wsConnect,
    this.davClient,
    this.frpEngine,
    this.tcpConnect,
    this.listInterfaces,
    this.bindMesh,
    this.openDatagram,
    this.multicastLock,
  });
}

/// One local network interface address, as reported by the LAN probe's
/// "network interfaces" step.
class ProbeIface {
  final String name;
  final String address;
  const ProbeIface({required this.name, required this.address});
}

/// Minimal UDP multicast surface the LAN probe needs. Real impl wraps
/// `dart:io`'s `RawDatagramSocket`; tests supply a fake.
///
/// Send-only on purpose. There used to be a `countAnswers(window)` here and a
/// "peer replies" step built on it, but the socket is bound to an EPHEMERAL
/// port (it must not steal [kDiscoveryPort] from a running group service), and
/// multicast delivery matches on destination port — so a peer's regular beacon,
/// addressed to the discovery port, can never arrive here. The count was
/// structurally always zero. Counting peers for real needs the group service to
/// unicast a reply to `probe:1` datagrams, i.e. a protocol change.
abstract class ProbeDatagram {
  bool joinMulticast();
  int send(List<int> data);
  Future<void> close();
}

/// The Android `MulticastLock`, as the LAN probe sees it.
///
/// Injected for one reason: the native lock is **process-wide and not
/// reference-counted**, and the running group service takes it in `start()`.
/// A probe that blindly acquires and then releases it would silently switch off
/// multicast reception for the live session — so the probe has to be able to
/// ask who holds it, and tests have to be able to assert that it never releases
/// a lock it did not take.
abstract class ProbeMulticastLock {
  /// False on platforms that don't need a lock at all (everything but Android),
  /// which makes the step report `skip`.
  bool get needed;

  /// Whether the process-wide lock is already held — by the group service, or
  /// by a previous run that failed to let go.
  Future<bool> isHeld();

  Future<void> acquire();
  Future<void> release();
}

/// Every port in the mesh port range was already taken. Not necessarily a
/// problem — see [ProbeConfig.groupRunning].
class MeshPortUnavailable implements Exception {
  const MeshPortUnavailable();
  @override
  String toString() => 'MeshPortUnavailable';
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
