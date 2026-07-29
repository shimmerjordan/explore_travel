use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// In-memory session table for the single admin account.
///
/// Maps an opaque session token to `(expires_at_unix_secs, config_key)`.
/// `config_key` is the 32-byte key derived by `auth::derive_config_key` at
/// login time; it never touches disk and is only ever handed back to the
/// caller that already holds a valid token for it.
pub struct Sessions {
    ttl_secs: u64,
    inner: Mutex<HashMap<String, (u64, [u8; 32])>>,
}

fn now_secs() -> u64 {
    // auth.rs deliberately has no `now_secs` helper (see task brief) — inlined
    // here per that note.
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Sessions {
    pub fn new(ttl_secs: u64) -> Self {
        Sessions {
            ttl_secs,
            inner: Mutex::new(HashMap::new()),
        }
    }

    /// Mint a fresh token bound to `key`, expiring `ttl_secs` from now.
    pub fn create(&self, key: [u8; 32]) -> String {
        let token = crate::auth::new_token();
        let expires_at = now_secs() + self.ttl_secs;
        self.inner.lock().unwrap().insert(token.clone(), (expires_at, key));
        token
    }

    /// Look up `token`. A hit that has not yet expired slides its expiry
    /// forward to `now + ttl_secs` (renew-on-use) before returning the key.
    /// A miss, or a hit whose `expires_at` is not in the future, returns
    /// `None` -- and in the expired case the stale entry is dropped so the
    /// table doesn't grow unbounded with dead sessions.
    pub fn get_key(&self, token: &str) -> Option<[u8; 32]> {
        let mut m = self.inner.lock().unwrap();
        let now = now_secs();
        match m.get(token).copied() {
            Some((expires_at, key)) if expires_at > now => {
                m.insert(token.to_string(), (now + self.ttl_secs, key));
                Some(key)
            }
            Some(_) => {
                m.remove(token);
                None
            }
            None => None,
        }
    }

    /// Drop a single session (used by logout). Unlike `revoke_all`, sibling
    /// sessions (e.g. a concurrently logged-in phone) are left untouched.
    pub fn remove(&self, token: &str) {
        self.inner.lock().unwrap().remove(token);
    }

    /// Drop every session -- used after a password change, since all
    /// previously issued config keys were derived from the now-stale password.
    pub fn revoke_all(&self) {
        self.inner.lock().unwrap().clear();
    }

    // Not called from production code yet (only from the tests below) --
    // part of the Sessions contract for a future admin "active sessions"
    // view. Silences the dead_code warning that would otherwise fire in a
    // non-test build.
    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.inner.lock().unwrap().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_then_get_returns_same_key() {
        let s = Sessions::new(60);
        let key = [7u8; 32];
        let t = s.create(key);
        assert_eq!(s.get_key(&t), Some(key));
    }

    #[test]
    fn unknown_token_is_rejected() {
        let s = Sessions::new(60);
        assert_eq!(s.get_key("nope"), None);
    }

    #[test]
    fn expired_token_is_rejected() {
        let s = Sessions::new(0); // expires immediately
        let t = s.create([1u8; 32]);
        std::thread::sleep(std::time::Duration::from_millis(1100));
        assert_eq!(s.get_key(&t), None);
    }

    #[test]
    fn revoke_all_drops_every_session() {
        let s = Sessions::new(60);
        let a = s.create([1u8; 32]);
        let b = s.create([2u8; 32]);
        assert_eq!(s.len(), 2);
        s.revoke_all();
        assert_eq!(s.get_key(&a), None);
        assert_eq!(s.get_key(&b), None);
        assert_eq!(s.len(), 0);
    }
}
