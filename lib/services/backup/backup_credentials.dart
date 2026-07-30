import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

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
///   * **The KDF parameters are authenticated**, not merely stored. They go in
///     as AEAD associated data, so an attacker cannot rewrite `iterations` down
///     to 1 (or swap the salt) and hand the file back: the tag stops verifying.
///     Storing them unauthenticated would make the high iteration count
///     advisory.
///   * **A wrong password is indistinguishable from a corrupt file.** `open`
///     returns null for both. There is nothing useful to tell apart — either
///     way the caller's move is the same — and a distinguishable failure is how
///     a decryption oracle starts.
class BackupCredentials {
  /// Archive member holding the sealed blob.
  static const fileName = 'settings/credentials.enc';

  static const _version = 1;
  static const _kdf = 'pbkdf2-hmac-sha256';
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
  ) async {
    final salt = _randomBytes(_saltBytes);
    final key = await _deriveKey(password, salt, _iterations);
    final algo = AesGcm.with256bits();
    final nonce = algo.newNonce();
    final header = _header(salt, _iterations, nonce);
    final box = await algo.encrypt(
      utf8.encode(jsonEncode(credentials)),
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(header),
    );
    return jsonEncode({
      'v': _version,
      'kdf': _kdf,
      'iterations': _iterations,
      'salt': base64.encode(salt),
      'nonce': base64.encode(nonce),
      'ct': base64.encode([...box.cipherText, ...box.mac.bytes]),
    });
  }

  /// Open a sealed blob, or return null.
  ///
  /// Null covers every failure — wrong password, tampering, truncation,
  /// unknown version, malformed JSON — on purpose. See the class doc.
  static Future<Map<String, dynamic>?> open(
    String envelope,
    String password,
  ) async {
    try {
      final j = jsonDecode(envelope) as Map<String, dynamic>;
      if ((j['v'] as num?)?.toInt() != _version) return null;
      if (j['kdf'] != _kdf) return null;
      final iterations = (j['iterations'] as num?)?.toInt() ?? 0;
      // Refuse a weakened file outright rather than spending the caller's time
      // proving it decrypts. A backup written by this code always carries the
      // constant; anything lower was edited.
      if (iterations < _iterations) return null;
      final salt = base64.decode(j['salt'] as String);
      final nonce = base64.decode(j['nonce'] as String);
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
        aad: utf8.encode(_header(salt, iterations, nonce)),
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
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
  static String _header(List<int> salt, int iterations, List<int> nonce) =>
      'explore_journal/backup-credentials/v$_version|$_kdf|$iterations|'
      '${base64.encode(salt)}|${base64.encode(nonce)}';

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

  static Uint8List _randomBytes(int n) {
    // `AesGcm.newNonce()` is the package's CSPRNG-backed source; 12 bytes at a
    // time, concatenated to whatever length is needed. Using it rather than
    // `Random.secure()` keeps every random byte in this file coming from the
    // same audited place.
    final out = <int>[];
    final algo = AesGcm.with256bits();
    while (out.length < n) {
      out.addAll(algo.newNonce());
    }
    return Uint8List.fromList(out.sublist(0, n));
  }
}
