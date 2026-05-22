import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;
import '../p2p/crypto.dart';
import 'group_service_io.dart' show GroupService;
import 'group_types.dart';

/// WebRTC + WebDAV-signaling group transport.
///
/// Wire-level protocol:
///   - Each peer has a `selfId`. The WebDAV root for this group is
///     `<signalingPath>/<groupId>/`.
///   - Inside that, every peer has a "mailbox" directory: `<peerId>/`.
///   - To send peer A → peer B, A creates a file
///     `<mailbox>/B/<unix-ms>-<from>-<kind>.json` with the SDP/ICE payload.
///   - Every [pollSec] seconds, each peer PROPFINDs its own mailbox, GETs
///     new files, then DELETEs them.
///   - An "announce.json" file in the group root lists active peer IDs +
///     last-seen timestamps, so peers can find each other to start
///     offer/answer.
///
/// After the SDP+ICE handshake completes, an [RTCDataChannel] is opened and
/// all subsequent traffic (chat, location, voice) flows over it — direct
/// P2P, no more WebDAV hits.
class WebRtcGroupService implements GroupService {
  static const _kAnnounceInterval = Duration(seconds: 30);

  final String selfId;
  final String selfName;
  final String groupId;
  final int selfColor;
  final P2PCrypto? crypto;
  final String webdavUrl;
  final String webdavUser;
  final String webdavPass;
  final String signalingPath;
  final int pollSec;
  final String iceServers;

  webdav.Client? _dav;
  Timer? _pollTimer;
  Timer? _announceTimer;
  bool _running = false;

  /// peerId → connection bundle.
  final _conns = <String, _PeerConn>{};
  final _peers = <String, GroupPeer>{};

  final _msgCtrl = StreamController<GroupMessage>.broadcast();
  final _peersCtrl = StreamController<List<GroupPeer>>.broadcast();

  @override
  Stream<GroupMessage> get messages => _msgCtrl.stream;
  @override
  Stream<List<GroupPeer>> get peers => _peersCtrl.stream;

  WebRtcGroupService({
    required this.selfId,
    required this.selfName,
    required this.groupId,
    required this.selfColor,
    this.crypto,
    required this.webdavUrl,
    required this.webdavUser,
    required this.webdavPass,
    required this.signalingPath,
    required this.pollSec,
    required this.iceServers,
  });

  String get _root => '$signalingPath/$groupId';
  String get _myMailbox => '$_root/$selfId';
  String get _announceFile => '$_root/announce.json';

  Map<String, dynamic> get _iceConfig => {
        'iceServers': iceServers
            .split(',')
            .map((u) => u.trim())
            .where((u) => u.isNotEmpty)
            .map((u) => {'urls': u})
            .toList(),
        'sdpSemantics': 'unified-plan',
      };

  @override
  Future<void> start() async {
    if (_running) return;
    if (webdavUrl.isEmpty) {
      throw StateError('WebRTC transport 需要先配置 WebDAV 账户');
    }
    _running = true;
    _dav = webdav.newClient(webdavUrl, user: webdavUser, password: webdavPass);
    try {
      await _dav!.mkdirAll(_root);
      await _dav!.mkdirAll(_myMailbox);
    } catch (_) {}
    await _announce();
    _pollTimer =
        Timer.periodic(Duration(seconds: pollSec), (_) => _pollMailbox());
    _announceTimer = Timer.periodic(_kAnnounceInterval, (_) => _announce());
    await _pollMailbox();
    await _connectKnownPeers();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
    _announceTimer?.cancel();
    for (final c in _conns.values) {
      await c.dispose();
    }
    _conns.clear();
    _peers.clear();
    _peersCtrl.add(const []);
    // Best-effort cleanup of our mailbox.
    try {
      await _dav?.remove(_myMailbox);
    } catch (_) {}
    _dav = null;
  }

