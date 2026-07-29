//! Static hosting for the Flutter web build, with an SPA fallback to
//! `index.html` for any path that doesn't resolve to a real file.
//!
//! This module serves whatever directory the operator points `EJ_WEB_ROOT`
//! at, so a single missed traversal case here is a filesystem read
//! primitive for anyone who can reach the port. Two independent checks
//! apply, and both have to hold:
//!
//!   1. The decoded URL path is split into `/`-segments, and `.`/`..`
//!      segments are dropped outright -- one segment at a time, never by
//!      string replacement (a single-pass `str::replace("../", "")` has a
//!      well-known bypass: `"..././".replace("../", "")` leaves `".."`
//!      behind). Decoding happens *before* splitting, so an encoded
//!      traversal (`..%2f`) is caught too, not smuggled past the filter.
//!   2. Every segment is appended with `PathBuf::push` (never string
//!      concatenation, which can blur a sibling directory into looking like
//!      a child of `root` -- see the tests), the candidate is then *opened*,
//!      and containment is decided against the inode that was actually
//!      opened rather than against the path that was requested (see
//!      `open_within`). That second check is what catches a symlink under
//!      `root` that points outside of it: dropping `..` segments doesn't
//!      help there, because the escape happens during symlink resolution,
//!      not in the URL text.
//!
//! Check 2 deliberately works on an open file descriptor, not on a path.
//! Canonicalizing a path and then reading that path is two separate lookups
//! with a window in between, and the window is exploitable: an attacker who
//! can rename inside `root` (the same capability the symlink attack needs)
//! can flip a name between a regular file and a symlink-to-outside, so a
//! path that passed the check is not the file that gets read. Holding the
//! descriptor collapses check and read onto one inode -- the file cannot be
//! swapped after it has been opened, only unlinked -- which is why the
//! containment comparison uses `/proc/self/fd/<n>` and the bytes are read
//! from the same `File` that was checked. If procfs is unavailable the
//! module fails closed (serves nothing) rather than falling back to the
//! raceable path comparison; see `open_within`.
//!
//! The tradeoff of check 2: a *legitimate* symlink under `root` that
//! happens to point outside of it is refused right along with a malicious
//! one -- this module has no way to tell the two apart, and the deliberate
//! choice here is to refuse rather than trust the symlink's target.

use std::fs::{File, Metadata};
use std::io::Read as _;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::UNIX_EPOCH;

