/// Wire-level constants and URI construction shared by the group transports
/// and the connectivity probes (`group_probe_io.dart`).
///
/// These used to be private to each transport. The probes have to speak the
/// EXACT same wire the real connection speaks — a probe that builds its own
/// URL or joins its own multicast group can pass while the real thing fails,
/// which is worse than having no probe at all. Keeping one definition here is
/// what makes that impossible.
library;

/// UDP multicast group used for LAN peer discovery.
const String kMcastGroup = '239.42.42.42';

/// UDP port the discovery datagrams are sent to / listened on.
const int kDiscoveryPort = 47829;

/// First TCP port tried for the local mesh server.
const int kMeshPortBase = 47830;

/// How many consecutive ports to try from [kMeshPortBase] before giving up.
const int kMeshPortProbeCount = 5;

/// Relay endpoint path appended to the configured base URL.
const String kRelayWsPath = '/group/v1/ws';

/// Normalizes a user-typed group id into the form the relay expects: lowercase,
/// alphanumerics only, never empty.
String groupSafeId(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').padRight(1, 'g');

/// Builds the relay WebSocket URI. `http(s)://` is rewritten to `ws(s)://`; a
/// bare host is assumed to be TLS-terminated (that's what a tunnel or reverse
/// proxy gives you, and it's the safer default to get wrong).
Uri relayWsUri({
  required String serverUrl,
  required String groupId,
  required String selfId,
  String? token,
}) {
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
  return Uri.parse('$base$kRelayWsPath').replace(queryParameters: {
    'group': groupSafeId(groupId),
    'peer': selfId,
    if ((token ?? '').isNotEmpty) 'token': token!,
  });
}
