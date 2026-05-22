import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:multicast_dns/multicast_dns.dart';
import 'crypto.dart';
import 'p2p_types.dart';
export 'p2p_types.dart';

/// P2P over ZeroTier (or any LAN). Each device advertises itself via mDNS,
/// discovers peers on the same virtual LAN, then exchanges JSON messages
/// over a plain TCP/WebSocket-like framing protocol.
///
/// Message types: hello, location, message, ping.

class P2PService {
  static const _serviceName = '_explorejournal._tcp.local';
  static const int defaultPort = 47821;

  final String displayName;
  final P2PCrypto? crypto;
  ServerSocket? _server;
  final _peers = <String, Socket>{};
  final _incoming = StreamController<P2PMessage>.broadcast();
  final _peerList = StreamController<List<PeerInfo>>.broadcast();
  Stream<P2PMessage> get messages => _incoming.stream;
  Stream<List<PeerInfo>> get peers => _peerList.stream;

  P2PService(this.displayName, {this.crypto});

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, defaultPort,
        shared: true);
    _server!.listen(_acceptSocket);
    // Discovery: periodically scan via mDNS.
    Timer.periodic(const Duration(seconds: 15), (_) => _discover());
    await _discover();
  }

  Future<void> stop() async {
    for (final s in _peers.values) {
      await s.close();
    }
    _peers.clear();
    await _server?.close();
    _server = null;
  }

  void _acceptSocket(Socket socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) async {
        try {
          String payload = line;
          if (line.startsWith('v1|') && crypto != null) {
            final clear = await crypto!.decrypt(line);
            if (clear == null) return;
            payload = clear;
          }
          final j = jsonDecode(payload) as Map<String, dynamic>;
          final msg = P2PMessage.fromJson(j);
          _peers[msg.from] = socket;
          _incoming.add(msg);
        } catch (_) {}
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  Future<void> _discover() async {
    final mdns = MDnsClient(rawDatagramSocketFactory:
        (dynamic host, int port, {bool? reuseAddress, bool? reusePort, int? ttl}) {
      return RawDatagramSocket.bind(host, port,
          reuseAddress: true, reusePort: false, ttl: ttl ?? 1);
    });
    try {
      await mdns.start();
      final ptrRecords = mdns.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(_serviceName));
      final list = <PeerInfo>[];
      await for (final ptr in ptrRecords) {
        await for (final srv in mdns.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName))) {
          await for (final ip in mdns.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target))) {
            list.add(PeerInfo(srv.target, ip.address.address, srv.port));
          }
        }
      }
      _peerList.add(list);
    } catch (_) {
    } finally {
      mdns.stop();
    }
  }

  /// Sends a JSON-line message to a peer (encrypted if [crypto] is set).
  Future<void> sendTo(PeerInfo peer, P2PMessage msg) async {
    final s = _peers[peer.name] ??
        await Socket.connect(peer.host, peer.port,
            timeout: const Duration(seconds: 5));
    _peers[peer.name] = s;
    final payload = jsonEncode(msg.toJson());
    final line =
        crypto != null ? await crypto!.encrypt(payload) : payload;
    s.write('$line\n');
    await s.flush();
  }

  /// Broadcast to all known peers (best-effort).
  Future<void> broadcast(P2PMessage msg, List<PeerInfo> known) async {
    for (final peer in known) {
      try {
        await sendTo(peer, msg);
      } catch (_) {}
    }
  }
}
