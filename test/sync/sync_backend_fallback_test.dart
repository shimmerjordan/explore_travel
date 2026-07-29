import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/services/sync/onedrive_service.dart';
import 'package:explore_journal/services/sync/sync_storage.dart';
import 'package:explore_journal/services/sync/webdav_sync_storage.dart';

/// [AppSettings.syncBackend] is a free-form string read out of persisted JSON,
/// so a value this build no longer knows has to resolve to *something*.
Future<ProviderContainer> containerWithBackend(String backend) async {
  SharedPreferences.setMockInitialValues({
    'app_settings_v1': jsonEncode({'syncBackend': backend}),
  });
  final c = ProviderContainer();
  addTearDown(c.dispose);
  while (!c.read(settingsProvider).loaded) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(c.read(settingsProvider).syncBackend, backend,
      reason: 'the fixture must actually reach settings');
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('an unknown persisted syncBackend falls back instead of throwing', () {
    test("a device still holding 'nas' syncs against OneDrive", () async {
      // 'nas' was a stub transport that never shipped. Installs that selected
      // it must keep syncing, not hit a runtime exception on first read.
      final c = await containerWithBackend('nas');
      expect(c.read(syncStorageProvider), isA<OneDriveService>());
    });

    test('and so does outright garbage', () async {
      final c = await containerWithBackend('definitely-not-a-backend');
      expect(c.read(syncStorageProvider), isA<OneDriveService>());
    });

    test('the surviving backends still resolve to their own transports',
        () async {
      final webdav = await containerWithBackend(SyncBackend.webdav);
      expect(webdav.read(syncStorageProvider), isA<WebdavSyncStorage>());
      expect(SyncBackend.all, ['onedrive', 'github', 'webdav'],
          reason: "'nas' is gone from the offered list too");
    });
  });
}
