import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../p2p/crypto.dart';
import 'frp_engine.dart';
import 'frp_group_service_io.dart';
import 'group_diagnostics.dart';
import 'group_types.dart';
import 'multicast_lock_io.dart';
import 'relay_group_service_io.dart';
import 'webrtc_group_service_io.dart';
export 'group_types.dart';

const _diagTag = 'lan';
GroupDiagnostics get _diag => groupDiagnostics;

/// Public interface — every transport (LAN/mDNS, ZeroTier, WebRTC) implements
/// these methods. The provider in [providers.dart] calls [GroupService.create]
/// with the user's selected transport; concrete classes are private to this
/// library.
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
  /// Targeted (1:1) variants. Implementations should route to the single
  /// connection for [peerId] when possible, instead of flooding the mesh.
  Future<void> sendChatTo(String peerId, String text);
  Future<void> sendVoiceTo(String peerId, List<int> audio, String mime);
  Future<void> sendVoiceEndTo(String peerId);

  /// Best-effort manual peer add. The setup screen exposes this so users
  /// can bootstrap discovery on a network where multicast is dropped —
  /// paste the other device's IP (and optionally port).
  ///
  /// Returns a short human-readable status:
  ///   - "ok: <port>"         connected & hello sent
  ///   - "service-not-running" the service hasn't been started yet
  ///   - "unsupported"         this transport doesn't use TCP
  ///   - "<errno>: <details>"  connect failed; what was tried + last error
  Future<String> addManualPeer(String host, {int? port});

  /// Trigger an active subnet scan immediately. Returns the number of new
  /// hosts attempted. Transports that don't use IP scanning return 0.
  /// [big] expands the scan to /16 — costs minutes; only call from user
  /// gesture.
  Future<int> scanNow({bool big = false}) async => 0;

  /// The local IPv4 addresses this device knows about (after filtering for
  /// private ranges). Used by the setup screen to tell the user "your IP is
  /// X, give it to the other side". Empty when not yet started.
  List<String> get localIps => const [];

  /// Escape hatch for higher layers (e.g. leaderboard sync) to flood an
  /// arbitrary typed message. Receivers see it on [messages] and switch
  /// on [GroupMessage.type].
  Future<void> broadcastCustom(String type, Map<String, dynamic> data);
  Future<void> sendCustomTo(
      String peerId, String type, Map<String, dynamic> data);

  Future<void> sendMusicPlay({
    required String url,
    required String title,
    required String artist,
    required int positionMs,
  });
  Future<void> sendMusicStop();

  /// Factory. [transport] is the index of [GroupTransport] in [models.dart];
  /// kept as an int here so this file doesn't depend on the models layer.
  ///   0 → lan         (mDNS + TCP, same wire format as ZT)
  ///   1 → zerotier    (also LAN mDNS + TCP — ZT is just the underlay)
  ///   2 → webrtc      (RTCDataChannel + WebDAV signaling)
  ///   3 → frp         (embedded frpc XTCP hole punch + TCP mesh)
  ///   4 → relay       (WebSocket fan-out via the self-hosted backend)
  static GroupService create({
    required int transport,
    required String selfId,
    required String selfName,
    required String groupId,
    required int selfColor,
    P2PCrypto? crypto,
    // LAN-only:
    String? lanScanIp,
    int lanScanCidrBits = 24,
    // WebRTC-only:
    String? webdavUrl,
    String? webdavUser,
    String? webdavPass,
    String signalingPath = '/explore_journal/signaling',
    int pollSec = 5,
    String iceServers = 'stun:stun.l.google.com:19302',
    // frp-only:
    String frpServerAddr = '',
    int frpServerPort = 7000,
    String? frpToken,
    String frpProtocol = 'quic',
    String frpSecretKey = '',
    String? frpDashboardUrl,
    String? frpDashboardUser,
    String? frpDashboardPass,
    // relay-only:
    String relayServerUrl = '',
    String? relayToken,
  }) {
    if (transport == 4) {
      return RelayGroupService(
        selfId: selfId,
        selfName: selfName,
        groupId: groupId,
        selfColor: selfColor,
        crypto: crypto,
        serverUrl: relayServerUrl,
        token: relayToken,
      );
    }
    if (transport == 3) {
      return FrpGroupService(
        selfId: selfId,
        selfName: selfName,
        groupId: groupId,
        selfColor: selfColor,
        crypto: crypto,
        engine: FrpEngine.create(),
        serverAddr: frpServerAddr,
        serverPort: frpServerPort,
        token: frpToken,
        protocol: frpProtocol,
        secretKey: frpSecretKey,
        dashboardUrl: frpDashboardUrl,
        dashboardUser: frpDashboardUser,
        dashboardPass: frpDashboardPass,
      );
    }
    // Legacy: transport==1 (zerotier) is the same wire as lan.
    if (transport == 2) {
      if (!_webrtcSupported) {
        throw StateError(
            '当前平台暂不支持 WebRTC transport，请改用 LAN/ZeroTier');
      }
      return WebRtcGroupService(
        selfId: selfId,
        selfName: selfName,
        groupId: groupId,
        selfColor: selfColor,
        crypto: crypto,
        webdavUrl: webdavUrl ?? '',
        webdavUser: webdavUser ?? '',
        webdavPass: webdavPass ?? '',
        signalingPath: signalingPath,
        pollSec: pollSec,
        iceServers: iceServers,
      );
    }
    return _LanGroupService(
      selfId: selfId,
      selfName: selfName,
      groupId: groupId,
      selfColor: selfColor,
      crypto: crypto,
      scanIp: lanScanIp,
      scanCidrBits: lanScanCidrBits,
    );
  }

  static bool get _webrtcSupported =>
      Platform.isAndroid || Platform.isIOS;
}

