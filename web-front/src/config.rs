use serde::Deserialize;
use std::env;
use std::fs;

/// Server settings: an optional JSON file (EJ_CONFIG, default
/// `/data/server.json`) that is then OVERRIDDEN by environment variables. Edit
/// the file on the NAS volume + restart the container to reconfigure — no
/// rebuild.
///
/// The default used to be `/data/config.json`, which is **the same path
/// `config_store` writes the encrypted user config to**. The collision was
/// silent in the worst way: `serde(default)` makes every field below optional,
/// so the encrypted envelope `{v, nonce_b64, ct_b64}` parsed *successfully*
/// into an all-defaults `Config`. An operator who had set `proxy_enabled` or
/// `proxy_allow_hosts` in that file lost it the moment a config was pushed from
/// the phone, with nothing in the log to say why.
///
/// Two changes keep it from coming back: the default name no longer collides,
/// and `deny_unknown_fields` means pointing `EJ_CONFIG` at the wrong file (or
/// misspelling a key) is a startup error instead of a silent set of defaults.
#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    /// Directory holding `admin.json` and the encrypted config blob
    /// `config.json`. Single flat data directory — no SQLite file.
    pub data_dir: String,
    /// Directory the static web build is served from.
    pub web_root: String,
    pub listen: String,
    pub proxy_enabled: bool,
    pub proxy_allow_hosts: Vec<String>,
    pub token_ttl_secs: u64,
    pub trust_proxy_header: bool,
    pub workers: usize,
    /// How often the background sampler appends a point to the metrics ring.
    /// `metrics.json` is rewritten every `PERSIST_EVERY_SAMPLES` of those, not
    /// every one -- see metrics.rs. Clamped to
    /// `[1, MAX_SAMPLE_INTERVAL_SECS]`.
    pub metrics_interval_secs: u64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            data_dir: "/data".into(),
            web_root: "/web".into(),
            listen: "0.0.0.0:48080".into(), // high port; avoids low-port clashes on a NAS
            proxy_enabled: false,
            proxy_allow_hosts: Vec::new(),
            // One hour by default. The old JWT-based design (stateless,
            // no server-side session table) leaned toward a long-lived
            // token because revoking a single session wasn't possible at
            // all -- that premise is gone now that `Sessions` holds a real
            // server-side table with sliding renewal on every use (see
            // session.rs::get_key), so a short TTL costs the admin nothing
            // in practice (any activity keeps the session alive) while
            // capping how long a leaked cookie/token stays valid. Tune with
            // EJ_TOKEN_TTL_SECS if you want it shorter or longer.
            token_ttl_secs: 3600,
            trust_proxy_header: false,
            workers: 8,
            // 60 s pairs with the 1440-point ring for exactly 24 hours of
            // history -- see metrics.rs. Lower it and the ring covers less
            // time, and metrics.json is rewritten proportionally more often,
            // which on a NAS's spinning disk is the cost that matters.
            metrics_interval_secs: crate::metrics::DEFAULT_SAMPLE_INTERVAL_SECS,
        }
    }
}

