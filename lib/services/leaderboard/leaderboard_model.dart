import 'dart:convert';
import 'package:crypto/crypto.dart' as h;

/// One leaderboard entry per peer. The whole leaderboard is just a list of
/// these — LWW (Last-Writer-Wins) by [statsAt] per [peerId] when merging.
///
/// Why this shape (and not a chain / Merkle tree / actual blockchain): the
/// only adversary we care about is a peer trying to inflate their own
/// score. Signing the canonical JSON with Ed25519 catches that without
/// the cost of consensus — when two peers merge, each one independently
/// verifies signatures and discards forgeries. The history is preserved
/// implicitly by appending entries to `leaderboard.jsonl` rather than
/// replacing the in-memory map; the file is the audit log.
class LeaderboardEntry {
  /// Stable per-device id. Same as `selfPeerId` in prefs.
  final String peerId;
  /// Base64-encoded raw Ed25519 public key for [peerId]. Used to verify
  /// [signature]. Once a peerId has shown up with a public key, peers
  /// should refuse later entries for the same peerId signed under a
  /// different key (key rotation requires a new peerId).
  final String publicKey;
  /// User-visible name at the time the snapshot was taken. Not load-bearing;
  /// purely cosmetic in the UI.
  final String displayName;
  /// Optional avatar — same base64 JPEG as [AppSettings.avatarBase64].
  /// Kept inline so merges over P2P don't need a separate transfer.
  /// Capped at ~24 KB by the producer to keep entries gossipable.
  final String avatarBase64;
  /// Cumulative km² of fog revealed across all owned layers, globally.
  /// 10 decimal places preserved (matches global progress on the explore
  /// screen).
  final double globalKm2;
  /// Same value as a percentage of Earth's surface (510 072 000 km²).
  /// Redundant with [globalKm2] but cheaper to display.
  final double globalPercent;
  /// Per-month deltas, keyed `yyyy-MM`. Only the last 24 months are kept
  /// (older months silently drop on the next snapshot). Drives the
  /// "本月" tab on the leaderboard.
  final Map<String, double> monthKm2;
  /// When the snapshot was taken (ISO8601). Used as the LWW timestamp.
  /// Entries with a future [statsAt] are accepted as long as the clock
  /// skew is < 24h; beyond that they're treated as the receiver's "now"
  /// to defang a peer fast-forwarding their clock to overwrite history.
  final DateTime statsAt;
  /// Base64 Ed25519 signature over [canonicalBytes]. Empty if the producer
  /// declined to sign (legacy entries from older clients); receivers must
  /// reject unsigned entries when the leaderboard's strict mode is on.
  final String signature;

  const LeaderboardEntry({
    required this.peerId,
    required this.publicKey,
    required this.displayName,
    required this.avatarBase64,
    required this.globalKm2,
    required this.globalPercent,
    required this.monthKm2,
    required this.statsAt,
    required this.signature,
  });

  /// What gets signed. Sorted keys, no whitespace — both sides recompute
  /// this on verify so flutter version / locale doesn't matter.
  Map<String, dynamic> _canonical() => {
        'peerId': peerId,
        'publicKey': publicKey,
        'displayName': displayName,
        'avatarBase64': avatarBase64,
        'globalKm2': globalKm2,
        'globalPercent': globalPercent,
        'monthKm2': Map.fromEntries(
            monthKm2.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
        'statsAt': statsAt.toUtc().toIso8601String(),
      };

  List<int> canonicalBytes() => utf8.encode(_sortedJson(_canonical()));

  /// Short content hash for "do I already have this exact entry?" gossip.
  /// Truncated to 16 hex chars — collisions don't lose data (they just
  /// trigger an extra entry exchange), and short hashes keep the location
  /// piggyback small.
  String contentHash() =>
      h.sha256.convert(canonicalBytes()).toString().substring(0, 16);

  Map<String, dynamic> toJson() => {
        ..._canonical(),
        'signature': signature,
      };

  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) =>
      LeaderboardEntry(
        peerId: j['peerId']?.toString() ?? '',
        publicKey: j['publicKey']?.toString() ?? '',
        displayName: j['displayName']?.toString() ?? '',
        avatarBase64: j['avatarBase64']?.toString() ?? '',
        globalKm2: (j['globalKm2'] as num?)?.toDouble() ?? 0,
        globalPercent: (j['globalPercent'] as num?)?.toDouble() ?? 0,
        monthKm2: ((j['monthKm2'] as Map?) ?? const {}).map(
            (k, v) => MapEntry(k.toString(), (v as num).toDouble())),
        statsAt: DateTime.tryParse(j['statsAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        signature: j['signature']?.toString() ?? '',
      );

  LeaderboardEntry copyWith({String? signature}) => LeaderboardEntry(
        peerId: peerId,
        publicKey: publicKey,
        displayName: displayName,
        avatarBase64: avatarBase64,
        globalKm2: globalKm2,
        globalPercent: globalPercent,
        monthKm2: monthKm2,
        statsAt: statsAt,
        signature: signature ?? this.signature,
      );
}

/// Stable JSON for signing/hashing — sorted keys, no whitespace,
/// numbers normalised so e.g. 3 and 3.0 give the same bytes.
String _sortedJson(Object? value) {
  if (value == null) return 'null';
  if (value is num) {
    if (value is int || value == value.truncate()) {
      return value.toInt().toString();
    }
    return value.toString();
  }
  if (value is bool) return value ? 'true' : 'false';
  if (value is String) return jsonEncode(value);
  if (value is List) {
    return '[${value.map(_sortedJson).join(',')}]';
  }
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_sortedJson(value[k])}').join(',')}}';
  }
  return jsonEncode(value);
}
