import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/core/prefs.dart';
import 'package:explore_journal/services/backup/backup_service.dart'
    show kVaultSecretKeys;
import 'package:explore_journal/services/security/secure_credentials.dart';
import 'package:explore_journal/services/vault/config_payload.dart';

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
  group('kConfigPayloadKeys — single source of truth', () {
    test('is a superset of the backup scrubber secret set', () {
      expect(ConfigPayload.kConfigPayloadKeys.containsAll(kVaultSecretKeys), isTrue,
          reason: 'every scrubbed secret must also travel in the config');
    });

    test('covers every SecureCredentials keystore key (camelCase mapped)', () {
      for (final k in SecureCredentials.all) {
        final mapped = _secureToSettings[k];
        expect(mapped, isNotNull, reason: 'unmapped keystore key: $k');
        expect(ConfigPayload.kConfigPayloadKeys.contains(mapped), isTrue,
            reason: '$mapped (from $k) missing from the config key set');
      }
    });

    test('deliberately excludes the per-device leaderboard identity', () {
      expect(ConfigPayload.kConfigPayloadKeys.contains('leaderboardPrivateKey'),
          isFalse);
      expect(ConfigPayload.kConfigPayloadKeys.contains('leaderboardPublicKey'),
          isFalse);
    });
  });

  group('ConfigPayload.extract', () {
    test('picks only config keys and stamps the schema', () {
      const s = AppSettings(
        webdavUrl: 'https://dav.example.com',
        webdavPass: 'secret',
        githubPat: 'ghp_x',
        fogColor: 0xDEADBEEF, // a non-config field
      );
      final p = ConfigPayload.extract(s);
      expect(p.schema, ConfigPayload.schemaVersion);
      expect(p.fields['webdavPass'], 'secret');
      expect(p.fields['githubPat'], 'ghp_x');
      expect(p.fields.containsKey('fogColor'), isFalse,
          reason: 'non-credential prefs must not enter the config');
    });
  });

  group('ConfigPayload.applyTo (local-first overlay)', () {
    test('overwrites with a present value', () {
      const cur = AppSettings(webdavPass: 'old');
      final applied =
          ConfigPayload({'_schema': 1, 'webdavPass': 'new'}).applyTo(cur);
      expect(applied.webdavPass, 'new');
    });

    test('does NOT clobber a local secret with an empty/absent remote value', () {
      const cur = AppSettings(webdavPass: 'keepme', githubPat: 'localPat');
      final applied = ConfigPayload({
        '_schema': 1,
        'webdavPass': '', // empty → skip
        // githubPat absent → skip
      }).applyTo(cur);
      expect(applied.webdavPass, 'keepme');
      expect(applied.githubPat, 'localPat');
    });

    test('ignores keys outside the config set', () {
      const cur = AppSettings(fogColor: 0x11223344);
      final applied =
          ConfigPayload({'_schema': 1, 'fogColor': 0x99}).applyTo(cur);
      expect(applied.fogColor, 0x11223344, reason: 'unknown keys are inert');
    });

    test('a wrong-TYPED remote value is skipped, not fatal', () {
      // Every one of these threw a Dart type error before the filter existed,
      // and it threw on the login path with a valid session already in hand —
      // i.e. correct credentials, permanent lockout, and no client-side way to
      // repair the stored config. `PUT /api/config` only checks that the body
      // is a JSON object, so any of these can genuinely be stored.
      const cur = AppSettings(webdavUrl: 'https://local', webdavPass: 'keepme');
      for (final bad in <Map<String, dynamic>>[
        {'_schema': 1, 'musicCredentials': 'oops-a-string'},
        {'_schema': 1, 'oneDriveAccount': 42},
        {'_schema': 1, 'webdavUrl': 7},
        {'_schema': 1, 'webdavPass': true},
        {'_schema': 1, 'musicCredentials': <String, dynamic>{'ok': 1}, },
        {'_schema': 1, 'syncBackend': <String>['webdav']},
      ]) {
        final applied = ConfigPayload(bad).applyTo(cur);
        expect(applied.webdavPass, 'keepme',
            reason: 'a malformed field must not take the rest down: $bad');
      }
      // The malformed key specifically leaves the local value alone.
      expect(
          ConfigPayload({'_schema': 1, 'webdavUrl': 7}).applyTo(cur).webdavUrl,
          'https://local');
    });

    test('a malformed field does not stop the well-formed ones applying', () {
      const cur = AppSettings();
      final applied = ConfigPayload({
        '_schema': 1,
        'musicCredentials': 'oops-a-string', // bad
        'webdavUrl': 'https://dav.example.com', // good
        'webdavUser': 'u', // good
      }).applyTo(cur);
      expect(applied.webdavUrl, 'https://dav.example.com');
      expect(applied.webdavUser, 'u');
      expect(applied.musicCredentials, isEmpty);
    });

    test('EVERY config key tolerates a wrong-typed value (no key left behind)',
        () {
      // The maintenance-free half of the guard: if someone adds a key whose
      // AppSettings field is an int/bool/list without listing it in
      // ConfigPayload.mapKeys (or extending _typeMatches), this fails here
      // instead of on a user's login screen.
      const cur = AppSettings();
      const wrongValues = <Object>[
        42,
        true,
        3.5,
        'a-string',
        <String, dynamic>{'k': 'v'},
        <String>['a'],
        <int, String>{1: 'v'}, // non-String map keys throw in fromJson too
      ];
      for (final k in ConfigPayload.kConfigPayloadKeys) {
        for (final v in wrongValues) {
          expect(() => ConfigPayload({'_schema': 1, k: v}).applyTo(cur),
              returnsNormally,
              reason: 'applyTo threw on $k = $v (${v.runtimeType})');
        }
      }
    });

    test('an unknown FUTURE schema still applies the keys it recognises', () {
      // The version stamp is informational (applyTo logs it) — it must not be
      // a reason to drop a config the client can perfectly well read.
      final applied = ConfigPayload({'_schema': 999, 'webdavUrl': 'https://ok'})
          .applyTo(const AppSettings());
      expect(applied.webdavUrl, 'https://ok');
    });

    test('round-trips the config subset onto a blank settings', () {
      const s = AppSettings(
        webdavUrl: 'https://dav.example.com',
        webdavUser: 'u',
        webdavPass: 'p',
        syncBackend: 'webdav',
      );
      final restored = ConfigPayload.extract(s).applyTo(const AppSettings());
      expect(restored.webdavUrl, 'https://dav.example.com');
      expect(restored.webdavUser, 'u');
      expect(restored.webdavPass, 'p');
      expect(restored.syncBackend, 'webdav');
    });
  });

  group('AppSettings.fromJson tolerates retired keys', () {
    test('a pre-console prefs blob (nasAccountEmail / nasKdfSalt) still loads',
        () {
      // `fromJson` reads by explicit key, so fields this build dropped are
      // simply not looked at — an install upgrading from the account-based
      // vault must not lose its settings over them.
      final s = AppSettings.fromJson({
        'nasServerUrl': 'http://192.168.1.9:48080',
        'nasAccountEmail': 'me@x.com',
        'nasKdfSalt': 'AAAAAAAAAAAAAAAAAAAAAA==',
        'webdavUrl': 'https://dav.example.com',
        'fogOpacity': 0.42,
      });
      expect(s.nasServerUrl, 'http://192.168.1.9:48080');
      expect(s.webdavUrl, 'https://dav.example.com');
      expect(s.fogOpacity, 0.42);
      expect(s.toJson().containsKey('nasAccountEmail'), isFalse,
          reason: 'the retired key must not be written back out');
    });
  });
}
