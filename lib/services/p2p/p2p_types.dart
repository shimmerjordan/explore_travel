class PeerInfo {
  final String name;
  final String host;
  final int port;
  PeerInfo(this.name, this.host, this.port);
}

class P2PMessage {
  final String type;
  final String from;
  final Map<String, dynamic> data;
  final DateTime time;
  P2PMessage(this.type, this.from, this.data, this.time);
  Map<String, dynamic> toJson() => {
        'type': type,
        'from': from,
        'data': data,
        'time': time.millisecondsSinceEpoch,
      };
  static P2PMessage fromJson(Map<String, dynamic> j) => P2PMessage(
        j['type'],
        j['from'],
        Map<String, dynamic>.from(j['data']),
        DateTime.fromMillisecondsSinceEpoch(j['time']),
      );
}
