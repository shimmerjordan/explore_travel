import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../p2p/crypto.dart';
import 'group_diagnostics.dart';
import 'group_service_io.dart' show GroupService;
import 'group_types.dart';

/// Cloud-relay transport: every member connects one WebSocket to the
/// self-hosted backend (`backends/` in this repo) and the server fans
/// messages out within the room. Compared to the P2P transports this is
/// the "always works" option — no multicast, no hole punching, no
/// signaling storage — at the cost of relaying through a server you run.
///
/// Wire format is IDENTICAL to the LAN/frp transports: one JSON
/// [GroupMessage] per line, optionally encrypted to `v1|…` by the shared
/// passphrase. The server never parses payloads — with a passphrase set it
/// relays ciphertext blindly (zero-knowledge). Targeted sends use a tiny
/// plaintext routing prefix `@<peerId>|<payload>` which the server strips,
/// so 1:1 chat/voice costs one hop instead of a room broadcast.
///
/// Presence: there is no server-side roster. Peers announce themselves via
/// periodic `hello` broadcasts (25 s) exactly like the LAN transport, and
/// are pruned after 75 s of silence. This keeps idle bandwidth at
/// ~10 B/s per member.
class RelayGroupService implements GroupService {
  final String selfId;
  final String selfName;
  final String groupId;
  final int selfColor;
  final P2PCrypto? crypto;
  /// Backend base URL, e.g. `https://ej.example.com` — http(s) scheme is
  /// converted to ws(s) automatically.
  final String serverUrl;
  final String? token;

  static const _tag = 'RelayGroup';
  static const _helloEvery = Duration(seconds: 25);
  static const _peerTimeout = Duration(seconds: 75);

  final _diag = groupDiagnostics;
  final _msgCtrl = StreamController<GroupMessage>.broadcast();
  final _peersCtrl = StreamController<List<GroupPeer>>.broadcast();
  final _peers = <String, GroupPeer>{};

  WebSocket? _ws;
  bool _running = false;
  int _backoffSec = 2;
  Timer? _helloTimer;
  Timer? _pruneTimer;

  RelayGroupService({
    required this.selfId,
    required this.selfName,
    required this.groupId,
    required this.selfColor,
    required this.serverUrl,
    this.token,
    this.crypto,
  });

  @override
  Stream<GroupMessage> get messages => _msgCtrl.stream;
  @override
  Stream<List<GroupPeer>> get peers => _peersCtrl.stream;

