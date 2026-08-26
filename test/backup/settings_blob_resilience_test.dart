import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/core/prefs.dart';

/// `AppSettings.fromJson` hard-casts (enum indices, ints, doubles), and
/// `PrefsStore.load()` runs during app start. So a settings blob of the wrong
/// shape — written by a much older version, hand-edited, or merged in from
/// another device's archive — used to abort startup: a cosmetic preference
/// problem turned into "the app does not open".
///
/// This was found the hard way: a test harness stores `mapStyle: 'dark'` as a
/// round-trip sentinel, and merely *reading* settings during a sync threw.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppSettings> loadWith(Object blob) async {
    SharedPreferences.setMockInitialValues({
      'app_settings_v1': blob is String ? blob : jsonEncode(blob),
    });
    return PrefsStore().load();
  }

  test('a wrong-typed enum field degrades to ITS default, keeping the rest',
      () async {
    // A string where an enum index is expected — the exact shape that threw.
    final s = await loadWith({'mapStyle': 'dark', 'displayName': '小明'});
    expect(s.mapStyle, const AppSettings().mapStyle);
    // Enum indices are read defensively (an unknown/foreign value falls back
    // per field), so the rest of the blob survives — this is what protects a
    // user who downgrades after a newer build stored a provider index this
    // build doesn't know: their fog colour / keys / sync backend stay put.
    expect(s.displayName, '小明');
  });

  test('a wrong-typed non-enum field still degrades the whole blob', () async {
    final s = await loadWith({'fogOpacity': 'high', 'displayName': '小明'});
    expect(s.displayName, const AppSettings().displayName);
  });

  test('several shapes of foreign blob all degrade, none throw', () async {
    for (final blob in <Object>[
      {'mapStyle': 'dark'},
      {'fogColor': 'not-an-int'},
      {'fogOpacity': 'high'},
      {'mapProvider': true},
      {'recordingMode': []},
      {'syncBackend': 42}, // a String field given a number
      'not json at all',
      '[]',
    ]) {
      final s = await loadWith(blob);
      expect(s, isA<AppSettings>(), reason: 'blob: $blob');
    }
  });

  test('the unreadable blob is left in prefs, not overwritten', () async {
    const raw = '{"mapStyle":"dark","somethingElse":1}';
    await loadWith(raw);
    final p = await SharedPreferences.getInstance();
    expect(p.getString('app_settings_v1'), raw,
        reason: 'destroying it would throw away the only copy of whatever the '
            'user had configured; the next successful save fixes it');
  });

  test('a well-formed blob is still read normally', () async {
    final s = await loadWith({'displayName': '小明', 'fogOpacity': 0.5});
    expect(s.displayName, '小明');
    expect(s.fogOpacity, 0.5);
  });
}
