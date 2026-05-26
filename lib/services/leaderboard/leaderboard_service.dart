import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'leaderboard_model.dart';

/// Decentralised, append-only LWW leaderboard.
///
/// **Storage**: one jsonl file per device under
/// `<documents>/leaderboard/entries.jsonl`. Each line is a
/// [LeaderboardEntry]. Re-loading the file is O(N×log N) but N stays
/// small (one entry per peer ever met) so we don't need an index.
///
/// **Merge rule**: per `peerId`, keep the entry with the largest
/// `statsAt` whose `publicKey` matches the *first* publicKey we ever
/// saw for that peer (Trust-On-First-Use). Forgeries fail signature
/// verification.
///
/// **Trust window**: entries dated more than [maxFutureSkew] ahead of
/// local clock are clamped to "now" — defends against a peer
/// fast-forwarding to overwrite history.
class LeaderboardService {
  static const _maxMonthHistory = 24;
  static const Duration maxFutureSkew = Duration(hours: 24);

  final _alg = Ed25519();
  final Map<String, LeaderboardEntry> _entries = {};
  /// First public key we ever saw for each peerId — TOFU pin. Persisted
  /// implicitly because the entry itself carries the publicKey.
  final Map<String, String> _peerKeyPin = {};

  final _entriesCtrl =
      StreamController<List<LeaderboardEntry>>.broadcast();
  Stream<List<LeaderboardEntry>> get watch => _entriesCtrl.stream;
  List<LeaderboardEntry> get current => _entries.values.toList();

  bool _loaded = false;
  File? _file;

  Future<File> _path() async {
    if (_file != null) return _file!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'leaderboard'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _file = File(p.join(dir.path, 'entries.jsonl'));
    return _file!;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = await _path();
    if (!await f.exists()) return;
    final raw = await f.readAsString();
    // CRITICAL: do NOT verify signatures on initial load. The local
    // jsonl is content we wrote ourselves (every line we accept goes
    // through `_ingest(verify: true)` once before being persisted), so
    // re-verifying ~N Ed25519 signatures every cold start used to add
    // hundreds of ms to startup. The merge / gossip paths still verify
    // incoming entries — that's where forgeries actually enter.
    for (final line in raw.split('\n')) {
      if (line.trim().isEmpty) continue;
      try {
        final entry =
            LeaderboardEntry.fromJson(jsonDecode(line) as Map<String, dynamic>);
        await _ingest(entry, persist: false, verify: false);
      } catch (e) {
        debugPrint('[Leaderboard] skipping bad line: $e');
      }
    }
    _entriesCtrl.add(current);
  }

  /// Generate an Ed25519 keypair. Returns (privateBase64, publicBase64).
  /// Caller should stash both in [AppSettings].
  Future<({String privateKey, String publicKey})> generateKeyPair() async {
    final kp = await _alg.newKeyPair();
    final priv = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    return (
      privateKey: base64.encode(priv),
      publicKey: base64.encode(pub.bytes),
    );
  }

  /// Sign [entry] with [privateKeyB64]. Returns a new entry with
  /// `signature` populated.
  Future<LeaderboardEntry> sign(
      LeaderboardEntry entry, String privateKeyB64) async {
    final priv = base64.decode(privateKeyB64);
    final kp = await _alg.newKeyPairFromSeed(priv);
    final sig = await _alg.sign(entry.canonicalBytes(), keyPair: kp);
    return entry.copyWith(signature: base64.encode(sig.bytes));
  }

  Future<bool> verify(LeaderboardEntry entry) async {
    if (entry.signature.isEmpty || entry.publicKey.isEmpty) return false;
    try {
      final sig = Signature(
        base64.decode(entry.signature),
        publicKey: SimplePublicKey(
          base64.decode(entry.publicKey),
          type: KeyPairType.ed25519,
        ),
      );
      return await _alg.verify(entry.canonicalBytes(), signature: sig);
    } catch (e) {
      debugPrint('[Leaderboard] verify error: $e');
      return false;
    }
  }

  /// Build a snapshot for "me" and persist+broadcast it. Caller (usually
  /// a provider) decides when to call this — e.g. on app launch after the
  /// fog engine has loaded, and after each recording session ends.
  Future<LeaderboardEntry> publishSelf({
    required String peerId,
    required String publicKeyB64,
    required String privateKeyB64,
    required String displayName,
    required String avatarBase64,
    required double globalKm2,
    required double globalPercent,
    required Map<String, double> monthKm2,
  }) async {
    // Trim months map to the last 24 entries.
    final months = monthKm2.keys.toList()..sort();
    final trimmed = <String, double>{};
    for (final k
        in months.sublist(months.length > _maxMonthHistory
            ? months.length - _maxMonthHistory
            : 0)) {
      trimmed[k] = monthKm2[k]!;
    }

    final unsigned = LeaderboardEntry(
      peerId: peerId,
      publicKey: publicKeyB64,
      displayName: displayName,
      avatarBase64: avatarBase64,
      globalKm2: globalKm2,
      globalPercent: globalPercent,
      monthKm2: trimmed,
      statsAt: DateTime.now().toUtc(),
      signature: '',
    );
    final signed = await sign(unsigned, privateKeyB64);
    await _ingest(signed, persist: true, verify: true);
    _entriesCtrl.add(current);
    return signed;
  }

