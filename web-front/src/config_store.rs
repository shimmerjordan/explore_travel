use base64::{engine::general_purpose::STANDARD, Engine as _};
use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305, Key, Nonce,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

const FILE_NAME: &str = "config.json";
const NONCE_LEN: usize = 12;

/// Upper bound on the plaintext config JSON this module is ever asked to
/// persist (the user's cloud credentials + locators: WebDAV password,
/// OneDrive token, GitHub image-host token, AI key, etc. -- all small
/// strings). Not enforced inside `save`/`load` themselves: the HTTP layer
/// owns the request body and rejects an oversized one before it ever reaches
/// this module (see `main.rs`'s `body_cap`, which caps `PUT /api/config`
/// against this constant the same way `MAX_API_BODY` caps the other `/api/*`
/// bodies). The constant lives here so that layer, and any other caller,
/// checks against one shared number instead of inventing its own.
pub const MAX_CONFIG_BYTES: usize = 256 * 1024;

/// Single, undifferentiated error returned by `load` for every failure that
/// happens once the file is known to exist: an unparsable envelope, a nonce
/// that doesn't decode to exactly `NONCE_LEN` bytes, or an AEAD
/// authentication failure -- whether the root cause is a wrong key or a
/// tampered ciphertext. This is deliberate, not an oversight: `load` is
/// reachable, via `GET /api/config` and `PUT /api/password`, from a network
/// client supplying a guessed admin password, and if "wrong key" produced a
/// different error than "corrupted file", that difference would be a
/// decryption oracle an attacker could use to tell how close a guess is. See
/// `decrypt` below, which returns `Result<_, ()>` specifically so there is no
/// message left to leak by the time it reaches here.
///
/// The text is fixed and identical for every cause -- which is what keeps it
/// oracle-free -- so it is safe to hand back to the client verbatim, and it
/// says what the operator can actually DO about it. That matters because this
/// error is self-sustaining once it happens: a config whose ciphertext no
/// longer matches the current password also blocks `PUT /api/password` (it
/// can't re-encrypt what it can't decrypt), so an operator who reads only
/// "config decrypt failed" has no way to tell that the way out is to
/// overwrite the blob rather than to keep retrying. `main.rs` distinguishes
/// this constant from an I/O failure precisely so this one can be surfaced
/// while path-bearing I/O detail stays in the log.
pub const DECRYPT_ERR: &str = "stored config could not be decrypted with the current password; \
     it is not recoverable, but the service is not stuck: overwrite it with a fresh \
     PUT /api/config (push settings again from the app or the console) and both reads and \
     password changes will work again";

/// On-disk envelope for the encrypted config blob. `v` is a format version
/// reserved for future migrations. `nonce_b64` / `ct_b64` use standard
/// (non-URL-safe) base64, matching the convention `admin_file::AdminFile`
/// already uses for `key_salt_b64`.
#[derive(Serialize, Deserialize)]
struct Envelope {
    v: u32,
    nonce_b64: String,
    ct_b64: String,
}

/// Encrypt `plaintext` under `key` with a fresh random nonce and atomically
/// write the envelope to `dir/config.json` via `atomic_file` (fsync'd sibling
/// `.tmp` + `rename` + directory fsync, the same path `admin_file::save`
/// takes). See `atomic_file`'s module comment for why the fsyncs are
/// load-bearing rather than belt-and-braces: this file and `admin.json` must
/// agree about which key the ciphertext is under, so a crash that makes one
/// rename durable and loses the other is exactly the failure mode to avoid.
///
/// The nonce is drawn fresh from the OS RNG on every call, never derived
/// from the key or the plaintext: reusing a ChaCha20-Poly1305 nonce under
/// the same key is catastrophic (it leaks the XOR of the two plaintexts and
/// lets an attacker forge ciphertexts), so "fresh every save" is a hard
/// requirement, not an optimization.
pub fn save(dir: &Path, key: &[u8; 32], plaintext: &[u8]) -> Result<(), String> {
    let mut nonce_bytes = [0u8; NONCE_LEN];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);

    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ct = cipher
        .encrypt(nonce, plaintext)
        .map_err(|_| "config encrypt failed".to_string())?;

    let envelope = Envelope {
        v: 1,
        nonce_b64: STANDARD.encode(nonce_bytes),
        ct_b64: STANDARD.encode(ct),
    };
    let text = serde_json::to_string_pretty(&envelope).map_err(|e| e.to_string())?;

    let path = dir.join(FILE_NAME);
    let tmp_path = dir.join(format!("{FILE_NAME}.tmp"));
    crate::atomic_file::write_tmp(&tmp_path, text.as_bytes())?;
    crate::atomic_file::commit(&tmp_path, &path)
}

