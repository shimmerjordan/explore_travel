mod auth;
mod config;
mod proxy;
mod store;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use config::Config;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Read;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use store::{Store, StoreError};
use tiny_http::{Header, Method, Request, Response, Server};

const MAX_AUTH_BODY: u64 = 8 << 10; // 8 KiB
const MAX_VAULT_BODY: u64 = 256 << 10; // 256 KiB

struct AppState {
    cfg: Config,
    store: Mutex<Store>,
    limiter: Mutex<HashMap<String, (Instant, u32)>>,
    agent: ureq::Agent,
}

/// A fully-formed response, before CORS headers are layered on.
struct Out {
    status: u16,
    content_type: String,
    body: Vec<u8>,
    extra: Vec<(String, String)>,
}

impl Out {
    fn json(status: u16, v: Value) -> Out {
        Out {
            status,
            content_type: "application/json; charset=utf-8".into(),
            body: serde_json::to_vec(&v).unwrap_or_default(),
            extra: Vec::new(),
        }
    }
    fn bytes(status: u16, content_type: &str, body: Vec<u8>) -> Out {
        Out {
            status,
            content_type: content_type.into(),
            body,
            extra: Vec::new(),
        }
    }
    fn with(mut self, k: &str, v: &str) -> Out {
        self.extra.push((k.to_string(), v.to_string()));
        self
    }
}