  /// Merge a batch of entries received from a peer / backup / server.
  /// Returns the number of entries that actually changed local state.
  Future<int> mergeBatch(List<LeaderboardEntry> incoming) async {
    if (!_loaded) await load();
    var changed = 0;
    for (final e in incoming) {
      if (await _ingest(e, persist: false, verify: true)) changed++;
    }
    if (changed > 0) {
      // Rewrite the file rather than appending — keeps it bounded at
      // O(peers ever met) instead of O(updates ever received).
      await _rewrite();
      _entriesCtrl.add(current);
    }
    return changed;
  }

  /// Internal: accept one entry if it beats what we have. Returns true if
  /// local state changed.
  Future<bool> _ingest(LeaderboardEntry e,
      {required bool persist, required bool verify}) async {
    if (e.peerId.isEmpty) return false;

    // TOFU pin: refuse a new publicKey for an existing peerId.
    final pinned = _peerKeyPin[e.peerId];
    if (pinned != null && pinned != e.publicKey) {
      debugPrint('[Leaderboard] DROP $e.peerId: key rotation not allowed');
      return false;
    }

    if (verify && !(await this.verify(e))) {
      debugPrint('[Leaderboard] DROP ${e.peerId}: signature invalid');
      return false;
    }

    // Defang future clock skew.
    var stats = e.statsAt;
    final now = DateTime.now().toUtc();
    if (stats.isAfter(now.add(maxFutureSkew))) {
      stats = now;
    }
    final entry = stats == e.statsAt
        ? e
        : LeaderboardEntry(
            peerId: e.peerId,
            publicKey: e.publicKey,
            displayName: e.displayName,
            avatarBase64: e.avatarBase64,
            globalKm2: e.globalKm2,
            globalPercent: e.globalPercent,
            monthKm2: e.monthKm2,
            statsAt: stats,
            signature: e.signature,
          );

    final cur = _entries[entry.peerId];
    if (cur != null && !entry.statsAt.isAfter(cur.statsAt)) return false;

    _entries[entry.peerId] = entry;
    _peerKeyPin[entry.peerId] = entry.publicKey;
    if (persist) {
      final f = await _path();
      await f.writeAsString('${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append, flush: true);
    }
    return true;
  }

  Future<void> _rewrite() async {
    final f = await _path();
    final buf = StringBuffer();
    for (final e in _entries.values) {
      buf.writeln(jsonEncode(e.toJson()));
    }
    await f.writeAsString(buf.toString(), flush: true);
  }

  /// All current entries as a list of maps — used by backup export and the
  /// GitHub PR / server flows.
  List<Map<String, dynamic>> toExportList() =>
      _entries.values.map((e) => e.toJson()).toList();

  /// Build the per-month delta map from a list of track points. Buckets
  /// by `time.toLocal()` yyyy-MM and assigns the layer's revealed km² of
  /// each month proportional to its point count. Approximate but
  /// matches the playback's month grouping.
  ///
  /// Caller passes a flat `(yyyyMM → relativeWeight)` map (typically point
  /// counts) and the cumulative km² across all months — this just
  /// distributes the total. Returns ≤24 months.
  static Map<String, double> distributeMonthly(
      Map<String, int> weights, double totalKm2) {
    if (weights.isEmpty || totalKm2 <= 0) return const {};
    final keys = weights.keys.toList()..sort();
    final sliced = keys.length > _maxMonthHistory
        ? keys.sublist(keys.length - _maxMonthHistory)
        : keys;
    final totalW = sliced.fold<int>(0, (a, k) => a + weights[k]!);
    if (totalW == 0) return const {};
    final out = <String, double>{};
    for (final k in sliced) {
      out[k] = totalKm2 * (weights[k]! / totalW);
    }
    return out;
  }

  /// Hash of "what I currently know" — sent on location heartbeats so
  /// peers can quickly tell if their leaderboard differs from ours
  /// without exchanging the whole list every ping.
  String stateHash() {
    final hashes = _entries.values.map((e) => e.contentHash()).toList()..sort();
    if (hashes.isEmpty) return '';
    return hashes.join(':').hashCode.toRadixString(16);
  }
}