impl Config {
    pub fn load() -> Result<Config, String> {
        let mut cfg = Config::default();

        let path = env::var("EJ_CONFIG").unwrap_or_else(|_| "/data/server.json".into());
        let mut had_file = true;
        match fs::read_to_string(&path) {
            Ok(text) => {
                cfg = serde_json::from_str(&text).map_err(|e| {
                    let hint = if text.contains("ct_b64") {
                        " — this looks like the ENCRYPTED USER CONFIG, not the \
server settings file. They are different files: the envelope lives at \
<data_dir>/config.json and is written by PUT /api/config; server settings \
default to <data_dir>/server.json. Point EJ_CONFIG at the latter (or unset it)."
                    } else {
                        " — unknown keys are rejected on purpose, so a typo \
fails loudly instead of being silently ignored"
                    };
                    format!("parse {path}: {e}{hint}")
                })?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => had_file = false,
            Err(e) => return Err(format!("read {path}: {e}")),
        }

        // Env overrides win over the file.
        if let Ok(v) = env::var("EJ_DATA_DIR") {
            if !v.is_empty() {
                cfg.data_dir = v;
            }
        }
        if let Ok(v) = env::var("EJ_WEB_ROOT") {
            if !v.is_empty() {
                cfg.web_root = v;
            }
        }
        if let Ok(v) = env::var("EJ_LISTEN") {
            if !v.is_empty() {
                cfg.listen = v;
            }
        }
        if let Ok(v) = env::var("EJ_PROXY_ENABLED") {
            cfg.proxy_enabled = boolish(&v);
        }
        if let Ok(v) = env::var("EJ_PROXY_ALLOW_HOSTS") {
            cfg.proxy_allow_hosts = split_csv(&v);
        }
        if let Ok(v) = env::var("EJ_TOKEN_TTL_SECS") {
            if let Ok(n) = v.parse::<u64>() {
                cfg.token_ttl_secs = n;
            }
        }
        if let Ok(v) = env::var("EJ_WORKERS") {
            if let Ok(n) = v.parse::<usize>() {
                cfg.workers = n;
            }
        }
        if let Ok(v) = env::var("EJ_TRUST_PROXY") {
            cfg.trust_proxy_header = boolish(&v);
        }
        if let Ok(v) = env::var("EJ_METRICS_INTERVAL_SECS") {
            match v.parse::<u64>() {
                Ok(n) => cfg.metrics_interval_secs = n,
                // Unlike the settings above, a rejected value here is said out
                // loud. Silently keeping the default is fine for a TTL that
                // still works; for the sampler it looks identical to a broken
                // sampler, and the operator's next move ("why is the graph
                // empty?") is a long one.
                Err(e) => eprintln!(
                    "WARN: EJ_METRICS_INTERVAL_SECS={v} is not a number ({e}); \
                     using {}s",
                    cfg.metrics_interval_secs
                ),
            }
        }

        // Deliberately after the env overrides: `data_dir` is only final here,
        // and checking earlier would look for the legacy file in the built-in
        // default directory rather than the one actually in use.
        //
        // Running on defaults is normal and not an error. But one shape of
        // "normal" is actually a silently-ignored upgrade: `<data_dir>/config.json`
        // USED to be this settings file, and now holds the encrypted user
        // config. Someone upgrading has their old settings sitting right there
        // being ignored, and without this line nothing anywhere says so.
        if !had_file {
            let legacy = std::path::Path::new(&cfg.data_dir).join("config.json");
            // Only when that file actually IS old settings. It normally holds the
            // encrypted user config, which every compose deployment has after the
            // first push -- warning on that would fire on every restart of every
            // default install, and the advice it gives ("rename it") would break
            // a working setup.
            if legacy.exists()
                && std::fs::read_to_string(&legacy)
                    .map(|t| crate::config_store::looks_like_server_settings(&t))
                    .unwrap_or(false)
            {
                eprintln!(
                    "WARN: no settings file at {path}, so built-in defaults are in use \
                     (still overridden by any EJ_* variables) -- but {} looks like a server \
                     settings file. That path was the settings file in older versions and is \
                     now where the encrypted user config lives. Rename it to server.json and \
                     restart to have it read.",
                    legacy.display()
                );
            }
        }

        if cfg.token_ttl_secs == 0 {
            cfg.token_ttl_secs = 3600;
        }
        if cfg.workers == 0 {
            cfg.workers = 8;
        }
        // Both ends of this range fail invisibly if left alone, which is why
        // they are the only settings in this function that log when they bite.
        // Zero would spin the sampler in a tight loop rewriting the file; a
        // huge value (`u64::MAX` is what a stray `-1` parses to) would park the
        // thread forever -- no samples, no `metrics.json`, no log line, and an
        // operator staring at an empty graph with nothing to go on.
        if cfg.metrics_interval_secs == 0 {
            eprintln!(
                "WARN: EJ_METRICS_INTERVAL_SECS=0 would spin the metrics sampler; using {}s",
                crate::metrics::DEFAULT_SAMPLE_INTERVAL_SECS
            );
            cfg.metrics_interval_secs = crate::metrics::DEFAULT_SAMPLE_INTERVAL_SECS;
        }
        if cfg.metrics_interval_secs > crate::metrics::MAX_SAMPLE_INTERVAL_SECS {
            eprintln!(
                "WARN: EJ_METRICS_INTERVAL_SECS={} exceeds the {}s maximum; clamped",
                cfg.metrics_interval_secs,
                crate::metrics::MAX_SAMPLE_INTERVAL_SECS
            );
            cfg.metrics_interval_secs = crate::metrics::MAX_SAMPLE_INTERVAL_SECS;
        }
        Ok(cfg)
    }

    /// Log-safe summary (no secret).
    pub fn redacted(&self) -> String {
        format!(
            "listen={} dataDir={} webRoot={} proxy={} proxyHosts={:?} tokenTTL={}s workers={} metricsInterval={}s",
            self.listen, self.data_dir, self.web_root,
            self.proxy_enabled, self.proxy_allow_hosts, self.token_ttl_secs, self.workers,
            self.metrics_interval_secs
        )
    }
}

fn split_csv(s: &str) -> Vec<String> {
    s.split(',')
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect()
}

fn boolish(s: &str) -> bool {
    matches!(s.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on")
}
