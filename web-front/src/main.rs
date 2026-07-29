mod admin_file;
mod atomic_file;
mod auth;
mod config;
mod config_store;
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

// POST /api/session and PUT /api/password bodies are small, fixed-shape JSON
// objects and share this tight cap. PUT /api/config carries the user's actual
// config (WebDAV credentials, tokens, etc.), which can be larger, so it uses
// `config_store::MAX_CONFIG_BYTES` instead -- see `body_cap` below.
const MAX_API_BODY: u64 = 8 << 10; // 8 KiB

/// Shared state. Three of these fields are locks, and they have a mandatory
/// acquisition order:
///
/// ```text
///     admin  →  config_write  →  sessions
/// ```
///
/// Every path that takes more than one MUST take them left to right, and any
/// new path must too -- an endpoint that reads the config and the admin
/// record together (e.g. an export/backup route) is the easy way to write the
/// reverse order by accident and deadlock against a concurrent password
/// change. Today's callers:
///
/// - `handle_change_password`: `admin` → `config_write` → `sessions`
///   (`revoke_all`), all three held together across re-encryption and commit.
/// - `handle_put_config`: `config_write` → `sessions` (`get_key`).
/// - `handle_login`: `admin` → `sessions` (`create`).
///
/// Note also that all of these are `.lock().unwrap()`, i.e. a panic while a
/// lock is held would poison it and make every later `unwrap` panic too. That
/// is deliberately not handled, and it is sound only because the release
/// profile sets `panic = "abort"` (see Cargo.toml): the first panic takes the
/// whole process down and Docker's `restart: unless-stopped` brings up a
/// fresh one, so a poisoned lock is unreachable in production. Do not
/// "improve" this into poison recovery -- continuing to serve requests after
/// a panic mid-way through a password change is strictly worse than dying.
struct AppState {
    cfg: Config,
    limiter: Mutex<HashMap<String, (Instant, u32)>>,
    agent: ureq::Agent,
    sessions: session::Sessions,
    admin: Mutex<AdminFile>,
    /// Serializes writers of `config.json`: `PUT /api/config`'s `save` and
    /// password-change's `reencrypt` both go through `config_store`, which
    /// writes via a shared, fixed `config.json.tmp` path with no locking of
    /// its own (see config_store.rs). Without this, two concurrent writers
    /// (e.g. two overlapping `PUT /api/config` calls, or one racing a
    /// password change) could interleave writes to that shared tmp path and
    /// have one of them silently lose its update.
    ///
    /// It guards more than the tmp path, though: it is also what makes a
    /// password change atomic with respect to config writes. A writer must
    /// hold this lock across BOTH the key lookup and the write, and a
    /// password change must hold it from `reencrypt` through `revoke_all`.
    /// See the comments in `handle_put_config` and
    /// `handle_change_password` -- getting that scope wrong lets a writer
    /// holding a pre-change key overwrite freshly re-encrypted ciphertext.
    ///
    /// Readers (`GET /api/config`) don't need to take this lock:
    /// `config_store::save`'s write-tmp-then-rename is atomic, so a
    /// concurrent read always observes a complete file, old or new, never a
    /// torn one.
    config_write: Mutex<()>,
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

/// A 500 whose *detail* stays on the server.
///
/// The internal error strings these handlers deal with are built for an
/// operator reading `docker logs`, and several of them embed absolute
/// filesystem paths (`write /data/admin.json.tmp: ...`) or library internals.
/// None of that helps the client and all of it hands an attacker free
/// reconnaissance about the container's layout, so the response body carries a
/// fixed, generic message and `detail` goes to the log only.
///
/// Errors that are safe AND useful to the caller -- currently just
/// `config_store::DECRYPT_ERR`, which is fixed text with no path in it and
/// tells the operator how to recover -- are returned directly with
/// `Out::json(500, ...)` instead of through here.
fn server_error(context: &str, detail: &str) -> Out {
    eprintln!("ERROR: {context}: {detail}");
    Out::json(500, json!({"error": "internal error"}))
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
        config_write: Mutex::new(()),
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

/// Which rate-limit bucket (and per-minute cap) a request counts against.
///
/// The split is by *what an attacker gains from repeating the request*, not by
/// URL prefix:
///
/// - `"auth"` (10/min) -- the two routes that check a credential and can be
///   attacked without already holding a session: login and password change.
///   The tight cap is the brute-force defence, and it's the only place a tight
///   cap buys anything.
/// - `"api"` (120/min) -- every other `/api/*` route. These all require a
///   valid session before they do anything, so hammering them is pointless
///   for an attacker but entirely normal for the real admin: the web client
///   fetches `/api/config` on load, writes it back on every settings change,
///   and the console polls its own endpoints. A 10/min cap here would throttle
///   ordinary use.
/// - `"other"` (60/min) -- everything that is neither of the above. Today that
///   is only `/healthz` and the two read-proxy routes. This number has NOT
///   been validated against the traffic shapes still to come: serving the
///   static web build means a cold page load spends tens of requests at once
///   (doubled by a hard refresh), and proxying map tiles or photos means one
///   pan across the map can spend a hundred. The cap for static and proxied
///   traffic must be re-evaluated -- most likely by splitting them into their
///   own bucket -- when static hosting is added, rather than assumed to fit.
///
/// Keeping `"auth"` in its own bucket is the load-bearing part: config reads
/// and writes must not be able to spend the login budget, or a client that
/// polls its config would lock the admin out of the login form -- which is
/// exactly what a single shared `/api/*` bucket did before this split.
fn bucket_for(method: &str, path: &str) -> (&'static str, u32) {
    match (method, path) {
        ("POST", "/api/session") | ("PUT", "/api/password") => ("auth", 10),
        (_, p) if p.starts_with("/api/") => ("api", 120),
        _ => ("other", 60),
    }
}

/// Rate limit `ip` within `bucket`: at most `limit` requests per rolling
/// 60-second window. Counters are per-(ip, bucket) and never share a budget,
/// so exhausting one can't spill over into another -- see `bucket_for` for
/// which routes land where, and why that isolation is what makes this safe.
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

    let (bucket, limit) = bucket_for(&method, &path);
    if !allow(state, &ip, bucket, limit) {
        log_access(&ip, &method, &path, 429);
        let out = Out::json(429, json!({"error":"rate limited"})).with("Retry-After", "60");
        respond(req, out);
        return;
    }

    // Read the body (capped) for methods that carry one. POST /api/session
    // and PUT /api/password use the small MAX_API_BODY cap; PUT /api/config
    // uses config_store::MAX_CONFIG_BYTES instead (see `body_cap`).
    let mut body = Vec::new();
    if method == "POST" || method == "PUT" {
        // PUT /api/config's cap is far larger than the others, so before
        // paying for that read, reject a missing/invalid session up front --
        // this check only needs the Authorization/Cookie header, not the
        // body. This both avoids reading a large payload that would be
        // rejected anyway, and makes 401 win over 413 when both would
        // apply, which is the check order this route promises: session
        // before size.
        if method == "PUT" && path == "/api/config" && !has_valid_session(state, &req) {
            log_access(&ip, &method, &path, 401);
            respond(req, Out::json(401, json!({"error":"unauthorized"})));
            return;
        }
        let cap = body_cap(&method, &path);
        // `take(cap + 1)` bounds how many bytes are ever pulled off the
        // socket -- an oversized body is never fully materialized in memory
        // just to be thrown away by the length check below.
        let _ = req.as_reader().take(cap + 1).read_to_end(&mut body);
        if body.len() as u64 > cap {
            log_access(&ip, &method, &path, 413);
            respond(req, Out::json(413, json!({"error":"body too large"})));
            return;
        }
    }

    let out = route(state, &req, &method, &path, &query, &body);
    log_access(&ip, &method, &path, out.status);
    respond(req, out);
}

/// Per-route cap on the request body `serve` reads before dispatch. Every
/// body-carrying route besides `PUT /api/config` shares the small,
/// fixed-shape `MAX_API_BODY` cap; `PUT /api/config` carries the user's
/// actual config JSON and gets the larger `config_store::MAX_CONFIG_BYTES`.
fn body_cap(method: &str, path: &str) -> u64 {
    if method == "PUT" && path == "/api/config" {
        config_store::MAX_CONFIG_BYTES as u64
    } else {
        MAX_API_BODY
    }
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
        ("GET", "/api/config") => handle_get_config(state, req),
        ("PUT", "/api/config") => handle_put_config(state, req, body),
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
        Err(e) => return server_error("login: decode key_salt", &e),
    };
    let key = match auth::derive_config_key(req_body.password.as_bytes(), &key_salt) {
        Ok(k) => k,
        Err(e) => return server_error("login: derive config key", &e),
    };
    let is_default = admin.is_default;

