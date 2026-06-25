import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_payload.dart';

/// Thrown when a blob can't be decrypted — wrong password OR tampering. The
/// two are deliberately indistinguishable (AES-GCM auth failure covers both).
class VaultDecryptException implements Exception {
  final String message;
  const VaultDecryptException(this.message);
  @override
  String toString() => 'VaultDecryptException: $message';
}

/// Thrown when a blob is structurally invalid or its parameters are refused
/// (unknown version, KDF below the security floor).
class VaultFormatException implements Exception {
  final String message;
  const VaultFormatException(this.message);
  @override
  String toString() => 'VaultFormatException: $message';
}

/// Thrown by [SettingsVault.seal] when the chosen password is too weak — the
/// password is the *only* entropy protecting an offline-crackable blob that
/// contains refresh tokens and PATs, so strength is enforced at the seal seam,
/// not left to the UI.
class VaultWeakPasswordException implements Exception {
  final String message;
  const VaultWeakPasswordException(this.message);
  @override
  String toString() => 'VaultWeakPasswordException: $message';
}

/// KDF parameters, stored *inside* the blob so the cost can be raised later
/// without breaking old blobs (decrypt always reads the KDF from the blob).
class VaultKdfParams {
  final String algo; // 'pbkdf2-sha256'
  final int iterations;
  final int dkLen; // bytes

  const VaultKdfParams({
    this.algo = 'pbkdf2-sha256',
    this.iterations = 600000,
    this.dkLen = 32,
  });

  Map<String, dynamic> toJson() =>
      {'algo': algo, 'iters': iterations, 'dk': dkLen};

  factory VaultKdfParams.fromJson(Map j) => VaultKdfParams(
        algo: (j['algo'] ?? 'pbkdf2-sha256').toString(),
        iterations: (j['iters'] as num).toInt(),
        dkLen: (j['dk'] as num).toInt(),
      );
}

/// The encrypted vault frame. JSON-encoded for transport; the NAS stores it as
/// opaque bytes and never parses it.
class VaultBlob {
  static const version = 1;

  final VaultKdfParams kdf;
  final Uint8List salt; // KDF salt
  final Uint8List nonce; // AES-GCM nonce (12 B)
  final Uint8List ciphertext;
  final Uint8List authTag; // AES-GCM tag (16 B)

  const VaultBlob({
    required this.kdf,
    required this.salt,
    required this.nonce,
    required this.ciphertext,
    required this.authTag,
  });

  Map<String, dynamic> toJson() => {
        'v': version,
        'kdf': kdf.toJson(),
        'salt': base64.encode(salt),
        'nonce': base64.encode(nonce),
        'ct': base64.encode(ciphertext),
        'tag': base64.encode(authTag),
      };

  /// UTF-8 JSON bytes — what gets PUT to the NAS / read back.
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  factory VaultBlob.fromJson(Map<String, dynamic> j) {
    final v = (j['v'] as num?)?.toInt();
    if (v != version) {
      throw VaultFormatException('unsupported vault blob version: $v');
    }
    return VaultBlob(
      kdf: VaultKdfParams.fromJson(j['kdf'] as Map),
      salt: base64.decode(j['salt'] as String),
      nonce: base64.decode(j['nonce'] as String),
      ciphertext: base64.decode(j['ct'] as String),
      authTag: base64.decode(j['tag'] as String),
    );
  }

  factory VaultBlob.fromBytes(List<int> bytes) {
    try {
      return VaultBlob.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    } on VaultFormatException {
      rethrow;
    } catch (e) {
      throw VaultFormatException('not a valid vault blob: $e');
    }
  }
}

/// The two domain-separated keys derived from one password+salt.
class DerivedKeys {
  /// Symmetric key for the vault cipher — stays in memory, NEVER uploaded.
  final SecretKey vaultKey;

  /// Password-equivalent sent to the NAS for auth. The server re-hashes it
  /// (Argon2id + server salt). HKDF domain separation makes this independent
  /// of [vaultKey] — holding it tells the server nothing about [vaultKey].
  final Uint8List authVerifier;

  /// KDF salt used (random on first seal; from the blob on open).
  final Uint8List salt;

  const DerivedKeys(this.vaultKey, this.authVerifier, this.salt);
}

/// Zero-knowledge settings vault: client-side AES-GCM-256 over a
/// password-derived key. The NAS only ever stores ciphertext and cannot
/// decrypt it.
///
/// Key schedule (single canonical KDF — see plan §4.3):
/// ```
/// master       = PBKDF2-HMAC-SHA256(password, salt, iters=600000, 32B)
/// vaultKey     = HKDF-SHA256(master, info="explore_journal/vault/v1/enc",  32B)
/// authVerifier = HKDF-SHA256(master, info="explore_journal/vault/v1/auth", 32B)
/// ```
/// PBKDF2 (not Argon2id) because the `cryptography` package does NOT
/// Web-Crypto-accelerate Argon2id — 64 MiB memory-hardening would jank/OOM the
/// browser main thread. PBKDF2-SHA256 is Web-Crypto-accelerated and consistent
/// across platforms.
///
/// Callers should run [derive] off the main thread (`compute` / a web worker)
/// since 600k iterations is perceptible; derive once per session and cache the
/// returned [SecretKey] in memory.
class SettingsVault {
  const SettingsVault();

