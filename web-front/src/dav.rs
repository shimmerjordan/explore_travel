//! Read-only WebDAV proxy, so the browser can render data it has no way to
//! fetch itself.
//!
//! Two things make this necessary rather than a convenience:
//!
//!   * **CORS.** Almost no WebDAV server sends CORS headers, so a page cannot
//!     talk to one directly no matter what credentials it holds.
//!   * **Credentials.** Even if CORS were solved, the browser would then hold
//!     the user's WebDAV password in JavaScript. Here it never leaves the
//!     server: the page asks this origin, this process attaches the
//!     `Authorization` header from its own encrypted config.
//!
//! The security posture is deliberately narrow in two directions at once:
//!
//!   * **Methods**: read verbs only. This proxy cannot be made to write,
//!     delete, move, or create — see [`ALLOWED_METHODS`]. The web client is a
//!     viewer; giving it a write path would mean one XSS could wipe the user's
//!     cloud backup.
//!   * **Paths**: every target is confined under the configured `webdavUrl`
//!     prefix by [`resolve_target`], which is a pure function precisely so the
//!     confinement can be attacked in a unit test rather than reasoned about.

use crate::config_store;
use crate::proxy;
use serde_json::Value;
use std::io::Read;

/// Read verbs only.
///
/// `PROPFIND` is how a WebDAV directory listing happens; `OPTIONS` is what a
/// client sends to discover DAV support. Everything that mutates is absent, and
/// a test asserts the absence rather than trusting this list to be read.
pub const ALLOWED_METHODS: &[&str] = &["PROPFIND", "GET", "HEAD", "OPTIONS"];

/// Depth values a listing may ask for.
///
/// `infinity` is excluded on purpose: on a large tree it asks the upstream to
/// walk everything, which is a denial-of-service against the user's own WebDAV
/// server that the browser can trigger with one request. Many servers refuse it
/// anyway; refusing it here makes the behaviour predictable instead of
/// server-dependent.
const ALLOWED_DEPTHS: &[&str] = &["0", "1"];

/// Join `rest` under `base`, or refuse.
///
/// The single guarantee: **the result always starts with `base`.** Everything
/// else in here exists to make that true for hostile input, and the function is
/// pure so those inputs can be enumerated in tests.
///
/// Order matters. Percent-decoding happens *before* segment splitting, because
/// `..%2f..%2f` only reveals itself as `../../` after decoding — checking first
/// and decoding later is the classic way this defence gets written backwards.
/// Segments are then dropped by *comparison*, not by string replacement:
/// `"....//".replace("../", "")` leaves `"../"` behind, and that whole family
/// of bugs comes from treating a path as text instead of as segments.
pub fn resolve_target(base: &str, rest: &str) -> Result<String, &'static str> {
    // Refuse an absolute or protocol-relative URL outright rather than trying
    // to normalise it. `//host/x` is the sneaky one: it is not "a path that
    // starts with a slash", it is a scheme-relative URL pointing at another
    // origin entirely.
    if rest.contains("://") || rest.starts_with("//") {
        return Err("absolute URLs are not accepted");
    }
    let decoded = percent_decode(rest);
    if decoded.contains("://") || decoded.starts_with("//") {
        return Err("absolute URLs are not accepted");
    }
    // A NUL (or any control byte) has no business in a path and is a truncation
    // trick against whatever parses it downstream.
    if decoded.bytes().any(|b| b < 0x20 || b == 0x7f) {
        return Err("control characters are not accepted");
    }

    let mut kept: Vec<String> = Vec::new();
    for seg in decoded.split('/') {
        match seg {
            "" | "." => continue,
            // Refuse rather than pop. Popping would silently serve a different
            // resource than the caller named, and a caller that sends `..` is
            // either broken or probing -- neither deserves a best-effort
            // answer.
            ".." => return Err("path traversal is not accepted"),
            s => {
                // Double-encoding defence. One decode has already happened; a
                // segment that would STILL decode into a separator or a `..`
                // is `%252f` / `%252e%252e` -- the classic bypass, because a
                // single decode leaves `%2f` which is not a `/` yet, so the
                // split above never saw it. Decoding twice for real would be
                // worse (it would make `%252e` mean `.` for every caller); so
                // the second decode is used only as a *test*, and its result
                // is thrown away.
                let twice = percent_decode(s);
                if twice.contains('/') || twice.contains('\\') || twice == ".." || twice == "." {
                    return Err("double-encoded path separators are not accepted");
                }
                kept.push(percent_encode_segment(s))
            }
        }
    }

    let base = base.trim_end_matches('/');
    let target = if kept.is_empty() {
        base.to_string()
    } else {
        format!("{}/{}", base, kept.join("/"))
    };

    // Belt and braces: even with the checks above, the one property callers
    // depend on is asserted rather than assumed.
    if !target.starts_with(base) {
        return Err("resolved target escaped the configured base");
    }
    Ok(target)
}

