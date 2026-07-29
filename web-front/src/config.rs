use serde::Deserialize;
use std::env;
use std::fs;

/// Config: an optional JSON file (EJ_CONFIG, default /data/config.json) that is
/// then OVERRIDDEN by environment variables. Edit the file on the NAS volume +
/// restart the container to reconfigure — no rebuild. (Plan §3.2.)
#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Directory holding `admin.json` (and, from Task 8 onward, the encrypted
    /// config blob). Single flat data directory — no more SQLite file.
    pub data_dir: String,
    /// Directory the static web build is served from (Task 6+).
    pub web_root: String,
    pub listen: String,
    pub proxy_enabled: bool,
    pub proxy_allow_hosts: Vec<String>,
    pub token_ttl_secs: u64,
    pub trust_proxy_header: bool,
    pub workers: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            data_dir: "/data".into(),
            web_root: "/web".into(),
            listen: "0.0.0.0:48080".into(), // high port; avoids low-port clashes on a NAS
            proxy_enabled: false,
            proxy_allow_hosts: Vec::new(),
            // Long-lived by design: the web client persists its session and
            // the user expects to stay logged in until they log OUT, not
            // until a timer fires. Personal/self-hosted threat model; tune
            // with EJ_TOKEN_TTL_SECS if you want shorter sessions.
            token_ttl_secs: 365 * 24 * 3600,
            trust_proxy_header: false,
            workers: 8,
        }
    }
}

impl Config {
    pub fn load() -> Result<Config, String> {
        let mut cfg = Config::default();

        let path = env::var("EJ_CONFIG").unwrap_or_else(|_| "/data/config.json".into());
        match fs::read_to_string(&path) {
            Ok(text) => {
                cfg = serde_json::from_str(&text)
                    .map_err(|e| format!("parse {path}: {e}"))?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
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
        if let Ok(v) = env::var("EJ_TRUST_PROXY") {
            cfg.trust_proxy_header = boolish(&v);
        }

        if cfg.token_ttl_secs == 0 {
            cfg.token_ttl_secs = 365 * 24 * 3600;
        }
        if cfg.workers == 0 {
            cfg.workers = 8;
        }
        Ok(cfg)
    }

    /// Log-safe summary (no secret).
    pub fn redacted(&self) -> String {
        format!(
            "listen={} dataDir={} webRoot={} proxy={} proxyHosts={:?} tokenTTL={}s workers={}",
            self.listen, self.data_dir, self.web_root,
            self.proxy_enabled, self.proxy_allow_hosts, self.token_ttl_secs, self.workers
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
