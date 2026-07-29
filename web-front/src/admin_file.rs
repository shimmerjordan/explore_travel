use crate::auth;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

const FILE_NAME: &str = "admin.json";

/// Persisted state for the single admin account.
///
/// `key_salt_b64` is the salt used ONLY to derive the config-encryption key
/// via `auth::derive_config_key`. It is independently generated (via
/// `auth::new_salt_b64`) and stored separately from `password_phc` -- it must
/// never be pulled out of the PHC string's own embedded salt. Reusing that
/// salt here would defeat the domain separation `auth::derive_config_key`
/// relies on (see `auth::CONFIG_KEY_DOMAIN`'s doc comment and the
/// `config_key_domain_separated_from_leaked_login_phc` test in `auth.rs`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AdminFile {
    pub v: u32,
    pub username: String,
    pub password_phc: String,
    pub key_salt_b64: String,
    /// True while the password is still the factory default ("admin"/"admin").
    /// This is a persisted field, not something re-derived by comparing the
    /// current hash against "admin" on every read: it must survive a reload
    /// and only clear once the operator explicitly saves a new password
    /// (see `changing_password_clears_default_flag`).
    pub is_default: bool,
}

impl AdminFile {
    /// Decode `key_salt_b64` (standard base64, not URL-safe) into raw bytes,
    /// ready to hand to `auth::derive_config_key`.
    pub fn key_salt(&self) -> Result<Vec<u8>, String> {
        STANDARD.decode(&self.key_salt_b64).map_err(|e| e.to_string())
    }
}

/// Load `dir/admin.json`.
///
/// If the file is missing, OR present but fails to parse as `AdminFile`, a
/// fresh default account (username "admin", password "admin", freshly
/// generated `key_salt_b64`, `is_default: true`) is created, written
/// atomically via `save`, and returned.
///
/// Trade-off (deliberate, see task report): treating a corrupt file the same
/// as a missing one means a damaged `admin.json` silently resets the
/// password to the factory default rather than making the service refuse to
/// start. That is a security trade-off (a corrupted-on-disk file becomes a
/// free password reset for anyone with filesystem access) accepted in favor
/// of availability (a bit-rotted file must not permanently lock the operator
/// out). This mirrors the brief's explicit wording ("解析失败或不存在则造一份默认的").
pub fn load_or_init(dir: &Path) -> Result<AdminFile, String> {
    let path = dir.join(FILE_NAME);
    match fs::read_to_string(&path) {
        Ok(text) => match serde_json::from_str::<AdminFile>(&text) {
            Ok(a) => Ok(a),
            Err(_) => init_default(dir),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => init_default(dir),
        Err(e) => Err(format!("read {}: {e}", path.display())),
    }
}

fn init_default(dir: &Path) -> Result<AdminFile, String> {
    let a = AdminFile {
        v: 1,
        username: "admin".into(),
        password_phc: auth::hash_password(b"admin")?,
        key_salt_b64: auth::new_salt_b64(),
        is_default: true,
    };
    save(dir, &a)?;
    Ok(a)
}

/// Write `admin.json` atomically: serialize to a sibling `admin.json.tmp`
/// and `rename` it over the real path. `rename` within the same directory is
/// atomic on POSIX filesystems, so a process killed mid-write can never
/// leave a half-written `admin.json` behind -- readers see either the old
/// file or the new one, never a torn one.
pub fn save(dir: &Path, a: &AdminFile) -> Result<(), String> {
    let path = dir.join(FILE_NAME);
    let tmp_path = dir.join(format!("{FILE_NAME}.tmp"));
    let text = serde_json::to_string_pretty(a).map_err(|e| e.to_string())?;
    fs::write(&tmp_path, text).map_err(|e| format!("write {}: {e}", tmp_path.display()))?;
    fs::rename(&tmp_path, &path).map_err(|e| format!("rename {}: {e}", tmp_path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        let d = env::temp_dir().join(format!("wf-admin-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn first_run_creates_default_admin() {
        let d = tmpdir("init");
        let a = load_or_init(&d).unwrap();
        assert_eq!(a.username, "admin");
        assert!(a.is_default, "首次初始化必须标记为默认密码");
        assert!(crate::auth::verify_password(&a.password_phc, b"admin"));
        assert!(d.join("admin.json").exists());
    }

    #[test]
    fn second_run_reads_back_without_resetting() {
        let d = tmpdir("reload");
        let first = load_or_init(&d).unwrap();
        let second = load_or_init(&d).unwrap();
        assert_eq!(first.password_phc, second.password_phc);
        assert_eq!(first.key_salt_b64, second.key_salt_b64);
    }

    #[test]
    fn changing_password_clears_default_flag() {
        let d = tmpdir("chpw");
        let mut a = load_or_init(&d).unwrap();
        a.password_phc = crate::auth::hash_password(b"s3cret").unwrap();
        a.is_default = false;
        save(&d, &a).unwrap();
        let reloaded = load_or_init(&d).unwrap();
        assert!(!reloaded.is_default);
        assert!(crate::auth::verify_password(&reloaded.password_phc, b"s3cret"));
        assert!(!crate::auth::verify_password(&reloaded.password_phc, b"admin"));
    }

    #[test]
    fn key_salt_decodes_to_16_bytes() {
        let d = tmpdir("salt");
        let a = load_or_init(&d).unwrap();
        assert_eq!(a.key_salt().unwrap().len(), 16);
    }
}
