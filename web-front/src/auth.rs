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

/// Derive the 32-byte config encryption key. Uses a salt that is DELIBERATELY
/// different from the login hash's salt (domain separation): leaking the
/// password hash must not reveal this key.
pub fn derive_config_key(pw: &[u8], key_salt: &[u8]) -> Result<[u8; 32], String> {
    let mut out = [0u8; 32];
    Argon2::default()
        .hash_password_into(pw, key_salt, &mut out)
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
        assert_eq!(k1, k1_again, "同密码同 salt 必须得到同密钥");
        assert_ne!(k1, k2, "换 salt 必须换密钥");
        assert_ne!(derive_config_key(b"other", s1).unwrap(), k1);
    }

    #[test]
    fn password_hash_does_not_leak_config_key() {
        // 域分离：PHC 串里不得出现配置密钥的任何字节片段
        let salt = b"salt-one-16bytes";
        let key = derive_config_key(b"admin", salt).unwrap();
        let phc = hash_password(b"admin").unwrap();
        let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
        assert!(!phc.contains(&hex[..16]));
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
