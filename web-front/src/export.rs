//! `GET /api/export` — hand the operator their own data back.
//!
//! Two audiences, and they want opposite things from the same bytes:
//!
//!   * **"help me debug this"** — the config's shape matters, its credentials
//!     do not, and the file is about to be pasted into a chat window. This is
//!     the default, and it is the default *because* getting it wrong leaks
//!     every cloud credential the user owns.
//!   * **"I'm moving to a new NAS"** — the credentials are the whole point.
//!     Only an explicit `secrets=1` selects this.
//!
//! The default therefore fails safe: a missing, empty, misspelled, or hostile
//! `secrets` value all scrub. Only the exact string `1` does not.

use serde_json::{json, Value};

/// Config keys whose values are credentials.
///
/// **The authority for this list is `kVaultSecretKeys` in
/// `lib/services/backup/backup_service.dart`** — the same constant the app's
/// backup scrubber uses. This is a hand-maintained copy across a language
/// boundary, which is a real hazard: a credential added there and forgotten
/// here is exported in cleartext by the "scrubbed" download, silently. So the
/// list is deliberately the *full* set rather than the narrower set that
/// currently roams — the phone stopped uploading the speech and music
/// credentials, but a config stored before that change still contains them,
/// and scrubbing a key that isn't present costs nothing while missing one
/// costs everything.
///
/// Direction of safety, if you are unsure whether something belongs: add it.
const SECRET_KEYS: &[&str] = &[
    "webdavPass",
    "p2pPassphrase",
    "aiApiKey",
    "githubPat",
    "githubPrivatePat",
    "customAuthHeader",
    "leaderboardRepoPat",
    "leaderboardServerToken",
    "oneDriveRefreshToken",
    "musicCredentials",
    "sttApiKey",
    "ttsApiKey",
    "volcTtsToken",
];

