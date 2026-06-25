import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/services/vault/settings_vault.dart';
import 'package:explore_journal/services/vault/vault_payload.dart';

void main() {
  const pw = 'correct horse battery staple';
  final payload = VaultPayload({
    '_schema': 1,
    'webdavUrl': 'https://dav.example.com/dav',
    'webdavUser': 'traveler',
    'webdavPass': 's3cr3t-pass',
    'githubPat': 'ghp_xxx',
    'syncBackend': 'webdav',
  });

  const vault = SettingsVault();

  group('SettingsVault seal/open round-trip', () {
    test('open with the right password recovers the exact payload', () async {
      final sealed = await vault.seal(payload, pw);
      final opened = await vault.open(sealed.blob, pw);
      expect(opened.payload.fields, equals(payload.fields));
    });

    test('blob survives a bytes round-trip (NAS stores opaque bytes)', () async {
      final sealed = await vault.seal(payload, pw);
      final reparsed = VaultBlob.fromBytes(sealed.blob.toBytes());
      final opened = await vault.decrypt(reparsed, sealed.keys.vaultKey);
      expect(opened.fields['webdavPass'], 's3cr3t-pass');
    });
  });

  group('SettingsVault integrity', () {
    test('wrong password fails as VaultDecryptException', () async {
      final sealed = await vault.seal(payload, pw);
      await expectLater(
        vault.open(sealed.blob, 'a different password entirely'),
        throwsA(isA<VaultDecryptException>()),
      );
    });

    test('tampered ciphertext fails authentication', () async {
      final sealed = await vault.seal(payload, pw);
      final ct = Uint8List.fromList(sealed.blob.ciphertext);
      ct[0] ^= 0xFF; // flip a byte
      final tampered = VaultBlob(
        kdf: sealed.blob.kdf,
        salt: sealed.blob.salt,
        nonce: sealed.blob.nonce,
        ciphertext: ct,
        authTag: sealed.blob.authTag,
      );
      await expectLater(
        vault.decrypt(tampered, sealed.keys.vaultKey),
        throwsA(isA<VaultDecryptException>()),
      );
    });

    test('swapping the KDF params (AAD) invalidates the tag', () async {
      final sealed = await vault.seal(payload, pw);
      // Same ciphertext, but claim different (still-valid-floor) KDF params.
      final tampered = VaultBlob(
        kdf: const VaultKdfParams(iterations: 800000),
        salt: sealed.blob.salt,
        nonce: sealed.blob.nonce,
        ciphertext: sealed.blob.ciphertext,
        authTag: sealed.blob.authTag,
      );
      await expectLater(
        vault.decrypt(tampered, sealed.keys.vaultKey),
        throwsA(isA<VaultDecryptException>()),
      );
    });
  });

  group('SettingsVault downgrade & version guards', () {
    test('decrypt refuses a KDF below the iteration floor', () async {
      final sealed = await vault.seal(payload, pw);
      final weak = VaultBlob(
        kdf: const VaultKdfParams(iterations: 1000),
        salt: sealed.blob.salt,
        nonce: sealed.blob.nonce,
        ciphertext: sealed.blob.ciphertext,
        authTag: sealed.blob.authTag,
      );
      await expectLater(
        vault.decrypt(weak, sealed.keys.vaultKey),
        throwsA(isA<VaultFormatException>()),
      );
    });

    test('fromJson rejects an unknown blob version', () {
      expect(() => VaultBlob.fromJson({'v': 2}),
          throwsA(isA<VaultFormatException>()));
    });

    test('seal rejects a too-short password', () async {
      await expectLater(
        vault.seal(payload, 'short'),
        throwsA(isA<VaultWeakPasswordException>()),
      );
    });
  });

  group('SettingsVault key schedule (domain separation)', () {
    final salt = Uint8List.fromList(List<int>.filled(16, 7));

    test('same password+salt deterministically reproduces both keys', () async {
      final a = await SettingsVault.derive(pw, salt: salt);
      final b = await SettingsVault.derive(pw, salt: salt);
      expect(await a.vaultKey.extractBytes(), await b.vaultKey.extractBytes());
      expect(a.authVerifier, b.authVerifier);
    });

    test('vaultKey and authVerifier are independent (HKDF info split)',
        () async {
      final k = await SettingsVault.derive(pw, salt: salt);
      expect(await k.vaultKey.extractBytes(), isNot(equals(k.authVerifier)),
          reason: 'NAS-held authVerifier must not equal the in-memory vaultKey');
      expect(k.authVerifier.length, 32);
    });

    test('a different salt yields different keys', () async {
      final a = await SettingsVault.derive(pw, salt: salt);
      final b = await SettingsVault.derive(pw,
          salt: Uint8List.fromList(List<int>.filled(16, 9)));
      expect(await a.vaultKey.extractBytes(),
          isNot(equals(await b.vaultKey.extractBytes())));
    });
  });
}
