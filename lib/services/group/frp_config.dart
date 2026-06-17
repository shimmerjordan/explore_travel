/// Generates frpc TOML config for the embedded frp client (frp >= 0.52, which
/// switched from .ini to .toml). The group's XTCP topology:
///
///   * Each member runs ONE xtcp "proxy" (the *server* side of a punch) that
///     exposes its local TCP mesh port. Proxy name is deterministic so peers
///     can find it: `<groupPrefix>.<selfPeerId>`.
///   * For every OTHER known member, the client runs an xtcp "visitor" that
///     binds a loopback port and hole-punches to that member's proxy. The
///     group's existing TCP-mesh protocol then runs over `127.0.0.1:<bind>`.
///
/// The shared `secretKey` (frp's `sk`) gates who may visit a proxy — we derive
/// it from the group's shared passphrase so only group members can punch in.
/// All of this interoperates with stock frpc/frps; nothing here is bespoke.
class FrpVisitorPlan {
  final String peerId;
  final String serverName; // remote proxy name to punch to
  final int bindPort; // loopback port the visitor listens on
  const FrpVisitorPlan({
    required this.peerId,
    required this.serverName,
    required this.bindPort,
  });
}

class FrpConfig {
  final String toml;
  final List<FrpVisitorPlan> visitors;
  const FrpConfig(this.toml, this.visitors);
}

class FrpConfigBuilder {
  final String serverAddr;
  final int serverPort;
  final String? token;
  final String protocol; // 'quic' | 'kcp' | 'tcp'
  final String groupPrefix; // sanitized group id, namespaces proxy names
  final String selfPeerId;
  final int localMeshPort; // our TCP mesh ServerSocket port
  final String secretKey; // shared xtcp sk (derived from passphrase)

  /// Loopback port where the first visitor binds; subsequent visitors take
  /// the next free port. Kept well clear of the mesh port range (47830+).
  static const int visitorPortBase = 48000;

  const FrpConfigBuilder({
    required this.serverAddr,
    required this.serverPort,
    required this.token,
    required this.protocol,
    required this.groupPrefix,
    required this.selfPeerId,
    required this.localMeshPort,
    required this.secretKey,
  });

  String proxyNameFor(String peerId) => '$groupPrefix.$peerId';

  /// Build the full frpc config for the current [roster] (other peers' ids).
  /// Visitor bind ports are assigned deterministically by sorted peer id so
  /// the same peer keeps the same loopback port across config reloads.
  FrpConfig build(Iterable<String> roster) {
    final others = roster.where((id) => id != selfPeerId).toSet().toList()
      ..sort();

    final b = StringBuffer();
    b.writeln('serverAddr = "${_esc(serverAddr)}"');
    b.writeln('serverPort = $serverPort');
    // Loginonly once; keep retrying so a flaky frps doesn't kill the client.
    b.writeln('loginFailExit = false');
    if ((token ?? '').isNotEmpty) {
      b.writeln('auth.method = "token"');
      b.writeln('auth.token = "${_esc(token!)}"');
    }
    b.writeln();

    // Our own xtcp proxy — the punchable endpoint other members visit.
    b.writeln('[[proxies]]');
    b.writeln('name = "${_esc(proxyNameFor(selfPeerId))}"');
    b.writeln('type = "xtcp"');
    b.writeln('secretKey = "${_esc(secretKey)}"');
    b.writeln('localIP = "127.0.0.1"');
    b.writeln('localPort = $localMeshPort');
    b.writeln();

    final plans = <FrpVisitorPlan>[];
    var port = visitorPortBase;
    for (final peerId in others) {
      final plan = FrpVisitorPlan(
        peerId: peerId,
        serverName: proxyNameFor(peerId),
        bindPort: port++,
      );
      plans.add(plan);
      b.writeln('[[visitors]]');
      b.writeln('name = "${_esc('${proxyNameFor(selfPeerId)}.to.$peerId')}"');
      b.writeln('type = "xtcp"');
      b.writeln('serverName = "${_esc(plan.serverName)}"');
      b.writeln('secretKey = "${_esc(secretKey)}"');
      b.writeln('bindAddr = "127.0.0.1"');
      b.writeln('bindPort = ${plan.bindPort}');
      b.writeln('keepTunnelOpen = true');
      // Punch protocol — quic/kcp survive more NATs than plain tcp.
      b.writeln('protocol = "${_esc(protocol)}"');
      b.writeln();
    }
    return FrpConfig(b.toString(), plans);
  }

  static String _esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}
