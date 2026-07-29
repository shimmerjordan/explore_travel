mod admin_file;
mod auth;
mod config;
mod proxy;

use config::Config;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Read;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tiny_http::{Header, Method, Request, Response, Server};

const MAX_AUTH_BODY: u64 = 8 << 10; // 8 KiB
const MAX_VAULT_BODY: u64 = 256 << 10; // 256 KiB — kept for Task 8's payload-cap config reuse

struct AppState {
    cfg: Config,
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
    println!("explore_journal NAS backend — {}", cfg.redacted());

    let listen = cfg.listen.clone();
    let workers = cfg.workers;
    let state = Arc::new(AppState {
        cfg,
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

    let out = route(state, &method, &path, &query, &upstream_auth, &accept);
    log_access(&ip, &method, &path, out.status, &origin, !cors.is_empty());
    respond(req, out, &cors);
}

/// One access-log line per request → visible in `docker logs web-front`. Includes
/// the request Origin and whether it matched the CORS allowlist (corsOk), the
/// #1 thing to check when a browser request "fails" with no server error.
fn log_access(ip: &str, method: &str, path: &str, status: u16, origin: &Option<String>, cors_ok: bool) {
    println!(
        "{ip} {method} {path} -> {status} (origin={}, corsOk={})",
        origin.as_deref().unwrap_or("-"),
        cors_ok
    );
}

fn route(
    state: &AppState,
    method: &str,
    path: &str,
    query: &str,
    upstream_auth: &Option<String>,
    accept: &Option<String>,
) -> Out {
    match (method, path) {
        ("GET", "/healthz") => Out::json(200, json!({"status":"ok"})),
        ("GET", p) if p.starts_with("/proxy/gh/") => {
            guard_proxy(state, || {
                handle_proxy_gh(state, &p["/proxy/gh/".len()..], upstream_auth, accept)
            })
        }
        ("GET", "/proxy/url") => {
            guard_proxy(state, || handle_proxy_url(state, query, upstream_auth, accept))
        }
        _ => Out::json(404, json!({"error":"not found"})),
    }
}

/// Gate a proxy call on the config toggle. Single-admin session auth will be
/// layered back in here once `AppState` grows a `sessions`/`admin` field.
fn guard_proxy<F: FnOnce() -> Out>(state: &AppState, f: F) -> Out {
    if !state.cfg.proxy_enabled {
        return Out::json(404, json!({"error":"not found"}));
    }
    f()
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
