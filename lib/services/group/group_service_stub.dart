import 'dart:async';
import '../p2p/crypto.dart';
import 'group_types.dart';
export 'group_types.dart';

/// Web stub: real group networking needs raw sockets / mDNS / WebRTC native
/// permissions which the browser does not expose. The UI still works in
/// single-device mode (you see your own avatar, can write chat to a local
/// log).
abstract class GroupService {
  Stream<GroupMessage> get messages;
  Stream<List<GroupPeer>> get peers;
  Future<void> start();
  Future<void> stop();

  Future<void> broadcastLocation({
    required double lat,
    required double lng,
    double? heading,
  });
  Future<void> sendChat(String text);
  Future<void> sendVoice(List<int> audio, String mime);
  Future<void> sendVoiceEnd();
  Future<void> sendChatTo(String peerId, String text);
  Future<void> sendVoiceTo(String peerId, List<int> audio, String mime);
  Future<void> sendVoiceEndTo(String peerId);
  Future<String> addManualPeer(String host, {int? port});
  Future<int> scanNow({bool big});
  List<String> get localIps;
  Future<void> sendMusicPlay({
    required String url,
    required String title,
    required String artist,
    required int positionMs,
  });
  Future<void> sendMusicStop();
  Future<void> broadcastCustom(String type, Map<String, dynamic> data);
  Future<void> sendCustomTo(
      String peerId, String type, Map<String, dynamic> data);

  static GroupService create({
    required int transport,
    required String selfId,
    required String selfName,
    required String groupId,
    required int selfColor,
    P2PCrypto? crypto,
    String? lanScanIp,
    int lanScanCidrBits = 24,
    String? webdavUrl,
    String? webdavUser,
    String? webdavPass,
    String signalingPath = '/explore_journal/signaling',
    int pollSec = 5,
    String iceServers = 'stun:stun.l.google.com:19302',
  }) =>
      _NoopGroupService();
}

class _NoopGroupService implements GroupService {
  @override
  Stream<GroupMessage> get messages => const Stream.empty();
  @override
  Stream<List<GroupPeer>> get peers => Stream.value(const <GroupPeer>[]);
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> broadcastLocation({
    required double lat,
    required double lng,
    double? heading,
  }) async {}
  @override
  Future<void> sendChat(String text) async {}
  @override
  Future<void> sendVoice(List<int> audio, String mime) async {}
  @override
  Future<void> sendVoiceEnd() async {}
  @override
  Future<void> sendMusicPlay({
    required String url,
    required String title,
    required String artist,
    required int positionMs,
  }) async {}
  @override
  Future<void> sendMusicStop() async {}
  @override
  Future<void> sendChatTo(String peerId, String text) async {}
  @override
  Future<void> sendVoiceTo(String peerId, List<int> audio, String mime) async {}
  @override
  Future<void> sendVoiceEndTo(String peerId) async {}
  @override
  Future<String> addManualPeer(String host, {int? port}) async =>
      'unsupported: 浏览器不能开 TCP socket';
  @override
  Future<int> scanNow({bool big = false}) async => 0;
  @override
  List<String> get localIps => const [];
  @override
  Future<void> broadcastCustom(
      String type, Map<String, dynamic> data) async {}
  @override
  Future<void> sendCustomTo(
      String peerId, String type, Map<String, dynamic> data) async {}
}