/// Read and decrypt `dir/config.json`.
///
/// `Ok(None)` means "no config has ever been saved" -- a normal, common
/// state, not an error. A cryptographic failure collapses into
/// `Err(DECRYPT_ERR)` (see that constant's doc comment for why it is
/// deliberately undifferentiated).
///
/// The ONE case pulled out of that collapse is a file that is not an envelope
/// at all, and it is pulled out because the generic message actively misleads
/// there. Before this server existed in its current shape, `/data/config.json`
/// was the *server settings* file; an upgraded deployment can still have one
/// sitting at that path. Reporting "could not be decrypted with the current
/// password -- overwrite it with a fresh PUT /api/config" against that file
/// tells the operator to run the one command that destroys it, for a problem
/// that is not the one they have. So: no `ct_b64` field, no decryption was
/// ever attempted, and the error says which file it actually is.
pub fn load(dir: &Path, key: &[u8; 32]) -> Result<Option<Vec<u8>>, String> {
    let path = dir.join(FILE_NAME);
    let text = match fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            eprintln!("ERROR: cannot read {}: {e}", path.display());
            return Err(DECRYPT_ERR.into());
        }
    };
    if !looks_like_envelope(&text) {
        eprintln!(
            "ERROR: {} is not an encrypted config envelope (no ct_b64 field). If this \
             deployment was upgraded, it is probably the OLD server settings file -- that \
             used to live at this exact path. Rename it to server.json and restart; do NOT \
             overwrite it via PUT /api/config, that would destroy it.",
            path.display()
        );
        return Err(NOT_AN_ENVELOPE.into());
    }
    decrypt(&text, key).map(Some).map_err(|()| DECRYPT_ERR.to_string())
}

/// Cheap structural test, deliberately NOT a full parse: the question is only
/// "was this file ever written by `save`", and every envelope `save` writes has
/// this field. A truncated or tampered envelope still has it and must keep
/// going down the undifferentiated crypto path.
fn looks_like_envelope(text: &str) -> bool {
    text.contains("ct_b64")
}

/// Distinct from [`DECRYPT_ERR`] on purpose -- see `load`.
///
/// It is safe for this one to be specific: it is reachable only for a file that
/// was never an envelope, so it reveals nothing about a key, a password, or any
/// ciphertext. Saying "wrong file" out loud is what keeps the operator from
/// deleting the right one.
pub const NOT_AN_ENVELOPE: &str = "the file at <data_dir>/config.json is not an encrypted \
config envelope. If this deployment was upgraded from an older version, it is most likely the \
old SERVER SETTINGS file (that used to be its path): rename it to server.json and restart. \
Do NOT push a config over it -- that would overwrite it.";

/// Parse the envelope, base64-decode both fields, and AEAD-decrypt. Returns
/// `Err(())` -- the unit type, not a `String` -- ON PURPOSE: it structurally
/// cannot carry a distinguishing message, so every branch below (bad JSON,
/// bad base64, wrong nonce length, failed authentication) is forced through
/// the exact same undifferentiated error by the time `load` maps it to
/// `DECRYPT_ERR`.
fn decrypt(text: &str, key: &[u8; 32]) -> Result<Vec<u8>, ()> {
    let envelope: Envelope = serde_json::from_str(text).map_err(|_| ())?;
    let nonce_bytes = STANDARD.decode(envelope.nonce_b64).map_err(|_| ())?;
    let ct = STANDARD.decode(envelope.ct_b64).map_err(|_| ())?;
    if nonce_bytes.len() != NONCE_LEN {
        return Err(());
    }
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let nonce = Nonce::from_slice(&nonce_bytes);
    cipher.decrypt(nonce, ct.as_ref()).map_err(|_| ())
}