/// LAN transport: UDP **multicast** discovery + TCP mesh data channel.
///
/// Why multicast instead of broadcast:
///   - `255.255.255.255` is "limited broadcast" — on Android many vendors
///     only emit it on the default route (Wi-Fi), so a ZeroTier `tun`
///     interface never sees it.
///   - ZeroTier's own subnet mask is typically /16 (`172.x.x.x/16`), so
///     computing directed broadcast as `a.b.c.255` (assumes /24) misses
///     most of the ZT membership.
///   - UDP multicast on a well-known group works identically across home
///     Wi-Fi, ZT, Tailscale subnets. Same machinery as mDNS uses.
///
/// Protocol:
///   - Each peer joins multicast group [_kMcastGroup]:[kDiscoveryPort] on
///     every IPv4 interface (Wi-Fi + ZT + ethernet + cellular).
///   - Every [_discoveryInterval] seconds it sends a small JSON datagram
///     to the multicast group: `{g, id, n, p, c}`.
///   - On receive, the peer opens a TCP connection to
///     (datagram.source, datagram.p) for the same group. Race-avoidance:
///     lexicographically-smaller peerId initiates.
///   - Actual data (chat, location, voice) flows over TCP. Wire format
///     unchanged.
class _LanGroupService implements GroupService {
  static const int kPortBase = 47830;
  static const int kProbeCount = 5;
  static const int kDiscoveryPort = 47829;
  static const String _kMcastGroup = '239.42.42.42';
  static const _heartbeat = Duration(seconds: 8);
  static const _discoveryInterval = Duration(seconds: 4);

  final String selfId;
  final String selfName;
  final String groupId;
  final P2PCrypto? crypto;
  final int selfColor;
  /// If non-null, restrict the active scan to the subnet of this IP. Empty
  /// or null = walk every private interface. Set this to your ZeroTier
  /// IP so the scan doesn't touch your home Wi-Fi.
  String? scanIp;
  /// CIDR prefix bits for the active scan. 24 = /24 (~254 hosts), 16 = /16
  /// (65k hosts; only ever runs on user-triggered scanNow()).
  int scanCidrBits;

  ServerSocket? _server;
  RawDatagramSocket? _udp;
  int? _port;
  Timer? _heartbeatTimer;
  Timer? _discoverTimer;
  Timer? _scanTimer;

  /// Hosts we've already TCP-poked this scan cycle. Cleared periodically so
  /// reachable peers that came online later get a fresh chance.
  final _triedHosts = <String>{};