  Future<void> _announce() async {
    if (!_running) return;
    try {
      Map<String, dynamic> doc = {'peers': <String, dynamic>{}};
      try {
        final raw = await _dav!.read(_announceFile);
        doc = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      } catch (_) {}
      final peers =
          (doc['peers'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      peers[selfId] = {
        'name': selfName,
        'color': selfColor,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
      // Drop peers older than 5 minutes.
      final cutoff = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      peers.removeWhere((_, v) =>
          (v is Map && (v['ts'] as int? ?? 0) < cutoff));
      doc['peers'] = peers;
      await _dav!.write(
          _announceFile, Uint8List.fromList(utf8.encode(jsonEncode(doc))));
    } catch (_) {}
  }

  Future<void> _connectKnownPeers() async {
    try {
      final raw = await _dav!.read(_announceFile);
      final doc = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      final peers = (doc['peers'] as Map).cast<String, dynamic>();
      for (final entry in peers.entries) {
        if (entry.key == selfId) continue;
        if (_conns.containsKey(entry.key)) continue;
        // Only the lexicographically-smaller id offers, to avoid both sides
        // racing to create offers.
        if (selfId.compareTo(entry.key) < 0) {
          await _initiate(entry.key);
        }
      }
    } catch (_) {}
  }

  Future<void> _pollMailbox() async {
    if (!_running) return;
    try {
      final files = await _dav!.readDir(_myMailbox);
      for (final f in files) {
        if (f.isDir == true) continue;
        final name = f.name ?? '';
        if (!name.endsWith('.json')) continue;
        final fullPath = '$_myMailbox/$name';
        try {
          final raw = await _dav!.read(fullPath);
          final doc = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
          await _handleSignal(doc);
        } catch (_) {}
        try {
          await _dav!.remove(fullPath);
        } catch (_) {}
      }
      // Also opportunistically (re)discover peers.
      await _connectKnownPeers();
    } catch (_) {}
  }

  Future<void> _putSignal(
      String toPeerId, String kind, Map<String, dynamic> payload) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = '$_root/$toPeerId/$ts-$selfId-$kind.json';
    final doc = {
      'from': selfId,
      'fromName': selfName,
      'color': selfColor,
      'kind': kind,
      'payload': payload,
    };
    try {
      await _dav!.mkdirAll('$_root/$toPeerId');
      await _dav!.write(path, Uint8List.fromList(utf8.encode(jsonEncode(doc))));
    } catch (_) {}
  }

  Future<void> _initiate(String peerId) async {
    final conn = await _ensureConn(peerId, asOfferer: true);
    final dc = await conn.pc.createDataChannel(
      'xj',
      RTCDataChannelInit()..ordered = true,
    );
    conn.attachDataChannel(dc);
    final offer = await conn.pc.createOffer();
    await conn.pc.setLocalDescription(offer);
    await _putSignal(peerId, 'offer', offer.toMap());
  }

  Future<_PeerConn> _ensureConn(String peerId,
      {required bool asOfferer}) async {
    final existing = _conns[peerId];
    if (existing != null) return existing;
    final pc = await createPeerConnection(_iceConfig);
    final conn = _PeerConn(peerId: peerId, pc: pc, onLine: _onLine);
    _conns[peerId] = conn;

    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _putSignal(peerId, 'ice', c.toMap());
    };
    pc.onConnectionState = (state) {
      if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        conn.dispose();
        _conns.remove(peerId);
      }
    };
    if (!asOfferer) {
      pc.onDataChannel = (channel) => conn.attachDataChannel(channel);
    }
    return conn;
  }

  Future<void> _handleSignal(Map<String, dynamic> doc) async {
    final from = doc['from'] as String?;
    if (from == null || from == selfId) return;
    final kind = doc['kind'] as String?;
    final payload = (doc['payload'] as Map?)?.cast<String, dynamic>();
    if (kind == null || payload == null) return;

    final color = (doc['color'] as int?) ?? groupPalette[
        (_peers.length + 1) % groupPalette.length];
    _peers[from] ??= GroupPeer(
      id: from,
      name: doc['fromName'] as String? ?? from,
      host: 'webrtc',
      port: 0,
      colorValue: color,
      lastSeen: DateTime.now(),
    );
    _peersCtrl.add(_peers.values.toList());

    switch (kind) {
      case 'offer':
        final conn = await _ensureConn(from, asOfferer: false);
        await conn.pc.setRemoteDescription(
            RTCSessionDescription(payload['sdp'], payload['type']));
        final answer = await conn.pc.createAnswer();
        await conn.pc.setLocalDescription(answer);
        await _putSignal(from, 'answer', answer.toMap());
        break;
      case 'answer':
        final conn = _conns[from];
        if (conn != null) {
          await conn.pc.setRemoteDescription(
              RTCSessionDescription(payload['sdp'], payload['type']));
        }
        break;
      case 'ice':
        final conn = _conns[from];
        if (conn != null) {
          await conn.pc.addCandidate(RTCIceCandidate(
            payload['candidate'],
            payload['sdpMid'],
            payload['sdpMLineIndex'],
          ));
        }
        break;
    }
  }

