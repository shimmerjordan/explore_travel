import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/services/backup/backup_credentials.dart';

/// The point of this file is the *failure* directions, not the happy path:
/// a backup zip lives on cloud storage and gets handed around, so what matters
/// is that everything short of the right password yields nothing.
void main() {
  const pw = 'correct horse battery staple';
  final creds = <String, dynamic>{
    'webdavPass': 'SECRET-webdav',
    'githubPat': 'ghp_SECRET',
    'musicCredentials': {'netease': 'COOKIE-SECRET'},
  };

  // 600k PBKDF2 rounds is ~1s per derivation on the VM — the right cost for
  // something that seals once and sits in cloud storage, but there is no reason
  // to pay it twenty times here. Tests that do not depend on a FRESH seal share
  // this one; the ones that do (salt/nonce freshness, swapping) still seal their
  // own.
  late final Future<String> shared = BackupCredentials.seal(creds, pw);

  group('BackupCredentials', () {
    test('round-trips every value, nested ones included', () async {
      final sealed = await shared;
      final opened = await BackupCredentials.open(sealed, pw);
      expect(opened, isNotNull);
      expect(opened!['webdavPass'], 'SECRET-webdav');
      expect(opened['githubPat'], 'ghp_SECRET');
      expect((opened['musicCredentials'] as Map)['netease'], 'COOKIE-SECRET');
    });

    test('the sealed text contains no plaintext secret', () async {
      final sealed = await shared;
      for (final leak in ['SECRET-webdav', 'ghp_SECRET', 'COOKIE-SECRET']) {
        expect(sealed.contains(leak), isFalse, reason: 'leaked $leak');
      }
      // ...and the key NAMES are hidden too: knowing which providers someone
      // configured is itself worth something to an attacker.
      expect(sealed.contains('webdavPass'), isFalse);
    });

    test('a wrong password yields null, not a partial result', () async {
      final sealed = await shared;
      for (final wrong in [
        'wrong',
        '',
        '$pw ', // trailing space
        pw.toUpperCase(),
      ]) {
        expect(await BackupCredentials.open(sealed, wrong), isNull,
            reason: 'opened with $wrong');
      }
    });

    test('two seals of the same data differ (fresh salt and nonce)', () async {
      final a = await BackupCredentials.seal(creds, pw);
      final b = await BackupCredentials.seal(creds, pw);
      expect(a, isNot(b));
      final ja = jsonDecode(a) as Map<String, dynamic>;
      final jb = jsonDecode(b) as Map<String, dynamic>;
      expect(ja['salt'], isNot(jb['salt']),
          reason: 'a fixed salt would let one table attack every backup');
      expect(ja['nonce'], isNot(jb['nonce']));
      // Both still open — the randomness is per-file, not per-password.
      expect(await BackupCredentials.open(a, pw), isNotNull);
      expect(await BackupCredentials.open(b, pw), isNotNull);
    });

    /// Rewriting the recorded iteration count cannot make the file cheaper to
    /// open — in EITHER direction — because that number feeds the key
    /// derivation. This is a property of the construction, not of a range check
    /// (there deliberately is none; see `open`).
    test('rewriting the iteration count breaks the key, either way', () async {
      final sealed = await shared;
      final j = jsonDecode(sealed) as Map<String, dynamic>;
      final original = j['iterations'] as int;
      expect(original, greaterThanOrEqualTo(600000),
          reason: 'a backup sitting in cloud storage deserves a real KDF cost');

      for (final tampered in [1, 1000, original - 1, original + 1, original * 2]) {
        j['iterations'] = tampered;
        expect(await BackupCredentials.open(jsonEncode(j), pw), isNull,
            reason: 'iterations=$tampered must not open');
      }
    });

    /// The reason the range check was left out: raising the seal-time cost must
    /// not strand backups already written at the old cost. Simulated by sealing
    /// at the current constant and opening a file that records a LOWER count
    /// than a future version would use — the only thing that matters is that
    /// the recorded count is what gets used.
    test('a backup opens at whatever cost it recorded', () async {
      // A hand-built envelope at a low cost, opened by this same code: proves
      // `open` honours the file rather than a compiled-in floor.
      const cheap = 1000;
      final low = await BackupCredentials.sealForTest(
          {'webdavPass': 'SECRET-webdav'}, pw, cheap);
      final opened = await BackupCredentials.open(low, pw);
      expect(opened, isNotNull,
          reason: 'a floor here would lock old backups out when the constant rises');
      expect(opened!['webdavPass'], 'SECRET-webdav');
      expect((jsonDecode(low) as Map)['iterations'], cheap);
    });

    test('swapping the salt or nonce is refused', () async {
      final a = jsonDecode(await BackupCredentials.seal(creds, pw))
          as Map<String, dynamic>;
      final b = jsonDecode(await BackupCredentials.seal(creds, pw))
          as Map<String, dynamic>;

      final saltSwapped = {...a, 'salt': b['salt']};
      expect(await BackupCredentials.open(jsonEncode(saltSwapped), pw), isNull);

      final nonceSwapped = {...a, 'nonce': b['nonce']};
      expect(await BackupCredentials.open(jsonEncode(nonceSwapped), pw), isNull);
    });

    /// The seal time is the only thing tying an envelope to the archive it
    /// shipped in, so it has to be unforgeable — otherwise a rollback (dropping
    /// an older backup's credentials member into a newer archive) could not even
    /// be noticed after the fact.
    test('the seal time is readable but not editable', () async {
      final sealed = await shared;
      final at = BackupCredentials.sealedAt(sealed);
      expect(at, isNotNull);
      expect(at!, greaterThan(0));
      final j = jsonDecode(sealed) as Map<String, dynamic>;
      j['sealedAt'] = 0;
      expect(await BackupCredentials.open(jsonEncode(j), pw), isNull,
          reason: 'an edited seal time must break the tag');
      j['sealedAt'] = at + 86400000;
      expect(await BackupCredentials.open(jsonEncode(j), pw), isNull);
      expect(BackupCredentials.sealedAt(null), isNull);
      expect(BackupCredentials.sealedAt('not json'), isNull);
    });

    test('tampering with the ciphertext is detected', () async {
      final j = jsonDecode(await shared)
          as Map<String, dynamic>;
      final ct = base64.decode(j['ct'] as String);
      ct[0] ^= 0xff;
      j['ct'] = base64.encode(ct);
      expect(await BackupCredentials.open(jsonEncode(j), pw), isNull);
    });

    test('a malformed or foreign envelope yields null, never throws', () async {
      for (final junk in [
        '',
        'not json',
        '{}',
        '[]',
        '{"v":99,"kdf":"pbkdf2-hmac-sha256","iterations":600000,'
            '"salt":"AA==","nonce":"AA==","ct":"AA=="}',
        '{"v":1,"kdf":"scrypt","iterations":600000,'
            '"salt":"AA==","nonce":"AA==","ct":"AA=="}',
        '{"v":1,"kdf":"pbkdf2-hmac-sha256","iterations":600000,'
            '"salt":"!!!not base64","nonce":"AA==","ct":"AA=="}',
      ]) {
        expect(await BackupCredentials.open(junk, pw), isNull,
            reason: 'input: $junk');
      }
    });

    test('isSealed tells the importer whether to ask for a password', () async {
      expect(BackupCredentials.isSealed(null), isFalse);
      expect(BackupCredentials.isSealed(''), isFalse);
      expect(BackupCredentials.isSealed('{}'), isFalse);
      expect(
        BackupCredentials.isSealed(await BackupCredentials.seal(creds, pw)),
        isTrue,
      );
    });

    test('an empty credential map still round-trips', () async {
      // The service skips writing the member in this case, but the primitive
      // must not be the thing that breaks if it ever does.
      final sealed = await BackupCredentials.seal(<String, dynamic>{}, pw);
      expect(await BackupCredentials.open(sealed, pw), isEmpty);
    });
  });
}