/// Percent-decode once. Decoding twice would re-introduce the `%252e` bypass
/// (a single decode leaves `%2e`, which is an ordinary filename character).
fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hi = (b[i + 1] as char).to_digit(16);
            let lo = (b[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Re-encode one path segment. `/` is deliberately not in the unreserved set:
/// segments were already split on it, so an encoded slash inside a name must
/// stay encoded or it would create a new segment after the fact.
fn percent_encode_segment(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The three config fields this proxy needs, or a description of what's absent.
pub struct DavConfig {
    pub base: String,
    pub user: String,
    pub pass: String,
}

/// Pull the WebDAV settings out of a decrypted config document.
///
/// Key names match the app's `AppSettings` (`webdavUrl` / `webdavUser` /
/// `webdavPass`) because this document IS that object's roaming subset — a
/// second naming here would be a silent mismatch, not a translation layer.
pub fn dav_config(cfg: &Value) -> Option<DavConfig> {
    let s = |k: &str| cfg.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let base = s("webdavUrl");
    if base.is_empty() || !(base.starts_with("http://") || base.starts_with("https://")) {
        return None;
    }
    Some(DavConfig {
        base,
        user: s("webdavUser"),
        pass: s("webdavPass"),
    })
}

/// `Authorization: Basic base64(user:pass)`, or `None` when unconfigured.
///
/// An empty user AND empty password means "the config has a URL but no
/// credentials", which is a legitimate setup (a public read-only share), so
/// this returns `None` rather than sending `Basic Og==` and confusing the
/// upstream.
pub fn basic_auth(user: &str, pass: &str) -> Option<String> {
    if user.is_empty() && pass.is_empty() {
        return None;
    }
    use base64::Engine as _;
    let raw = format!("{user}:{pass}");
    Some(format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(raw)
    ))
}

/// `Depth` to forward, defaulting to `1` for a listing.
pub fn depth_or_default(requested: Option<&str>) -> Result<&str, &'static str> {
    match requested.map(str::trim) {
        None | Some("") => Ok("1"),
        Some(d) if ALLOWED_DEPTHS.contains(&d) => Ok(match d {
            "0" => "0",
            _ => "1",
        }),
        Some(_) => Err("Depth must be 0 or 1"),
    }
}

/// Response headers worth passing back to the browser.
///
/// `WWW-Authenticate` is conspicuously absent and must stay absent: forwarding
/// it makes the browser raise its own native credential prompt for *this*
/// origin, which invites the user to type their WebDAV password into a dialog
/// that has nothing to do with it. An upstream 401 should surface to the page
/// as a plain 401.
pub const FORWARDED_RESPONSE_HEADERS: &[&str] = &[
    "Content-Type",
    "Content-Length",
    "Content-Range",
    "Accept-Ranges",
    "ETag",
    "Last-Modified",
    "DAV",
];

/// One upstream exchange. Kept separate from the HTTP handler so the handler
/// stays about policy (session, method, config) and this stays about bytes.
pub struct Relayed {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

pub fn relay(
    agent: &ureq::Agent,
    method: &str,
    url: &str,
    auth: Option<&str>,
    depth: Option<&str>,
    range: Option<&str>,
    body: &[u8],
) -> Option<Relayed> {
    let mut req = agent.request(method, url);
    if let Some(a) = auth {
        req = req.set("Authorization", a);
    }
    if let Some(d) = depth {
        req = req.set("Depth", d);
    }
    if let Some(r) = range {
        req = req.set("Range", r);
    }
    let sent = if body.is_empty() {
        req.call()
    } else {
        req.set("Content-Type", "application/xml; charset=utf-8")
            .send_bytes(body)
    };
    let resp = match sent {
        Ok(r) => r,
        // redirects(0) turns 3xx into Status too; pass the code through rather
        // than following it, which would escape the pre-dial IP check.
        Err(ureq::Error::Status(_, r) ) => r,
        Err(_) => return None,
    };
    let status = resp.status();
    let headers: Vec<(String, String)> = FORWARDED_RESPONSE_HEADERS
        .iter()
        .filter_map(|h| resp.header(h).map(|v| ((*h).to_string(), v.to_string())))
        .collect();
    let mut out = Vec::new();
    resp.into_reader()
        .take(proxy::BODY_CAP)
        .read_to_end(&mut out)
        .ok()?;
    Some(Relayed {
        status,
        headers,
        body: out,
    })
}

/// Read and decrypt the stored config for this session's key.
pub fn load_config(dir: &std::path::Path, key: &[u8; 32]) -> Result<Option<Value>, String> {
    match config_store::load(dir, key)? {
        None => Ok(None),
        Some(bytes) => match serde_json::from_slice::<Value>(&bytes) {
            Ok(v) => Ok(Some(v)),
            Err(e) => Err(format!("stored config is not JSON: {e}")),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const BASE: &str = "https://dav.example.com/remote.php/dav/files/me";

    #[test]
    fn joins_relative_path_under_base() {
        assert_eq!(
            resolve_target(BASE, "Sync/fow/a.png").unwrap(),
            format!("{BASE}/Sync/fow/a.png")
        );
    }

    #[test]
    fn tolerates_leading_slash_and_double_slash_in_base() {
        assert_eq!(
            resolve_target(BASE, "/Sync/a").unwrap(),
            format!("{BASE}/Sync/a")
        );
        assert_eq!(
            resolve_target("https://d.example.com/dav/", "x").unwrap(),
            "https://d.example.com/dav/x"
        );
        // An empty rest addresses the base itself, which is what a listing of
        // the root needs.
        assert_eq!(resolve_target(BASE, "").unwrap(), BASE);
    }

    #[test]
    fn refuses_escaping_the_base_prefix() {
        for bad in [
            "../../etc",
            "..%2f..%2fetc",
            "..%252f..%252fetc",
            "/../outside",
            "a/../../../outside",
            "a/%2e%2e/%2e%2e/outside",
            "%2e%2e/outside",
        ] {
            let got = resolve_target(BASE, bad);
            assert!(got.is_err(), "must refuse {bad:?}, got {got:?}");
        }
    }

    #[test]
    fn refuses_absolute_url_injection() {
        for bad in [
            "https://evil.example.com/x",
            "http://evil.example.com/x",
            "//evil.example.com/x",
            "%2f%2fevil.example.com/x",
            "https%3A%2F%2Fevil.example.com/x",
        ] {
            let got = resolve_target(BASE, bad);
            assert!(got.is_err(), "must refuse {bad:?}, got {got:?}");
        }
    }

    #[test]
    fn refuses_control_bytes() {
        assert!(resolve_target(BASE, "a%00b").is_err());
        assert!(resolve_target(BASE, "a%0db").is_err());
    }

    /// `....//` is a real bypass — but only against implementations that strip
    /// `../` as *text*, where `"....//".replace("../","")` leaves `"../"`
    /// behind. Segment comparison never sees a `..` here: `....` is four dots,
    /// a legal (if odd) directory name. So it must resolve, under base, rather
    /// than be refused — refusing it would mean the traversal defence is
    /// pattern-matching on shapes instead of understanding path structure.
    #[test]
    fn four_dots_is_a_name_not_a_traversal() {
        let t = resolve_target(BASE, "....//outside").unwrap();
        assert_eq!(t, format!("{BASE}/..../outside"));
        assert!(t.starts_with(BASE));
    }

    #[test]
    fn result_always_starts_with_base() {
        for ok in ["a", "a/b/c", "%E4%B8%AD%E6%96%87/x", "with space/x", "....//x"] {
            let t = resolve_target(BASE, ok).unwrap();
            assert!(t.starts_with(BASE), "escaped base: {t}");
        }
    }

    /// A single-encoded slash is a *separator*, not part of a name.
    ///
    /// This follows from decoding before splitting, and decoding before
    /// splitting is what stops `..%2f..%2f`. The trade-off is that a WebDAV
    /// resource whose name contains a literal `/` cannot be addressed through
    /// this proxy -- which is not a real loss, since `/` is the path separator
    /// and such a name is not addressable over WebDAV either.
    #[test]
    fn an_encoded_slash_is_a_separator_not_part_of_a_name() {
        assert_eq!(
            resolve_target(BASE, "odd%2Fname").unwrap(),
            format!("{BASE}/odd/name")
        );
        // A literal space, by contrast, is part of the name and must be
        // encoded on the way out rather than travelling raw into a URL.
        assert_eq!(
            resolve_target(BASE, "a b").unwrap(),
            format!("{BASE}/a%20b")
        );
        // And the double-encoded form is refused outright rather than passed
        // to the upstream to interpret however it likes.
        assert!(resolve_target(BASE, "odd%252Fname").is_err());
    }

    #[test]
    fn method_whitelist_excludes_writes() {
        for m in [
            "PUT",
            "DELETE",
            "MKCOL",
            "MOVE",
            "COPY",
            "POST",
            "PROPPATCH",
            "LOCK",
            "UNLOCK",
            "PATCH",
        ] {
            assert!(!ALLOWED_METHODS.contains(&m), "{m} must not be proxied");
        }
        for m in ["PROPFIND", "GET", "HEAD", "OPTIONS"] {
            assert!(ALLOWED_METHODS.contains(&m));
        }
    }

    #[test]
    fn www_authenticate_is_never_forwarded() {
        assert!(
            !FORWARDED_RESPONSE_HEADERS
                .iter()
                .any(|h| h.eq_ignore_ascii_case("WWW-Authenticate")),
            "forwarding it makes the browser prompt for credentials on this origin"
        );
    }

    #[test]
    fn depth_defaults_to_one_and_refuses_infinity() {
        assert_eq!(depth_or_default(None).unwrap(), "1");
        assert_eq!(depth_or_default(Some("")).unwrap(), "1");
        assert_eq!(depth_or_default(Some("0")).unwrap(), "0");
        assert_eq!(depth_or_default(Some("1")).unwrap(), "1");
        assert!(depth_or_default(Some("infinity")).is_err());
        assert!(depth_or_default(Some("2")).is_err());
    }

    #[test]
    fn config_is_read_only_when_it_has_a_usable_url() {
        assert!(dav_config(&json!({})).is_none());
        assert!(dav_config(&json!({"webdavUrl": ""})).is_none());
        assert!(dav_config(&json!({"webdavUrl": "dav.example.com"})).is_none(),
            "a bare host is not a URL this can dial");
        assert!(dav_config(&json!({"webdavUrl": "ftp://x/y"})).is_none());
        let c = dav_config(&json!({
            "webdavUrl": "https://dav.example.com/d",
            "webdavUser": "u",
            "webdavPass": "p",
        }))
        .unwrap();
        assert_eq!(c.base, "https://dav.example.com/d");
        assert_eq!(c.user, "u");
    }

    #[test]
    fn basic_auth_is_omitted_when_there_is_nothing_to_send() {
        assert!(basic_auth("", "").is_none());
        assert_eq!(basic_auth("u", "p").unwrap(), "Basic dTpw");
        // A password-only share is still a credential.
        assert!(basic_auth("", "p").is_some());
    }

    /// The credential must not turn up anywhere except the header it belongs
    /// in -- notably not in the resolved URL, which gets logged.
    #[test]
    fn credentials_never_reach_the_url() {
        let t = resolve_target("https://dav.example.com/d", "Sync/a").unwrap();
        assert!(!t.contains("hunter2"));
        assert!(!t.contains('@'), "no userinfo in the dialed URL: {t}");
    }
}