  final _peerByConn = <Socket, String>{};
  final _peers = <String, GroupPeer>{};
  final _outgoing = <String, Socket>{};

  final _msgCtrl = StreamController<GroupMessage>.broadcast();
  final _peersCtrl = StreamController<List<GroupPeer>>.broadcast();

  @override
  Stream<GroupMessage> get messages => _msgCtrl.stream;
  @override
  Stream<List<GroupPeer>> get peers => _peersCtrl.stream;

  _LanGroupService({
    required this.selfId,
    required this.selfName,
    required this.groupId,
    required this.selfColor,
    this.crypto,
    this.scanIp,
    this.scanCidrBits = 24,
  });

  static String _safeId(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').padRight(1, 'g');

  String get _safeGroup => _safeId(groupId);

  @override
  Future<void> start() async {
    if (_server != null) return;
    for (int i = 0; i < kProbeCount; i++) {
      try {
        _server = await ServerSocket.bind(
            InternetAddress.anyIPv4, kPortBase + i,
            shared: true);
        _port = kPortBase + i;
        break;
      } catch (_) {}
    }
    if (_server == null) {
      throw StateError('Could not bind any port in '
          '$kPortBase..${kPortBase + kProbeCount - 1}');
    }
    _server!.listen(_acceptIncoming, onError: (e) {
      _diag.warn(_diagTag, 'TCP server error: $e');
    });
    _diag.info(_diagTag,
        'Started: selfId=$selfId, groupId="$groupId", safeGroup=$_safeGroup, '
        'tcpPort=$_port, crypto=${crypto != null ? "on" : "off"}');

    // Critical for Android Wi-Fi: without this the radio drops incoming
    // multicast packets to save power. No-op on other platforms.
    await MulticastLock.acquire();

    try {
      _udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, kDiscoveryPort,
          reuseAddress: true, reusePort: false);
      _udp!.broadcastEnabled = true;
      _udp!.multicastLoopback = false;
      _udp!.multicastHops = 8; // a few hops in case ZT routes via relay
      await _refreshInterfaces();
      final mcast = InternetAddress(_kMcastGroup);
      int joined = 0;
      for (final iface in _cachedInterfaces) {
        final hasV4 = iface.addresses
            .any((a) => a.type == InternetAddressType.IPv4);
        if (!hasV4) continue;
        try {
          _udp!.joinMulticast(mcast, iface);
          joined++;
          _diag.trace(
              _diagTag, 'joined multicast on ${iface.name}');
        } catch (e) {
          _diag.warn(_diagTag,
              'joinMulticast failed on ${iface.name}: $e');
        }
      }
      _diag.info(_diagTag,
          'UDP listening on $kDiscoveryPort, joined $joined interfaces');
      _udp!.listen(_onDatagram);
    } catch (e) {
      _diag.error(_diagTag,
          'UDP bind on $kDiscoveryPort failed: $e (manual peer still works)');
      _udp = null;
    }

    _heartbeatTimer =
        Timer.periodic(_heartbeat, (_) => _broadcastHello());
    _discoverTimer =
        Timer.periodic(_discoveryInterval, (_) => _broadcastBeacon());
    // Active subnet scan as a belt-and-suspenders for networks where
    // multicast is silently dropped. Runs once now, then on an adaptive
    // schedule (see [_scheduleScan]).
    _scanBackoff = _kScanMin;
    _broadcastBeacon();
    _broadcastHello();
    // Kick off the first scan a beat after start so the server is fully up.
    _scanTimer = Timer(const Duration(seconds: 1), _scanTick);
  }

  static const _kScanMin = Duration(seconds: 60);
  static const _kScanMax = Duration(minutes: 10);
  Duration _scanBackoff = _kScanMin;

