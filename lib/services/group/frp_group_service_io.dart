import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'p2p_crypto.dart';
import 'frp_config.dart';
import 'frp_engine.dart';
import 'group_diagnostics.dart';
import 'group_service_io.dart' show GroupService;
import 'group_types.dart';

const _tag = 'frp';
GroupDiagnostics get _diag => groupDiagnostics;

/// frp XTCP transport. Reuses the exact same TCP-mesh wire protocol as the LAN
/// transport (newline-framed JSON [GroupMessage], optional `v1|` crypto
/// frames), so it interoperates with the rest of the group stack unchanged.
/// The only difference is *how* a socket to a peer is obtained:
///
///   LAN  → connect to the peer's discovered IP:port.
///   frp  → the embedded frpc punches an XTCP tunnel; we connect to the
///          loopback port the visitor binds locally (`127.0.0.1:bindPort`),
///          and that tunnel carries the bytes straight to the peer's mesh
///          server with no server-side relay of payload.
///
/// Roster discovery: poll the frps dashboard API for xtcp proxies whose name
/// starts with our group prefix; each is a member. Race avoidance: the
/// lexicographically-smaller id initiates the visitor connection, the larger
/// one accepts on its own proxy — exactly one socket per pair.
class FrpGroupService implements GroupService {
  static const int kPortBase = 47830;
  static const int kProbeCount = 5;

  final String selfId;
  final String selfName;
  final String groupId;
  final int selfColor;
  final P2PCrypto? crypto;

  final FrpEngine _engine;
  final String serverAddr;
  final int serverPort;
  final String? token;
  final String protocol;
  final String secretKey;
  final String? dashboardUrl;
  final String? dashboardUser;
  final String? dashboardPass;

  ServerSocket? _server;
  int? _meshPort;
  FrpConfigBuilder? _builder;
  Timer? _rosterTimer;
  Timer? _reconnectTimer;
  StreamSubscription<String>? _engineSub;

  /// peerId → loopback bind port assigned by the last config build.
  final _visitorPort = <String, int>{};
  /// Manually added peer ids (when dashboard discovery isn't configured).
  final _manualRoster = <String>{};
  /// Peers we've decided to actively connect to (selfId < peerId).
  final _wantConnect = <String>{};

  final _peerByConn = <Socket, String>{};
  final _peers = <String, GroupPeer>{};
  final _outgoing = <String, Socket>{};

  final _msgCtrl = StreamController<GroupMessage>.broadcast();
  final _peersCtrl = StreamController<List<GroupPeer>>.broadcast();

  FrpGroupService({
    required this.selfId,
    required this.selfName,
    required this.groupId,
    required this.selfColor,
    required FrpEngine engine,
    required this.serverAddr,
    required this.serverPort,
    required this.token,
    required this.protocol,
    required this.secretKey,
    this.crypto,
    this.dashboardUrl,
    this.dashboardUser,
    this.dashboardPass,
  }) : _engine = engine;

  @override
  Stream<GroupMessage> get messages => _msgCtrl.stream;
  @override
  Stream<List<GroupPeer>> get peers => _peersCtrl.stream;

