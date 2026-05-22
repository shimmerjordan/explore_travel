import 'package:latlong2/latlong.dart';

enum RecordingMode { highPerformance, balanced, batterySaver }

extension RecordingModeX on RecordingMode {
  Duration get interval => switch (this) {
        RecordingMode.highPerformance => const Duration(seconds: 2),
        RecordingMode.balanced => const Duration(seconds: 10),
        RecordingMode.batterySaver => const Duration(seconds: 30),
      };

  double get distanceFilter => switch (this) {
        RecordingMode.highPerformance => 5,
        RecordingMode.balanced => 15,
        RecordingMode.batterySaver => 40,
      };

  String get label => switch (this) {
        RecordingMode.highPerformance => '高性能',
        RecordingMode.balanced => '平衡',
        RecordingMode.batterySaver => '省电',
      };
}

enum MapProvider { osm, amap, google }

enum MapStyle { standard, satellite, hybrid }

/// How peers reach each other.
/// - lan:    Anything IP-routable between members — home Wi-Fi, ZeroTier,
///           Tailscale, hotspot. The app uses UDP multicast + TCP. ZT users
///           start their ZT client *outside* the app; once their devices
///           can ping each other, this transport just works.
/// - webrtc: No LAN required. Members share a WebDAV account; the app uses
///           it to exchange SDP/ICE, then connects P2P directly. Use this
///           when members are on totally separate networks.
///
/// `zerotier` is kept as a legacy enum value so older saved settings still
/// load, but it's now treated identically to `lan` and not exposed in UI.
enum GroupTransport { lan, zerotier, webrtc }

extension GroupTransportX on GroupTransport {
  /// Maps the legacy `zerotier` value to `lan` so the rest of the code only
  /// sees two cases.
  GroupTransport get canonical =>
      this == GroupTransport.zerotier ? GroupTransport.lan : this;

  String get label => switch (canonical) {
        GroupTransport.lan => '局域网 / 虚拟局域网',
        GroupTransport.webrtc => 'WebRTC + WebDAV 信令',
        _ => '局域网 / 虚拟局域网',
      };

  String get description => switch (canonical) {
        GroupTransport.lan =>
          '同一个 Wi-Fi / 热点 / ZeroTier / Tailscale 都可以。'
              '用 UDP 多播自动发现，最简单稳定。',
        GroupTransport.webrtc =>
          '成员不在同一个网络时用这个。配同一个 WebDAV 账户做信令，之后 P2P 直连。',
        _ => '',
      };
}

class TrackPoint {
  final double lat;
  final double lng;
  final DateTime time;
  final double? accuracy;
  final double? altitude;
  final double? speed;
  final int layerId;
  TrackPoint({
    required this.lat,
    required this.lng,
    required this.time,
    required this.layerId,
    this.accuracy,
    this.altitude,
    this.speed,
  });
  LatLng get latLng => LatLng(lat, lng);
}

class TrackLayer {
  final int id;
  final String name;
  final int colorValue;
  final bool visible;
  final String? tag;
  final DateTime createdAt;
  TrackLayer({
    required this.id,
    required this.name,
    required this.colorValue,
    required this.visible,
    required this.createdAt,
    this.tag,
  });
}

class JournalEntry {
  final int id;
  final DateTime time;
  final double lat;
  final double lng;
  final String title;
  final String richContent; // Quill JSON
  final List<String> mediaPaths;
  final int layerId;
  JournalEntry({
    required this.id,
    required this.time,
    required this.lat,
    required this.lng,
    required this.title,
    required this.richContent,
    required this.mediaPaths,
    required this.layerId,
  });
}