/// Re-encrypt the stored config from `old` to `new` -- used when the admin
/// password changes, since the config key is derived from it (see
/// `auth::derive_config_key`). A missing file is a no-op: there is nothing
/// to migrate, and treating it as an error would make password changes fail
/// on a freshly installed instance that has never saved a config yet.
///
/// A file that DOES exist but fails to decrypt under `old` (wrong key
/// passed in, or a corrupted file) is NOT folded into that no-op case: the
/// `?` below propagates `load`'s `Err` unchanged, so a caller can tell "there
/// was nothing to do" apart from "something is wrong" instead of both
/// looking like silent success.
pub fn reencrypt(dir: &Path, old: &[u8; 32], new: &[u8; 32]) -> Result<(), String> {
    match load(dir, old)? {
        None => Ok(()),
        Some(plaintext) => save(dir, new, &plaintext),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("wf-cfg-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn missing_file_reads_as_none() {
        let d = tmpdir("none");
        assert_eq!(load(&d, &[1u8; 32]).unwrap(), None);
    }

    #[test]
    fn roundtrip_returns_exact_bytes() {
        let d = tmpdir("rt");
        let key = [9u8; 32];
        let payload = br#"{"webdavUrl":"https://dav.example.com","aiModel":"x"}"#;
        save(&d, &key, payload).unwrap();
        assert_eq!(load(&d, &key).unwrap().unwrap(), payload.to_vec());
    }

    #[test]
    fn wrong_key_fails_to_decrypt() {
        let d = tmpdir("wrongkey");
        save(&d, &[1u8; 32], b"secret").unwrap();
        assert!(load(&d, &[2u8; 32]).is_err(), "wrong key must fail to decrypt, not return garbage");
    }

    #[test]
    fn tampered_ciphertext_is_rejected() {
        let d = tmpdir("tamper");
        let key = [3u8; 32];
        save(&d, &key, b"secret").unwrap();
        let p = d.join("config.json");
        let mut s = std::fs::read_to_string(&p).unwrap();
        // Flip one character inside the ciphertext.
        let idx = s.find("\"ct_b64\"").unwrap() + 12;
        let ch = s.as_bytes()[idx];
        s.replace_range(idx..idx + 1, if ch == b'A' { "B" } else { "A" });
        std::fs::write(&p, s).unwrap();
        assert!(load(&d, &key).is_err(), "AEAD must reject tampered ciphertext");
    }

    #[test]
    fn each_save_uses_a_fresh_nonce() {
        let d = tmpdir("nonce");
        let key = [4u8; 32];
        save(&d, &key, b"same").unwrap();
        let first = std::fs::read_to_string(d.join("config.json")).unwrap();
        save(&d, &key, b"same").unwrap();
        let second = std::fs::read_to_string(d.join("config.json")).unwrap();
        assert_ne!(first, second, "encrypting the same plaintext twice must produce different ciphertext (nonce must change)");
    }

    #[test]
    fn reencrypt_switches_key_and_preserves_content() {
        let d = tmpdir("reenc");
        let (old, new) = ([5u8; 32], [6u8; 32]);
        save(&d, &old, b"payload").unwrap();
        reencrypt(&d, &old, &new).unwrap();
        assert_eq!(load(&d, &new).unwrap().unwrap(), b"payload".to_vec());
        assert!(load(&d, &old).is_err(), "the old key must no longer work after reencrypt");
    }

    #[test]
    fn reencrypt_on_missing_file_is_a_noop() {
        let d = tmpdir("reenc-none");
        reencrypt(&d, &[1u8; 32], &[2u8; 32]).unwrap();
        assert_eq!(load(&d, &[2u8; 32]).unwrap(), None);
    }

    /// The tests above do not, on their own, prove that `reencrypt` tells
    /// "missing file" apart from "file exists but `old` is wrong" -- which is
    /// the distinction a password change depends on. A buggy `reencrypt` that
    /// swallows every `load(old)` error
    /// (not just the specific `None` case) into `Ok(())` -- e.g. `match
    /// load(dir, old) { Ok(Some(pt)) => save(..), _ => Ok(()) }` -- would
    /// pass all 7 original tests unchanged, because none of them ever calls
    /// `reencrypt` with a wrong key against a file that actually exists.
    /// This test closes that gap.
    #[test]
    fn reencrypt_with_wrong_old_key_on_existing_file_errors_and_leaves_file_untouched() {
        let d = tmpdir("reenc-wrongold");
        let real_key = [7u8; 32];
        save(&d, &real_key, b"untouched-payload").unwrap();
        let before = std::fs::read_to_string(d.join("config.json")).unwrap();

        let wrong_old = [8u8; 32];
        let new_key = [9u8; 32];
        assert!(
            reencrypt(&d, &wrong_old, &new_key).is_err(),
            "reencrypt must propagate a real decrypt failure, not silently treat it as a no-op"
        );

        let after = std::fs::read_to_string(d.join("config.json")).unwrap();
        assert_eq!(before, after, "a failed reencrypt must not modify the on-disk file");
        assert_eq!(
            load(&d, &real_key).unwrap().unwrap(),
            b"untouched-payload".to_vec(),
            "the original content must still be readable under its real key after a failed reencrypt"
        );
    }
}
