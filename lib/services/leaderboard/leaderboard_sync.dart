import 'dart:async';
import 'package:flutter/foundation.dart';
import '../group/group_service.dart';
import 'leaderboard_model.dart';
import 'leaderboard_service.dart';

/// Bridges [GroupService] ↔ [LeaderboardService].
///
/// Wire protocol (all sent via `broadcastCustom`):
///
///   * `lb_hello`  — on connect, both sides emit their stateHash + count.
///                   { h: "<hash>", n: <count>, t: "<iso8601>" }
///   * `lb_pull`   — "your hash differs from mine; send me everything".
///                   { }   (broadcast, but recipients should `to:` reply)
///   * `lb_batch`  — entries payload (array of full entry JSONs).
///                   { entries: [ ... ] }
///
/// Each device keeps a per-peer "last seen hash" cache so we don't request
/// pulls every few seconds when nothing's changed. A pull from peer P is
/// also rate-limited to once per minute.
class LeaderboardSync {
  final LeaderboardService leaderboard;
  GroupService? _group;
  StreamSubscription<GroupMessage>? _sub;
  Timer? _periodic;

  /// `peerId → hash` last seen — skip pull if matches.
  final Map<String, String> _peerHashes = {};
  /// `peerId → DateTime` of the last pull we requested from this peer.
  final Map<String, DateTime> _lastPullAt = {};

  LeaderboardSync(this.leaderboard);

  /// Attach to a (started) group service. Safe to call repeatedly.
  void attach(GroupService group) {
    detach();
    _group = group;
    _sub = group.messages.listen(_onMessage);
    // Send our hello shortly after attach so newly-joined peers learn we
    // exist. The periodic timer afterwards is a safety net for when we
    // joined the group before any peer was online.
    Future.delayed(const Duration(seconds: 2), _broadcastHello);
    _periodic = Timer.periodic(const Duration(minutes: 5),
        (_) => _broadcastHello());
  }

  void detach() {
    _sub?.cancel();
    _periodic?.cancel();
    _sub = null;
    _periodic = null;
    _group = null;
    _peerHashes.clear();
    _lastPullAt.clear();
  }

  Future<void> _broadcastHello() async {
    final g = _group;
    if (g == null) return;
    await g.broadcastCustom('lb_hello', {
      'h': leaderboard.stateHash(),
      'n': leaderboard.current.length,
      't': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _onMessage(GroupMessage m) async {
    final g = _group;
    if (g == null) return;
    switch (m.type) {
      case 'lb_hello':
        final theirHash = m.data['h']?.toString() ?? '';
        _peerHashes[m.fromId] = theirHash;
        if (theirHash != leaderboard.stateHash()) {
          // Hashes differ — request a pull, but no more than once a
          // minute per peer.
          final last = _lastPullAt[m.fromId];
          if (last != null &&
              DateTime.now().difference(last) < const Duration(minutes: 1)) {
            return;
          }
          _lastPullAt[m.fromId] = DateTime.now();
          await g.sendCustomTo(m.fromId, 'lb_pull', const {});
        }
        break;
      case 'lb_pull':
        // Someone asked for our current snapshot — send it. If `to` is
        // set, route 1:1; otherwise broadcast.
        final to = m.data['to']?.toString();
        final payload = {'entries': leaderboard.toExportList()};
        if (to != null && to.isNotEmpty) {
          await g.sendCustomTo(m.fromId, 'lb_batch', payload);
        } else {
          await g.broadcastCustom('lb_batch', payload);
        }
        break;
      case 'lb_batch':
        final list = (m.data['entries'] as List?)
                ?.cast<Map<String, dynamic>>()
                .map(LeaderboardEntry.fromJson)
                .toList() ??
            const <LeaderboardEntry>[];
        final changed = await leaderboard.mergeBatch(list);
        if (changed > 0) {
          debugPrint('[lb_sync] merged $changed entries from ${m.fromId}');
          // Our state hash just changed — gossip it.
          await _broadcastHello();
        }
        break;
    }
  }
}
