//! The operator console, compiled into the binary.
//!
//! `include_str!` rather than a file read at startup: the page and the JSON it
//! consumes are two halves of one contract, and shipping them as one artifact
//! means a running container cannot serve a console that disagrees with its own
//! `/api/metrics`. It also keeps `/admin` working when `EJ_WEB_ROOT` holds no
//! web build at all -- the console is how you diagnose that situation, so it
//! must not depend on it.
//!
//! The page has no external references of any kind (verified by a grep in this
//! crate's test below, not by convention): a NAS is often reachable only from
//! the LAN, and a console that needs a CDN to render is a console that fails
//! exactly when you need it.

pub const DASHBOARD_HTML: &str = include_str!("../assets/dashboard.html");

#[cfg(test)]
mod tests {
    use super::DASHBOARD_HTML;

    /// The page must be renderable with no network beyond the origin serving
    /// it. This is a real deployment constraint (LAN-only NAS, air-gapped
    /// homelab), and it is the kind of thing that regresses by someone pasting
    /// in a font link, so it is asserted rather than documented.
    #[test]
    fn console_has_no_external_references() {
        for needle in ["http://", "https://", "//fonts.", "@import", "cdn."] {
            assert!(
                !DASHBOARD_HTML.contains(needle),
                "dashboard.html must not reference {needle} -- the console has \
                 to render on a LAN-only host"
            );
        }
    }

    /// Cheap smoke test that `include_str!` picked up a whole document rather
    /// than a truncated write.
    #[test]
    fn console_is_a_complete_document() {
        // The doctype is case-insensitive per the HTML spec, so match it that
        // way rather than pinning whichever casing the file happens to use.
        let head: String = DASHBOARD_HTML.chars().take(15).collect();
        assert!(
            head.eq_ignore_ascii_case("<!doctype html>"),
            "expected a doctype, got {head:?}"
        );
        assert!(DASHBOARD_HTML.trim_end().ends_with("</html>"));
    }
}
