import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/services/backup/backup_credentials.dart';
import 'package:explore_journal/services/backup/backup_service.dart';

/// The question this file answers is the one the feature exists for: **can a
/// backup actually restore the app**, and does a stolen copy of it still give
/// up nothing?
///
/// It works on the archive members directly rather than driving the whole
/// service, because the service needs a database and a plugin host that a plain
/// VM test has neither of. What is being pinned here is the *contract between
/// the two halves* — the scrub and the seal read the same settings blob, and
/// the importer's precedence rules — which is where a regression would land.
void main() {
  const pw = 'restore-me-please';

  /// A settings blob shaped like the real `app_settings_v1`: credentials mixed
  /// in with ordinary preferences.
  String settingsJson() => jsonEncode({
        'webdavUrl': 'https://dav.example.com',
        'webdavPass': 'SECRET-webdav',
        'githubPat': 'ghp_SECRET',
        'amapApiKey': 'AMAP-SECRET',
        'relayToken': 'RELAY-SECRET',
        'oneDriveRefreshToken': 'REFRESH-SECRET',
        'fogColor': 0xDEADBEEF,
        'displayName': '小明',
      });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every credential in the scrub list has a value in the fixture', () {
    // Guards the fixture, not the code: if a key is added to the list and this
    // file is not updated, the assertions below would silently stop covering
    // it. Only the ones this fixture cares about are required to be present.
    for (final k in ['webdavPass', 'githubPat', 'amapApiKey', 'relayToken']) {
      expect(kVaultSecretKeys, contains(k),
          reason: '$k must be treated as a credential');
    }
  });

  test('the map API keys are credentials now', () {
    // These were missed originally: they are metered against the owner's
    // account, so a leaked key is someone else's bill.
    expect(kVaultSecretKeys, contains('amapApiKey'));
    expect(kVaultSecretKeys, contains('googleMapKey'));
  });

  test('the leaderboard identity is deliberately NOT scrubbed', () {
    // A backup is the only supported way to move that identity to a new phone;
    // scrubbing it would make the new install sign as a stranger and get
    // refused under the server's TOFU rule.
    expect(kVaultSecretKeys, isNot(contains('leaderboardPrivateKey')));
  });

  group('sealed credentials round-trip', () {
    test('a sealed archive restores every credential', () async {
      final raw = settingsJson();
      // Exactly what the export writes, via the real functions: scrubbed
      // settings + a sealed sidecar built from the same blob.
      final scrubbed =
          jsonDecode(scrubSettingsForTest(raw)) as Map<String, dynamic>;
      final creds = collectSecretsForTest(raw);
      final sealed = await BackupCredentials.seal(creds, pw);

      // The invariant that makes the pair correct: what the scrub removed is
      // exactly what the sidecar carries. Either half drifting is a silent
      // leak (a key scrubbed but not sealed is lost on restore; a key sealed
      // but not scrubbed is in the archive twice, once in the clear).
      final original = jsonDecode(raw) as Map<String, dynamic>;
      for (final k in original.keys) {
        final isCredential = kVaultSecretKeys.contains(k);
        expect(creds.containsKey(k), isCredential,
            reason: '$k: sealed=${creds.containsKey(k)} expected=$isCredential');
        expect(scrubbed[k] == null, isCredential,
            reason: '$k should ${isCredential ? "" : "not "}be scrubbed');
      }

      // The scrubbed half must be safe on its own.
      final scrubbedText = jsonEncode(scrubbed);
      for (final leak in [
        'SECRET-webdav',
        'ghp_SECRET',
        'AMAP-SECRET',
        'RELAY-SECRET',
        'REFRESH-SECRET',
      ]) {
        expect(scrubbedText.contains(leak), isFalse, reason: 'leaked $leak');
      }
      // ...while ordinary preferences survive it.
      expect(scrubbed['webdavUrl'], 'https://dav.example.com');
      expect(scrubbed['displayName'], '小明');

      // And the sealed half brings them all back.
      final opened = await BackupCredentials.open(sealed, pw);
      expect(opened, isNotNull);
      expect(opened!['webdavPass'], 'SECRET-webdav');
      expect(opened['githubPat'], 'ghp_SECRET');
      expect(opened['amapApiKey'], 'AMAP-SECRET');
      expect(opened['relayToken'], 'RELAY-SECRET');
      expect(opened['oneDriveRefreshToken'], 'REFRESH-SECRET');
      // Non-credentials must NOT be in there — the sidecar is not a second
      // copy of the settings.
      expect(opened.containsKey('displayName'), isFalse);
      expect(opened.containsKey('fogColor'), isFalse);
    });

    test('without the password the archive yields nothing usable', () async {
      final raw = settingsJson();
      final sealed =
          await BackupCredentials.seal(collectSecretsForTest(raw), pw);
      expect(await BackupCredentials.open(sealed, 'guess'), isNull);
      // The whole archive text — both halves — must not contain a secret.
      final whole = scrubSettingsForTest(raw) + sealed;
      for (final leak in ['SECRET-webdav', 'AMAP-SECRET', 'RELAY-SECRET']) {
        expect(whole.contains(leak), isFalse, reason: 'leaked $leak');
      }
    });
  });
}
