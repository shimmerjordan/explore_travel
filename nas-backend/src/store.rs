use rusqlite::{params, Connection, OptionalExtension};
use std::time::{SystemTime, UNIX_EPOCH};

/// SQLite persistence. Holds ONLY accounts and opaque vault ciphertext — never
/// any plaintext user data.
pub struct Store {
    conn: Connection,
}

pub struct User {
    pub id: String,
    pub pw_hash: String, // Argon2id PHC of the authVerifier
    pub kdf_salt: String, // b64 client KDF salt, returned by GET /auth/salt
}

#[derive(Debug)]
pub enum StoreError {
    Conflict(i64), // current version
    Db(String),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StoreError::Conflict(v) => write!(f, "vault version conflict (server at {v})"),
            StoreError::Db(e) => write!(f, "db error: {e}"),
        }
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

impl Store {
    pub fn open(path: &str) -> Result<Store, String> {
        let conn = Connection::open(path).map_err(|e| e.to_string())?;
        // WAL + busy timeout for resilience. DB MUST be on a local volume
        // (not NFS/SMB) — SQLite locking is unreliable on network mounts.
        conn.busy_timeout(std::time::Duration::from_secs(5))
            .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| e.to_string())?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|e| e.to_string())?;
        let s = Store { conn };
        s.migrate()?;
        Ok(s)
    }

    fn migrate(&self) -> Result<(), String> {
        self.conn
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS users (
                    id         TEXT PRIMARY KEY,
                    email      TEXT UNIQUE NOT NULL,
                    pw_hash    TEXT NOT NULL,
                    kdf_salt   TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS vaults (
                    user_id    TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                    blob       BLOB NOT NULL,
                    version    INTEGER NOT NULL DEFAULT 1,
                    updated_at INTEGER NOT NULL
                 );",
            )
            .map_err(|e| e.to_string())
    }

    pub fn create_user(
        &self,
        id: &str,
        email: &str,
        pw_hash: &str,
        kdf_salt: &str,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO users (id, email, pw_hash, kdf_salt, created_at) VALUES (?1,?2,?3,?4,?5)",
                params![id, email, pw_hash, kdf_salt, now()],
            )
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    pub fn user_by_email(&self, email: &str) -> Result<Option<User>, String> {
        self.conn
            .query_row(
                "SELECT id, pw_hash, kdf_salt FROM users WHERE email = ?1",
                params![email],
                |row| {
                    Ok(User {
                        id: row.get(0)?,
                        pw_hash: row.get(1)?,
                        kdf_salt: row.get(2)?,
                    })
                },
            )
            .optional()
            .map_err(|e| e.to_string())
    }

    pub fn vault_version(&self, user_id: &str) -> Result<i64, String> {
        let v: Option<i64> = self
            .conn
            .query_row(
                "SELECT version FROM vaults WHERE user_id = ?1",
                params![user_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        Ok(v.unwrap_or(0))
    }

    /// Returns (blob, version) or None if the user has no vault yet.
    pub fn get_vault(&self, user_id: &str) -> Result<Option<(Vec<u8>, i64)>, String> {
        self.conn
            .query_row(
                "SELECT blob, version FROM vaults WHERE user_id = ?1",
                params![user_id],
                |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()
            .map_err(|e| e.to_string())
    }

    /// Compare-and-swap on version. `if_match` is the version the client last
    /// saw (0 = expects none). Returns the new version or StoreError::Conflict.
    pub fn put_vault(&self, user_id: &str, blob: &[u8], if_match: i64) -> Result<i64, StoreError> {
        let cur: Option<i64> = self
            .conn
            .query_row(
                "SELECT version FROM vaults WHERE user_id = ?1",
                params![user_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| StoreError::Db(e.to_string()))?;

        match cur {
            Some(v) => {
                if v != if_match {
                    return Err(StoreError::Conflict(v));
                }
                let next = v + 1;
                self.conn
                    .execute(
                        "UPDATE vaults SET blob = ?1, version = ?2, updated_at = ?3 WHERE user_id = ?4",
                        params![blob, next, now(), user_id],
                    )
                    .map_err(|e| StoreError::Db(e.to_string()))?;
                Ok(next)
            }
            None => {
                if if_match != 0 {
                    return Err(StoreError::Conflict(0));
                }
                self.conn
                    .execute(
                        "INSERT INTO vaults (user_id, blob, version, updated_at) VALUES (?1,?2,1,?3)",
                        params![user_id, blob, now()],
                    )
                    .map_err(|e| StoreError::Db(e.to_string()))?;
                Ok(1)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vault_cas_create_update_and_conflict() {
        let s = Store::open(":memory:").unwrap();
        s.create_user("u1", "a@b.c", "phc", "salt-b64").unwrap();
        assert_eq!(s.vault_version("u1").unwrap(), 0);

        // First write expects no existing vault (if_match 0) → v1.
        let v1 = s.put_vault("u1", b"blob-1", 0).unwrap();
        assert_eq!(v1, 1);

        // Stale base (0) now conflicts.
        match s.put_vault("u1", b"blob-x", 0) {
            Err(StoreError::Conflict(cur)) => assert_eq!(cur, 1),
            other => panic!("expected conflict, got {other:?}"),
        }

        // Correct base advances to v2 and round-trips the bytes.
        let v2 = s.put_vault("u1", b"blob-2", 1).unwrap();
        assert_eq!(v2, 2);
        let (blob, ver) = s.get_vault("u1").unwrap().unwrap();
        assert_eq!(blob, b"blob-2");
        assert_eq!(ver, 2);
    }

    #[test]
    fn user_lookup_and_unique_email() {
        let s = Store::open(":memory:").unwrap();
        s.create_user("u1", "a@b.c", "phc", "salt").unwrap();
        assert!(s.user_by_email("a@b.c").unwrap().is_some());
        assert!(s.user_by_email("nope@b.c").unwrap().is_none());
        assert!(s.create_user("u2", "a@b.c", "p", "s").is_err()); // UNIQUE
    }
}
