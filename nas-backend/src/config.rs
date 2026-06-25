use serde::Deserialize;
use std::env;
use std::fs;

/// Config: an optional JSON file (EJ_CONFIG, default /data/config.json) that is
/// then OVERRIDDEN by environment variables. Edit the file on the NAS volume +
/// restart the container to reconfigure — no rebuild. (Plan §3.2.)
#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct Config {
    pub jwt_secret: String,
    pub db_path: String,
    pub listen: String,
    pub cors_origins: Vec<String>,
    pub allow_registration: bool,
    pub proxy_enabled: bool,
    pub proxy_allow_hosts: Vec<String>,
    pub token_ttl_secs: u64,
    pub trust_proxy_header: bool,
    pub workers: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            jwt_secret: String::new(),
            db_path: "/data/ej.db".into(),
            listen: "0.0.0.0:48080".into(), // high port; avoids low-port clashes on a NAS
            cors_origins: Vec::new(),
            allow_registration: true,
            proxy_enabled: false,
            proxy_allow_hosts: Vec::new(),
            token_ttl_secs: 3600,
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
        if let Ok(v) = env::var("EJ_JWT_SECRET") {
            if !v.is_empty() {
                cfg.jwt_secret = v;
            }
        }
        if let Ok(v) = env::var("EJ_DB_PATH") {
            if !v.is_empty() {
                cfg.db_path = v;
            }
        }
        if let Ok(v) = env::var("EJ_LISTEN") {
            if !v.is_empty() {
                cfg.listen = v;
            }
        }
        if let Ok(v) = env::var("EJ_CORS_ORIGINS") {
            cfg.cors_origins = split_csv(&v);
        }
        if let Ok(v) = env::var("EJ_ALLOW_REGISTRATION") {
            cfg.allow_registration = boolish(&v);
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

        if cfg.jwt_secret.len() < 32 {
            return Err(format!(
                "EJ_JWT_SECRET must be set and >= 32 bytes (got {})",
                cfg.jwt_secret.len()
            ));
        }
        if cfg.token_ttl_secs == 0 {
            cfg.token_ttl_secs = 3600;
        }
        if cfg.workers == 0 {
            cfg.workers = 8;
        }
        Ok(cfg)
    }

    /// Log-safe summary (no secret).
    pub fn redacted(&self) -> String {
        format!(
            "listen={} db={} cors={:?} allowRegister={} proxy={} proxyHosts={:?} tokenTTL={}s workers={}",
            self.listen, self.db_path, self.cors_origins, self.allow_registration,
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