/// Result of resolving one request against the web root.
pub enum Served {
    File {
        bytes: Vec<u8>,
        mime: &'static str,
        etag: String,
    },
    /// The caller's `If-None-Match` already matches what's on disk, so the
    /// bytes are not read and not sent. See `etag_for`.
    NotModified { etag: String, mime: &'static str },
    NotConfigured,
    NotFound,
}

/// Shown at `/` (and other paths that expect a page, see `main.rs`) when
/// `EJ_WEB_ROOT` is missing or empty, so an operator who starts the container
/// without a web build gets an explanation instead of a bare 404.
pub const SETUP_HTML: &str = r#"<!doctype html>
<html>
<head><meta charset="utf-8"><title>explore_journal</title></head>
<body>
<h1>No web build is mounted</h1>
<p>This image's <code>/web</code> directory is empty, so there is nothing to
serve here yet. Either:</p>
<ul>
<li>mount a directory containing a Flutter web build at the path
<code>EJ_WEB_ROOT</code> points to, or</li>
<li>use an image tag that already bundles the web build.</li>
</ul>
</body>
</html>
"#;

/// Serve `url_path` from `root`. `url_path` is expected to already have any
/// query string stripped by the caller (see `main.rs`'s `serve`), but this
/// function strips one defensively too -- it's `pub` and must not assume
/// every caller got that right.
///
/// `if_none_match` is the request's `If-None-Match` header, if any: when it
/// matches the current validator the result is `NotModified` and the file is
/// never read, which is the whole point of having a validator (the SPA shell
/// is served with `no-cache`, i.e. revalidated on *every* navigation).
pub fn serve(root: &Path, url_path: &str, if_none_match: Option<&str>) -> Served {
    let canonical_root = match root.canonicalize() {
        Ok(p) => p,
        Err(_) => return Served::NotConfigured,
    };
    match is_empty_or_placeholder_only(&canonical_root) {
        Ok(true) => return Served::NotConfigured,
        Ok(false) => {}
        // A root that exists but can't be listed (wrong owner, mode 000, a
        // bind mount that didn't come back after a reboot) is NOT "empty":
        // reporting it as `NotConfigured` would show the operator a page
        // saying the directory has no web build in it, sending them off to
        // fix a mount that is already mounted. The real errno goes to the
        // log only, per this crate's convention of never putting filesystem
        // detail in a response body.
        Err(e) => {
            eprintln!(
                "ERROR: static: cannot list web root {}: {e}",
                canonical_root.display()
            );
            return Served::NotFound;
        }
    }

    let candidate = resolve(&canonical_root, url_path);
    match serve_file(&canonical_root, &candidate, if_none_match) {
        Some(served) => served,
        // Either nothing matched, or it matched a directory, or containment
        // refused it -- all of them are "this path had no asset", so they all
        // fall back to the SPA shell. The shell goes through the exact same
        // containment check: `root/index.html` being a symlink out of the
        // root is no more trustworthy than any other escape.
        None => serve_file(&canonical_root, &canonical_root.join("index.html"), if_none_match)
            .unwrap_or(Served::NotFound),
    }
}

/// Open `path`, confirm it is contained and is a regular file, and either
/// report `NotModified` or read it. `None` means "treat this as a miss".
fn serve_file(canonical_root: &Path, path: &Path, if_none_match: Option<&str>) -> Option<Served> {
    let mut f = open_within(canonical_root, path)?;
    // Stat the *descriptor*, not the path, for the same reason containment is
    // checked on the descriptor: this is the file that will be read.
    let meta = f.metadata().ok()?;
    // A directory (or a fifo/socket someone dropped in the web root) is never
    // read directly -- reading it would surface an I/O error for what is
    // really just a miss.
    if !meta.is_file() {
        return None;
    }

    // MIME comes from the *requested* name, not from the opened inode's name:
    // a symlink `foo.js -> bar.txt` inside the root is legitimate, and the
    // client asked for a script.
    let mime = mime_for(path.file_name().and_then(|n| n.to_str()).unwrap_or(""));
    let etag = etag_for(&meta);
    if if_none_match.is_some_and(|h| etag_matches(h, &etag)) {
        return Some(Served::NotModified { etag, mime });
    }

    let mut bytes = Vec::with_capacity(meta.len() as usize);
    f.read_to_end(&mut bytes).ok()?;
    Some(Served::File { bytes, mime, etag })
}

/// Set once the procfs lookup in `open_within` has failed, so a platform
/// without `/proc/self/fd` logs the explanation a single time instead of once
/// per request.
static PROCFS_WARNED: AtomicBool = AtomicBool::new(false);

/// Open `path` and return the handle only if the inode that was actually
/// opened lies inside `canonical_root`.
///
/// The containment comparison is done on `/proc/self/fd/<n>`, the kernel's
/// name for the open descriptor, rather than on `path` or on
/// `path.canonicalize()`. Checking a path and then reading it are two
/// lookups, and between them the name can be re-pointed at a symlink
/// leading out of the root; the descriptor cannot be re-pointed once opened,
/// so checking it and reading it is one atomic decision about one inode.
///
/// `strip_prefix` compares path *components*, not characters -- `/x/webother`
/// is not inside `/x/web` even though one string is a prefix of the other
/// (see the sibling-directory tests).
///
/// If the procfs lookup fails, this refuses to serve rather than falling
/// back to comparing paths: the fallback is exactly the raceable check this
/// exists to remove, and a static file server that serves nothing is a much
/// smaller problem than one that can be raced into reading `/data`.
fn open_within(canonical_root: &Path, path: &Path) -> Option<File> {
    let f = File::open(path).ok()?;
    let opened = match std::fs::read_link(format!("/proc/self/fd/{}", f.as_raw_fd())) {
        Ok(p) => p,
        Err(e) => {
            if !PROCFS_WARNED.swap(true, Ordering::Relaxed) {
                eprintln!(
                    "ERROR: static: cannot resolve /proc/self/fd ({e}); refusing to serve \
                     any static file. Containment against the web root is checked on the \
                     open descriptor and there is no non-raceable substitute for it, so \
                     this fails closed. Mount procfs into the container, or put the web \
                     build behind a separate static file server."
                );
            }
            return None;
        }
    };
    if opened.strip_prefix(canonical_root).is_ok() {
        Some(f)
    } else {
        None
    }
}

/// Cache validator for a served file: length plus mtime, which together
/// change on every real redeploy of a Flutter build.
///
/// This exists because `Cache-Control` alone can't avoid a transfer.
/// `no-cache` means "cacheable, but revalidate every time", and revalidation
/// with no validator to send degrades into re-downloading the whole body; the
/// same applies to `max-age` assets once the hour is up. `main.dart.js` is
/// several MB and this server does no compression, so a validator is the
/// difference between a 304 and a multi-megabyte retransfer.
///
/// The mtime's sub-second part is included on purpose: two consecutive
/// deploys can land inside the same wall-clock second, and a validator that
/// can't tell them apart would serve the previous build's bytes.
fn etag_for(meta: &Metadata) -> String {
    let (secs, nanos) = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| (d.as_secs(), d.subsec_nanos()))
        .unwrap_or((0, 0));
    format!("\"{:x}-{:x}.{:x}\"", meta.len(), secs, nanos)
}

