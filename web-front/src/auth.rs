use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

/// Argon2id PHC over the client's `authVerifier` (a password-equivalent — the
/// server never sees the password). A DB leak then still requires a brute force.
pub fn hash_verifier(verifier: &[u8]) -> Result<String, String> {
    let mut salt_bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut salt_bytes);
    let salt = SaltString::encode_b64(&salt_bytes).map_err(|e| e.to_string())?;
    Argon2::default()
        .hash_password(verifier, &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

pub fn verify_verifier(verifier: &[u8], phc: &str) -> bool {
    match PasswordHash::new(phc) {
        Ok(parsed) => Argon2::default().verify_password(verifier, &parsed).is_ok(),
        Err(_) => false,
    }
}

#[derive(Serialize, Deserialize)]
pub struct Claims {
    pub sub: String,
    pub iat: usize,
    pub exp: usize,
    pub v: u8,
}

fn now_secs() -> usize {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as usize)
        .unwrap_or(0)
}

pub fn mint_jwt(secret: &str, sub: &str, ttl_secs: u64) -> Result<String, String> {
    let iat = now_secs();
    let claims = Claims {
        sub: sub.to_string(),
        iat,
        exp: iat + ttl_secs as usize,
        v: 1,
    };
    encode(
        &Header::new(Algorithm::HS256),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .map_err(|e| e.to_string())
}

/// Parse + validate. Algorithm is pinned to HS256 (defeats alg-confusion:
/// "none"/RS256 tokens are rejected); `exp` is validated by the library.
pub fn parse_jwt(secret: &str, token: &str) -> Option<Claims> {
    let validation = Validation::new(Algorithm::HS256);
    decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &validation,
    )
    .ok()
    .map(|d| d.claims)
}

/// 16 random bytes, base64. Used for user ids and the deterministic pseudo-salt
/// path lives elsewhere.
pub fn new_id() -> String {
    let mut b = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut b);
    STANDARD.encode(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn argon2_roundtrip_and_reject() {
        let phc = hash_verifier(b"verifier-bytes-0123456789").unwrap();
        assert!(verify_verifier(b"verifier-bytes-0123456789", &phc));
        assert!(!verify_verifier(b"WRONG", &phc));
    }

    #[test]
    fn jwt_roundtrip_and_wrong_secret_rejected() {
        let secret = "01234567890123456789012345678901"; // 32 bytes
        let tok = mint_jwt(secret, "user-123", 3600).unwrap();
        let claims = parse_jwt(secret, &tok).expect("valid token must parse");
        assert_eq!(claims.sub, "user-123");
        assert_eq!(claims.v, 1);
        // A different secret must not verify (HMAC mismatch).
        assert!(parse_jwt("a-totally-different-secret-32bytes!", &tok).is_none());
        // Garbage is rejected.
        assert!(parse_jwt(secret, "not.a.jwt").is_none());
    }
}
