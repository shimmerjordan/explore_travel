use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use argon2::password_hash::{SaltString, rand_core::OsRng};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD, engine::general_purpose::STANDARD};
use rand::RngCore;

/// Hash the admin password into an Argon2id PHC string, suitable for storage
/// and later verification via `verify_password`.
pub fn hash_password(pw: &[u8]) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(pw, &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

/// Verify a password against a previously stored Argon2id PHC string.
pub fn verify_password(phc: &str, pw: &[u8]) -> bool {
    match PasswordHash::new(phc) {
        Ok(parsed) => Argon2::default().verify_password(pw, &parsed).is_ok(),
        Err(_) => false,
    }
}

/// Domain-separation label mixed into `derive_config_key`'s input before it
/// ever reaches Argon2. This is a STRUCTURAL guarantee, not just a convention
/// of "pass a different salt": even if a caller accidentally reuses the login
/// PHC's own salt as `key_salt` (e.g. by extracting it from a stored
/// `admin.json`), the resulting key still cannot equal the login hash's
/// output, because the login hash never had this label prepended to its
/// input. Bump the version suffix if this label ever needs to change.
const CONFIG_KEY_DOMAIN: &[u8] = b"ej-config-key-v1\0";

/// Derive the 32-byte config encryption key. Domain-separated from the login
/// password hash via `CONFIG_KEY_DOMAIN` (see its doc comment) in addition to
/// deliberately using a different salt: leaking the password hash must not
/// reveal this key.
pub fn derive_config_key(pw: &[u8], key_salt: &[u8]) -> Result<[u8; 32], String> {
    let mut input = Vec::with_capacity(CONFIG_KEY_DOMAIN.len() + pw.len());
    input.extend_from_slice(CONFIG_KEY_DOMAIN);
    input.extend_from_slice(pw);
    let mut out = [0u8; 32];
    Argon2::default()
        .hash_password_into(&input, key_salt, &mut out)
        .map_err(|e| e.to_string())?;
    Ok(out)
}

/// A fresh 32-byte random session/admin token, base64url-encoded without padding.
pub fn new_token() -> String {
    let mut b = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut b);
    URL_SAFE_NO_PAD.encode(b)
}

/// A fresh 16-byte random salt, standard base64-encoded. Used e.g. as the
/// `key_salt` fed into `derive_config_key`.
pub fn new_salt_b64() -> String {
    let mut b = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut b);
    STANDARD.encode(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_hash_roundtrip_and_reject() {
        let phc = hash_password(b"admin").unwrap();
        assert!(verify_password(&phc, b"admin"));
        assert!(!verify_password(&phc, b"admin2"));
        assert!(!verify_password(&phc, b""));
    }

    #[test]
    fn config_key_is_deterministic_and_salt_dependent() {
        let s1 = b"salt-one-16bytes";
        let s2 = b"salt-two-16bytes";
        let k1 = derive_config_key(b"admin", s1).unwrap();
        let k1_again = derive_config_key(b"admin", s1).unwrap();
        let k2 = derive_config_key(b"admin", s2).unwrap();
        assert_eq!(k1, k1_again, "same password + same salt must yield the same key");
        assert_ne!(k1, k2, "changing the salt must change the key");
        assert_ne!(derive_config_key(b"other", s1).unwrap(), k1);
    }

    #[test]
    fn config_key_domain_separated_from_leaked_login_phc() {
        // Attack model: the stored login PHC (e.g. from a leaked admin.json)
        // is fully known to the attacker. They parse it, pull out its
        // embedded salt, and reuse that exact salt as `key_salt` -- betting
        // that domain separation is missing so the derived config key
        // collides with the login PHC's own hash bytes. This is the scenario
        // CONFIG_KEY_DOMAIN exists to defeat, and it must fail even though
        // password and salt are identical to what produced the PHC.
        let phc_str = hash_password(b"admin").unwrap();
        let phc = PasswordHash::new(&phc_str).unwrap();
        let mut salt_buf = [0u8; 64];
        let login_salt_raw = phc.salt.unwrap().decode_b64(&mut salt_buf).unwrap().to_vec();
        let login_hash_bytes = phc.hash.unwrap().as_bytes().to_vec();

        let key = derive_config_key(b"admin", &login_salt_raw).unwrap();
        assert_ne!(
            key.to_vec(),
            login_hash_bytes,
            "config key must not equal the login PHC's hash bytes, even when its own salt is reused as key_salt"
        );

        // A freshly generated key salt must also not coincide, byte-for-byte,
        // with the login PHC's own embedded salt.
        let key_salt_raw = STANDARD.decode(new_salt_b64()).unwrap();
        assert_ne!(
            key_salt_raw, login_salt_raw,
            "new_salt_b64 output must not collide with the login PHC's embedded salt"
        );
    }

    #[test]
    fn tokens_are_unique_and_urlsafe() {
        let a = new_token();
        let b = new_token();
        assert_ne!(a, b);
        assert!(a.len() >= 40);
        assert!(a.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }
}