/// Whether an `If-None-Match` header matches `etag`. The header is a
/// comma-separated list, `*` matches any existing representation, and a
/// `W/` prefix marks a weak comparison -- which is the only kind defined for
/// `If-None-Match` anyway, so the prefix is accepted and ignored.
fn etag_matches(if_none_match: &str, etag: &str) -> bool {
    if_none_match.split(',').any(|candidate| {
        let candidate = candidate.trim();
        candidate == "*"
            || candidate == etag
            || candidate.strip_prefix("W/").is_some_and(|inner| inner == etag)
    })
}

/// Map `url_path` onto a candidate path under `canonical_root` -- see the
/// module doc for why segments are filtered rather than string-replaced. The
/// result is only a *candidate*: whether it is contained is decided by
/// `open_within` on the opened descriptor, not here.
fn resolve(canonical_root: &Path, url_path: &str) -> PathBuf {
    let path_only = url_path.split('?').next().unwrap_or("");
    let decoded = percent_decode(path_only);

    let mut joined = canonical_root.to_path_buf();
    for seg in decoded.split('/') {
        match seg {
            "" | "." | ".." => continue, // dropped, never resolved against a parent
            s => joined.push(s),
        }
    }
    joined
}

/// A directory that holds nothing but the git placeholder counts as "not
/// configured" -- the same as a missing directory -- rather than serving an
/// empty tree with no `index.html`. An unreadable directory is neither, and
/// the error is propagated so the caller can say so; see `serve`.
fn is_empty_or_placeholder_only(dir: &Path) -> std::io::Result<bool> {
    let entries = std::fs::read_dir(dir)?;
    Ok(entries
        .filter_map(|e| e.ok())
        .all(|e| e.file_name() == ".gitkeep"))
}