  static String _safeId(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').padRight(1, 'g');

  Uri _wsUri() {
    var base = serverUrl.trim();
    if (base.isEmpty) {
      throw StateError('未配置中继服务器地址');
    }
    base = base.replaceAll(RegExp(r'/+$'), '');
    if (base.startsWith('https://')) {
      base = 'wss://${base.substring(8)}';
    } else if (base.startsWith('http://')) {
      base = 'ws://${base.substring(7)}';
    } else if (!base.startsWith('ws://') && !base.startsWith('wss://')) {
      base = 'wss://$base';
    }
    return Uri.parse('$base/group/v1/ws').replace(queryParameters: {
      'group': _safeId(groupId),
      'peer': selfId,
      if ((token ?? '').isNotEmpty) 'token': token!,
    });
  }

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _diag.info(_tag,
        'Starting relay → $serverUrl, group="$groupId", '
        'crypto=${crypto != null ? "on" : "off"}');
    _helloTimer = Timer.periodic(_helloEvery, (_) => _broadcastHello());
    _pruneTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _prunePeers());
    // First connection failure should surface to the caller (bad URL /
    // token) instead of silently retrying forever in the background.
    await _connect(rethrowFirst: true);
  }

  @override
  Future<void> stop() async {
    _running = false;
    _helloTimer?.cancel();
    _pruneTimer?.cancel();
    _helloTimer = null;
    _pruneTimer = null;
    try {
      await _ws?.close(1000);
    } catch (_) {}
    _ws = null;
    _peers.clear();
    _peersCtrl.add(const []);
    _diag.info(_tag, 'Stopped');
  }

  Future<void> _connect({bool rethrowFirst = false}) async {
    if (!_running || _ws != null) return;
    try {
      final ws = await WebSocket.connect(_wsUri().toString())
          .timeout(const Duration(seconds: 10));
      // The server pings every 30 s; this is a belt-and-suspenders probe so
      // half-dead mobile links are noticed from our side too.
      ws.pingInterval = const Duration(seconds: 30);
      _ws = ws;
      _backoffSec = 2;
      _diag.info(_tag, 'Connected to relay');
      ws.listen(
        (frame) {
          if (frame is String) _onLine(frame);
        },
        onError: (e) {
          _diag.warn(_tag, 'socket error: $e');
          _onDisconnected();
        },
        onDone: () {
          _diag.info(_tag, 'disconnected (code=${ws.closeCode})');
          _onDisconnected();
        },
        cancelOnError: true,
      );
      await _broadcastHello();
    } catch (e) {
      _ws = null;
      _diag.error(_tag, '连接中继失败：$e');
      if (rethrowFirst) rethrow;
      _scheduleReconnect();
    }
  }

  void _onDisconnected() {
    _ws = null;
    if (_running) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_running) return;
    final delay = Duration(seconds: _backoffSec);
    _backoffSec = (_backoffSec * 2).clamp(2, 30);
    _diag.info(_tag, 'reconnect in ${delay.inSeconds}s');
    Timer(delay, () => _connect());
  }

  Future<void> _onLine(String line) async {
    try {
      String payload = line;
      if (line.startsWith('v1|')) {
        if (crypto == null) {
          _diag.error(_tag, '收到加密帧但本端未设置口令，请两端配置相同共享口令');
          return;
        }
        final clear = await crypto!.decrypt(line);
        if (clear == null) {
          _diag.error(_tag, '解密失败 — 两端共享口令不一致？');
          return;
        }
        payload = clear;
      } else if (crypto != null) {
        _diag.warn(_tag, '收到明文帧但本端设置了口令，忽略');
        return;
      }
      final msg =
          GroupMessage.fromJson(jsonDecode(payload) as Map<String, dynamic>);
      if (msg.groupId != groupId) return;
      if (msg.fromId == selfId) return;
      final to = msg.data['to'];
      if (to is String && to.isNotEmpty && to != selfId) return;
      _onMessage(msg);
    } catch (e) {
      _diag.warn(_tag, '处理消息出错：$e');
    }
  }

  void _onMessage(GroupMessage msg) {
    final existing = _peers[msg.fromId];
    final color = msg.type == 'hello'
        ? (msg.data['color'] as int? ??
            groupPalette[(_peers.length + 1) % groupPalette.length])
        : existing?.colorValue ??
            groupPalette[(_peers.length + 1) % groupPalette.length];
    final isNew = existing == null;
    final peer = existing ??
        GroupPeer(
          id: msg.fromId,
          name: msg.fromName,
          host: 'relay',
          port: 0,
          colorValue: color,
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
    // A peer we've never seen said hello → answer directly so THEY learn
    // about us without waiting for our next periodic hello.
    if (msg.type == 'hello' && isNew) {
      _sendLine(_msg('hello', {'color': selfColor}), to: msg.fromId);
    }
  }

  void _prunePeers() {
    final now = DateTime.now();
    final before = _peers.length;
    _peers.removeWhere((_, p) => now.difference(p.lastSeen) > _peerTimeout);
    if (_peers.length != before) _peersCtrl.add(_peers.values.toList());
  }

  GroupMessage _msg(String type, Map<String, dynamic> data) => GroupMessage(
        type: type,
        fromId: selfId,
        fromName: selfName,
        groupId: groupId,
        data: data,
        time: DateTime.now(),
      );

  /// Serialize (+encrypt) and write one message. When [to] is set the
  /// plaintext routing prefix keeps it off everyone else's downlink.
  Future<void> _sendLine(GroupMessage msg, {String? to}) async {
    final ws = _ws;
    if (ws == null) return;
    try {
      final payload = jsonEncode(msg.toJson());
      final line = crypto != null ? await crypto!.encrypt(payload) : payload;
      ws.add(to == null ? line : '@$to|$line');
    } catch (e) {
      _diag.warn(_tag, 'send failed: $e');
    }
  }

  Future<void> _broadcastHello() =>
      _sendLine(_msg('hello', {'color': selfColor}));

  @override
  Future<void> broadcastLocation({
    required double lat,
    required double lng,
    double? heading,
  }) =>
      _sendLine(_msg('location', {
        'lat': lat,
        'lng': lng,
        if (heading != null) 'heading': heading,
      }));

  @override
  Future<void> sendChat(String text) => _sendLine(_msg('chat', {'text': text}));

  @override
  Future<void> sendVoice(List<int> audio, String mime) => _sendLine(
      _msg('voice', {'audio': base64.encode(audio), 'mime': mime}));

  @override
  Future<void> sendVoiceEnd() => _sendLine(_msg('voice_end', {}));

  @override
  Future<void> sendChatTo(String peerId, String text) =>
      _sendLine(_msg('chat', {'text': text, 'to': peerId}), to: peerId);

  @override
  Future<void> sendVoiceTo(String peerId, List<int> audio, String mime) =>
      _sendLine(
          _msg('voice',
              {'audio': base64.encode(audio), 'mime': mime, 'to': peerId}),
          to: peerId);

  @override
  Future<void> sendVoiceEndTo(String peerId) =>
      _sendLine(_msg('voice_end', {'to': peerId}), to: peerId);

  @override
  Future<void> sendMusicPlay({
    required String url,
    required String title,
    required String artist,
    required int positionMs,
  }) =>
      _sendLine(_msg('music_play', {
        'url': url,
        'title': title,
        'artist': artist,
        'pos': positionMs,
      }));

  @override
  Future<void> sendMusicStop() => _sendLine(_msg('music_stop', {}));

  @override
  Future<void> broadcastCustom(String type, Map<String, dynamic> data) =>
      _sendLine(_msg(type, data));

  @override
  Future<void> sendCustomTo(
          String peerId, String type, Map<String, dynamic> data) =>
      _sendLine(_msg(type, {...data, 'to': peerId}), to: peerId);

  @override
  Future<String> addManualPeer(String host, {int? port}) async =>
      'unsupported: 中继模式无需手动添加成员';

  @override
  Future<int> scanNow({bool big = false}) async => 0;

  @override
  List<String> get localIps => const [];
}