/// Replace every credential value with `null`, at any depth.
///
/// Recursive because at least one credential (`musicCredentials`) is itself an
/// object: a top-level-only scrub would null the wrapper on the way past but
/// leave a nested `{"netease": "..."}` intact if the schema ever gains one.
/// Keys are nulled rather than removed so the reader can still see *that* a
/// credential is configured — which is usually the question being debugged.
pub fn scrub(v: &mut Value) {
    match v {
        Value::Object(map) => {
            for (k, val) in map.iter_mut() {
                if SECRET_KEYS.contains(&k.as_str()) {
                    *val = Value::Null;
                } else {
                    scrub(val);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(scrub),
        _ => {}
    }
}

/// `true` only for the exact opt-in. Everything else scrubs — see the module
/// doc for why this is not merely a style preference.
pub fn wants_secrets(query: &str) -> bool {
    param(query, "secrets").as_deref() == Some("1")
}

/// What the caller asked for. Unknown values are rejected by the caller rather
/// than defaulted, so a typo produces a 400 instead of quietly handing back
/// the wrong artifact.
pub fn what(query: &str) -> Option<String> {
    param(query, "what")
}

fn param(query: &str, name: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (k, v) = pair.split_once('=')?;
        (k == name).then(|| v.to_string())
    })
}

/// The metrics time series as CSV.
///
/// Values are **cumulative**, exactly as stored: the sampler records running
/// totals so that a restart shows up as a visible reset rather than a
/// plausible-looking rate. Differentiating adjacent rows gives per-interval
/// rates; doing that here would throw away the ability to tell "quiet minute"
/// apart from "sampler was not running".
///
/// The plan specified `ts,requests,errors,bytes_out`; the 4xx/5xx split,
/// credential failures and RSS are appended because this file is the only
/// place the series is available at all, and collapsing 4xx and 5xx into one
/// `errors` column would make the export strictly worse than the console it
/// was exported from. Nothing parses this programmatically.
pub fn metrics_csv(snapshot: &Value) -> String {
    let mut out =
        String::from("ts,requests,errors,bytes_out,client_err,server_err,login_failures,rss_mb\n");
    let rows = snapshot.get("samples").and_then(Value::as_array);
    for s in rows.into_iter().flatten() {
        let n = |k: &str| s.get(k).and_then(Value::as_u64).unwrap_or(0);
        let (ce, se) = (n("client_err"), n("server_err"));
        out.push_str(&format!(
            "{},{},{},{},{},{},{},{}\n",
            n("ts"),
            n("requests"),
            ce + se,
            n("bytes_out"),
            ce,
            se,
            n("login_failures"),
            n("rss_mb"),
        ));
    }
    out
}

/// Wrap a config document and a metrics snapshot into one file.
pub fn bundle(config: Value, metrics: Value) -> Value {
    json!({ "config": config, "metrics": metrics })
}

/// Parse stored config bytes into JSON, or fall back to a wrapper that says so.
///
/// The stored blob is opaque to this server: it was validated as a JSON object
/// when it was written, but a hand-edited data directory can put anything
/// there. Refusing to export in that case would deny the operator the one
/// artifact that would let them see what went wrong, so unparseable content is
/// passed through as a string under an obvious key instead.
pub fn config_doc(bytes: Option<Vec<u8>>) -> Value {
    match bytes {
        None => json!({}),
        Some(b) => match serde_json::from_slice::<Value>(&b) {
            Ok(v @ Value::Object(_)) => v,
            Ok(other) => json!({ "_unexpected_shape": other }),
            Err(e) => json!({ "_unparseable": String::from_utf8_lossy(&b), "_error": e.to_string() }),
        },
    }
}

/// `Content-Disposition` value for a download.
pub fn attachment(filename: &str) -> String {
    format!("attachment; filename=\"{filename}\"")
}

/// Names the console asks for, so the two agree in one place.
pub fn filename(what: &str, secrets: bool) -> &'static str {
    match (what, secrets) {
        ("config", false) => "web-front-config.json",
        ("config", true) => "web-front-config-secrets.json",
        ("metrics", _) => "web-front-metrics.csv",
        (_, false) => "web-front-export.json",
        (_, true) => "web-front-export-secrets.json",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Value {
        json!({
            "webdavUrl": "https://dav.example.com",
            "webdavPass": "SECRET123",
            "githubPat": "ghp_secret",
            "aiModel": "gpt-x",
            "musicCredentials": { "netease": "cookie-secret" },
        })
    }

    #[test]
    fn scrubbing_nulls_credentials_and_keeps_locators() {
        let mut v = cfg();
        scrub(&mut v);
        assert_eq!(v["webdavPass"], Value::Null);
        assert_eq!(v["githubPat"], Value::Null);
        assert_eq!(v["musicCredentials"], Value::Null);
        assert_eq!(v["webdavUrl"], "https://dav.example.com");
        assert_eq!(v["aiModel"], "gpt-x");
        // The key survives so the reader can still tell it was configured.
        assert!(v.as_object().unwrap().contains_key("webdavPass"));
        let text = v.to_string();
        assert!(!text.contains("SECRET123"), "scrubbed export leaked: {text}");
        assert!(!text.contains("ghp_secret"));
        assert!(!text.contains("cookie-secret"));
    }

    /// A credential nested one level deeper must not survive. This is the case
    /// a top-level-only scrub would miss, so it is asserted rather than
    /// assumed.
    #[test]
    fn scrubbing_reaches_nested_objects_and_arrays() {
        let mut v = json!({
            "profiles": [ { "webdavPass": "deep-secret", "webdavUser": "u" } ],
            "nested": { "inner": { "aiApiKey": "also-deep" } },
        });
        scrub(&mut v);
        let text = v.to_string();
        assert!(!text.contains("deep-secret"), "{text}");
        assert!(!text.contains("also-deep"), "{text}");
        assert_eq!(v["profiles"][0]["webdavUser"], "u");
    }

    /// The failure that matters is "scrubbing did not happen", so every way of
    /// *not* saying `secrets=1` is pinned, not just the empty case.
    #[test]
    fn only_an_exact_opt_in_releases_credentials() {
        assert!(wants_secrets("what=config&secrets=1"));
        for q in [
            "what=config",
            "what=config&secrets=0",
            "what=config&secrets=",
            "what=config&secrets=yes",
            "what=config&secrets=true",
            "what=config&secrets=01",
            "what=config&secrets=1 ",
            "what=config&SECRETS=1",
            "",
        ] {
            assert!(!wants_secrets(q), "{q} must not release credentials");
        }
    }

    #[test]
    fn what_is_read_but_never_defaulted() {
        assert_eq!(what("what=metrics").as_deref(), Some("metrics"));
        assert_eq!(what("secrets=1&what=all").as_deref(), Some("all"));
        assert_eq!(what("secrets=1"), None);
        assert_eq!(what(""), None);
    }

    #[test]
    fn csv_has_a_header_and_one_row_per_sample() {
        let snap = json!({"samples": [
            {"ts": 10, "requests": 5, "bytes_out": 100, "client_err": 1, "server_err": 2,
             "login_failures": 3, "rss_mb": 40},
            {"ts": 20, "requests": 9, "bytes_out": 200, "client_err": 4, "server_err": 0,
             "login_failures": 3, "rss_mb": 41},
        ]});
        let csv = metrics_csv(&snap);
        let lines: Vec<&str> = csv.trim_end().split('\n').collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].starts_with("ts,requests,errors,bytes_out"));
        assert_eq!(lines[1], "10,5,3,100,1,2,3,40");
        assert_eq!(lines[2], "20,9,4,200,4,0,3,41");
    }

    #[test]
    fn csv_of_a_fresh_server_is_a_header_only() {
        let csv = metrics_csv(&json!({"samples": []}));
        assert_eq!(csv.trim_end().split('\n').count(), 1);
        // A snapshot with no samples key at all must not panic either.
        assert!(metrics_csv(&json!({})).starts_with("ts,"));
    }

    #[test]
    fn a_config_that_was_never_pushed_exports_as_an_empty_object() {
        assert_eq!(config_doc(None), json!({}));
    }

    #[test]
    fn unparseable_stored_config_is_surfaced_not_swallowed() {
        let v = config_doc(Some(b"{not json".to_vec()));
        assert!(v.get("_unparseable").is_some(), "{v}");
        assert!(v["_unparseable"].as_str().unwrap().contains("not json"));
    }

    /// The real guard: read the Dart constant this list is a copy of, and
    /// require them to agree.
    ///
    /// Without this, the two sides drift silently and the drift is a *cleartext
    /// leak*: a credential added to `kVaultSecretKeys` starts roaming
    /// immediately (the payload is a union), the Dart-side tests stay green
    /// (their assertion is about the difference from `deviceOnlySecretKeys`,
    /// which still holds), and this scrubber has never heard of the key -- so
    /// the download labelled "scrubbed" hands it over in the clear. Demonstrated
    /// on the running server before this test existed: pushing an unknown
    /// credential key came back verbatim from `?what=config`.
    ///
    /// The path is relative to this file and resolved at COMPILE time, so
    /// renaming or moving the Dart file breaks the build rather than quietly
    /// disabling the check.
    #[test]
    fn secret_list_matches_the_dart_constant_it_copies() {
        const DART: &str =
            include_str!("../../lib/services/backup/backup_service.dart");
        let body = DART
            .split_once("const kVaultSecretKeys = <String>{")
            .expect("kVaultSecretKeys moved or was renamed in the Dart source")
            .1
            .split_once("};")
            .expect("unterminated kVaultSecretKeys literal")
            .0;
        // Quoted entries only: the literal carries comments, and a comment
        // mentioning a key name must not count as declaring one.
        let mut dart: Vec<&str> = body
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .flat_map(|l| l.split('\'').skip(1).step_by(2))
            .collect();
        dart.sort_unstable();
        let mut rust: Vec<&str> = SECRET_KEYS.to_vec();
        rust.sort_unstable();

        assert!(!dart.is_empty(), "parsed nothing from the Dart literal");
        let only_dart: Vec<_> = dart.iter().filter(|k| !rust.contains(k)).collect();
        let only_rust: Vec<_> = rust.iter().filter(|k| !dart.contains(k)).collect();
        assert!(
            only_dart.is_empty(),
            "these credentials are scrubbed from backups but NOT from the server's \
             \"scrubbed\" export -- add them to SECRET_KEYS: {only_dart:?}"
        );
        assert!(
            only_rust.is_empty(),
            "SECRET_KEYS names keys the Dart authority does not: {only_rust:?} \
             (harmless today, but it means one side moved)"
        );
    }

    /// Kept alongside the comparison above as a floor: if the Dart parse ever
    /// silently yields an empty or wrong set, this still fails.
    #[test]
    fn secret_list_covers_the_known_roaming_credentials() {
        for k in [
            "webdavPass",
            "githubPat",
            "githubPrivatePat",
            "oneDriveRefreshToken",
            "aiApiKey",
            "leaderboardRepoPat",
            "leaderboardServerToken",
            "customAuthHeader",
            "p2pPassphrase",
        ] {
            assert!(SECRET_KEYS.contains(&k), "{k} missing from SECRET_KEYS");
        }
    }
}
