import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/core/prefs.dart';
import 'package:explore_journal/services/backup/backup_service.dart'
    show kVaultSecretKeys;
import 'package:explore_journal/services/security/secure_credentials.dart';
import 'package:explore_journal/services/vault/vault_payload.dart';

/// snake_case keystore keys → camelCase AppSettings field names.
const _secureToSettings = <String, String>{
  SecureCredentials.githubPat: 'githubPat',
  SecureCredentials.githubPrivatePat: 'githubPrivatePat',
  SecureCredentials.customAuthHeader: 'customAuthHeader',
  SecureCredentials.webdavPass: 'webdavPass',
  SecureCredentials.p2pPassphrase: 'p2pPassphrase',
  SecureCredentials.aiApiKey: 'aiApiKey',
  SecureCredentials.leaderboardRepoPat: 'leaderboardRepoPat',
  SecureCredentials.leaderboardServerToken: 'leaderboardServerToken',
};

void main() {
  group('kVaultPayloadKeys — single source of truth', () {
    test('is a superset of the backup scrubber secret set', () {
      expect(VaultPayload.kVaultPayloadKeys.containsAll(kVaultSecretKeys), isTrue,
          reason: 'every scrubbed secret must also travel in the vault');
    });

    test('covers every SecureCredentials keystore key (camelCase mapped)', () {
      for (final k in SecureCredentials.all) {
        final mapped = _secureToSettings[k];
        expect(mapped, isNotNull, reason: 'unmapped keystore key: $k');
        expect(VaultPayload.kVaultPayloadKeys.contains(mapped), isTrue,
            reason: '$mapped (from $k) missing from the vault key set');
      }
    });

    test('deliberately excludes the per-device leaderboard identity', () {
      expect(VaultPayload.kVaultPayloadKeys.contains('leaderboardPrivateKey'),
          isFalse);
      expect(VaultPayload.kVaultPayloadKeys.contains('leaderboardPublicKey'),
          isFalse);
    });
  });

  group('VaultPayload.extract', () {
    test('picks only vault keys and stamps the schema', () {
      const s = AppSettings(
        webdavUrl: 'https://dav.example.com',
        webdavPass: 'secret',
        githubPat: 'ghp_x',
        fogColor: 0xDEADBEEF, // a non-vault field
      );
      final p = VaultPayload.extract(s);
      expect(p.schema, VaultPayload.schemaVersion);
      expect(p.fields['webdavPass'], 'secret');
      expect(p.fields['githubPat'], 'ghp_x');
      expect(p.fields.containsKey('fogColor'), isFalse,
          reason: 'non-credential prefs must not enter the vault');
    });
  });

  group('VaultPayload.applyTo (local-first overlay)', () {
    test('overwrites with a present value', () {
      const cur = AppSettings(webdavPass: 'old');
      final applied =
          VaultPayload({'_schema': 1, 'webdavPass': 'new'}).applyTo(cur);
      expect(applied.webdavPass, 'new');
    });

    test('does NOT clobber a local secret with an empty/absent vault value', () {
      const cur = AppSettings(webdavPass: 'keepme', githubPat: 'localPat');
      final applied = VaultPayload({
        '_schema': 1,
        'webdavPass': '', // empty → skip
        // githubPat absent → skip
      }).applyTo(cur);
      expect(applied.webdavPass, 'keepme');
      expect(applied.githubPat, 'localPat');
    });

    test('ignores keys outside the vault set', () {
      const cur = AppSettings(fogColor: 0x11223344);
      final applied =
          VaultPayload({'_schema': 1, 'fogColor': 0x99}).applyTo(cur);
      expect(applied.fogColor, 0x11223344, reason: 'unknown keys are inert');
    });

    test('round-trips the vault subset onto a blank settings', () {
      const s = AppSettings(
        webdavUrl: 'https://dav.example.com',
        webdavUser: 'u',
        webdavPass: 'p',
        syncBackend: 'webdav',
      );
      final restored = VaultPayload.extract(s).applyTo(const AppSettings());
      expect(restored.webdavUrl, 'https://dav.example.com');
      expect(restored.webdavUser, 'u');
      expect(restored.webdavPass, 'p');
      expect(restored.syncBackend, 'webdav');
    });
  });
}