  Future<void> _onLine(String fromId, String line) async {
    try {
      String payload = line;
      if (line.startsWith('v1|') && crypto != null) {
        final clear = await crypto!.decrypt(line);
        if (clear == null) return;
        payload = clear;
      }
      final j = jsonDecode(payload) as Map<String, dynamic>;
      final msg = GroupMessage.fromJson(j);
      if (msg.groupId != groupId) return;
      if (msg.fromId == selfId) return;
      final to = msg.data['to'];
      if (to is String && to.isNotEmpty && to != selfId) return;

      final existing = _peers[msg.fromId];
      final peer = existing ??
          GroupPeer(
            id: msg.fromId,
            name: msg.fromName,
            host: 'webrtc',
            port: 0,
            colorValue: (msg.data['color'] as int?) ??
                groupPalette[(_peers.length + 1) % groupPalette.length],
            lastSeen: msg.time,
          );
      peer.lastSeen = DateTime.now();
      if (msg.type == 'location') {
        peer.lat = (msg.data['lat'] as num?)?.toDouble();
        peer.lng = (msg.data['lng'] as num?)?.toDouble();
        peer.heading = (msg.data['heading'] as num?)?.toDouble();
      }
      _peers[msg.fromId] = peer;
      _peersCtrl.add(_peers.values.toList());
      _msgCtrl.add(msg);
    } catch (_) {}
  }

  GroupMessage _msg(String type, Map<String, dynamic> data) =>
      GroupMessage(
        type: type,
        fromId: selfId,
        fromName: selfName,
        groupId: groupId,
        data: data,
        time: DateTime.now(),
      );

  Future<void> _broadcast(GroupMessage msg) async {
    final payload = jsonEncode(msg.toJson());
    final line =
        crypto != null ? await crypto!.encrypt(payload) : payload;
    for (final c in _conns.values) {
      c.send(line);
    }
  }

  @override
  Future<void> broadcastLocation({
    required double lat,
    required double lng,
    double? heading,
  }) async {
    await _broadcast(_msg('location', {
      'lat': lat,
      'lng': lng,
      if (heading != null) 'heading': heading,
    }));
  }

  @override
  Future<void> sendChat(String text) async =>
      _broadcast(_msg('chat', {'text': text}));

  @override
  Future<void> sendVoice(List<int> audio, String mime) async => _broadcast(
      _msg('voice', {'audio': base64.encode(audio), 'mime': mime}));

  @override
  Future<void> sendVoiceEnd() async =>
      _broadcast(_msg('voice_end', const {}));

  @override
  Future<void> sendMusicPlay({
    required String url,
    required String title,
    required String artist,
    required int positionMs,
  }) async =>
      _broadcast(_msg('music_play', {
        'url': url,
        'title': title,
        'artist': artist,
        'pos': positionMs,
      }));

  @override
  Future<void> sendMusicStop() async =>
      _broadcast(_msg('music_stop', const {}));

  Future<void> _sendOne(String peerId, GroupMessage msg) async {
    final payload = jsonEncode(msg.toJson());
    final line =
        crypto != null ? await crypto!.encrypt(payload) : payload;
    final c = _conns[peerId];
    if (c == null) {
      // No direct channel yet — fall back to broadcast; receivers filter.
      for (final cc in _conns.values) {
        cc.send(line);
      }
      return;
    }
    c.send(line);
  }

  @override
  Future<void> sendChatTo(String peerId, String text) =>
      _sendOne(peerId, _msg('chat', {'text': text, 'to': peerId}));

  @override
  Future<void> sendVoiceTo(
          String peerId, List<int> audio, String mime) =>
      _sendOne(
          peerId,
          _msg('voice', {
            'audio': base64.encode(audio),
            'mime': mime,
            'to': peerId,
          }));

  @override
  Future<void> sendVoiceEndTo(String peerId) =>
      _sendOne(peerId, _msg('voice_end', {'to': peerId}));

  @override
  Future<String> addManualPeer(String host, {int? port}) async =>
      'unsupported: WebRTC transport 通过 WebDAV 信令自动发现，不需要手动 IP';
  @override
  Future<int> scanNow({bool big = false}) async => 0;
  @override
  List<String> get localIps => const [];
}

class _PeerConn {
  final String peerId;
  final RTCPeerConnection pc;
  final Future<void> Function(String fromId, String line) onLine;
  RTCDataChannel? _dc;
  final _outbox = <String>[];

  _PeerConn(
      {required this.peerId, required this.pc, required this.onLine});

  void attachDataChannel(RTCDataChannel dc) {
    _dc = dc;
    dc.onMessage = (msg) {
      if (!msg.isBinary) onLine(peerId, msg.text);
    };
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        for (final pending in _outbox) {
          dc.send(RTCDataChannelMessage(pending));
        }
        _outbox.clear();
      }
    };
  }

  void send(String line) {
    final dc = _dc;
    if (dc == null) {
      _outbox.add(line);
      return;
    }
    try {
      dc.send(RTCDataChannelMessage(line));
    } catch (_) {
      _outbox.add(line);
    }
  }

  Future<void> dispose() async {
    try {
      await _dc?.close();
    } catch (_) {}
    try {
      await pc.close();
    } catch (_) {}
  }
}

// Avoid an unused-import warning when Platform isn't referenced elsewhere.
// ignore: unused_element
final _platformGuard = Platform.numberOfProcessors;
