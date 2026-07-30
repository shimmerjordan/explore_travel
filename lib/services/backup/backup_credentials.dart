import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// The credential half of a backup, sealed under a password the user chooses
/// at export time.
///
/// Why this exists at all: an export used to simply *drop* every credential
/// (see `kVaultSecretKeys`), because backup zips end up on cloud storage and
/// get handed to friends — a plaintext PAT in there is a stolen PAT. But that
/// made a backup unable to actually restore the app: after a restore you were
/// re-entering a WebDAV password, a GitHub token, an OneDrive session and
/// several API keys by hand.
///
/// So the credentials travel, encrypted, in a separate member of the archive.
/// Someone who obtains the zip without the password gets exactly what they got
/// before this existed: the scrubbed settings, with every secret still `null`.
///
/// Deliberate choices, and why:
///
///   * **A random salt per backup**, not the fixed one `P2PCrypto` uses. That
///     one is fixed on purpose — two devices must derive the same key from the
///     same phrase with nothing exchanged. Here the opposite is wanted: two
///     backups of the same data under the same password must not produce
///     comparable ciphertext, and a stolen archive must not be attackable with
///     a table precomputed against a known salt.
///   * **A high iteration count.** This runs twice in the life of a backup
///     (seal, open), so a cost measured in a second or so is the right trade —
///     it is the only thing between a stolen archive and the credentials
///     inside it. `P2PCrypto`'s 50k is tuned for a per-session handshake, not
///     for something that sits in cloud storage indefinitely.
///   * **The KDF parameters go in as AEAD associated data.** Note what this does
///     and does not buy: rewriting `iterations` or the salt already breaks
///     decryption on its own, because both feed the key derivation — the tag
///     fails because the KEY is different, not because of the AAD. So the AAD is
///     defence in depth, not the thing standing between a rewritten file and a
///     cheap crack. It is kept because it stays correct if the format ever gains
///     a parameter that does NOT feed the key, and it costs nothing; it is
///     documented this way because an overstated reason is worse than none —
///     the next reader would believe removing it opens a hole.
///   * **A wrong password is indistinguishable from a corrupt file.** `open`
///     returns null for both. There is nothing useful to tell apart — either
///     way the caller's move is the same — and a distinguishable failure is how
///     a decryption oracle starts.
class BackupCredentials {
  /// What is NOT in here: `leaderboardPrivateKey`.
  ///
  /// It is absent from `kVaultSecretKeys` entirely, so it never reaches this
  /// class — it travels in the archive **in the clear**. That is deliberate and
  /// is a DIFFERENT decision from the one in `ConfigPayload.locatorKeys` (which
  /// excludes it from *roaming*): a backup is the only supported way to move a
  /// leaderboard identity to a new phone, and sealing it would mean a restore
  /// without the password produces an install that signs as a stranger and gets
  /// refused under the server's TOFU rule. Losing the identity is worse than the
  /// key being readable in a file the user already controls.
  ///
  /// Archive member holding the sealed blob.
  static const fileName = 'settings/credentials.enc';

  static const _version = 1;
  static const _kdf = 'pbkdf2-hmac-sha256';
  /// The cost paid when SEALING. Opening uses whatever the file records, so
  /// this can be raised later without stranding existing backups.
  static const _iterations = 600000;
  static const _saltBytes = 16;
  static const _macBytes = 16;

  /// Seal [credentials] under [password].
  ///
  /// Returns the archive member's text. Callers should skip writing the member
  /// entirely when there is nothing to seal — an envelope around an empty map
  /// still advertises "this backup has credentials" and still costs the
  /// importer a password prompt.
  static Future<String> seal(
    Map<String, dynamic> credentials,
    String password,
  ) =>
      _seal(credentials, password, _iterations);

  static Future<String> _seal(
    Map<String, dynamic> credentials,
    String password,
    int iterations,
  ) async {
    final salt = _randomBytes(_saltBytes);
    final key = await _deriveKey(password, salt, iterations);
    final algo = AesGcm.with256bits();
    final nonce = algo.newNonce();
    // Authenticated, so the recorded time cannot be edited. It exists because
    // nothing else ties this envelope to the archive it shipped in: someone who
    // can rewrite a zip could drop in the credentials member from an OLDER
    // backup of the same user, and the rightful password would open it — a
    // rollback to stale credentials, no password needed. The timestamp does not
    // prevent that, but it makes it visible: `sealedAt` is returned to the
    // caller, which can compare it against the archive's own export time.
    final sealedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
    final header = _header(salt, iterations, nonce, sealedAt);
    final box = await algo.encrypt(
      utf8.encode(jsonEncode(credentials)),
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(header),
    );
    return jsonEncode({
      'v': _version,
      'kdf': _kdf,
      'iterations': iterations,
      'salt': base64.encode(salt),
      'nonce': base64.encode(nonce),
      'sealedAt': sealedAt,
      'ct': base64.encode([...box.cipherText, ...box.mac.bytes]),
    });
  }