  /// A /24 sweep is ~1270 TCP connects with 32 workers — the single most
  /// expensive periodic thing the app does, and it used to run every 60 s
  /// (with the tried-host memory wiped every 5 min) for as long as a group
  /// was configured, whoever was or wasn't on the network. Now: while
  /// nobody has been found the interval doubles 1 → 2 → 4 → 8 → 10 min;
  /// once a peer is connected we only re-sweep every 10 min for latecomers
  /// (multicast handles the normal case). Losing every peer drops back to
  /// the 1-minute cadence.
  Future<void> _scanTick() async {
    if (_server == null) return;
    // Rare sweeps should retry hosts the earlier sweeps gave up on.
    if (_scanBackoff >= const Duration(minutes: 5)) _triedHosts.clear();
    try {
      await _scanLan();
    } catch (_) {}
    if (_server == null) return;
    _scheduleScan();
  }

  void _scheduleScan() {
    _scanTimer?.cancel();
    final Duration next;
    if (_peerByConn.isNotEmpty) {
      next = _kScanMax;
      _scanBackoff = _kScanMin;
    } else {
      next = _scanBackoff;
      final doubled = _scanBackoff * 2;
      _scanBackoff = doubled > _kScanMax ? _kScanMax : doubled;
    }
    _scanTimer = Timer(next, _scanTick);
  }

  @override
  Future<void> stop() async {
    _heartbeatTimer?.cancel();
    _discoverTimer?.cancel();
    _scanTimer?.cancel();
    _scanTimer = null;
    _triedHosts.clear();
    try {
      _udp?.close();
    } catch (_) {}
    _udp = null;
    for (final s in _outgoing.values) {
      try {
        await s.close();
      } catch (_) {}
    }
    _outgoing.clear();
    _peerByConn.clear();
    _peers.clear();
    _peersCtrl.add(const []);
    await _server?.close();
    _server = null;
    await MulticastLock.release();
    _diag.info(_diagTag, 'Stopped');
  }

  void _broadcastBeacon() {
    final udp = _udp;
    final port = _port;
    if (udp == null || port == null) return;
    final payload = utf8.encode(jsonEncode({
      'g': _safeGroup,
      'id': selfId,
      'n': selfName,
      'p': port,
      'c': selfColor,
    }));
    final mcast = InternetAddress(_kMcastGroup);
    try {
      udp.send(payload, mcast, kDiscoveryPort);
    } catch (_) {}
    // Also send to the limited broadcast address as a fallback for networks
    // where multicast is blocked (some captive portals, corporate APs).
    try {
      udp.send(payload, InternetAddress('255.255.255.255'), kDiscoveryPort);
    } catch (_) {}
  }

  /// Refreshed lazily. Cheap to recompute; not worth a timer.
  List<NetworkInterface> _cachedInterfaces = const [];
  DateTime _lastIfaceProbe = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _refreshInterfaces() async {
    if (DateTime.now().difference(_lastIfaceProbe) <
        const Duration(seconds: 30)) {
      return;
    }
    _lastIfaceProbe = DateTime.now();
    try {
      _cachedInterfaces = await NetworkInterface.list();
    } catch (_) {}
  }

  /// Active scan over private IPv4 subnets.
  ///
  /// If [scanIp] is set, only the subnet around that interface is scanned;
  /// otherwise every private interface is scanned. The CIDR width comes
  /// from [scanCidrBits] (default 24).
  ///
  /// [bigOverride] forces a /16 walk regardless of [scanCidrBits] — used by
  /// the user-triggered "full scan" button in the setup screen. The
  /// background timer never calls this with [bigOverride] true.
  Future<int> _scanLan({bool bigOverride = false}) async {
    if (_server == null) return 0;
    await _refreshInterfaces();

    // Hosts we already have a live socket to — skip them.
    final connectedHosts = <String>{};
    for (final s in _outgoing.values) {
      connectedHosts.add(s.remoteAddress.address);
    }
    for (final s in _peerByConn.keys) {
      connectedHosts.add(s.remoteAddress.address);
    }

    // Build (anchor IP → bits) entries to scan.
    final anchors = <_ScanAnchor>[];
    final mine = <String>{};
    for (final iface in _cachedInterfaces) {
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        if (!_isPrivate(addr.address)) continue;
        mine.add(addr.address);
        if (scanIp != null &&
            scanIp!.isNotEmpty &&
            addr.address != scanIp) {
          continue;
        }
        final bits = bigOverride ? 16 : scanCidrBits.clamp(16, 30);
        anchors.add(_ScanAnchor(addr.address, bits));
      }
    }
    if (anchors.isEmpty) return 0;

