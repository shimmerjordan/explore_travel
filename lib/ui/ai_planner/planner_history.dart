import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// A single saved planner conversation.
/// Stored in SharedPreferences as a JSON array under [_prefsKey]. Entries
/// older than [_retentionDays] are purged on every load + every save.
class PlannerSession {
  final String id;
  final DateTime updatedAt;
  /// First non-empty user message — used as the list-row title.
  final String title;
  /// Full conversation: [{role, content}, ...].
  final List<Map<String, String>> messages;

  PlannerSession({
    required this.id,
    required this.updatedAt,
    required this.title,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'updatedAt': updatedAt.toIso8601String(),
        'title': title,
        'messages': messages,
      };

  static PlannerSession? fromJson(Map<String, dynamic> j) {
    try {
      return PlannerSession(
        id: j['id'].toString(),
        updatedAt: DateTime.parse(j['updatedAt'].toString()),
        title: j['title']?.toString() ?? '',
        messages: ((j['messages'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => m.map(
                (k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }
}

class PlannerHistory {
  static const String _prefsKey = 'planner_history_v1';
  static const int _retentionDays = 30;

  Future<List<PlannerSession>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List)
        .whereType<Map<String, dynamic>>()
        .map(PlannerSession.fromJson)
        .whereType<PlannerSession>()
        .toList();
    final cutoff =
        DateTime.now().subtract(const Duration(days: _retentionDays));
    final live = list.where((s) => s.updatedAt.isAfter(cutoff)).toList();
    if (live.length != list.length) {
      // Persist the pruned copy.
      await _save(live, p);
    }
    live.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return live;
  }

  Future<void> upsert(PlannerSession s) async {
    final p = await SharedPreferences.getInstance();
    final all = await load();
    final idx = all.indexWhere((x) => x.id == s.id);
    if (idx >= 0) {
      all[idx] = s;
    } else {
      all.add(s);
    }
    await _save(all, p);
  }

  Future<void> delete(String id) async {
    final p = await SharedPreferences.getInstance();
    final all = (await load()).where((s) => s.id != id).toList();
    await _save(all, p);
  }

  Future<void> _save(List<PlannerSession> list, SharedPreferences p) async {
    final cutoff =
        DateTime.now().subtract(const Duration(days: _retentionDays));
    final live = list.where((s) => s.updatedAt.isAfter(cutoff)).toList();
    await p.setString(_prefsKey,
        jsonEncode(live.map((s) => s.toJson()).toList()));
  }

  static String newId() => const Uuid().v4();
}

final plannerHistoryProvider = Provider((_) => PlannerHistory());
