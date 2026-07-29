//! Durable, atomic single-file replacement: write a sibling `.tmp`, fsync it,
//! then `rename` it over the real path and fsync the directory.
//!
//! Both `admin_file` and `config_store` replace a whole small JSON file this
//! way, and the two files now have a cross-file consistency requirement: the
//! config ciphertext in `config.json` is only decryptable with the key derived
//! from the password whose hash lives in `admin.json`. A password change
//! rewrites both, so a crash that lands between the two renames -- or a
//! `rename` that returns success while the data is still only in the page
//! cache -- leaves the pair permanently mismatched (unreadable config). That
//! is why the durability steps live here, in one place, instead of being
//! re-derived per call site:
//!
//! - `write_tmp` fsyncs the tmp file's *contents* before anyone renames it.
//!   Without this, `rename` can be durable while the bytes it points at are
//!   not, and a post-crash `admin.json` can be a zero-length or truncated
//!   file -- which `load_or_init` correctly refuses to start on.
//! - `commit` fsyncs the *directory* after the rename, which is what actually
//!   makes the new name durable; fsyncing the file alone does not.
//!
//! `rename` within a single directory is atomic on POSIX filesystems, so a
//! reader concurrent with a commit always sees either the whole old file or
//! the whole new one, never a torn mix.

use std::fs;
use std::io::Write;
use std::path::Path;

/// Serialize `bytes` into `tmp_path`, fsync'd, so a later `commit` only has
/// to do the rename. Cleans the tmp file up on failure so a botched write
/// never leaves a stale candidate lying around for a later commit to pick up.
pub fn write_tmp(tmp_path: &Path, bytes: &[u8]) -> Result<(), String> {
    match write_and_sync(tmp_path, bytes) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = fs::remove_file(tmp_path); // best-effort; don't mask the write error
            Err(format!("write {}: {e}", tmp_path.display()))
        }
    }
}

fn write_and_sync(tmp_path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut f = fs::File::create(tmp_path)?;
    f.write_all(bytes)?;
    f.sync_all()
}

/// Rename `tmp_path` over `path`, then fsync the containing directory to make
/// that rename durable. Removes the tmp file if the rename fails, so a failed
/// commit leaves the directory exactly as it was.
pub fn commit(tmp_path: &Path, path: &Path) -> Result<(), String> {
    if let Err(e) = fs::rename(tmp_path, path) {
        let _ = fs::remove_file(tmp_path); // best-effort; don't mask the rename error
        return Err(format!("rename {}: {e}", tmp_path.display()));
    }
    if let Some(dir) = path.parent() {
        // Best-effort on purpose: the caller's data IS already visible under
        // the real name at this point, so a filesystem that refuses to fsync a
        // directory handle must not turn a successful write into a failed
        // request. Log it -- losing only the durability guarantee is worth
        // knowing about -- and carry on.
        if let Err(e) = fs::File::open(dir).and_then(|d| d.sync_all()) {
            eprintln!("WARN: fsync dir {} failed: {e}", dir.display());
        }
    }
    Ok(())
}