    // Enumerate target IPs from anchors, deduped.
    final targets = <String>{};
    for (final a in anchors) {
      targets.addAll(a.enumerate());
    }
    targets.removeAll(mine);
    targets.removeAll(connectedHosts);
    targets.removeAll(_triedHosts);
    if (targets.isEmpty) return 0;

    final queue = targets.toList();
    int next = 0;
    int triedThisCall = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= queue.length) return;
        final host = queue[i];
        if (_triedHosts.add(host)) triedThisCall++;
        await _tryConnectHost(host);
      }
    }

    // Wider parallelism for big scans so /16 finishes in minutes not hours.
    final workers = bigOverride || scanCidrBits < 24 ? 64 : 32;
    await Future.wait([for (int j = 0; j < workers; j++) worker()]);
    return triedThisCall;
  }

  Future<bool> _tryConnectHost(String host) async {
    for (int i = 0; i < kProbeCount; i++) {
      try {
        final sock = await Socket.connect(host, kPortBase + i,
            timeout: const Duration(milliseconds: 600));
        _bindSocket(sock, outgoing: true);
        _sendHello(sock);
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// RFC1918 + the common ZeroTier 172.x range (which is itself part of
  /// RFC1918 172.16/12, but we accept the full 172.0.0.0/8 for ZT setups
  /// that use unusual subnetting). Also accepts 100.64.0.0/10 (CGN, what
  /// Tailscale uses).
  bool _isPrivate(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]) ?? -1;
    final b = int.tryParse(p[1]) ?? -1;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172) return true; // includes 172.16/12 + ZT's range
    if (a == 100 && b >= 64 && b <= 127) return true; // Tailscale CGN
    return false;
  }

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _udp?.receive();
    if (dg == null) return;
    try {
      final doc = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (doc['g'] != _safeGroup) {
        _diag.warn(_diagTag,
            'Datagram from ${dg.address.address}: group "${doc['g']}" '
            '!= ours "$_safeGroup" — wrong group, ignored');
        return;
      }
      final fromId = doc['id'] as String?;
      if (fromId == null) {
        _diag.warn(_diagTag,
            'Datagram from ${dg.address.address}: missing peer id');
        return;
      }
      if (fromId == selfId) return; // our own beacon, normal
      final tcpPort = (doc['p'] as num?)?.toInt();
      if (tcpPort == null) {
        _diag.warn(_diagTag,
            'Datagram from $fromId: missing tcpPort');
        return;
      }
      _diag.info(_diagTag,
          'Beacon from ${dg.address.address}:$tcpPort id=$fromId — connecting');
      _maybeConnect(dg.address.address, tcpPort, fromId);
    } catch (e) {
      _diag.warn(_diagTag,
          'Datagram from ${dg.address.address} parse failed: $e');
    }
  }

  Future<void> _maybeConnect(String host, int port, String peerHint) async {
    await _refreshInterfaces();
    final mine = <String>{};
    for (final i in _cachedInterfaces) {
      for (final a in i.addresses) {
        mine.add(a.address);
      }
    }
    if (mine.contains(host) && port == _port) return;

    // Already have a live socket to this peer? Skip.
    if (_outgoing.containsKey(peerHint)) return;
    if (_outgoing.values.any((s) =>
        '${s.remoteAddress.address}:${s.remotePort}' == '$host:$port')) {
      return;
    }

    // Avoid both sides racing to connect: only the lexicographically-smaller
    // id initiates. If our id is larger we wait for the other side to come
    // to us via _acceptIncoming.
    if (selfId.compareTo(peerHint) > 0) return;

    try {
      final sock = await Socket.connect(host, port,
          timeout: const Duration(seconds: 5));
      _bindSocket(sock, outgoing: true);
      _sendHello(sock);
    } catch (_) {}
  }

  void _acceptIncoming(Socket socket) {
    _diag.info(_diagTag,
        'TCP accept from ${socket.remoteAddress.address}:${socket.remotePort}');
    _bindSocket(socket, outgoing: false);
  }

  void _bindSocket(Socket socket, {required bool outgoing}) {
    final dir = outgoing ? 'out' : 'in';
    final peerEp =
        '${socket.remoteAddress.address}:${socket.remotePort}';
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
              _diag.error(_diagTag,
                  '$dir $peerEp: got encrypted v1| frame but I have no '
                  'passphrase set. Set the same shared passphrase on both sides.');
              return;
            }
            final clear = await crypto!.decrypt(line);
            if (clear == null) {
              _diag.error(_diagTag,
                  '$dir $peerEp: DECRYPT FAILED — passphrase mismatch on '
                  'the two devices?');
              return;
            }
            payload = clear;
          } else if (crypto != null) {
            _diag.warn(_diagTag,
                '$dir $peerEp: got plaintext frame but I have a passphrase '
                'set — peer is missing the passphrase, ignored');
            return;
          }
          Map<String, dynamic> j;
          try {
            j = jsonDecode(payload) as Map<String, dynamic>;
          } catch (e) {
            _diag.warn(_diagTag,
                '$dir $peerEp: JSON parse failed: $e — line head: '
                '"${payload.length > 60 ? payload.substring(0, 60) : payload}"');
            return;
          }
          final msg = GroupMessage.fromJson(j);
          if (msg.groupId != groupId) {
            _diag.warn(_diagTag,
                '$dir $peerEp: group id mismatch — theirs="${msg.groupId}" '
                'ours="$groupId", ignored');
            return;
          }
          if (msg.fromId == selfId) return;
          final to = msg.data['to'];
          if (to is String && to.isNotEmpty && to != selfId) return;
          final isFirstFromPeer = !_peerByConn.containsValue(msg.fromId);
          _peerByConn[socket] = msg.fromId;
          if (outgoing) {
            _outgoing[msg.fromId] = socket;
          }
          if (isFirstFromPeer) {
            _diag.info(_diagTag,
                'HANDSHAKE OK: $dir $peerEp ↔ ${msg.fromName}'
                ' (${msg.fromId.substring(0, msg.fromId.length.clamp(0, 8))}…)');
          } else if (msg.type != 'location') {
            _diag.trace(_diagTag,
                '$dir ${msg.fromName}: ${msg.type}');
          }
          _onMessage(msg, socket);
          if (msg.type == 'hello' && !outgoing && isFirstFromPeer) {
            _sendHello(socket);
          }
        } catch (e) {
          _diag.warn(_diagTag, '$dir $peerEp: unexpected error: $e');
        }
      },
      onError: (e) {
        _diag.warn(_diagTag, '$dir $peerEp socket error: $e');
        _closeSocket(socket);
      },
      onDone: () {
        _diag.info(_diagTag, '$dir $peerEp disconnected');
        _closeSocket(socket);
      },
    );
  }

  void _closeSocket(Socket s) {
    final id = _peerByConn.remove(s);
    if (id != null) {
      _outgoing.remove(id);
    }
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
          host: from.remoteAddress.address,
          port: from.remotePort,
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

  Future<void> _send(Socket s, GroupMessage msg) async {
    try {
      final payload = jsonEncode(msg.toJson());
      final line =
          crypto != null ? await crypto!.encrypt(payload) : payload;
      s.write('$line\n');
      await s.flush();
    } catch (_) {
      _closeSocket(s);
    }
  }

  Future<void> _broadcastTo(
      GroupMessage msg, Iterable<Socket> sockets) async {
    for (final s in sockets) {
      await _send(s, msg);
    }
  }

  Future<void> _broadcast(GroupMessage msg) async {
    final all = <Socket>{
      ..._outgoing.values,
      ..._peerByConn.keys,
    };
    await _broadcastTo(msg, all);
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

  void _sendHello(Socket s) {
    _send(s, _msg('hello', {'color': selfColor}));
  }

  void _broadcastHello() {
    _broadcast(_msg('hello', {'color': selfColor}));
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
  Future<void> sendChat(String text) async {
    await _broadcast(_msg('chat', {'text': text}));
  }

  @override
  Future<void> sendVoice(List<int> audio, String mime) async {
    final b64 = base64.encode(audio);
    await _broadcast(_msg('voice', {'audio': b64, 'mime': mime}));
  }

  @override
  Future<void> sendVoiceEnd() async {
    await _broadcast(_msg('voice_end', {}));
  }

  @override
  Future<void> sendMusicPlay({
    required String url,
    required String title,
    required String artist,
    required int positionMs,
  }) async {
    await _broadcast(_msg('music_play', {
      'url': url,
      'title': title,
      'artist': artist,
      'pos': positionMs,
    }));
  }

  @override
  Future<void> sendMusicStop() async {
    await _broadcast(_msg('music_stop', {}));
  }

  @override
  Future<void> broadcastCustom(
      String type, Map<String, dynamic> data) async {
    await _broadcast(_msg(type, data));
  }

  @override
  Future<void> sendCustomTo(
      String peerId, String type, Map<String, dynamic> data) async {
    await _sendOne(peerId, _msg(type, {...data, 'to': peerId}));
  }

  Future<void> _sendOne(String peerId, GroupMessage msg) async {
    final s = _outgoing[peerId];
    if (s == null) {
      // Fall back to flooding — the receive-side `to` filter will hide it
      // from non-targets. Less private but the message still gets there.
      await _broadcast(msg);
      return;
    }
    await _send(s, msg);
  }

  @override
  Future<void> sendChatTo(String peerId, String text) async {
    await _sendOne(peerId, _msg('chat', {'text': text, 'to': peerId}));
  }

  @override
  Future<void> sendVoiceTo(
      String peerId, List<int> audio, String mime) async {
    await _sendOne(
        peerId,
        _msg('voice',
            {'audio': base64.encode(audio), 'mime': mime, 'to': peerId}));
  }

  @override
  Future<void> sendVoiceEndTo(String peerId) async {
    await _sendOne(peerId, _msg('voice_end', {'to': peerId}));
  }

  @override
  Future<String> addManualPeer(String host, {int? port}) async {
    if (_server == null) return 'service-not-running';
    final candidates = port != null
        ? [port]
        : [for (int i = 0; i < kProbeCount; i++) kPortBase + i];
    Object? lastErr;
    for (final p in candidates) {
      try {
        final sock = await Socket.connect(host, p,
            timeout: const Duration(seconds: 4));
        _bindSocket(sock, outgoing: true);
        _sendHello(sock);
        return 'ok: $p';
      } catch (e) {
        lastErr = e;
      }
    }
    final tried = port != null
        ? '$port'
        : '$kPortBase-${kPortBase + kProbeCount - 1}';
    return '连不上 $host:$tried（${lastErr ?? "未知错误"}）';
  }

  @override
  Future<int> scanNow({bool big = false}) async {
    if (_server == null) return 0;
    return _scanLan(bigOverride: big);
  }

  @override
  List<String> get localIps {
    final out = <String>[];
    for (final iface in _cachedInterfaces) {
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        if (!_isPrivate(addr.address)) continue;
        out.add(addr.address);
      }
    }
    return out;
  }
}

/// (anchorIp, cidrBits) → enumerate every host IP in that subnet (skipping
/// network and broadcast addresses). Used by [_LanGroupService._scanLan].
class _ScanAnchor {
  final String anchorIp;
  final int bits;
  _ScanAnchor(this.anchorIp, this.bits);

  Iterable<String> enumerate() sync* {
    final parts = anchorIp.split('.');
    if (parts.length != 4) return;
    final ip = (int.parse(parts[0]) << 24) |
        (int.parse(parts[1]) << 16) |
        (int.parse(parts[2]) << 8) |
        int.parse(parts[3]);
    final mask = bits >= 32 ? 0xFFFFFFFF : ~((1 << (32 - bits)) - 1) & 0xFFFFFFFF;
    final network = ip & mask;
    final broadcast = network | (~mask & 0xFFFFFFFF);
    for (int addr = network + 1; addr < broadcast; addr++) {
      yield '${(addr >> 24) & 0xFF}.${(addr >> 16) & 0xFF}.'
          '${(addr >> 8) & 0xFF}.${addr & 0xFF}';
    }
  }
}
