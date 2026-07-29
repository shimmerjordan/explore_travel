use crate::auth;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

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
/// - Missing file (`ErrorKind::NotFound`): this is a genuine first run. A
///   fresh default account (username "admin", password "admin", freshly
///   generated `key_salt_b64`, `is_default: true`) is created, written
///   atomically via `save`, and returned.
/// - File present but fails to parse as `AdminFile`: this is NOT treated as
///   "missing". Auto-resetting credentials here would turn any disk
///   corruption, truncated write, or bad backup restore into a silent full
///   credential reset -- and since `key_salt_b64` lives in the same file,
///   it would also permanently strand any config ciphertext encrypted under
///   the old key. Instead the corrupt file is quarantined (renamed, never
///   overwritten or deleted) and `load_or_init` returns `Err` so the service
///   refuses to start with clear, actionable log output. See
///   `default_flag_is_persisted_not_inferred` and the corrupt-file tests for
///   the behavior this guards.
/// - Any other I/O error (e.g. `PermissionDenied`) is propagated as `Err`
///   too -- it must never be folded into the "missing" case, or a
///   permissions problem would masquerade as a first run.
pub fn load_or_init(dir: &Path) -> Result<AdminFile, String> {
    let path = dir.join(FILE_NAME);
    match fs::read_to_string(&path) {
        Ok(text) => match serde_json::from_str::<AdminFile>(&text) {
            Ok(a) => Ok(a),
            Err(parse_err) => quarantine_corrupt(dir, &path, &parse_err.to_string()),
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

/// Move an unparsable `admin.json` out of the way (never delete, never
/// overwrite) so it survives for forensics, log a message that explains what
/// happened and how to recover, and return `Err` so startup fails loudly
/// instead of silently resetting credentials.
fn quarantine_corrupt(dir: &Path, path: &Path, parse_err: &str) -> Result<AdminFile, String> {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let quarantine_path = dir.join(format!("{FILE_NAME}.corrupt-{secs}"));

    let msg = match fs::rename(path, &quarantine_path) {
        Ok(()) => format!(
            "admin.json failed to parse ({parse_err}); refusing to auto-reset credentials. \
             The original file was preserved as {} for forensics. To reinitialize with a \
             fresh admin/admin account, delete that file (or admin.json) and restart.",
            quarantine_path.display()
        ),
        Err(rename_err) => format!(
            "admin.json failed to parse ({parse_err}); additionally failed to quarantine it \
             to {} ({rename_err}). Refusing to auto-reset credentials -- manual intervention \
             required.",
            quarantine_path.display()
        ),
    };
    eprintln!("ERROR: {msg}");
    Err(msg)
}

/// Path of the staging file `write_tmp` produces and `commit_tmp` consumes.
pub fn tmp_path(dir: &Path) -> PathBuf {
    dir.join(format!("{FILE_NAME}.tmp"))
}

/// Stage `a` into `dir/admin.json.tmp`, fully written and fsync'd, WITHOUT
/// touching the real `admin.json` yet.
///
/// This half exists separately from `commit_tmp` for callers that must fail
/// before the point of no return. `PUT /api/password` is the one that needs
/// it: it also has to re-encrypt `config.json` under the new key, and the two
/// files must agree or the config becomes permanently undecryptable. By
/// staging the new `admin.json` first, everything that can plausibly fail
/// (serialization, ENOSPC, EACCES, a `admin.json.tmp` that is somehow a
/// directory) happens while the on-disk state is still entirely untouched and
/// the request can be aborted with no side effects at all. See the step-order
/// comment on `main.rs`'s `handle_change_password`.
pub fn write_tmp(dir: &Path, a: &AdminFile) -> Result<(), String> {
    let text = serde_json::to_string_pretty(a).map_err(|e| e.to_string())?;
    crate::atomic_file::write_tmp(&tmp_path(dir), text.as_bytes())
}

/// Commit a previously staged `admin.json.tmp` over the real `admin.json`.
///
/// This is the point of no return, and it is deliberately reduced to a single
/// same-directory `rename`: the bytes are already on disk and fsync'd, so
/// there is nothing left here that can fail for a mundane reason like a full
/// disk. `rename` within one directory is atomic on POSIX filesystems, so a
/// reader concurrent with this call sees either the whole old file or the
/// whole new one.
pub fn commit_tmp(dir: &Path) -> Result<(), String> {
    crate::atomic_file::commit(&tmp_path(dir), &dir.join(FILE_NAME))
}

/// Write `admin.json` atomically: stage it, then commit it. Callers that have
/// nothing else to keep in sync with this file (first-run initialization, the
/// tests) want exactly this; `handle_change_password` uses the two halves
/// separately so it can interleave `config_store::reencrypt` between them.
pub fn save(dir: &Path, a: &AdminFile) -> Result<(), String> {
    write_tmp(dir, a)?;
    commit_tmp(dir)
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
        assert!(a.is_default, "first run must be flagged as still using the default password");
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

    /// Guards against a `load_or_init` that DERIVES `is_default` at read time
    /// (e.g. `verify_password(&a.password_phc, b"admin")`) instead of trusting
    /// the persisted field. We hand-craft an `admin.json` where `is_default`
    /// is `true` but the password is deliberately NOT "admin". A field-based
    /// implementation must read `is_default` back as `true` regardless of the
    /// password; an inferring implementation would compute `false` here
    /// (since the password doesn't verify against "admin") and fail this
    /// assertion.
    #[test]
    fn default_flag_is_persisted_not_inferred() {
        let d = tmpdir("persisted-flag");
        let phc = crate::auth::hash_password(b"not-the-default-password").unwrap();
        let manual = AdminFile {
            v: 1,
            username: "admin".into(),
            password_phc: phc,
            key_salt_b64: crate::auth::new_salt_b64(),
            is_default: true,
        };
        save(&d, &manual).unwrap();

        let reloaded = load_or_init(&d).unwrap();
        assert!(
            reloaded.is_default,
            "is_default must be read back from the stored field, not re-derived from the password"
        );
    }

    /// The staging half must be exactly that: after `write_tmp`, the real
    /// `admin.json` still holds the OLD content, and only `commit_tmp` makes
    /// the new one visible. This is the property `handle_change_password`
    /// relies on to be able to abort a password change, after staging, with
    /// zero on-disk side effects.
    #[test]
    fn write_tmp_stages_without_touching_the_live_file() {
        let d = tmpdir("stage");
        let original = load_or_init(&d).unwrap();

        let mut next = original.clone();
        next.password_phc = crate::auth::hash_password(b"staged-password").unwrap();
        next.is_default = false;
        write_tmp(&d, &next).unwrap();

        assert!(tmp_path(&d).exists(), "staging must produce admin.json.tmp");
        let live = load_or_init(&d).unwrap();
        assert_eq!(
            live.password_phc, original.password_phc,
            "write_tmp must not change the live admin.json"
        );

        commit_tmp(&d).unwrap();
        let committed = load_or_init(&d).unwrap();
        assert!(crate::auth::verify_password(&committed.password_phc, b"staged-password"));
        assert!(!tmp_path(&d).exists(), "commit must consume the tmp file");
    }

    /// A corrupt `admin.json` must never be silently reset to admin/admin.
    /// `load_or_init` should quarantine the unparsable file (move it aside,
    /// never delete or overwrite it) and return `Err` so startup fails
    /// loudly instead of handing out a fresh default credential.
    #[test]
    fn corrupt_file_is_quarantined_not_reset() {
        let d = tmpdir("corrupt");
        std::fs::write(d.join("admin.json"), b"{ this is not valid json").unwrap();

        let result = load_or_init(&d);
        assert!(
            result.is_err(),
            "a corrupt admin.json must cause load_or_init to return Err, not silently reset"
        );
        assert!(
            !d.join("admin.json").exists(),
            "the corrupt file must be moved aside, not left in place"
        );

        let quarantined: Vec<_> = std::fs::read_dir(&d)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with("admin.json.corrupt-"))
            .collect();
        assert_eq!(quarantined.len(), 1, "expected exactly one quarantined copy of the corrupt file");
    }
}