    // `create` runs while the `admin` lock is still held, and `drop(admin)`
    // comes after it -- not before. `handle_change_password` holds that same
    // lock from its credential check all the way through `revoke_all`, so
    // minting the session under it makes "this session was created before the
    // password changed" impossible: a login either completes entirely before
    // the change starts (and is then revoked by it), or waits and derives its
    // key from the new password. Dropping the lock first reopens a window
    // where a session minted with the OLD key lands in the table *after*
    // `revoke_all` has run, surviving the change while holding a key that no
    // longer matches the stored config.
    let token = state.sessions.create(key);
    drop(admin);
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
/// The config-encryption key is derived from the admin password (see
/// `auth::derive_config_key`), so changing the password means the stored
/// config -- if any -- must be re-encrypted from the old key to the new one.
/// `admin.json` (which password verifies) and `config.json` (which key the
/// ciphertext is under) therefore have to change *together*: any outcome where
/// one moved and the other didn't leaves the config permanently
/// undecryptable, because the old password no longer verifies (so its key
/// can't be re-derived by logging in) and the new password derives a key that
/// can't open ciphertext written under the old one. That is data loss, not a
/// failed request.
///
/// Two files can't be replaced in one atomic step, so the order below instead
/// pushes every fallible operation ahead of a single commit that is as close
/// to infallible as the filesystem allows:
///
///   1. validate the session (401)
///   2. validate `old` against the stored PHC (401)
///   3. validate `new`'s length (400)
///   4. derive `old_key` and `new_key` from the (now-verified) passwords
///   5. hash `new` and STAGE the new `admin.json` to `admin.json.tmp`
///      (`admin_file::write_tmp`): fsync'd, but the live file is untouched
///   6. `config_store::reencrypt(dir, &old_key, &new_key)`
///   7. COMMIT the staged file (`admin_file::commit_tmp`): a single
///      same-directory `rename` of already-fsync'd bytes
///   8. only now mutate the in-memory `AdminFile`
///   9. revoke every existing session
///
/// Steps 1-6 can all fail, and every one of them aborts with 500 while the
/// pair on disk is still consistent (before 6 nothing has changed at all;
/// during 6 `config_store::save` is itself atomic, and a `reencrypt` that
/// fails to decrypt has written nothing). Step 7 is what makes the change
/// real, and it is deliberately reduced to a rename so that the mundane
/// reasons a write fails -- ENOSPC, EACCES, a serialization error -- have
/// already been paid for in step 5. If step 7 nonetheless fails, the config
/// has already been re-encrypted, so the handler tries to roll that back to
/// `old_key` and reports *in the response and the log* whether the rollback
/// worked; that is the difference between "retry with the old password" and
/// "restore from backup", and an operator can't guess which without being
/// told.
///
/// Step 8's placement is not cosmetic either: mutating the in-memory record
/// before the commit succeeds would leave the process serving a password that
/// isn't the one on disk -- new password accepted, old password rejected, and
/// a restart flipping it back.
///
/// LOCKING: `admin` is held from step 2 (so the credential this decision was
/// based on can't change under us) and `config_write` from step 6 through step
/// 9, i.e. `reencrypt`, the commit and `revoke_all` are one indivisible unit.
/// `revoke_all` MUST be inside that scope: sessions minted before the change
/// hold the OLD key, and a `PUT /api/config` from one of them -- which takes
/// `config_write` too -- would otherwise slip in between `reencrypt` and the
/// revocation and rewrite `config.json` under the old key, silently undoing
/// step 6. Acquisition order is `admin` → `config_write` → `sessions`, the
/// global order documented on `AppState`.
fn handle_change_password(state: &AppState, req: &Request, body: &[u8]) -> Out {
    if !has_valid_session(state, req) {
        return Out::json(401, json!({"error":"unauthorized"}));
    }

    let req_body: PasswordBody = match serde_json::from_slice(body) {
        Ok(b) => b,
        Err(_) => return Out::json(400, json!({"error":"bad request"})),
    };

    let mut admin = state.admin.lock().unwrap();
    // Undifferentiated 401 -- same rationale as `handle_login`: never lets a
    // caller distinguish "wrong old password" from any other failure mode.
    if !auth::verify_password(&admin.password_phc, req_body.old.as_bytes()) {
        return Out::json(401, json!({"error":"unauthorized"}));
    }
    if req_body.new.len() < 8 {
        return Out::json(400, json!({"error":"new password too short"}));
    }

    let key_salt = match admin.key_salt() {
        Ok(k) => k,
        Err(e) => return server_error("password change: decode key_salt", &e),
    };
    let old_key = match auth::derive_config_key(req_body.old.as_bytes(), &key_salt) {
        Ok(k) => k,
        Err(e) => return server_error("password change: derive old config key", &e),
    };
    let new_key = match auth::derive_config_key(req_body.new.as_bytes(), &key_salt) {
        Ok(k) => k,
        Err(e) => return server_error("password change: derive new config key", &e),
    };
    let new_phc = match auth::hash_password(req_body.new.as_bytes()) {
        Ok(p) => p,
        Err(e) => return server_error("password change: hash new password", &e),
    };

    // The record we intend to commit. `admin` itself is left alone until the
    // commit has actually succeeded (step 8).
    let mut next = admin.clone();
    next.password_phc = new_phc;
    next.is_default = false;

    let dir = Path::new(&state.cfg.data_dir);

    // Step 5: stage admin.json. Nothing on disk changes yet, so any failure
    // here is a clean 500 -- the password and the config are both exactly as
    // they were.
    if let Err(e) = admin_file::write_tmp(dir, &next) {
        return server_error("password change: stage admin.json", &e);
    }

    // Steps 6-9 are one critical section; see the LOCKING note above.
    let _config_guard = state.config_write.lock().unwrap();

    // Step 6.
    if let Err(e) = config_store::reencrypt(dir, &old_key, &new_key) {
        // Drop the staged file: leaving it behind would hand a later commit a
        // new PHC that no config was ever re-encrypted for.
        let _ = std::fs::remove_file(admin_file::tmp_path(dir));
        if e == config_store::DECRYPT_ERR {
            // Safe to surface verbatim, and the only 500 here that tells the
            // operator something actionable -- see `config_store::DECRYPT_ERR`.
            eprintln!("ERROR: password change aborted: {e}");
            return Out::json(500, json!({"error": e}));
        }
        return server_error("password change: reencrypt config", &e);
    }

    // Step 7: the commit.
    if let Err(e) = admin_file::commit_tmp(dir) {
        // The config is now under `new_key` but `admin.json` still verifies
        // the OLD password, which is the one mismatch we cannot leave behind.
        // Put the ciphertext back the way it was.
        match config_store::reencrypt(dir, &new_key, &old_key) {
            Ok(()) => {
                eprintln!(
                    "ERROR: password change: failed to commit admin.json ({e}); \
                     re-encrypted config back to the old password successfully. \
                     Password is UNCHANGED and the config is readable with it -- \
                     fix the cause (see the error above; check the data directory's \
                     permissions and free space) and retry the change."
                );
                Out::json(500, json!({"error":
                    "password change failed while committing; it was rolled back \
                     cleanly -- your password is unchanged and the stored config is \
                     still readable with it. Retry after checking the server log."}))
            }
            Err(rollback_err) => {
                eprintln!(
                    "ERROR: password change: failed to commit admin.json ({e}) AND failed \
                     to roll the config back to the old key ({rollback_err}). The stored \
                     config is now encrypted under the NEW password while admin.json still \
                     verifies the OLD one -- logging in with the old password will not be \
                     able to read the config. Recover by restoring config.json from backup, \
                     or by overwriting it with a fresh PUT /api/config after logging in with \
                     the old password."
                );
                Out::json(500, json!({"error":
                    "password change failed while committing and could NOT be rolled back: \
                     the password is unchanged but the stored config is no longer readable \
                     with it. Overwrite the config with a fresh PUT /api/config to recover, \
                     and check the server log."}))
            }
        }
    } else {
        // Step 8: on-disk state is now the new password; make the process
        // agree with it.
        *admin = next;
        // Step 9, still inside the `config_write` critical section.
        state.sessions.revoke_all();
        Out::json(200, json!({"ok": true}))
    }
}

/// `GET /api/config`: return the caller's decrypted config JSON verbatim.
///
/// `config_store::load` returning `Ok(None)` means no config has ever been
/// pushed -- a normal, common first-run state, not an error -- so the
/// response is `200 {}`, not a 404 or 500. `Err` is `config_store`'s single,
/// deliberately undifferentiated `DECRYPT_ERR` (see that module's doc comment
/// for why it must not be differentiated, and why its fixed text is safe to
/// return verbatim) and is passed through unchanged, not rewrapped here.
///
/// Every response carries `Cache-Control: no-store`. The whole point of this
/// endpoint is that the config is encrypted at rest, and the body here is the
/// decrypted form of it -- WebDAV password, OneDrive/GitHub/AI tokens, in
/// cleartext. Letting a browser write that to its own on-disk HTTP cache would
/// undo the encryption at the other end of the wire: an attacker with the
/// user's laptop wouldn't need the admin password at all. `nosniff` rides
/// along because this hands back a body whose bytes the client supplied.
fn handle_get_config(state: &AppState, req: &Request) -> Out {
    let key = match session_token(req).and_then(|t| state.sessions.get_key(&t)) {
        Some(k) => k,
        None => return no_store(Out::json(401, json!({"error":"unauthorized"}))),
    };
    let dir = Path::new(&state.cfg.data_dir);
    no_store(match config_store::load(dir, &key) {
        Ok(None) => Out::json(200, json!({})),
        Ok(Some(plaintext)) => Out::bytes(200, "application/json; charset=utf-8", plaintext),
        Err(e) => Out::json(500, json!({"error": e})),
    })
}

/// Mark a response as never-cacheable. See `handle_get_config`.
fn no_store(out: Out) -> Out {
    out.with("Cache-Control", "no-store")
        .with("X-Content-Type-Options", "nosniff")
}

/// `PUT /api/config`: encrypt and persist the caller's config JSON verbatim.
///
/// By the time this runs, `serve` has already: rejected a missing/invalid
/// session (401) and enforced the `config_store::MAX_CONFIG_BYTES` size cap
/// (413) via a bounded read, in that order. What's left here is checking
/// that the body actually parses as a JSON *object* (not an array, string,
/// number, bool, or null) before it's handed to `config_store::save` --
/// `config_store` stores opaque bytes and has no opinion on their shape, so
/// this is the only place that would ever catch a malformed payload.
///
/// The `config_write` lock is taken BEFORE the session's key is looked up, and
/// that order is load-bearing rather than incidental. The key this handler
/// writes with is the one derived at login from the password in effect *then*.
/// A concurrent password change re-encrypts `config.json` to a new key and
/// revokes every session in one `config_write` critical section, so looking
/// the key up inside the lock is what makes the two mutually exclusive: this
/// handler either gets the lock first (and the password change's `reencrypt`
/// then correctly re-encrypts what was just written) or waits, and by the time
/// it wakes up `revoke_all` has run, its token is gone, and it returns 401
/// instead of overwriting fresh ciphertext with a stale key. Hoisting the
/// lookup back above the lock reintroduces exactly that overwrite: the token
/// was still valid when it was read, so the handler proceeds with a key the
/// stored config is no longer encrypted under, and the config becomes
/// unreadable with the new password. Note this is an ordinary collision (the
/// phone pushing settings while the console changes the password), not an
/// attack that needs a hostile client.
fn handle_put_config(state: &AppState, req: &Request, body: &[u8]) -> Out {
    // Serialize against other `PUT /api/config` calls and against
    // password-change's `reencrypt`/`revoke_all` -- see the doc comment on
    // `AppState::config_write`, and the paragraph above on why the key lookup
    // belongs under this lock.
    let _guard = state.config_write.lock().unwrap();

    let key = match session_token(req).and_then(|t| state.sessions.get_key(&t)) {
        Some(k) => k,
        None => return Out::json(401, json!({"error":"unauthorized"})),
    };
    match serde_json::from_slice::<Value>(body) {
        Ok(Value::Object(_)) => {}
        _ => return Out::json(400, json!({"error":"config must be a JSON object"})),
    }

    let dir = Path::new(&state.cfg.data_dir);
    match config_store::save(dir, &key, body) {
        Ok(()) => Out::json(200, json!({"ok": true})),
        Err(e) => server_error("put config: save", &e),
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The property that matters: the two credential-checking routes are the
    /// ONLY ones in the tight bucket, and session-gated `/api/*` routes are in
    /// a separate, looser one. If someone widens `"auth"` back to all of
    /// `/api/*`, the config assertions below fail.
    #[test]
    fn credential_routes_are_the_only_tightly_capped_ones() {
        assert_eq!(bucket_for("POST", "/api/session"), ("auth", 10));
        assert_eq!(bucket_for("PUT", "/api/password"), ("auth", 10));

        for (m, p) in [
            ("GET", "/api/config"),
            ("PUT", "/api/config"),
            ("DELETE", "/api/session"), // logout checks a session, not a password
            ("GET", "/api/metrics"),    // an unrouted /api/* path lands here too
        ] {
            let (bucket, limit) = bucket_for(m, p);
            assert_eq!(bucket, "api", "{m} {p} must not share the login budget");
            assert!(limit > 10, "{m} {p} cap {limit} is too tight for normal use");
        }

        assert_eq!(bucket_for("GET", "/healthz").0, "other");
        assert_eq!(bucket_for("GET", "/proxy/gh/a/b/c/d").0, "other");
        assert_eq!(bucket_for("GET", "/index.html").0, "other");
    }

    /// Buckets must not share a counter: spending one to exhaustion has to
    /// leave the others untouched. This is what keeps a config-polling client
    /// from locking the admin out of the login form.
    #[test]
    fn exhausting_one_bucket_leaves_the_others_alone() {
        let state = AppState {
            cfg: config::Config::default(),
            limiter: Mutex::new(HashMap::new()),
            agent: proxy::safe_agent(),
            sessions: session::Sessions::new(60),
            admin: Mutex::new(AdminFile {
                v: 1,
                username: "admin".into(),
                password_phc: String::new(),
                key_salt_b64: String::new(),
                is_default: true,
            }),
            config_write: Mutex::new(()),
        };

        // Drain "api" completely.
        for _ in 0..120 {
            assert!(allow(&state, "1.2.3.4", "api", 120));
        }
        assert!(!allow(&state, "1.2.3.4", "api", 120), "api bucket should be spent");

        // Login still works for that same IP...
        assert!(allow(&state, "1.2.3.4", "auth", 10), "auth budget must be independent");
        // ...and a different IP is unaffected in the drained bucket.
        assert!(allow(&state, "5.6.7.8", "api", 120), "buckets must be per-IP");
    }
}
