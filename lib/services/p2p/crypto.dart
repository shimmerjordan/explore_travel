import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// AES-GCM-256 envelope: derive a key from the user's shared passphrase via
/// PBKDF2-SHA256, then encrypt JSON payloads with a fresh random nonce per
/// message. Output frame: `v1|base64(nonce)|base64(ciphertext+mac)`.
class P2PCrypto {
  final Future<SecretKey> _keyFuture;
  P2PCrypto._(this._keyFuture);

  /// Derive a key from a passphrase. The salt is a deterministic constant so
  /// every device with the same passphrase ends up with the same key — that
  /// is the whole point: no exchange needed, just share a phrase out-of-band.
  static P2PCrypto fromPassphrase(String passphrase) {
    final algo = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 50000,
      bits: 256,
    );
    final salt = utf8.encode('explore_journal/v1');
    final future = algo.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    return P2PCrypto._(future);
  }

  Future<String> encrypt(String plaintext) async {
    final key = await _keyFuture;
    final algo = AesGcm.with256bits();
    final nonce = algo.newNonce();
    final box = await algo.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    final blob = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return 'v1|${base64.encode(nonce)}|${base64.encode(blob)}';
  }

  Future<String?> decrypt(String frame) async {
    try {
      final parts = frame.split('|');
      if (parts.length != 3 || parts[0] != 'v1') return null;
      final nonce = base64.decode(parts[1]);
      final blob = base64.decode(parts[2]);
      final macBytes = blob.sublist(blob.length - 16);
      final cipher = blob.sublist(0, blob.length - 16);
      final algo = AesGcm.with256bits();
      final key = await _keyFuture;
      final clear = await algo.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(macBytes)),
        secretKey: key,
      );
      return utf8.decode(clear);
    } catch (_) {
      return null;
    }
  }
}