fn main() {
    let cfg = match Config::load() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("config error: {e}");
            std::process::exit(1);
        }
    };
    let store = match Store::open(&cfg.db_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("open db: {e}");
            std::process::exit(1);
        }
    };
    println!("explore_journal NAS backend — {}", cfg.redacted());

    let listen = cfg.listen.clone();
    let workers = cfg.workers;
    let state = Arc::new(AppState {
        cfg,
        store: Mutex::new(store),
        limiter: Mutex::new(HashMap::new()),
        agent: proxy::safe_agent(),
    });

    let server = match Server::http(&listen) {
        Ok(s) => Arc::new(s),
        Err(e) => {
            eprintln!("listen on {listen}: {e}");
            std::process::exit(1);
        }
    };
    println!("listening on {listen}");

    let mut handles = Vec::new();
    for _ in 0..workers {
        let server = server.clone();
        let state = state.clone();
        handles.push(thread::spawn(move || loop {
            match server.recv() {
                Ok(req) => serve(&state, req),
                Err(_) => break,
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
}

fn header(req: &Request, name: &str) -> Option<String> {
    req.headers()
        .iter()
        .find(|h| h.field.to_string().eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str().to_string())
}

fn client_ip(state: &AppState, req: &Request) -> String {
    if state.cfg.trust_proxy_header {
        if let Some(xff) = header(req, "X-Forwarded-For") {
            return xff.split(',').next().unwrap_or("").trim().to_string();
        }
    }
    req.remote_addr()
        .map(|a| a.ip().to_string())
        .unwrap_or_default()
}

fn allow(state: &AppState, ip: &str, limit: u32) -> bool {
    let mut m = state.limiter.lock().unwrap();
    let now = Instant::now();
    let e = m.entry(ip.to_string()).or_insert((now, 0));
    if now.duration_since(e.0) > Duration::from_secs(60) {
        *e = (now, 1);
        return true;
    }
    if e.1 >= limit {
        return false;
    }
    e.1 += 1;
    true
}

fn cors_for(state: &AppState, origin: &Option<String>) -> Vec<(String, String)> {
    let mut v = Vec::new();
    if let Some(o) = origin {
        if state.cfg.cors_origins.iter().any(|a| a == o) {
            // Exact-origin echo only — never "*", never a prefix match.
            v.push(("Access-Control-Allow-Origin".into(), o.clone()));
            v.push(("Vary".into(), "Origin".into()));
            v.push(("Access-Control-Allow-Methods".into(), "GET,POST,PUT,OPTIONS".into()));
            v.push((
                "Access-Control-Allow-Headers".into(),
                "Authorization,Content-Type,If-Match,If-None-Match,X-Upstream-Authorization".into(),
            ));
            v.push(("Access-Control-Expose-Headers".into(), "ETag".into()));
            v.push(("Access-Control-Max-Age".into(), "600".into()));
        }
    }
    v
}

fn serve(state: &AppState, mut req: Request) {
    let method = match req.method() {
        Method::Get => "GET",
        Method::Post => "POST",
        Method::Put => "PUT",
        Method::Options => "OPTIONS",
        _ => "OTHER",
    }
    .to_string();

    let raw_url = req.url().to_string();
    let (path, query) = match raw_url.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (raw_url.clone(), String::new()),
    };
    let origin = header(&req, "Origin");
    let auth = header(&req, "Authorization");
    let if_match = header(&req, "If-Match");
    let if_none_match = header(&req, "If-None-Match");
    let upstream_auth = header(&req, "X-Upstream-Authorization");
    let accept = header(&req, "Accept");
    let ip = client_ip(state, &req);

    let cors = cors_for(state, &origin);

    // Preflight: answer OPTIONS before anything else. Logged so `docker logs`
    // shows whether the browser's CORS preflight is even reaching us, and
    // whether the Origin matched (corsOk).
    if method == "OPTIONS" {
        let cors_ok = !cors.is_empty();
        log_access(&ip, &method, &path, 204, &origin, cors_ok);
        respond(req, Out::bytes(204, "text/plain", Vec::new()), &cors);
        return;
    }

    // Rate limit (auth endpoints are tighter).
    let limit = if path.starts_with("/auth/") { 10 } else { 60 };
    if !allow(state, &ip, limit) {
        log_access(&ip, &method, &path, 429, &origin, !cors.is_empty());
        let out = Out::json(429, json!({"error":"rate limited"})).with("Retry-After", "60");
        respond(req, out, &cors);
        return;
    }

    // Read the body (capped) for methods that carry one.
    let max_body = if path == "/vault" { MAX_VAULT_BODY } else { MAX_AUTH_BODY };
    let mut body = Vec::new();
    if method == "POST" || method == "PUT" {
        let _ = req.as_reader().take(max_body + 1).read_to_end(&mut body);
        if body.len() as u64 > max_body {
            log_access(&ip, &method, &path, 413, &origin, !cors.is_empty());
            respond(req, Out::json(413, json!({"error":"body too large"})), &cors);
            return;
        }
    }

    let out = route(state, &method, &path, &query, &body, &auth, &if_match,
                    &if_none_match, &upstream_auth, &accept);
    log_access(&ip, &method, &path, out.status, &origin, !cors.is_empty());
    respond(req, out, &cors);
}

/// One access-log line per request → visible in `docker logs ejnas`. Includes
/// the request Origin and whether it matched the CORS allowlist (corsOk), the
/// #1 thing to check when a browser request "fails" with no server error.
fn log_access(ip: &str, method: &str, path: &str, status: u16, origin: &Option<String>, cors_ok: bool) {
    println!(
        "{ip} {method} {path} -> {status} (origin={}, corsOk={})",
        origin.as_deref().unwrap_or("-"),
        cors_ok
    );
}

#[allow(clippy::too_many_arguments)]
fn route(
    state: &AppState,
    method: &str,
    path: &str,
    query: &str,
    body: &[u8],
    auth: &Option<String>,
    if_match: &Option<String>,
    if_none_match: &Option<String>,
    upstream_auth: &Option<String>,
    accept: &Option<String>,
) -> Out {
    match (method, path) {
        ("GET", "/healthz") => Out::json(200, json!({"status":"ok"})),
        ("POST", "/auth/register") => handle_register(state, body),
        ("POST", "/auth/login") => handle_login(state, body),
        ("GET", "/auth/salt") => handle_salt(state, query),
        ("GET", "/auth/me") => match authed(state, auth) {
            Some(uid) => {
                let ver = state.store.lock().unwrap().vault_version(&uid).unwrap_or(0);
                Out::json(200, json!({"user_id": uid, "vault_version": ver}))
            }
            None => unauthorized(),
        },
        ("GET", "/vault") => match authed(state, auth) {
            Some(uid) => handle_get_vault(state, &uid, if_none_match),
            None => unauthorized(),
        },
        ("PUT", "/vault") => match authed(state, auth) {
            Some(uid) => handle_put_vault(state, &uid, body, if_match),
            None => unauthorized(),
        },
        ("GET", p) if p.starts_with("/proxy/gh/") => {
            guard_proxy(state, auth, |_uid| {
                handle_proxy_gh(state, &p["/proxy/gh/".len()..], upstream_auth, accept)
            })
        }
        ("GET", "/proxy/url") => {
            guard_proxy(state, auth, |_uid| {
                handle_proxy_url(state, query, upstream_auth, accept)
            })
        }
        _ => Out::json(404, json!({"error":"not found"})),
    }
}

fn unauthorized() -> Out {
    Out::json(401, json!({"error":"missing or invalid token"}))
}

fn authed(state: &AppState, auth: &Option<String>) -> Option<String> {
    let a = auth.as_ref()?;
    let tok = a.strip_prefix("Bearer ")?;
    auth::parse_jwt(&state.cfg.jwt_secret, tok).map(|c| c.sub)
}

fn guard_proxy<F: FnOnce(String) -> Out>(state: &AppState, auth: &Option<String>, f: F) -> Out {
    if !state.cfg.proxy_enabled {
        return Out::json(404, json!({"error":"not found"}));
    }
    match authed(state, auth) {
        Some(uid) => f(uid),
        None => unauthorized(),
    }
}

fn parse_body(body: &[u8]) -> Option<Value> {
    serde_json::from_slice(body).ok()
}

fn normalize_email(s: &str) -> String {
    s.trim().to_ascii_lowercase()
}

fn issue_session(state: &AppState, uid: &str, vault_version: i64) -> Out {
    match auth::mint_jwt(&state.cfg.jwt_secret, uid, state.cfg.token_ttl_secs) {
        Ok(tok) => Out::json(
            200,
            json!({"token": tok, "user_id": uid, "vault_version": vault_version}),
        ),
        Err(_) => Out::json(500, json!({"error":"token"})),
    }
}

fn handle_register(state: &AppState, body: &[u8]) -> Out {
    if !state.cfg.allow_registration {
        return Out::json(403, json!({"reason":"registration closed"}));
    }
    let Some(j) = parse_body(body) else {
        return Out::json(400, json!({"reason":"bad json"}));
    };
    let email = normalize_email(j.get("email").and_then(|v| v.as_str()).unwrap_or(""));
    let verifier = j
        .get("authVerifier")
        .and_then(|v| v.as_str())
        .and_then(|s| STANDARD.decode(s).ok());
    let salt = j.get("salt").and_then(|v| v.as_str()).unwrap_or("");
    let Some(verifier) = verifier else {
        return Out::json(400, json!({"reason":"malformed register"}));
    };
    if email.is_empty() || verifier.len() < 16 || salt.is_empty() {
        return Out::json(400, json!({"reason":"malformed register"}));
    }
    let store = state.store.lock().unwrap();
    match store.user_by_email(&email) {
        Ok(Some(_)) => return Out::json(409, json!({"reason":"email already registered"})),
        Ok(None) => {}
        Err(_) => return Out::json(500, json!({"reason":"db"})),
    }
    let phc = match auth::hash_verifier(&verifier) {
        Ok(h) => h,
        Err(_) => return Out::json(500, json!({"reason":"hash"})),
    };
    let id = auth::new_id();
    if store.create_user(&id, &email, &phc, salt).is_err() {
        return Out::json(500, json!({"reason":"create"}));
    }
    drop(store);
    issue_session(state, &id, 0)
}

fn handle_login(state: &AppState, body: &[u8]) -> Out {
    let Some(j) = parse_body(body) else {
        return Out::json(400, json!({"reason":"bad json"}));
    };
    let email = normalize_email(j.get("email").and_then(|v| v.as_str()).unwrap_or(""));
    let verifier = j
        .get("authVerifier")
        .and_then(|v| v.as_str())
        .and_then(|s| STANDARD.decode(s).ok());
    let Some(verifier) = verifier else {
        return Out::json(400, json!({"reason":"malformed login"}));
    };
    if email.is_empty() {
        return Out::json(400, json!({"reason":"malformed login"}));
    }
    let store = state.store.lock().unwrap();
    let user = match store.user_by_email(&email) {
        Ok(u) => u,
        Err(_) => return Out::json(500, json!({"reason":"db"})),
    };
    match user {
        Some(u) if auth::verify_verifier(&verifier, &u.pw_hash) => {
            let ver = store.vault_version(&u.id).unwrap_or(0);
            drop(store);
            issue_session(state, &u.id, ver)
        }
        Some(_) => Out::json(401, json!({"reason":"invalid credentials"})),
        None => {
            // Spend ~equal CPU so timing doesn't reveal account existence.
            auth::verify_verifier(&verifier, dummy_phc());
            Out::json(401, json!({"reason":"invalid credentials"}))
        }
    }
}

fn handle_salt(state: &AppState, query: &str) -> Out {
    let email = normalize_email(&query_get(query, "email").unwrap_or_default());
    if email.is_empty() {
        return Out::json(400, json!({"reason":"email required"}));
    }
    if let Ok(Some(u)) = state.store.lock().unwrap().user_by_email(&email) {
        return Out::json(200, json!({"salt": u.kdf_salt}));
    }
    // Unknown account → deterministic pseudo-salt (anti-enumeration).
    let mut h = Sha256::new();
    h.update(state.cfg.jwt_secret.as_bytes());
    h.update(b"salt:");
    h.update(email.as_bytes());
    let digest = h.finalize();
    Out::json(200, json!({"salt": STANDARD.encode(&digest[..16])}))
}

fn handle_get_vault(state: &AppState, uid: &str, if_none_match: &Option<String>) -> Out {
    match state.store.lock().unwrap().get_vault(uid) {
        Ok(Some((blob, version))) => {
            let etag = format!("\"{version}\"");
            if if_none_match.as_deref() == Some(etag.as_str()) {
                return Out::bytes(304, "application/octet-stream", Vec::new()).with("ETag", &etag);
            }
            Out::bytes(200, "application/octet-stream", blob).with("ETag", &etag)
        }
        Ok(None) => Out::json(404, json!({"error":"no vault"})).with("ETag", "\"0\""),
        Err(_) => Out::json(500, json!({"error":"db"})),
    }
}

fn handle_put_vault(state: &AppState, uid: &str, body: &[u8], if_match: &Option<String>) -> Out {
    let if_match_v: i64 = match if_match {
        Some(raw) => match raw.trim_matches('"').parse() {
            Ok(n) => n,
            Err(_) => return Out::json(400, json!({"error":"bad If-Match"})),
        },
        None => 0,
    };
    if body.is_empty() {
        return Out::json(400, json!({"error":"empty body"}));
    }
    match state.store.lock().unwrap().put_vault(uid, body, if_match_v) {
        Ok(version) => Out::json(200, json!({"version": version}))
            .with("ETag", &format!("\"{version}\"")),
        Err(StoreError::Conflict(cur)) => {
            Out::json(409, json!({"current_version": cur}))
        }
        Err(StoreError::Db(_)) => Out::json(500, json!({"error":"db"})),
    }
}

fn handle_proxy_gh(
    state: &AppState,
    rest: &str,
    upstream_auth: &Option<String>,
    accept: &Option<String>,
) -> Out {
    // rest = owner/repo/branch/<path...>
    let parts: Vec<&str> = rest.splitn(4, '/').collect();
    if parts.len() < 4 {
        return Out::json(400, json!({"error":"expected owner/repo/branch/path"}));
    }
    let enc_path: Vec<String> = parts[3]
        .split('/')
        .map(|seg| url_encode(seg))
        .collect();
    let target = format!(
        "https://raw.githubusercontent.com/{}/{}/{}/{}",
        url_encode(parts[0]),
        url_encode(parts[1]),
        url_encode(parts[2]),
        enc_path.join("/")
    );
    do_proxy(state, &target, upstream_auth, accept)
}

fn handle_proxy_url(
    state: &AppState,
    query: &str,
    upstream_auth: &Option<String>,
    accept: &Option<String>,
) -> Out {
    let Some(target) = query_get(query, "u") else {
        return Out::json(400, json!({"error":"missing u"}));
    };
    let host = match url_host(&target) {
        Some(h) => h,
        None => return Out::json(400, json!({"error":"bad url"})),
    };
    if !state.cfg.proxy_allow_hosts.iter().any(|h| h.eq_ignore_ascii_case(&host)) {
        return Out::json(403, json!({"error":"host not allowlisted"}));
    }
    do_proxy(state, &target, upstream_auth, accept)
}

fn do_proxy(
    state: &AppState,
    target: &str,
    upstream_auth: &Option<String>,
    accept: &Option<String>,
) -> Out {
    match proxy::fetch(&state.agent, target, upstream_auth.as_deref(), accept.as_deref()) {
        Some(f) => {
            let ct = f.content_type.unwrap_or_else(|| "application/octet-stream".into());
            Out::bytes(f.status, &ct, f.body).with("Cache-Control", "private, max-age=300")
        }
        None => Out::json(502, json!({"error":"upstream fetch failed or blocked"})),
    }
}

fn respond(req: Request, out: Out, cors: &[(String, String)]) {
    let mut resp = Response::from_data(out.body).with_status_code(out.status);
    if let Ok(h) = Header::from_bytes(b"Content-Type".as_ref(), out.content_type.as_bytes()) {
        resp = resp.with_header(h);
    }
    for (k, v) in cors.iter().chain(out.extra.iter()) {
        if let Ok(h) = Header::from_bytes(k.as_bytes(), v.as_bytes()) {
            resp = resp.with_header(h);
        }
    }
    let _ = req.respond(resp);
}

// ── tiny URL helpers ─────────────────────────────────────────────────────────

fn query_get(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k == key {
                return Some(url_decode(v));
            }
        }
    }
    None
}

fn url_host(u: &str) -> Option<String> {
    let after = u.split("://").nth(1)?;
    let authority = after.split(['/', '?', '#']).next()?;
    let hostport = authority.rsplit('@').next()?; // drop userinfo
    let host = if let Some(stripped) = hostport.strip_prefix('[') {
        stripped.split(']').next()? // IPv6 literal
    } else {
        hostport.split(':').next()?
    };
    if host.is_empty() {
        None
    } else {
        Some(host.to_string())
    }
}

/// Percent-encode one path segment (keep unreserved chars).
fn url_encode(seg: &str) -> String {
    let mut out = String::with_capacity(seg.len());
    for b in seg.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn url_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hi = (bytes[i + 1] as char).to_digit(16);
                let lo = (bytes[i + 2] as char).to_digit(16);
                if let (Some(h), Some(l)) = (hi, lo) {
                    out.push((h * 16 + l) as u8);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

// A fixed valid PHC, computed once, to keep unknown-email logins ~constant time.
use std::sync::OnceLock;
static DUMMY_PHC_CELL: OnceLock<String> = OnceLock::new();
fn dummy_phc() -> &'static str {
    DUMMY_PHC_CELL
        .get_or_init(|| {
            auth::hash_verifier(b"dummy-verifier-padding-0000000000").unwrap_or_default()
        })
        .as_str()
}
