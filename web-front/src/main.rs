mod admin_file;
mod auth;
mod config;
mod proxy;
mod session;

use admin_file::AdminFile;
use config::Config;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Read;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tiny_http::{Header, Method, Request, Response, Server};

// Only /api/* routes carry a request body today (POST /api/session, PUT
// /api/password), and both payloads are small JSON objects -- proxy routes
// are GET-only. Task 8's config storage may introduce its own, larger cap
// when it adds a body-carrying config endpoint.
const MAX_API_BODY: u64 = 8 << 10; // 8 KiB

struct AppState {
    cfg: Config,
    limiter: Mutex<HashMap<String, (Instant, u32)>>,
    agent: ureq::Agent,
    sessions: session::Sessions,
    admin: Mutex<AdminFile>,
}

/// A fully-formed response.
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
    println!("explore_journal web-front — {}", cfg.redacted());

    let listen = cfg.listen.clone();
    let workers = cfg.workers;

    let data_dir = std::path::PathBuf::from(&cfg.data_dir);
    if let Err(e) = std::fs::create_dir_all(&data_dir) {
        eprintln!("failed to create data dir {}: {e}", data_dir.display());
        std::process::exit(1);
    }
    let admin = match admin_file::load_or_init(&data_dir) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("admin file error: {e}");
            std::process::exit(1);
        }
    };
    let sessions = session::Sessions::new(cfg.token_ttl_secs);

    let state = Arc::new(AppState {
        sessions,
        admin: Mutex::new(admin),
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

/// Extract the session token from a request: `Authorization: Bearer <token>`
/// takes priority (native/mobile clients), falling back to the `ej_session`
/// cookie (the browser client).
fn session_token(req: &Request) -> Option<String> {
    if let Some(auth) = header(req, "Authorization") {
        if let Some(tok) = auth.strip_prefix("Bearer ") {
            let tok = tok.trim();
            if !tok.is_empty() {
                return Some(tok.to_string());
            }
        }
    }
    if let Some(cookie) = header(req, "Cookie") {
        for part in cookie.split(';') {
            if let Some(v) = part.trim().strip_prefix("ej_session=") {
                if !v.is_empty() {
                    return Some(v.to_string());
                }
            }
        }
    }
    None
}

fn has_valid_session(state: &AppState, req: &Request) -> bool {
    session_token(req)
        .map(|t| state.sessions.get_key(&t).is_some())
        .unwrap_or(false)
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

/// Rate limit `ip` within `bucket`. `bucket` keeps the counter for `/api/*`
/// (tight cap, brute-force resistance on the credential checks) separate
/// from the counter for everything else (looser cap) -- sharing one counter
/// across both would let a burst of ordinary requests exhaust the `/api/*`
/// budget and lock the admin out of logging in.
fn allow(state: &AppState, ip: &str, bucket: &str, limit: u32) -> bool {
    let mut m = state.limiter.lock().unwrap();
    let now = Instant::now();
    let key = format!("{ip}|{bucket}");
    let e = m.entry(key).or_insert((now, 0));
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

fn serve(state: &AppState, mut req: Request) {
    let method = match req.method() {
        Method::Get => "GET",
        Method::Post => "POST",
        Method::Put => "PUT",
        Method::Delete => "DELETE",
        _ => "OTHER",
    }
    .to_string();

    let raw_url = req.url().to_string();
    let (path, query) = match raw_url.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (raw_url.clone(), String::new()),
    };
    let ip = client_ip(state, &req);

    // /api/* (login, logout, password change) gets its own, tighter-capped
    // counter -- brute-force resistance on the credential checks -- kept
    // separate from the general-route counter (see `allow`'s doc comment).
    let (bucket, limit) = if path.starts_with("/api/") { ("api", 10) } else { ("other", 60) };
    if !allow(state, &ip, bucket, limit) {
        log_access(&ip, &method, &path, 429);
        let out = Out::json(429, json!({"error":"rate limited"})).with("Retry-After", "60");
        respond(req, out);
        return;
    }

    // Read the body (capped) for methods that carry one. Today that's only
    // POST /api/session and PUT /api/password; both fit comfortably under
    // MAX_API_BODY.
    let mut body = Vec::new();
    if method == "POST" || method == "PUT" {
        let _ = req.as_reader().take(MAX_API_BODY + 1).read_to_end(&mut body);
        if body.len() as u64 > MAX_API_BODY {
            log_access(&ip, &method, &path, 413);
            respond(req, Out::json(413, json!({"error":"body too large"})));
            return;
        }
    }

    let out = route(state, &req, &method, &path, &query, &body);
    log_access(&ip, &method, &path, out.status);
    respond(req, out);
}

/// One access-log line per request → visible in `docker logs web-front`.
fn log_access(ip: &str, method: &str, path: &str, status: u16) {
    println!("{ip} {method} {path} -> {status}");
}

fn route(state: &AppState, req: &Request, method: &str, path: &str, query: &str, body: &[u8]) -> Out {
    match (method, path) {
        ("GET", "/healthz") => Out::json(200, json!({"status":"ok"})),
        ("POST", "/api/session") => handle_login(state, body),
        ("DELETE", "/api/session") => handle_logout(state, req),
        ("PUT", "/api/password") => handle_change_password(state, req, body),
        ("GET", p) if p.starts_with("/proxy/gh/") => {
            guard_proxy(state, req, || handle_proxy_gh(state, req, &p["/proxy/gh/".len()..]))
        }
        ("GET", "/proxy/url") => {
            guard_proxy(state, req, || handle_proxy_url(state, req, query))
        }
        _ => Out::json(404, json!({"error":"not found"})),
    }
}

/// Gate a proxy call on BOTH the config toggle and a valid admin session.
/// Without the session check, `/proxy/gh/*` and `/proxy/url` are an open
/// relay to any allowlisted host for anyone who can reach this port.
fn guard_proxy<F: FnOnce() -> Out>(state: &AppState, req: &Request, f: F) -> Out {
    if !state.cfg.proxy_enabled {
        return Out::json(404, json!({"error":"not found"}));
    }
    if !has_valid_session(state, req) {
        return Out::json(401, json!({"error":"unauthorized"}));
    }
    f()
}

#[derive(Deserialize)]
struct LoginBody {
    username: String,
    password: String,
}

/// `POST /api/session`: verify the admin credential and mint a session.
///
/// Failure is always a single undifferentiated 401 -- it never distinguishes
/// "unknown username" from "wrong password", so the response can't be used
/// to enumerate the (single, fixed) admin username.
fn handle_login(state: &AppState, body: &[u8]) -> Out {
    let req_body: LoginBody = match serde_json::from_slice(body) {
        Ok(b) => b,
        Err(_) => return Out::json(400, json!({"error":"bad request"})),
    };

    let admin = state.admin.lock().unwrap();
    let ok = req_body.username == admin.username
        && auth::verify_password(&admin.password_phc, req_body.password.as_bytes());
    if !ok {
        return Out::json(401, json!({"error":"unauthorized"}));
    }

    let key_salt = match admin.key_salt() {
        Ok(k) => k,
        Err(e) => return Out::json(500, json!({"error": e})),
    };
    let key = match auth::derive_config_key(req_body.password.as_bytes(), &key_salt) {
        Ok(k) => k,
        Err(e) => return Out::json(500, json!({"error": e})),
    };
    let is_default = admin.is_default;
    drop(admin);

    let token = state.sessions.create(key);
    let ttl = state.cfg.token_ttl_secs;
    Out::json(
        200,
        json!({"ok": true, "is_default_password": is_default, "token": token}),
    )
    .with(
        "Set-Cookie",
        // Deliberately no `Secure` attribute: LAN access over plain HTTP is
        // this project's normal deployment mode (self-hosted NAS, no TLS),
        // and `Secure` would make browsers silently refuse to store the
        // cookie at all under http://, breaking login outright.
        &format!("ej_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age={ttl}"),
    )
}

/// `DELETE /api/session`: drop only the caller's own session (a sibling
/// session, e.g. a concurrently logged-in phone, is left untouched) and
/// clear the cookie.
fn handle_logout(state: &AppState, req: &Request) -> Out {
    if let Some(token) = session_token(req) {
        state.sessions.remove(&token);
    }
    Out::json(200, json!({"ok": true}))
        .with("Set-Cookie", "ej_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0")
}

#[derive(Deserialize)]
struct PasswordBody {
    old: String,
    new: String,
}

/// `PUT /api/password`: rotate the admin password.
///
/// Requires BOTH a valid session AND the correct `old` password -- knowing
/// `old` is capability-equivalent to being able to log in (see `POST
/// /api/session`), so this session check doesn't raise the bar on what an
/// attacker needs to know. It exists for defense in depth: without it, a
/// future logic bug in `verify_password`/`admin_file::save` would be
/// directly reachable by ANY unauthenticated network client, rather than
/// only by a client that already holds a session. The session check runs
/// FIRST, before touching `old` at all, so an unauthenticated caller never
/// even reaches the password-verification path.
///
/// SIMPLIFIED for Task 5: config storage doesn't exist yet, so this only
/// verifies `old`, writes the new PHC, clears `is_default`, and revokes every
/// existing session (every previously issued session key was derived from
/// the now-stale password, so keeping them alive would leak a key nothing
/// can use safely). Task 8 MUST extend this to decrypt the stored config
/// under the OLD derived key and re-encrypt it under the NEW one before
/// persisting -- otherwise existing config ciphertext becomes permanently
/// unreadable the moment the password changes.
fn handle_change_password(state: &AppState, req: &Request, body: &[u8]) -> Out {
    if !has_valid_session(state, req) {
        return Out::json(401, json!({"error":"unauthorized"}));
    }

    let req_body: PasswordBody = match serde_json::from_slice(body) {
        Ok(b) => b,
        Err(_) => return Out::json(400, json!({"error":"bad request"})),
    };
    if req_body.new.len() < 8 {
        return Out::json(400, json!({"error":"new password too short"}));
    }

    let mut admin = state.admin.lock().unwrap();
    if !auth::verify_password(&admin.password_phc, req_body.old.as_bytes()) {
        return Out::json(401, json!({"error":"unauthorized"}));
    }

    let new_phc = match auth::hash_password(req_body.new.as_bytes()) {
        Ok(p) => p,
        Err(e) => return Out::json(500, json!({"error": e})),
    };
    admin.password_phc = new_phc;
    admin.is_default = false;
    if let Err(e) = admin_file::save(Path::new(&state.cfg.data_dir), &admin) {
        return Out::json(500, json!({"error": e}));
    }
    drop(admin);

    state.sessions.revoke_all();
    Out::json(200, json!({"ok": true}))
}

fn handle_proxy_gh(state: &AppState, req: &Request, rest: &str) -> Out {
    // rest = owner/repo/branch/<path...>
    let parts: Vec<&str> = rest.splitn(4, '/').collect();
    if parts.len() < 4 {
        return Out::json(400, json!({"error":"expected owner/repo/branch/path"}));
    }
    let enc_path: Vec<String> = parts[3].split('/').map(url_encode).collect();
    let target = format!(
        "https://raw.githubusercontent.com/{}/{}/{}/{}",
        url_encode(parts[0]),
        url_encode(parts[1]),
        url_encode(parts[2]),
        enc_path.join("/")
    );
    do_proxy(state, req, &target)
}

fn handle_proxy_url(state: &AppState, req: &Request, query: &str) -> Out {
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
    do_proxy(state, req, &target)
}

fn do_proxy(state: &AppState, req: &Request, target: &str) -> Out {
    let upstream_auth = header(req, "X-Upstream-Authorization");
    let accept = header(req, "Accept");
    match proxy::fetch(&state.agent, target, upstream_auth.as_deref(), accept.as_deref()) {
        Some(f) => {
            let ct = f.content_type.unwrap_or_else(|| "application/octet-stream".into());
            Out::bytes(f.status, &ct, f.body).with("Cache-Control", "private, max-age=300")
        }
        None => Out::json(502, json!({"error":"upstream fetch failed or blocked"})),
    }
}

fn respond(req: Request, out: Out) {
    let mut resp = Response::from_data(out.body).with_status_code(out.status);
    if let Ok(h) = Header::from_bytes(b"Content-Type".as_ref(), out.content_type.as_bytes()) {
        resp = resp.with_header(h);
    }
    for (k, v) in out.extra.iter() {
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
