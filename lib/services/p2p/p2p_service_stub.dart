import 'dart:async';
import 'crypto.dart';
import 'p2p_types.dart';
export 'p2p_types.dart';

/// Web stub: no UDP multicast or raw sockets in the browser. The chat UI
/// shows "0 peers" and `broadcast` is a no-op. To enable cross-device chat
/// on web, you'd need to add a WebSocket signaling endpoint (out of scope
/// for the zero-backend goal).
class P2PService {
  final String displayName;
  final P2PCrypto? crypto;
  Stream<P2PMessage> get messages => const Stream.empty();
  Stream<List<PeerInfo>> get peers =>
      Stream.value(const <PeerInfo>[]);
  P2PService(this.displayName, {this.crypto});
  Future<void> start() async {}
  Future<void> stop() async {}
  Future<void> sendTo(PeerInfo peer, P2PMessage msg) async {}
  Future<void> broadcast(P2PMessage msg, List<PeerInfo> known) async {}
}
