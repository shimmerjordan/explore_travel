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
//!      a child of `root` -- see the tests), then the whole path is
//!      `canonicalize`d and checked against `root`'s own canonical form with
//!      `Path::strip_prefix`, which compares path *components*, not
//!      characters. That second check is what catches a symlink under
//!      `root` that points outside of it: dropping `..` segments doesn't
//!      help there, because the escape happens during symlink resolution,
//!      not in the URL text.
//!
//! The tradeoff of check 2: a *legitimate* symlink under `root` that
//! happens to point outside of it is refused right along with a malicious
//! one -- this module has no way to tell the two apart, and the deliberate
//! choice here is to refuse rather than trust the symlink's target.

use std::path::{Path, PathBuf};

/// Result of resolving one request against the web root.
pub enum Served {
    File { bytes: Vec<u8>, mime: &'static str },
    NotConfigured,
    NotFound,
}

/// Shown at `/` (and any other path, via the same SPA fallback machinery)
/// when `EJ_WEB_ROOT` is missing or empty, so an operator who starts the
/// container without a web build gets an explanation instead of a bare 404.
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
pub fn serve(root: &Path, url_path: &str) -> Served {
    let canonical_root = match root.canonicalize() {
        Ok(p) => p,
        Err(_) => return Served::NotConfigured,
    };
    if is_empty_or_placeholder_only(&canonical_root) {
        return Served::NotConfigured;
    }

    match resolve(&canonical_root, url_path) {
        Some(path) if path.is_file() => match std::fs::read(&path) {
            Ok(bytes) => {
                let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                Served::File { bytes, mime: mime_for(name) }
            }
            // Existed a moment ago (`is_file` above) but became unreadable
            // before the read -- fall back rather than surface an I/O error
            // to the client for what's still just "this path had no asset".
            Err(_) => fallback_index(&canonical_root),
        },
        // Either nothing matched, or it matched a directory (which is never
        // read directly -- doing so would either error or, worse on some
        // platforms, panic) -- both cases fall back to the SPA shell.
        _ => fallback_index(&canonical_root),
    }
}

fn fallback_index(canonical_root: &Path) -> Served {
    match std::fs::read(canonical_root.join("index.html")) {
        Ok(bytes) => Served::File { bytes, mime: mime_for("index.html") },
        Err(_) => Served::NotFound,
    }
}

/// Resolve `url_path` to a real, existing path inside `canonical_root`, or
/// `None` if it doesn't exist or would escape -- see the module doc for why
/// both the segment filtering and the final `strip_prefix` are needed.
fn resolve(canonical_root: &Path, url_path: &str) -> Option<PathBuf> {
    let path_only = url_path.split('?').next().unwrap_or("");
    let decoded = percent_decode(path_only);

    let mut joined = canonical_root.to_path_buf();
    for seg in decoded.split('/') {
        match seg {
            "" | "." | ".." => continue, // dropped, never resolved against a parent
            s => joined.push(s),
        }
    }

    let canonical = joined.canonicalize().ok()?;
    if canonical.strip_prefix(canonical_root).is_ok() {
        Some(canonical)
    } else {
        None
    }
}

/// A directory that holds nothing but the git placeholder counts as "not
/// configured" -- the same as a missing directory -- rather than serving an
/// empty tree with no `index.html`.
fn is_empty_or_placeholder_only(dir: &Path) -> bool {
    match std::fs::read_dir(dir) {
        Ok(entries) => entries
            .filter_map(|e| e.ok())
            .all(|e| e.file_name() == ".gitkeep"),
        Err(_) => true,
    }
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
        "json" | "map" => "application/json",
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
        assert_eq!(mime_for("manifest.json"), "application/json");
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

    #[test]
    fn serves_index_at_root() {
        let d = tmproot("index");
        std::fs::write(d.join("index.html"), "<h1>hi</h1>").unwrap();
        match serve(&d, "/") {
            Served::File { bytes, mime } => {
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
        if let Served::File { bytes, .. } = serve(&root, "other/secret.txt") {
            assert_ne!(bytes, b"TOPSECRET", "must not reach the sibling directory");
        }

        let _ = std::fs::remove_dir_all(&sibling);
    }

    /// A symlink under `root` pointing at a file outside of it must not be
    /// followed out. This is the case the segment-based `..`/`.` filtering
    /// does NOT catch -- the escape happens when `canonicalize` resolves the
    /// symlink, not in the URL text -- so it's the final `strip_prefix`
    /// check in `resolve` that has to catch it instead.
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
            Served::File { bytes, mime } => {
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
}