  static String _safeId(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').padRight(1, 'g');
  String get _groupPrefix => 'ej-${_safeId(groupId)}';

  @override
  Future<void> start() async {
    if (_server != null) return;
    if (serverAddr.isEmpty) {
      throw StateError('未配置 frp 服务器地址');
    }
    // 1) Local mesh server — the xtcp proxy exposes this port.
    for (int i = 0; i < kProbeCount; i++) {
      try {
        _server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4, kPortBase + i,
            shared: true);
        _meshPort = kPortBase + i;
        break;
      } catch (_) {}
    }
    if (_server == null) {
      throw StateError('无法绑定本地 mesh 端口 '
          '$kPortBase..${kPortBase + kProbeCount - 1}');
    }
    _server!.listen(_acceptIncoming,
        onError: (e) => _diag.warn(_tag, 'mesh server error: $e'));

    _builder = FrpConfigBuilder(
      serverAddr: serverAddr,
      serverPort: serverPort,
      token: token,
      protocol: protocol,
      groupPrefix: _groupPrefix,
      selfPeerId: selfId,
      localMeshPort: _meshPort!,
      secretKey: secretKey,
    );

    _engineSub = _engine.events.listen((line) {
      if (line.isNotEmpty) _diag.trace(_tag, 'frpc: $line');
    });

    _diag.info(_tag,
        'Starting frpc → $serverAddr:$serverPort, proxy='
        '${_builder!.proxyNameFor(selfId)}, meshPort=$_meshPort, '
        'crypto=${crypto != null ? "on" : "off"}, '
        'discovery=${(dashboardUrl ?? '').isNotEmpty ? "dashboard" : "manual"}');

    // 2) Boot frpc with just our own proxy registered.
    await _applyConfig();

    // 3) Roster discovery + reconnect loops.
    await _refreshRoster();
    _rosterTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _refreshRoster());
    _reconnectTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _reconnectAll());
  }

  @override
  Future<void> stop() async {
    _rosterTimer?.cancel();
    _reconnectTimer?.cancel();
    await _engineSub?.cancel();
    _engineSub = null;
    for (final s in _outgoing.values) {
      try {
        await s.close();
      } catch (_) {}
    }
    _outgoing.clear();
    _peerByConn.clear();
    _peers.clear();
    _visitorPort.clear();
    _wantConnect.clear();
    _peersCtrl.add(const []);
    await _server?.close();
    _server = null;
    try {
      await _engine.stop();
    } catch (_) {}
    _diag.info(_tag, 'Stopped');
  }

  /// Rebuild + (re)apply the frpc config for the current want-connect roster.
  Future<void> _applyConfig() async {
    final builder = _builder;
    if (builder == null) return;
    // We only need a visitor (and thus an active socket) for peers we should
    // initiate to. The smaller-id side initiates; the larger side just keeps
    // its proxy and accepts the punched-in connection.
    final initiate = _wantConnect.toList();
    final cfg = builder.build(initiate);
    _visitorPort
      ..clear()
      ..addEntries(cfg.visitors.map((v) => MapEntry(v.peerId, v.bindPort)));
    try {
      if (await _engine.isRunning()) {
        await _engine.reload(cfg.toml);
      } else {
        await _engine.start(cfg.toml);
      }
    } on FrpUnsupported catch (e) {
      _diag.error(_tag, '内置 frpc 不可用：${e.message}');
      rethrow;
    } catch (e) {
      _diag.error(_tag, 'frpc 配置应用失败：$e');
    }
  }

  // ── Roster discovery ──────────────────────────────────────────────────

  Future<void> _refreshRoster() async {
    final discovered = <String>{..._manualRoster};
    final dash = dashboardUrl ?? '';
    if (dash.isNotEmpty) {
      try {
        discovered.addAll(await _queryDashboard(dash));
      } catch (e) {
        _diag.warn(_tag, 'dashboard 查询失败：$e');
      }
    }
    // Decide who we actively connect to (smaller id initiates).
    final want = discovered
        .where((id) => id != selfId && selfId.compareTo(id) < 0)
        .toSet();
    if (!_setEquals(want, _wantConnect)) {
      _wantConnect
        ..clear()
        ..addAll(want);
      _diag.info(_tag,
          'roster: ${discovered.length} member(s), '
          'initiating to ${want.length}');
      await _applyConfig();
    }
  }

  /// frps dashboard: GET /api/proxy/xtcp → { proxies: [ { name, ... } ] }.
  /// Names are `<groupPrefix>.<peerId>`; extract peer ids for our group.
  Future<Set<String>> _queryDashboard(String base) async {
    final uri = Uri.parse(
        '${base.replaceAll(RegExp(r"/+$"), "")}/api/proxy/xtcp');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(uri);
      final user = dashboardUser ?? '';
      final pass = dashboardPass ?? '';
      if (user.isNotEmpty || pass.isNotEmpty) {
        final cred = base64.encode(utf8.encode('$user:$pass'));
        req.headers.set(HttpHeaders.authorizationHeader, 'Basic $cred');
      }
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final doc = jsonDecode(body) as Map<String, dynamic>;
      final list = (doc['proxies'] as List?) ?? const [];
      final out = <String>{};
      final prefix = '$_groupPrefix.';
      for (final p in list) {
        if (p is! Map) continue;
        final name = p['name']?.toString() ?? '';
        if (!name.startsWith(prefix)) continue;
        final peerId = name.substring(prefix.length);
        if (peerId.isNotEmpty && !peerId.contains('.')) out.add(peerId);
      }
      return out;
    } finally {
      client.close(force: true);
    }
  }

  // ── Connection management ───────────────────────────────────────────────

  void _reconnectAll() {
    for (final entry in _visitorPort.entries) {
      final peerId = entry.key;
      if (_outgoing.containsKey(peerId)) continue; // already linked
      _connectVisitor(peerId, entry.value);
    }
  }

  Future<void> _connectVisitor(String peerId, int bindPort) async {
    if (_outgoing.containsKey(peerId)) return;
    try {
      final sock = await Socket.connect(
          InternetAddress.loopbackIPv4, bindPort,
          timeout: const Duration(seconds: 6));
      _outgoing[peerId] = sock; // optimistic; confirmed on first frame
      _bindSocket(sock, outgoing: true, hintPeer: peerId);
      _sendHello(sock);
      _diag.info(_tag, 'visitor → $peerId via 127.0.0.1:$bindPort');
    } catch (e) {
      _diag.trace(_tag, 'visitor $peerId not ready yet: $e');
    }
  }

  void _acceptIncoming(Socket socket) {
    _diag.info(_tag, 'mesh accept (punched-in tunnel)');
    _bindSocket(socket, outgoing: false);
  }

  void _bindSocket(Socket socket, {required bool outgoing, String? hintPeer}) {
    final dir = outgoing ? 'out' : 'in';
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) async {
        try {
          String payload = line;
          if (line.startsWith('v1|')) {
            if (crypto == null) {
              _diag.error(_tag,
                  '$dir: 收到加密帧但本端未设置口令，请两端配置相同共享口令');
              return;
            }
            final clear = await crypto!.decrypt(line);
            if (clear == null) {
              _diag.error(_tag, '$dir: 解密失败 — 两端共享口令不一致？');
              return;
            }
            payload = clear;
          } else if (crypto != null) {
            _diag.warn(_tag, '$dir: 收到明文帧但本端设置了口令，忽略');
            return;
          }
          final j = jsonDecode(payload) as Map<String, dynamic>;
          final msg = GroupMessage.fromJson(j);
          if (msg.groupId != groupId) {
            _diag.warn(_tag, '$dir: group 不匹配，忽略');
            return;
          }
          if (msg.fromId == selfId) return;
          final to = msg.data['to'];
          if (to is String && to.isNotEmpty && to != selfId) return;
          final isFirst = !_peerByConn.containsValue(msg.fromId);
          _peerByConn[socket] = msg.fromId;
          if (outgoing) _outgoing[msg.fromId] = socket;
          if (isFirst) {
            _diag.info(_tag, 'HANDSHAKE OK ($dir) ↔ ${msg.fromName}');
          }
          _onMessage(msg, socket);
          if (msg.type == 'hello' && !outgoing && isFirst) {
            _sendHello(socket);
          }
        } catch (e) {
          _diag.warn(_tag, '$dir: 处理消息出错：$e');
        }
      },
      onError: (e) {
        _diag.warn(_tag, '$dir socket error: $e');
        _closeSocket(socket, hintPeer);
      },
      onDone: () {
        _diag.info(_tag, '$dir disconnected');
        _closeSocket(socket, hintPeer);
      },
    );
  }

  void _closeSocket(Socket s, [String? hintPeer]) {
    final id = _peerByConn.remove(s) ?? hintPeer;
    if (id != null && _outgoing[id] == s) _outgoing.remove(id);
    try {
      s.destroy();
    } catch (_) {}
  }

  void _onMessage(GroupMessage msg, Socket from) {
    final existing = _peers[msg.fromId];
    final color = msg.type == 'hello'
        ? (msg.data['color'] as int? ??
            groupPalette[(_peers.length + 1) % groupPalette.length])
        : existing?.colorValue ??
            groupPalette[(_peers.length + 1) % groupPalette.length];
    final peer = existing ??
        GroupPeer(
          id: msg.fromId,
          name: msg.fromName,
          host: 'frp',
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
  }

  // ── Send paths (identical framing to the LAN transport) ─────────────────

  Future<void> _send(Socket s, GroupMessage msg) async {
    try {
      final payload = jsonEncode(msg.toJson());
      final line = crypto != null ? await crypto!.encrypt(payload) : payload;
      s.write('$line\n');
      await s.flush();
    } catch (_) {
      _closeSocket(s);
    }
  }

  Future<void> _broadcast(GroupMessage msg) async {
    final all = <Socket>{..._outgoing.values, ..._peerByConn.keys};
    for (final s in all) {
      await _send(s, msg);
    }
  }

  Future<void> _sendOne(String peerId, GroupMessage msg) async {
    final s = _outgoing[peerId];
    if (s == null) {
      await _broadcast(msg);
      return;
    }
    await _send(s, msg);
  }

  GroupMessage _msg(String type, Map<String, dynamic> data) => GroupMessage(
        type: type,
        fromId: selfId,
        fromName: selfName,
        groupId: groupId,
        data: data,
        time: DateTime.now(),
      );

  void _sendHello(Socket s) => _send(s, _msg('hello', {'color': selfColor}));

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
  Future<void> sendVoiceEnd() async => _broadcast(_msg('voice_end', {}));

  @override
  Future<void> sendChatTo(String peerId, String text) async =>
      _sendOne(peerId, _msg('chat', {'text': text, 'to': peerId}));

  @override
  Future<void> sendVoiceTo(String peerId, List<int> audio, String mime) async =>
      _sendOne(peerId,
          _msg('voice', {'audio': base64.encode(audio), 'mime': mime, 'to': peerId}));

  @override
  Future<void> sendVoiceEndTo(String peerId) async =>
      _sendOne(peerId, _msg('voice_end', {'to': peerId}));

  @override
  Future<void> sendMusicPlay({
    required String url,
    required String title,
    required String artist,
    required int positionMs,
  }) async {
    await _broadcast(_msg('music_play',
        {'url': url, 'title': title, 'artist': artist, 'pos': positionMs}));
  }

  @override
  Future<void> sendMusicStop() async => _broadcast(_msg('music_stop', {}));

  @override
  Future<void> broadcastCustom(String type, Map<String, dynamic> data) async =>
      _broadcast(_msg(type, data));

  @override
  Future<void> sendCustomTo(
          String peerId, String type, Map<String, dynamic> data) async =>
      _sendOne(peerId, _msg(type, {...data, 'to': peerId}));

  /// For frp, "manual peer" is a peer id (there's no IP to dial). Adds it to
  /// the roster so a visitor + connection are created even without dashboard
  /// discovery. The [port] arg is ignored.
  @override
  Future<String> addManualPeer(String host, {int? port}) async {
    if (_server == null) return 'service-not-running';
    final peerId = host.trim();
    if (peerId.isEmpty) return '请输入对方的 Peer ID';
    if (peerId == selfId) return '不能添加自己';
    _manualRoster.add(peerId);
    await _refreshRoster();
    return selfId.compareTo(peerId) < 0
        ? 'ok: 已加入并尝试打洞 $peerId'
        : 'ok: 已记录 $peerId（由对方发起连接）';
  }

  @override
  Future<int> scanNow({bool big = false}) async {
    await _refreshRoster();
    return _wantConnect.length;
  }

  @override
  List<String> get localIps => const [];

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