  /// Seal at an explicit cost. Only for tests that need to prove `open` honours
  /// the count recorded in the file rather than a compiled-in floor — production
  /// always seals at [_iterations].
  @visibleForTesting
  static Future<String> sealForTest(
    Map<String, dynamic> credentials,
    String password,
    int iterations,
  ) =>
      _seal(credentials, password, iterations);

  /// Open a sealed blob.
  ///
  /// `null` means **could not open** — wrong password, tampering, truncation,
  /// unknown version, malformed JSON — undifferentiated on purpose (see the
  /// class doc). An empty map means **opened, and it was empty**, which is a
  /// different thing: callers must not collapse the two, or a legitimately
  /// empty envelope gets reported to the user as a wrong password.
  static Future<Map<String, dynamic>?> open(
    String envelope,
    String password,
  ) async {
    try {
      final j = jsonDecode(envelope) as Map<String, dynamic>;
      if ((j['v'] as num?)?.toInt() != _version) return null;
      if (j['kdf'] != _kdf) return null;
      final iterations = (j['iterations'] as num?)?.toInt() ?? 0;
      if (iterations <= 0) return null;
      // Deliberately NO "iterations must be >= our constant" check.
      //
      // It looks like a downgrade defence and is not one: `iterations` feeds
      // `_deriveKey`, so rewriting it produces a DIFFERENT key and the tag stops
      // verifying on its own. And an attacker brute-forcing the file offline
      // picks his own iteration count regardless of what the field says — the
      // field only ever constrains the legitimate opener.
      //
      // What such a check WOULD do is make raising `_iterations` later a
      // breaking change that silently locks every already-written backup out of
      // its own credentials. A guard that protects nothing and costs that is
      // not a guard.
      final salt = base64.decode(j['salt'] as String);
      final nonce = base64.decode(j['nonce'] as String);
      final sealedAt = (j['sealedAt'] as num?)?.toInt() ?? 0;
      final blob = base64.decode(j['ct'] as String);
      if (blob.length < _macBytes) return null;

      final key = await _deriveKey(password, salt, iterations);
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          blob.sublist(0, blob.length - _macBytes),
          nonce: nonce,
          mac: Mac(blob.sublist(blob.length - _macBytes)),
        ),
        secretKey: key,
        aad: utf8.encode(_header(salt, iterations, nonce, sealedAt)),
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  /// When the envelope was sealed (UTC ms), or null. Authenticated, so it
  /// cannot be edited without breaking the tag — see `_seal` for what it is for.
  static int? sealedAt(String? envelope) {
    if (envelope == null) return null;
    try {
      return ((jsonDecode(envelope) as Map<String, dynamic>)['sealedAt'] as num?)
          ?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// Does this archive carry sealed credentials? Lets the importer ask for a
  /// password only when one is actually needed.
  static bool isSealed(String? envelope) {
    if (envelope == null) return false;
    try {
      final j = jsonDecode(envelope) as Map<String, dynamic>;
      return j['ct'] != null && j['salt'] != null;
    } catch (_) {
      return false;
    }
  }

  /// The authenticated header. Its exact bytes are part of the contract: change
  /// the format and old backups stop opening, so the version is in it.
  static String _header(
    List<int> salt,
    int iterations,
    List<int> nonce,
    int sealedAt,
  ) =>
      'explore_journal/backup-credentials/v$_version|$_kdf|$iterations|'
      '${base64.encode(salt)}|${base64.encode(nonce)}|$sealedAt';

  static Future<SecretKey> _deriveKey(
    String password,
    List<int> salt,
    int iterations,
  ) =>
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
          .deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );

  static final _rng = Random.secure();

  /// Salt bytes.
  ///
  /// `Random.secure()` rather than the crypto package's `newNonce()`: that one
  /// draws from `Cryptography.instance`, which is process-global and
  /// REPLACEABLE — a test or a future dependency that swaps in a seeded
  /// implementation would silently make this salt deterministic, which is the
  /// exact property the random salt exists to prevent. `Random.secure()` has no
  /// such seam.
  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));
}
