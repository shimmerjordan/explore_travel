/// Shared types for the multi-peer group system.
///
/// Replaces the old 1-to-1 P2P concept with a real "group" / "room" where
/// any number of devices on the same LAN (e.g. ZeroTier virtual network)
/// can join by sharing a group ID, exchange live locations as colored
/// trails, chat, and broadcast synchronized music or voice clips.
class GroupPeer {
  final String id; // stable unique id per device
  final String name; // display name
  final String host;
  final int port;
  final int colorValue; // assigned per peer to render their trail
  DateTime lastSeen;
  double? lat;
  double? lng;
  double? heading;

  GroupPeer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.colorValue,
    required this.lastSeen,
    this.lat,
    this.lng,
    this.heading,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'color': colorValue,
        'lastSeen': lastSeen.millisecondsSinceEpoch,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (heading != null) 'heading': heading,
      };

  static GroupPeer fromJson(Map<String, dynamic> j) => GroupPeer(
        id: j['id'],
        name: j['name'],
        host: j['host'] ?? '',
        port: (j['port'] ?? 0) as int,
        colorValue: (j['color'] ?? 0xFF26A69A) as int,
        lastSeen:
            DateTime.fromMillisecondsSinceEpoch(j['lastSeen'] ?? 0),
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        heading: (j['heading'] as num?)?.toDouble(),
      );
}

/// Message envelope flowing through the group mesh.
///
/// Types:
///   - hello       (id, name, color) — peer joined / replied
///   - location    (lat, lng, heading) — live position broadcast
///   - chat        (text)
///   - voice       (audioB64, mime)
///   - music_play  (url, title, artist, sourceTimeMs, positionMs)
///   - music_stop
///   - ping
class GroupMessage {
  final String type;
  final String fromId;
  final String fromName;
  final Map<String, dynamic> data;
  final DateTime time;
  final String groupId;

  GroupMessage({
    required this.type,
    required this.fromId,
    required this.fromName,
    required this.data,
    required this.time,
    required this.groupId,
  });

  Map<String, dynamic> toJson() => {
        't': type,
        'fid': fromId,
        'fn': fromName,
        'g': groupId,
        'd': data,
        'ts': time.millisecondsSinceEpoch,
      };

  static GroupMessage fromJson(Map<String, dynamic> j) => GroupMessage(
        type: j['t'],
        fromId: j['fid'],
        fromName: j['fn'],
        groupId: j['g'],
        data: Map<String, dynamic>.from(j['d'] ?? {}),
        time: DateTime.fromMillisecondsSinceEpoch(j['ts'] ?? 0),
      );
}

/// Pre-defined trail colors auto-assigned to peers in join order.
const groupPalette = <int>[
  0xFF26A69A, // teal — me
  0xFFEF5350, // red
  0xFFAB47BC, // purple
  0xFF42A5F5, // blue
  0xFFFFA726, // orange
  0xFF66BB6A, // green
  0xFFEC407A, // pink
  0xFF7E57C2, // deep purple
  0xFF26C6DA, // cyan
  0xFFD4E157, // lime
];