  static const _encInfo = 'explore_journal/vault/v1/enc';
  static const _authInfo = 'explore_journal/vault/v1/auth';

  /// Security floor: refuse to decrypt a blob whose KDF was weakened below
  /// this (a downgrade-attack guard, since AAD alone can't prevent re-sealing
  /// with cheaper params).
  static const minIterations = 600000;

  /// Minimum password length enforced at [seal]. The blob is offline-crackable
  /// if stolen, and the password is the only secret.
  static const minPasswordLength = 8;

  static final Random _rng = Random.secure();

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

  /// A fresh CSPRNG salt (16 bytes) — used by the NAS controller to mint the
  /// per-account salt at registration.
  static Uint8List randomSalt([int n = 16]) => _randomBytes(n);

  /// AAD binds the header (version|kdf|salt) into the cipher so the params
  /// can't be swapped without invalidating the tag.
  static List<int> _aad(int version, VaultKdfParams p, Uint8List salt) =>
      utf8.encode(jsonEncode({
        'v': version,
        'kdf': p.toJson(),
        'salt': base64.encode(salt),
      }));

  /// Derive [DerivedKeys] from [password]. Pass [salt]/[params] from a blob to
  /// reproduce an existing key; omit for a fresh seal (random 16-byte salt).
  static Future<DerivedKeys> derive(
    String password, {
    Uint8List? salt,
    VaultKdfParams params = const VaultKdfParams(),
  }) async {
    final useSalt = salt ?? _randomBytes(16);
    final master = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: params.iterations,
      bits: params.dkLen * 8,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: useSalt,
    );
    final masterBytes = await master.extractBytes();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final vaultKey = await hkdf.deriveKey(
      secretKey: SecretKey(masterBytes),
      info: utf8.encode(_encInfo),
      nonce: const [],
    );
    final authKey = await hkdf.deriveKey(
      secretKey: SecretKey(masterBytes),
      info: utf8.encode(_authInfo),
      nonce: const [],
    );
    return DerivedKeys(
      vaultKey,
      Uint8List.fromList(await authKey.extractBytes()),
      useSalt,
    );
  }

  /// Encrypt [payload] with an already-derived [vaultKey]+[salt].
  Future<VaultBlob> encrypt(
    VaultPayload payload,
    SecretKey vaultKey,
    Uint8List salt, {
    VaultKdfParams params = const VaultKdfParams(),
  }) async {
    final cipher = AesGcm.with256bits();
    final nonce = cipher.newNonce(); // fresh 12-byte random nonce
    final box = await cipher.encrypt(
      utf8.encode(jsonEncode(payload.toJson())),
      secretKey: vaultKey,
      nonce: nonce,
      aad: _aad(VaultBlob.version, params, salt),
    );
    return VaultBlob(
      kdf: params,
      salt: salt,
      nonce: Uint8List.fromList(box.nonce),
      ciphertext: Uint8List.fromList(box.cipherText),
      authTag: Uint8List.fromList(box.mac.bytes),
    );
  }

  /// Decrypt [blob] with an already-derived [vaultKey]. Throws
  /// [VaultDecryptException] on wrong key / tampering, [VaultFormatException]
  /// on a downgraded KDF.
  Future<VaultPayload> decrypt(VaultBlob blob, SecretKey vaultKey) async {
    if (blob.kdf.iterations < minIterations) {
      throw VaultFormatException(
          'vault KDF below floor (${blob.kdf.iterations} < $minIterations)');
    }
    final List<int> clear;
    try {
      clear = await AesGcm.with256bits().decrypt(
        SecretBox(blob.ciphertext,
            nonce: blob.nonce, mac: Mac(blob.authTag)),
        secretKey: vaultKey,
        aad: _aad(VaultBlob.version, blob.kdf, blob.salt),
      );
    } on SecretBoxAuthenticationError {
      throw const VaultDecryptException('wrong password or corrupted vault');
    }
    return VaultPayload.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
  }

  /// Convenience: derive a fresh key and seal [payload] in one call. Returns
  /// both the blob (to PUT) and the derived keys (the caller keeps [vaultKey]
  /// in memory and sends [authVerifier] to the NAS).
  Future<({VaultBlob blob, DerivedKeys keys})> seal(
    VaultPayload payload,
    String password, {
    VaultKdfParams params = const VaultKdfParams(),
  }) async {
    if (password.length < minPasswordLength) {
      throw VaultWeakPasswordException(
          '口令至少需要 $minPasswordLength 个字符');
    }
    final keys = await derive(password, params: params);
    final blob = await encrypt(payload, keys.vaultKey, keys.salt, params: params);
    return (blob: blob, keys: keys);
  }

  /// Convenience: derive the key from [blob]'s own salt/params and open it.
  Future<({VaultPayload payload, DerivedKeys keys})> open(
    VaultBlob blob,
    String password,
  ) async {
    final keys = await derive(password, salt: blob.salt, params: blob.kdf);
    final payload = await decrypt(blob, keys.vaultKey);
    return (payload: payload, keys: keys);
  }
}