/// Percent-decode a URL path. Unlike query-string decoding, `+` is left
/// alone here -- it's a literal character in a path segment, not a space
/// encoding (that convention is specific to `application/x-www-form-urlencoded`
/// query strings and bodies).
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// MIME table covering what a Flutter web build actually produces. Unknown
/// extensions fall back to `application/octet-stream` rather than guessing.
pub fn mime_for(name: &str) -> &'static str {
    let ext = match name.rsplit_once('.') {
        Some((_, ext)) => ext,
        None => "",
    };
    match ext.to_ascii_lowercase().as_str() {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        // `charset=utf-8` matches what the JSON API routes send. JSON is
        // UTF-8 by definition, so the parameter is redundant per RFC 8259 --
        // but having two different Content-Types for the same media type in
        // one server invites someone to "fix" the mismatch by dropping the
        // charset from the API instead, where it is not redundant to the
        // browsers that still sniff.
        "json" | "map" => "application/json; charset=utf-8",
        "wasm" => "application/wasm",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "bin" => "application/octet-stream",
        "txt" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Most of these tests predate conditional GET and have nothing to say
    /// about it, so they call through this two-argument shim rather than
    /// repeating `None` at every call site. The cases that DO care about
    /// `If-None-Match` call `super::serve` directly.
    fn serve(root: &Path, url_path: &str) -> Served {
        super::serve(root, url_path, None)
    }

    fn tmproot(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("wf-web-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn mime_table_covers_flutter_web_assets() {
        assert_eq!(mime_for("index.html"), "text/html; charset=utf-8");
        assert_eq!(mime_for("main.dart.js"), "text/javascript; charset=utf-8");
        assert_eq!(mime_for("sqlite3.wasm"), "application/wasm");
        assert_eq!(mime_for("style.css"), "text/css; charset=utf-8");
        assert_eq!(mime_for("manifest.json"), "application/json; charset=utf-8");
        assert_eq!(mime_for("main.dart.js.map"), "application/json; charset=utf-8");
        assert_eq!(mime_for("icon.png"), "image/png");
        assert_eq!(mime_for("f.woff2"), "font/woff2");
        assert_eq!(mime_for("unknown.xyz"), "application/octet-stream");
    }

    #[test]
    fn empty_or_missing_root_yields_not_configured() {
        let d = tmproot("empty");
        assert!(matches!(serve(&d, "/"), Served::NotConfigured));
        assert!(matches!(serve(&d.join("nope"), "/"), Served::NotConfigured));
    }

    /// A root that exists but cannot be listed is a broken mount or a
    /// permissions mistake, NOT an empty directory -- reporting
    /// `NotConfigured` would show the operator a setup page telling them the
    /// directory is empty while the file they need is sitting right there,
    /// unreadable.
    #[test]
    fn unreadable_root_is_not_reported_as_unconfigured() {
        use std::os::unix::fs::PermissionsExt;
        let d = tmproot("unreadable");
        std::fs::write(d.join("index.html"), "hi").unwrap();
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o000)).unwrap();

        // Running as root defeats the whole premise (mode 000 is still
        // readable), so verify the setup actually denies access first rather
        // than passing vacuously.
        let denied = std::fs::read_dir(&d).is_err();
        let got = serve(&d, "/");
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o755)).unwrap();

        if !denied {
            eprintln!("SKIP unreadable_root_is_not_reported_as_unconfigured: this user can \
                       still list a mode-000 directory (running as root?)");
            return;
        }
        assert!(
            matches!(got, Served::NotFound),
            "an unreadable root must not be reported as an empty one"
        );
    }

    #[test]
    fn serves_index_at_root() {
        let d = tmproot("index");
        std::fs::write(d.join("index.html"), "<h1>hi</h1>").unwrap();
        match serve(&d, "/") {
            Served::File { bytes, mime, .. } => {
                assert_eq!(bytes, b"<h1>hi</h1>");
                assert_eq!(mime, "text/html; charset=utf-8");
            }
            _ => panic!("根路径应返回 index.html"),
        }
    }

    #[test]
    fn unknown_path_falls_back_to_index() {
        let d = tmproot("fallback");
        std::fs::write(d.join("index.html"), "<h1>spa</h1>").unwrap();
        match serve(&d, "/deep/link") {
            Served::File { bytes, .. } => assert_eq!(bytes, b"<h1>spa</h1>"),
            _ => panic!("未命中路径应回退 index.html"),
        }
    }

    #[test]
    fn serves_nested_asset() {
        let d = tmproot("nested");
        std::fs::create_dir_all(d.join("assets")).unwrap();
        std::fs::write(d.join("assets/a.png"), [0x89, 0x50]).unwrap();
        match serve(&d, "/assets/a.png") {
            Served::File { mime, .. } => assert_eq!(mime, "image/png"),
            _ => panic!("嵌套资源应能取到"),
        }
    }

    /// The plan's own version of this test has a `_ => {}` arm that treats
    /// "returned NotFound" and "returned some other file" as equally
    /// passing -- it only proves the secret didn't leak, not that the
    /// implementation actually filters by path segment. The added
    /// `assert_eq!(bytes, b"ok")` below closes that gap: a traversal attempt
    /// against a *configured* root may only ever produce the SPA fallback,
    /// nothing else.
    #[test]
    fn path_traversal_is_refused() {
        let d = tmproot("traverse");
        std::fs::write(d.join("index.html"), "ok").unwrap();
        let secret = d.parent().unwrap().join("wf-secret.txt");
        std::fs::write(&secret, "TOPSECRET").unwrap();
        for attack in ["/../wf-secret.txt", "/..%2fwf-secret.txt", "/a/../../wf-secret.txt"] {
            match serve(&d, attack) {
                Served::File { bytes, .. } => {
                    assert_ne!(bytes, b"TOPSECRET", "路径穿越必须被拒: {attack}");
                    assert_eq!(bytes, b"ok", "穿越路径只能落到 index.html 回退: {attack}");
                }
                Served::NotFound => {}
                Served::NotModified { .. } => panic!("no validator was sent: {attack}"),
                Served::NotConfigured => panic!("root 已配置，不应是 NotConfigured: {attack}"),
            }
        }
        let _ = std::fs::remove_file(&secret);
    }

    /// `root`'s basename plus "other" is a *sibling* directory, not a child
    /// of it -- e.g. root=`/tmp/x/web`, sibling=`/tmp/x/webother`. A
    /// containment check built by turning both paths into strings and
    /// calling `starts_with` on them would wrongly treat the sibling as
    /// "inside" root, since the two strings share a prefix even though the
    /// paths themselves don't share a parent/child relationship. Appending
    /// path segments one at a time with `PathBuf::push` (rather than
    /// `format!("{root}{url_path}")`) can't produce this confusion: `push`
    /// always inserts its own separator, so there is no URL path that joins
    /// onto `root` and lands on `root`'s sibling.
    ///
    /// This test therefore only falsifies the *join*, not the containment
    /// check -- `symlink_into_prefix_sharing_sibling_is_refused` below is the
    /// one that falsifies the containment check.
    #[test]
    fn sibling_directory_sharing_a_path_prefix_is_not_reachable() {
        let root = tmproot("prefix");
        std::fs::write(root.join("index.html"), "root-index").unwrap();

        let sibling_name = format!("{}other", root.file_name().unwrap().to_str().unwrap());
        let sibling = root.parent().unwrap().join(&sibling_name);
        let _ = std::fs::remove_dir_all(&sibling);
        std::fs::create_dir_all(&sibling).unwrap();
        std::fs::write(sibling.join("secret.txt"), "TOPSECRET").unwrap();

        // Deliberately no leading slash: this is the exact input shape a
        // naive `format!("{}{}", root.display(), url_path)` join would
        // concatenate directly onto root's string form with no separator in
        // between, landing on the sibling.
        match serve(&root, "other/secret.txt") {
            Served::File { bytes, .. } => {
                assert_ne!(bytes, b"TOPSECRET", "must not reach the sibling directory");
                // Positive assertion, mirroring `path_traversal_is_refused`:
                // without it, NotFound/NotConfigured/some third file all
                // count as a pass and the test proves almost nothing.
                assert_eq!(bytes, b"root-index", "must land on the SPA shell, nothing else");
            }
            other => panic!(
                "expected the SPA shell, got {}",
                match other {
                    Served::NotFound => "NotFound",
                    Served::NotConfigured => "NotConfigured",
                    Served::NotModified { .. } => "NotModified",
                    Served::File { .. } => unreachable!(),
                }
            ),
        }

        let _ = std::fs::remove_dir_all(&sibling);
    }

    /// The case that actually falsifies *how* containment is judged.
    ///
    /// `sibling_directory_sharing_a_path_prefix_is_not_reachable` can't:
    /// there is no URL that makes the join land on the sibling, so the
    /// containment check never even sees an out-of-root path. And
    /// `symlink_escaping_root_is_refused` can't either: its target
    /// (`/tmp/wf-outside-*.txt`) doesn't share a string prefix with the root,
    /// so a `to_string_lossy().starts_with()` check rejects it correctly by
    /// accident.
    ///
    /// Both weaknesses are needed at once to expose a string-prefix check: a
    /// symlink *inside* the root pointing at a sibling directory whose name
    /// merely starts with the root's name. Then the resolved target is
    /// genuinely outside the root while its string form still starts with the
    /// root's string form -- `strip_prefix` refuses it, `starts_with` lets it
    /// through.
    #[test]
    fn symlink_into_prefix_sharing_sibling_is_refused() {
        let root = tmproot("pfxlink");
        std::fs::write(root.join("index.html"), "root-index").unwrap();

        let sibling_name = format!("{}other", root.file_name().unwrap().to_str().unwrap());
        let sibling = root.parent().unwrap().join(&sibling_name);
        let _ = std::fs::remove_dir_all(&sibling);
        std::fs::create_dir_all(&sibling).unwrap();
        std::fs::write(sibling.join("secret.txt"), "TOPSECRET-SIBLING").unwrap();

        let _ = std::fs::remove_file(root.join("link"));
        std::os::unix::fs::symlink(&sibling, root.join("link")).unwrap();

        // Guard against the test passing because the setup silently failed.
        assert!(
            sibling.to_string_lossy().starts_with(&*root.to_string_lossy()),
            "test premise: the sibling's path must share a string prefix with the root"
        );

        let got = serve(&root, "/link/secret.txt");
        let _ = std::fs::remove_dir_all(&sibling);

        match got {
            Served::File { bytes, .. } => {
                assert_ne!(
                    bytes, b"TOPSECRET-SIBLING",
                    "containment must be judged on path components, not on string prefixes"
                );
                assert_eq!(bytes, b"root-index", "must land on the SPA shell, nothing else");
            }
            Served::NotFound => {}
            Served::NotConfigured => panic!("root is populated, must not be NotConfigured"),
            Served::NotModified { .. } => panic!("no validator was sent"),
        }
    }

    /// A symlink under `root` pointing at a file outside of it must not be
    /// followed out. This is the case the segment-based `..`/`.` filtering
    /// does NOT catch -- the escape happens when the symlink is resolved, not
    /// in the URL text -- so it's `open_within`'s containment check on the
    /// opened descriptor that has to catch it instead.
    #[test]
    fn symlink_escaping_root_is_refused() {
        let d = tmproot("symlink");
        std::fs::write(d.join("index.html"), "spa-index").unwrap();

        let outside = std::env::temp_dir().join(format!("wf-outside-{}.txt", std::process::id()));
        std::fs::write(&outside, "TOPSECRET").unwrap();
        let _ = std::fs::remove_file(d.join("escape"));
        std::os::unix::fs::symlink(&outside, d.join("escape")).unwrap();

        if let Served::File { bytes, .. } = serve(&d, "/escape") {
            assert_ne!(bytes, b"TOPSECRET", "symlink escape must be refused");
        }

        let _ = std::fs::remove_file(&outside);
    }

    /// A symlink that stays *inside* the root is fine, and must keep working
    /// -- otherwise "refuse escapes" could be implemented as "refuse every
    /// symlink" and every test above would still pass.
    #[test]
    fn symlink_inside_root_is_followed() {
        let d = tmproot("inlink");
        std::fs::write(d.join("index.html"), "spa-index").unwrap();
        std::fs::write(d.join("real.txt"), "INSIDE").unwrap();
        let _ = std::fs::remove_file(d.join("alias.txt"));
        std::os::unix::fs::symlink(d.join("real.txt"), d.join("alias.txt")).unwrap();

        match serve(&d, "/alias.txt") {
            Served::File { bytes, mime, .. } => {
                assert_eq!(bytes, b"INSIDE");
                assert_eq!(mime, "text/plain; charset=utf-8");
            }
            _ => panic!("a symlink that stays inside the root must still be served"),
        }
    }

    /// `serve` must not panic or return a read error when a request path
    /// resolves to a directory rather than a file -- it should behave
    /// exactly like a miss and fall back to the SPA shell.
    #[test]
    fn directory_hit_falls_back_to_index_not_panic() {
        let d = tmproot("dirhit");
        std::fs::write(d.join("index.html"), "spa-index").unwrap();
        std::fs::create_dir_all(d.join("assets")).unwrap();
        match serve(&d, "/assets") {
            Served::File { bytes, .. } => assert_eq!(bytes, b"spa-index"),
            Served::NotFound => {}
            Served::NotConfigured => panic!("root is populated, must not be NotConfigured"),
            Served::NotModified { .. } => panic!("no validator was sent"),
        }
    }

    /// `main.rs` already splits the query string off of `path` before
    /// calling in, but `serve` is `pub` and must not rely on every caller
    /// having done that -- a `?v=1` cache-buster must not be treated as part
    /// of the filename.
    #[test]
    fn serve_strips_query_string_defensively() {
        let d = tmproot("query");
        std::fs::write(d.join("index.html"), "spa-index").unwrap();
        match serve(&d, "/index.html?v=1") {
            Served::File { bytes, mime, .. } => {
                assert_eq!(bytes, b"spa-index");
                assert_eq!(mime, "text/html; charset=utf-8");
            }
            _ => panic!("query string must not stop index.html from being served"),
        }
    }

    #[test]
    fn gitkeep_only_directory_is_not_configured_but_with_index_it_is() {
        let d = tmproot("gitkeep");
        std::fs::write(d.join(".gitkeep"), "").unwrap();
        assert!(matches!(serve(&d, "/"), Served::NotConfigured));

        std::fs::write(d.join("index.html"), "hi").unwrap();
        match serve(&d, "/") {
            Served::File { bytes, .. } => assert_eq!(bytes, b"hi"),
            _ => panic!(".gitkeep alongside index.html must not count as empty"),
        }
    }

    /// A matching validator must short-circuit to `NotModified`, and a
    /// stale one must not -- the second half is what stops "always 304"
    /// from passing.
    #[test]
    fn matching_validator_yields_not_modified() {
        let d = tmproot("etag");
        std::fs::write(d.join("index.html"), "shell").unwrap();
        std::fs::write(d.join("app.js"), "console.log(1)").unwrap();

        let etag = match super::serve(&d, "/app.js", None) {
            Served::File { etag, .. } => etag,
            _ => panic!("app.js should be served"),
        };
        match super::serve(&d, "/app.js", Some(&etag)) {
            Served::NotModified { etag: back, mime } => {
                assert_eq!(back, etag);
                assert_eq!(mime, "text/javascript; charset=utf-8");
            }
            _ => panic!("a matching If-None-Match must produce NotModified"),
        }
        match super::serve(&d, "/app.js", Some("\"stale-0.0\"")) {
            Served::File { bytes, .. } => assert_eq!(bytes, b"console.log(1)"),
            _ => panic!("a stale If-None-Match must still send the body"),
        }
    }

    /// Different content must produce a different validator, or a redeploy
    /// would keep serving the previous build out of the browser cache.
    #[test]
    fn validator_changes_when_the_file_changes() {
        let d = tmproot("etagchange");
        std::fs::write(d.join("index.html"), "shell").unwrap();
        std::fs::write(d.join("app.js"), "v1").unwrap();
        let first = match super::serve(&d, "/app.js", None) {
            Served::File { etag, .. } => etag,
            _ => panic!("app.js should be served"),
        };
        std::fs::write(d.join("app.js"), "version-two").unwrap();
        let second = match super::serve(&d, "/app.js", None) {
            Served::File { etag, .. } => etag,
            _ => panic!("app.js should be served"),
        };
        assert_ne!(first, second, "a changed file must get a new validator");
    }

    #[test]
    fn validator_comparison_handles_lists_weak_tags_and_star() {
        assert!(etag_matches("\"a\"", "\"a\""));
        assert!(etag_matches("W/\"a\"", "\"a\""));
        assert!(etag_matches("\"b\", \"a\"", "\"a\""));
        assert!(etag_matches("*", "\"a\""));
        assert!(!etag_matches("\"b\"", "\"a\""));
        assert!(!etag_matches("", "\"a\""));
    }
}
