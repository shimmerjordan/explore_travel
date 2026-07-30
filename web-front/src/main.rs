mod admin_file;
mod atomic_file;
mod auth;
mod config;
mod config_store;
mod dashboard;
mod dav;
mod export;
mod metrics;
mod proxy;
mod session;
mod static_files;

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
use tiny_http::{Header, Request, Response, Server};

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
    limiter: Mutex<Limiter>,
    agent: ureq::Agent,
    /// Separate from `agent` because the two proxies must NOT share an address
    /// predicate: see `proxy::is_lan_or_public_ip` for why a LAN WebDAV host
    /// has to be reachable while `/proxy/url` must keep refusing private
    /// ranges.
    dav_agent: ureq::Agent,
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
    /// Request counters. Holds a mutex of its own, but a *leaf* one: nothing
    /// in `metrics` acquires another lock, so it is outside the order above
    /// and can be taken anywhere.
    ///
    /// The other half of "leaf" has to be maintained here, not there: never
    /// take this lock while holding one of the three above. Both credential
    /// checks (`handle_login`, `handle_change_password`) therefore `drop(admin)`
    /// before counting their 401. Nothing deadlocks if you forget -- metrics
    /// takes nothing else -- but the moment one call site nests it, "metrics is
    /// a leaf" stops being checkable by reading this list and becomes something
    /// the next person has to audit every call site to believe.
    metrics: metrics::Metrics,
    /// When this process started, for the uptime the console shows. An
    /// `Instant` rather than a wall-clock time because it is monotonic: a
    /// clock correction (NTP step on a NAS that just got its network back)
    /// must not make uptime jump or go negative.
    // The console's metrics endpoint reads this back as `uptime_secs`.
    started: Instant,
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

    let sample_interval = Duration::from_secs(cfg.metrics_interval_secs);
    let state = Arc::new(AppState {
        sessions,
        admin: Mutex::new(admin),
        cfg,
        limiter: Mutex::new(Limiter::new()),
        agent: proxy::safe_agent(),
        dav_agent: proxy::lan_agent(),
        config_write: Mutex::new(()),
        metrics: metrics::Metrics::load_or_new(data_dir.clone()),
        started: Instant::now(),
    });

    spawn_metrics_sampler(state.clone(), sample_interval);

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

/// Start the metrics sampler: one detached thread that appends a point to the
/// ring every `interval`, and rewrites `metrics.json` every
/// `PERSIST_EVERY_SAMPLES` of those.
///
/// The two cadences are separate on purpose. The ring is what the console
/// graphs, so it must gain a point per interval; the file only has to be recent
/// enough that a restart doesn't lose history worth caring about. Writing on
/// every sample meant rewriting the whole ~160 KB document (plus two fsyncs)
/// once a minute forever -- see `PERSIST_EVERY_SAMPLES` for the arithmetic and
/// what is being traded.
///
/// Detached on purpose -- it is never joined, so it cannot hold up process
/// exit. Docker sends SIGTERM and the process dies with whatever the last
/// written file said; a partial window of counters is not worth a shutdown
/// handshake.
///
/// It also must not be able to take the service down with it. `persist`
/// returns its error instead of unwrapping (a full or read-only volume logs a
/// warning and the loop keeps sampling in memory), and the body does nothing
/// else that can fail: no indexing, no parsing, no `unwrap` on anything but
/// the metrics mutex, whose only failure mode is poisoning by an earlier panic
/// -- which the release profile's `panic = "abort"` makes unreachable (see
/// `AppState`).
fn spawn_metrics_sampler(state: Arc<AppState>, interval: Duration) {
    thread::spawn(move || {
        // Counts samples since the last write, so the first write lands one
        // full persist period in rather than immediately.
        let mut since_write: u32 = 0;
        loop {
            // Sleep first: sampling at t=0 would only record an empty process.
            thread::sleep(interval);
            state.metrics.take_sample();
            since_write += 1;
            if since_write >= metrics::PERSIST_EVERY_SAMPLES {
                since_write = 0;
                if let Err(e) = state.metrics.persist() {
                    eprintln!("WARN: metrics persist failed: {e}");
                }
            }
        }
    });
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
/// The split is by *what an attacker gains from repeating the request*
/// crossed with *how the route is actually used*, not by URL prefix alone:
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
/// - `"healthz"` (120/min) -- the liveness probe, in its own bucket separate
///   from every kind of user traffic. A monitor polls at a fixed interval
///   regardless of how busy the console is, so sharing a budget with
///   static/proxy traffic would let a page-load storm starve the health
///   check -- making the container look unhealthy purely because someone
///   else is using it. 120/min is generous for any sane probe interval (a
///   1-second interval is 60/min).
/// - `"proxy"` (600/min) -- `/proxy/gh/*` and `/proxy/url`. These already
///   require a valid admin session (`guard_proxy`), so the cap here isn't a
///   brute-force defence -- it bounds how hard one browser tab can hammer an
///   upstream host (GitHub, a WebDAV server, ...) through this process,
///   since paging through photos or dragging a map across fog tiles can fire
///   a request per tile. 600/min (10/sec) covers that comfortably without
///   leaving the upstream connection effectively uncapped.
/// - `"static"` (1200/min) -- every other `GET`, i.e. the web build served at
///   the bottom of `route`. This traffic is a local disk read with no
///   credential and no upstream dependency, so it's the one bucket that can
///   be sized for the *shape* of the traffic instead of for abuse
///   resistance: a cold Flutter web load is 20-30 requests, a hard refresh
///   doubles that, and a few concurrent tabs behind the same NAT'd IP stack
///   on top of it -- 1200/min (20/sec) leaves headroom over all of that at
///   once.
/// - `"other"` (60/min) -- everything that matched none of the above, which
///   after the `GET` arm above means non-`GET` methods on unrouted paths
///   (`POST /foo`, `DELETE /foo`, `OPTIONS /anything`). `route` answers all
///   of them with a 404, but `serve` reads a capped body off the socket for
///   `POST`/`PUT` before it gets there, so these are NOT free to repeat. They
///   must not inherit the static bucket's 1200/min: nothing legitimate sends
///   them at all, so the tight cap costs a real client nothing. Restricting
///   the wide bucket to `GET` is what keeps this arm from being dead code --
///   with a bare `_ =>` catch-all for static, an unauthenticated `POST` flood
///   was landing in the 1200/min bucket.
///
/// Keeping `"auth"` in its own bucket remains the load-bearing part: config
/// reads and writes must not be able to spend the login budget, or a client
/// that polls its config would lock the admin out of the login form -- which
/// is exactly what a single shared `/api/*` bucket did before that split.
///
/// `HEAD` never reaches here as itself: `serve` maps it onto `GET` before
/// calling this, so a `HEAD` for a static asset is billed to `"static"` like
/// the `GET` it mirrors.
fn bucket_for(method: &str, path: &str) -> (&'static str, u32) {
    match (method, path) {
        ("POST", "/api/session") | ("PUT", "/api/password") => ("auth", 10),
        (_, p) if p.starts_with("/api/") => ("api", 120),
        ("GET", "/healthz") => ("healthz", 120),
        // The console shell is the ONE route answered without a session, and it
        // is ~50 KB of compiled-in HTML. Left in the catch-all it would inherit
        // 1200/min, i.e. roughly 60 MB/min of unauthenticated egress per IP.
        // A human opens this page a handful of times; a scanner does not.
        ("GET", "/admin") => ("console", 60),
        (_, p) if p.starts_with("/proxy/") => ("proxy", 600),
        ("GET", _) => ("static", 1200),
        _ => ("other", 60),
    }
}

/// Rolling window for the rate limiter, and the staleness threshold used by
/// `sweep_expired` -- an entry whose window has fully elapsed carries no
/// information worth keeping.
const LIMITER_WINDOW: Duration = Duration::from_secs(60);

/// A sweep is only considered once the limiter table holds more than this
/// many tracked `(ip, bucket)` keys. A flat size threshold (rather than
/// "sweep every Nth call") means a slow trickle of distinct keys gets swept
/// just as reliably as a burst, and it keeps the common case -- well under
/// this many active keys -- from ever paying an O(n) scan.
///
/// Note the check runs *before* the insert, so the steady state parks at
/// THRESHOLD+1 resident entries even if every one of them has expired: at
/// 512 the sweep doesn't run, and the 513th key is inserted without one.
/// That is deliberate, not an oversight -- 513 entries is roughly 50 KB and
/// not worth a scan. This is a size ceiling on when scanning *starts*, not a
/// promise that an expired entry is removed promptly.
const LIMITER_SWEEP_THRESHOLD: usize = 512;

/// Minimum time between two sweeps, whatever the table size.
///
/// The size threshold alone is not a bound on sweep *frequency*, only on
/// table size, and the difference is remotely exploitable. `retain` can only
/// drop entries whose window has fully elapsed, so a caller that mints N
/// distinct keys inside one window leaves the table holding N entries that
/// are all still live: every subsequent request then re-scans all N of them
/// under the global mutex and frees nothing, turning an O(1) `allow` into
/// O(n) for every worker at once. That is reachable without a session --
/// with `EJ_TRUST_PROXY=1` the key comes from `X-Forwarded-For`, which the
/// client picks (see `allow`) -- and it measurably collapses throughput
/// (~24k req/s at 10k keys, ~280 req/s at 500k).
///
/// Gating on elapsed time caps the cost at one scan per interval no matter
/// how the table got big. Half the window is the natural value: anything
/// worth reclaiming has to have sat idle for a full `LIMITER_WINDOW`, so
/// sweeping more often than twice per window cannot free more memory, and
/// sweeping less often would let the table carry more than a window's worth
/// of dead keys. The cost is that the table can grow for up to half a window
/// between scans, i.e. the resident bound is ~1.5 windows of distinct keys
/// instead of ~1 -- a constant factor, paid to make the scan itself
/// unreachable as an amplification lever.
const LIMITER_MIN_SWEEP_INTERVAL: Duration = Duration::from_secs(LIMITER_WINDOW.as_secs() / 2);

/// The rate limiter's whole state, behind one mutex: the per-`(ip, bucket)`
/// counters plus when they were last swept. `last_sweep` has to live next to
/// the map rather than in a separate lock -- the decision to sweep reads both
/// the size and the timestamp, and they must be consistent with each other.
struct Limiter {
    counters: HashMap<String, (Instant, u32)>,
    last_sweep: Instant,
}

impl Limiter {
    fn new() -> Limiter {
        Limiter {
            counters: HashMap::new(),
            last_sweep: Instant::now(),
        }
    }
}

/// Remove every `(ip, bucket)` counter whose window has fully elapsed as of
/// `now`. Pulled out as a pure function over an explicit `now` so a test can
/// simulate "long after" without waiting on the wall clock: `Instant`
/// supports plain `Duration` arithmetic, so a later point can be constructed
/// directly (`now + Duration::from_secs(...)`) instead of introducing a
/// mockable clock abstraction just for this.
fn sweep_expired(m: &mut HashMap<String, (Instant, u32)>, now: Instant, window: Duration) {
    m.retain(|_, (seen, _)| now.duration_since(*seen) <= window);
}

/// Rate limit `ip` within `bucket`: at most `limit` requests per rolling
/// 60-second window. Counters are per-(ip, bucket) and never share a budget,
/// so exhausting one can't spill over into another -- see `bucket_for` for
/// which routes land where, and why that isolation is what makes this safe.
///
/// With `EJ_TRUST_PROXY=1` (the frp/Cloudflare deployment default) the key is
/// derived from `X-Forwarded-For`, a header the client fully controls -- a
/// caller that varies it on every request mints a fresh table entry each
/// time. Without eviction those entries were never removed, only reset in
/// place once their window passed, so the table grew for as long as the
/// process ran. `sweep_expired`, triggered once the table is big enough to
/// matter AND not more often than `LIMITER_MIN_SWEEP_INTERVAL`, is what
/// bounds it -- both conditions are load-bearing, see each constant's doc.
fn allow(state: &AppState, ip: &str, bucket: &str, limit: u32) -> bool {
    let mut l = state.limiter.lock().unwrap();
    let now = Instant::now();

    if l.counters.len() > LIMITER_SWEEP_THRESHOLD
        && now.duration_since(l.last_sweep) >= LIMITER_MIN_SWEEP_INTERVAL
    {
        sweep_expired(&mut l.counters, now, LIMITER_WINDOW);
        // Stamped even when the sweep freed nothing. That is the point: a
        // table full of live keys must not re-scan on the next request just
        // because it is still over the size threshold.
        l.last_sweep = now;
    }

    let key = format!("{ip}|{bucket}");
    let e = l.counters.entry(key).or_insert((now, 0));
    if now.duration_since(e.0) > LIMITER_WINDOW {
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
    // The method verbatim, uppercased -- NOT collapsed into a known-methods
    // enum. The WebDAV proxy needs `PROPFIND` and `OPTIONS` to survive as
    // themselves: folding every unrecognised verb into one `"OTHER"` bucket
    // erased the method before routing ever saw it, so a PROPFIND could not be
    // routed at all, only 404'd. Uppercasing means a lowercase verb can't slip
    // past a match arm; an unknown verb still falls through to the unrouted
    // arm exactly as before, it just does so under its own name (and shows up
    // that way in the access log, which is strictly more useful when
    // diagnosing a client).
    let method = req.method().as_str().to_ascii_uppercase();

    let raw_url = req.url().to_string();
    let (path, query) = match raw_url.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (raw_url.clone(), String::new()),
    };
    let ip = client_ip(state, &req);

    // A `HEAD` is a `GET` whose body is discarded, so it is routed and rate
    // limited as one -- anything this server answers with a `GET` must answer
    // the same headers to a `HEAD`, which is what uptime probes and reverse
    // proxies send by default. Falling into the unrouted arm instead produced
    // `HEAD / -> 404` next to `GET / -> 200`.
    //
    // The body is deliberately still built and NOT cleared here: tiny_http
    // suppresses it on the wire for `HEAD` (`Request::respond` passes
    // `do_not_send_body = method == Head`) while still emitting the
    // `Content-Length`/`Transfer-Encoding` the `GET` would have used, which
    // is exactly the required behaviour. Emptying `out.body` ourselves would
    // instead advertise `Content-Length: 0` and lie about the resource. The
    // cost is that a `HEAD` reads the file it will not send; the alternative
    // is a second response path that can drift from the `GET` one.
    let routed_method = if method == "HEAD" { "GET" } else { method.as_str() };

    let (bucket, limit) = bucket_for(routed_method, &path);
    if !allow(state, &ip, bucket, limit) {
        let out = Out::json(429, json!({"error":"rate limited"})).with("Retry-After", "60");
        finish(state, req, &ip, &method, &path, out);
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
            let out = Out::json(401, json!({"error":"unauthorized"}));
            finish(state, req, &ip, &method, &path, out);
            return;
        }
        let cap = body_cap(&method, &path);
        // `take(cap + 1)` bounds how many bytes are ever pulled off the
        // socket -- an oversized body is never fully materialized in memory
        // just to be thrown away by the length check below.
        let _ = req.as_reader().take(cap + 1).read_to_end(&mut body);
        if body.len() as u64 > cap {
            let out = Out::json(413, json!({"error":"body too large"}));
            finish(state, req, &ip, &method, &path, out);
            return;
        }
    }

    let out = route(state, &req, routed_method, &path, &query, &body);
    finish(state, req, &ip, &method, &path, out);
}

/// The single exit from `serve`: log the request, count it, send it.
///
/// Every early return above funnels through here rather than logging and
/// responding on its own. When those three steps were spelled out per exit,
/// each new observability concern had to be added in four places, and the
/// exits most worth watching -- the 429 and the 413, i.e. exactly the ones
/// that fire when something is going wrong -- were the easiest to miss.
///
/// The send is inlined here rather than kept as its own `respond(req, out)`
/// helper, and that is the point: consuming the `Request` is the only way to
/// answer it, so with no other function willing to take one by value, a future
/// exit *cannot* be written that skips the log and the counter. Had `respond`
/// survived as a callable function, `respond(req, out); return;` would compile,
/// pass the end-to-end suites (they assert status codes), and only show up as
/// one missing `docker logs` line. Same technique as `Persisted` and
/// `write_json` below in metrics.rs: make the wrong state unrepresentable
/// instead of documenting it.
///
/// `method` is the verb the client actually sent, not the one the request was
/// routed as, so `HEAD /` and `GET /` stay distinguishable in the log; that is
/// the pre-existing `log_access` format and operators read it in
/// `docker logs`, so it is unchanged.
fn finish(state: &AppState, req: Request, ip: &str, method: &str, path: &str, out: Out) {
    log_access(ip, method, path, out.status);
    // Body length, not bytes on the wire: response headers aren't counted, and
    // a `HEAD` is billed for the body tiny_http suppresses (see the routing
    // note above). Both are knowingly approximate -- this number exists to
    // show which routes move data, and a second accounting path just to make
    // `HEAD` exact would be more machinery than the answer is worth.
    state
        .metrics
        .record_access(path, out.status, out.body.len() as u64, ip);

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
        ("GET", "/api/metrics") => handle_metrics(state, req),
        ("GET", "/api/export") => handle_export(state, req, query),
        // Any read verb under this prefix. Must sit above the static fallback,
        // and above the `/proxy/` JSON-404 arm, or a PROPFIND would never
        // reach it.
        (m, p) if p.starts_with("/proxy/dav/") || p == "/proxy/dav" => {
            let rest = p.strip_prefix("/proxy/dav").unwrap_or("");
            guard_proxy(state, req, || handle_dav(state, req, m, rest, body))
        }
        // The console is a page, so it deliberately does NOT require a session
        // to be served -- it renders its own login form and then talks to the
        // session-gated endpoints. Serving the shell unauthenticated leaks
        // nothing (it is a constant compiled into the binary) and is what lets
        // an operator reach the login form at all.
        ("GET", "/admin") => no_cache_html(dashboard::DASHBOARD_HTML),
        ("GET", p) if p.starts_with("/proxy/gh/") => {
            guard_proxy(state, req, || handle_proxy_gh(state, req, &p["/proxy/gh/".len()..]))
        }
        ("GET", "/proxy/url") => {
            guard_proxy(state, req, || handle_proxy_url(state, req, query))
        }
        // Anything left under these two prefixes is a missing *endpoint*, not
        // a missing page, and must 404 as JSON instead of falling through to
        // the SPA shell below. Without this arm the catch-all served
        // `text/html` with a 200 for `GET /api/anything`, so a client that
        // called an endpoint this server doesn't implement yet (or misspelled
        // one) got a JSON parse error pointing at `<!doctype html>` rather
        // than a 404 -- and a "not logged in" check against such a route
        // would read as success. No SPA deep link lives under `/api/` or
        // `/proxy/`, so nothing legitimate is caught here.
        ("GET", p) if p.starts_with("/api/") || p.starts_with("/proxy/") => {
            Out::json(404, json!({"error":"not found"}))
        }
        ("GET", p) => handle_static(state, req, p),
        _ => Out::json(404, json!({"error":"not found"})),
    }
}

/// Fall back to the static web build for any `GET` that didn't match a route
/// above. This has to sit at the very bottom of `route`'s match, after every
/// `/api/*`, `/proxy/*` and `/healthz` arm, so none of those can be shadowed
/// by a same-named static asset.
fn handle_static(state: &AppState, req: &Request, path: &str) -> Out {
    let root = Path::new(&state.cfg.web_root);
    let if_none_match = header(req, "If-None-Match");
    match static_files::serve(root, path, if_none_match.as_deref()) {
        static_files::Served::File { bytes, mime, etag } => Out::bytes(200, mime, bytes)
            .with("Cache-Control", static_cache_control(path, mime))
            .with("ETag", &etag)
            .with("X-Content-Type-Options", "nosniff"),
        // A 304 carries no body but must repeat the caching headers, or the
        // client has nothing to refresh its cache entry's freshness with and
        // revalidates again on the very next request.
        static_files::Served::NotModified { etag, mime } => Out::bytes(304, mime, Vec::new())
            .with("Cache-Control", static_cache_control(path, mime))
            .with("ETag", &etag)
            .with("X-Content-Type-Options", "nosniff"),
        static_files::Served::NotConfigured => {
            if expects_a_page(path) {
                Out::bytes(
                    200,
                    "text/html; charset=utf-8",
                    static_files::SETUP_HTML.as_bytes().to_vec(),
                )
                // `no-store`, not just `no-cache`: this page is a transient
                // description of a misconfiguration, and once the operator
                // fixes the mount the page must not be what a reload shows.
                .with("Cache-Control", "no-store")
                .with("X-Content-Type-Options", "nosniff")
            } else {
                Out::json(404, json!({"error":"not found"})).with("X-Content-Type-Options", "nosniff")
            }
        }
        static_files::Served::NotFound => {
            Out::json(404, json!({"error":"not found"})).with("X-Content-Type-Options", "nosniff")
        }
    }
}

/// Whether a request that found no web build at all should get the setup page
/// instead of a 404.
///
/// Answering the setup page for *every* path is worse than a 404 for the
/// paths that aren't pages. The case that bites: the build was mounted once,
/// a browser installed `flutter_service_worker.js`, then a reboot lost the
/// bind mount. The service worker's update check fetches `/version.json`, and
/// handing it a 200 full of HTML fails that check with an unrelated JSON
/// parse error -- the app keeps running from its cache and nothing anywhere
/// says the mount is gone. A 404 is a signal the client can act on.
///
/// The test is "does the last segment look like a filename": a Flutter build
/// asks for `/version.json`, `/canvaskit/canvaskit.wasm`,
/// `/flutter_service_worker.js` -- all with extensions -- while `/` and SPA
/// deep links like `/settings/sync` have none and are genuinely expecting a
/// page.
fn expects_a_page(path: &str) -> bool {
    let last = path.rsplit('/').next().unwrap_or("");
    last.is_empty() || !last.contains('.')
}

/// Which `Cache-Control` a served static asset gets.
///
/// `index.html` is the SPA shell -- every route in the app, including one
/// this server only reached by falling back to it (see
/// `static_files::serve`), ends up serving those exact bytes -- so it's
/// identified by MIME (`text/html`) rather than by the literal request path:
/// a deep link like `/some/route` serves the same shell and must get the
/// same treatment, or a stale shell would keep pointing at assets from the
/// previous deploy. `flutter_service_worker.js` is the other file that must
/// never be cached -- it's how the app discovers a new deploy at all -- and
/// it's matched by name since its own MIME type doesn't distinguish it from
/// any other script. Every other asset in a Flutter web build is
/// content-hashed, so a long `max-age` is safe: a new deploy gets new
/// filenames rather than overwriting bytes an old cache entry already points
/// at.
///
/// Matching on MIME does mean any *other* `.html` in the build -- a hand
/// written `about.html`, say -- also gets `no-cache`. A Flutter build has no
/// second HTML file, and `no-cache` on a rarely-changing page costs one
/// conditional request that the `ETag` answers with a 304, so the false
/// positive is cheaper than the alternative failure (a cached shell pointing
/// at a previous deploy's assets).
fn static_cache_control(path: &str, mime: &str) -> &'static str {
    if mime == "text/html; charset=utf-8" || path.ends_with("/flutter_service_worker.js") {
        "no-cache"
    } else {
        "public, max-age=3600"
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
        // Release `admin` before touching the metrics mutex. Not a deadlock
        // risk (metrics is a leaf lock and takes nothing else), but keeping
        // the nesting one-directional is what lets that stay a checkable
        // property instead of a comment.
        drop(admin);
        state.metrics.record_login_failure();
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
        // Counted as a login failure, like `handle_login`'s 401. `bucket_for`
        // already treats `POST /api/session` and `PUT /api/password` as one
        // `("auth", 10)` bucket because they are the same kind of credential
        // check; a brute-force run against this endpoint has to show up in the
        // same counter, or the console reads zero while it happens.
        //
        // `admin` is released first: the metrics mutex is a leaf lock and
        // taking it under `admin` would be the one place in the process where
        // it is not, which is the property `AppState` claims.
        drop(admin);
        state.metrics.record_login_failure();
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
/// `GET /admin`: the operator console shell.
///
/// `no-cache` rather than a long `max-age`: the page is compiled into the
/// binary, so its version is the image's version, and a stale copy in the
/// browser after a container upgrade would be a console that disagrees with
/// the `/api/metrics` shape it is reading. Revalidation is one request against
/// a host the operator is already talking to.
fn no_cache_html(html: &str) -> Out {
    Out::bytes(200, "text/html; charset=utf-8", html.as_bytes().to_vec())
        .with("Cache-Control", "no-cache")
        .with("X-Content-Type-Options", "nosniff")
}

/// `GET /api/metrics`: the console's data source.
///
/// `no_store` is not optional here: the snapshot carries the recent-access
/// ring, and that ring carries client IPs. Letting it into a shared browser
/// cache would persist visitor addresses on disk for exactly the surface whose
/// whole point is that they stay in memory (see `metrics::snapshot_json`).
///
/// `is_default_password` rides along rather than living on its own endpoint so
/// the console cannot show a stale "all good" after a password change: every
/// poll re-reads it.
fn handle_metrics(state: &AppState, req: &Request) -> Out {
    if !has_valid_session(state, req) {
        return no_store(Out::json(401, json!({"error":"unauthorized"})));
    }
    let uptime = state.started.elapsed().as_secs();
    let mut doc = state.metrics.snapshot_json(uptime, metrics::rss_mb());
    let is_default = state.admin.lock().unwrap().is_default;
    if let Some(obj) = doc.as_object_mut() {
        obj.insert("is_default_password".into(), json!(is_default));
    }
    no_store(Out::json(200, doc))
}

/// `GET /api/export`: hand the operator their own data back as a download.
///
/// Three artifacts, selected by `what`, all behind a session. The one decision
/// that matters here is that `secrets=1` is the ONLY way to get cleartext
/// credentials out -- see `export::wants_secrets`. That path is also the only
/// one that logs, because "someone pulled every cloud credential off this box"
/// is exactly the line an operator wants to find afterwards, and the access log
/// alone cannot distinguish it from the scrubbed download.
fn handle_export(state: &AppState, req: &Request, query: &str) -> Out {
    let key = match session_token(req).and_then(|t| state.sessions.get_key(&t)) {
        Some(k) => k,
        None => return no_store(Out::json(401, json!({"error":"unauthorized"}))),
    };
    let what = match export::what(query) {
        Some(w) => w,
        None => {
            return no_store(Out::json(
                400,
                json!({"error":"what must be one of config, metrics, all"}),
            ))
        }
    };
    let secrets = export::wants_secrets(query);

    // Reading the config is the expensive/failable half, so only do it for the
    // two artifacts that contain one.
    let config = if what == "config" || what == "all" {
        match config_store::load(Path::new(&state.cfg.data_dir), &key) {
            Ok(bytes) => {
                let mut doc = export::config_doc(bytes);
                if !secrets {
                    export::scrub(&mut doc);
                }
                Some(doc)
            }
            Err(e) if e == config_store::DECRYPT_ERR => {
                return no_store(Out::json(500, json!({"error": e})))
            }
            Err(e) => return server_error("export: load config", &e),
        }
    } else {
        None
    };

    if secrets && config.is_some() {
        eprintln!(
            "AUDIT: cleartext credential export (what={what}) served to a valid session from {}",
            client_ip(state, req)
        );
    }

    // `snapshot_shareable_json`, never `snapshot_json`: the latter carries the
    // recent-access ring, and that ring carries client IPs. An export is by
    // definition a file that leaves this machine.
    let metrics = || {
        state
            .metrics
            .snapshot_shareable_json(state.started.elapsed().as_secs(), metrics::rss_mb())
    };

    let (body, mime) = match what.as_str() {
        "config" => (
            serde_json::to_vec_pretty(&config.unwrap_or_else(|| json!({}))).unwrap_or_default(),
            "application/json; charset=utf-8",
        ),
        "metrics" => (
            export::metrics_csv(&metrics()).into_bytes(),
            "text/csv; charset=utf-8",
        ),
        "all" => (
            serde_json::to_vec_pretty(&export::bundle(
                config.unwrap_or_else(|| json!({})),
                metrics(),
            ))
            .unwrap_or_default(),
            "application/json; charset=utf-8",
        ),
        _ => {
            return no_store(Out::json(
                400,
                json!({"error":"what must be one of config, metrics, all"}),
            ))
        }
    };

    no_store(Out::bytes(200, mime, body)).with(
        "Content-Disposition",
        &export::attachment(export::filename(&what, secrets)),
    )
}

/// `GET|HEAD|PROPFIND|OPTIONS /proxy/dav/<path>`: read the user's own WebDAV
/// through this server, because the browser cannot.
///
/// The order of the checks below is the security design, not an accident:
/// session first (so an unauthenticated caller learns nothing, not even
/// whether WebDAV is configured), then method (so a write verb is refused
/// before any config is decrypted), then config, then path confinement. Each
/// step's failure is a different status precisely so an operator can tell
/// "not logged in" from "not configured" from "that path is not allowed".
fn handle_dav(state: &AppState, req: &Request, method: &str, rest: &str, body: &[u8]) -> Out {
    let key = match session_token(req).and_then(|t| state.sessions.get_key(&t)) {
        Some(k) => k,
        None => return no_store(Out::json(401, json!({"error":"unauthorized"}))),
    };
    if !dav::ALLOWED_METHODS.contains(&method) {
        return no_store(Out::json(
            405,
            json!({"error":"this proxy is read-only", "allowed": dav::ALLOWED_METHODS}),
        ))
        .with("Allow", &dav::ALLOWED_METHODS.join(", "));
    }

    let cfg = match dav::load_config(Path::new(&state.cfg.data_dir), &key) {
        Ok(Some(v)) => v,
        Ok(None) => return no_store(Out::json(409, json!({"error": DAV_UNCONFIGURED}))),
        Err(e) if e == config_store::DECRYPT_ERR => {
            return no_store(Out::json(500, json!({"error": e})))
        }
        Err(e) => return server_error("dav: load config", &e),
    };
    let dc = match dav::dav_config(&cfg) {
        Some(c) => c,
        None => return no_store(Out::json(409, json!({"error": DAV_UNCONFIGURED}))),
    };

    let target = match dav::resolve_target(&dc.base, rest) {
        Ok(t) => t,
        Err(why) => return no_store(Out::json(403, json!({"error": why}))),
    };
    let depth_hdr = header(req, "Depth");
    let depth = match dav::depth_or_default(depth_hdr.as_deref()) {
        Ok(d) => d,
        Err(why) => return no_store(Out::json(400, json!({"error": why}))),
    };

    let relayed = dav::relay(
        &state.dav_agent,
        method,
        &target,
        dav::basic_auth(&dc.user, &dc.pass).as_deref(),
        (method == "PROPFIND").then_some(depth),
        header(req, "Range").as_deref(),
        body,
    );
    match relayed {
        None => no_store(Out::json(
            502,
            json!({"error":"the WebDAV server did not answer"}),
        )),
        Some(r) => {
            let mime = r
                .headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case("Content-Type"))
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| "application/octet-stream".into());
            let mut out = Out::bytes(r.status, &mime, r.body);
            for (k, v) in r.headers {
                // Content-Type is already the response's own; re-adding it
                // would emit the header twice.
                if !k.eq_ignore_ascii_case("Content-Type")
                    && !k.eq_ignore_ascii_case("Content-Length")
                {
                    out = out.with(&k, &v);
                }
            }
            no_store(out)
        }
    }
}

/// One message for "no WebDAV to talk to", whether that is a missing config or
/// a config without a usable URL. The distinction is invisible to the caller
/// and the fix is the same, so telling them apart would only invite guessing.
const DAV_UNCONFIGURED: &str = "no WebDAV server is configured; push the app's \
settings to this server first (phone: 备份 → Web 前端 · 配置推送)";

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

    fn test_state() -> AppState {
        AppState {
            cfg: config::Config::default(),
            limiter: Mutex::new(Limiter::new()),
            agent: proxy::safe_agent(),
            dav_agent: proxy::lan_agent(),
            sessions: session::Sessions::new(60),
            admin: Mutex::new(AdminFile {
                v: 1,
                username: "admin".into(),
                password_phc: String::new(),
                key_salt_b64: String::new(),
                is_default: true,
            }),
            config_write: Mutex::new(()),
            metrics: metrics::Metrics::new(std::env::temp_dir().join("wf-main-tests")),
            started: Instant::now(),
        }
    }

    /// The property that matters: the two credential-checking routes are the
    /// ONLY ones in the tight bucket, and every other route -- session-gated
    /// `/api/*`, the health probe, the proxy, and the static build -- is in
    /// one of the separate, looser buckets. If someone widens `"auth"` back
    /// to all of `/api/*`, or folds another route back into it, the
    /// assertions below fail.
    #[test]
    fn credential_routes_are_the_only_tightly_capped_ones() {
        assert_eq!(bucket_for("POST", "/api/session"), ("auth", 10));
        assert_eq!(bucket_for("PUT", "/api/password"), ("auth", 10));

        for (m, p) in [
            ("GET", "/api/config"),
            ("PUT", "/api/config"),
            ("DELETE", "/api/session"), // logout checks a session, not a password
            ("GET", "/api/metrics"),    // an unrouted /api/* path lands here too
            ("GET", "/healthz"),
            ("GET", "/proxy/gh/a/b/c/d"),
            ("GET", "/proxy/url"),
            ("GET", "/index.html"),
            ("GET", "/"),
        ] {
            let (bucket, limit) = bucket_for(m, p);
            assert_ne!(bucket, "auth", "{m} {p} must not share the login/password budget");
            assert!(limit > 10, "{m} {p} cap {limit} is too tight for normal use");
        }

        // Each of those lands in its own bucket, not lumped together --
        // otherwise a page-load storm could starve the health probe, or
        // static traffic could starve the proxy.
        assert_eq!(bucket_for("GET", "/healthz").0, "healthz");
        // The unauthenticated console page gets its own, deliberately tight
        // bucket -- not the catch-all's 1200/min. It is ~50 KB of compiled-in
        // HTML served with no session, so cheap repetition is pure egress.
        let (cb, cl) = bucket_for("GET", "/admin");
        assert_eq!(cb, "console");
        assert!(cl <= 120, "an unauthenticated 50 KB page must not be cheap to hammer");
        assert_eq!(bucket_for("GET", "/proxy/gh/a/b/c/d").0, "proxy");
        assert_eq!(bucket_for("GET", "/proxy/url").0, "proxy");
        assert_eq!(bucket_for("GET", "/index.html").0, "static");
        assert_eq!(bucket_for("GET", "/").0, "static");
        assert_eq!(bucket_for("GET", "/api/config").0, "api");
    }

    /// The wide static bucket is for `GET`s only. An unrouted non-`GET`
    /// (`POST /foo`, `DELETE /foo`, an `OPTIONS` preflight) is answered with a
    /// 404, but `serve` still reads a capped body off the socket for
    /// `POST`/`PUT` first, and nothing legitimate sends any of them -- so they
    /// belong in the tight bucket, not in the 1200/min one a bare `_ =>`
    /// catch-all was handing them.
    #[test]
    fn unrouted_non_get_requests_do_not_get_the_static_budget() {
        for (m, p) in [
            ("POST", "/foo"),
            ("PUT", "/foo"),
            ("DELETE", "/foo"),
            ("OTHER", "/foo"), // OPTIONS/PATCH/... all fold into "OTHER"
            ("OTHER", "/"),
        ] {
            assert_eq!(
                bucket_for(m, p),
                ("other", 60),
                "{m} {p} must not inherit the static bucket"
            );
        }
        // ...while the GET side of the same paths keeps the wide budget.
        assert_eq!(bucket_for("GET", "/foo"), ("static", 1200));
    }

    /// Buckets must not share a counter: spending one to exhaustion has to
    /// leave the others untouched. This is what keeps a config-polling client
    /// from locking the admin out of the login form.
    #[test]
    fn exhausting_one_bucket_leaves_the_others_alone() {
        let state = test_state();

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

    /// A cold Flutter web load alone is 20-30 requests; this pins the
    /// concrete number the static bucket must absorb without a 429. Against
    /// the old shared `("other", 60)` bucket this passes too in isolation
    /// (40 < 60) -- what actually catches a regression back to a shared
    /// bucket is the end-to-end script, which runs this alongside the other
    /// static-serving checks on the same IP; see its own notes on why.
    #[test]
    fn forty_consecutive_static_requests_are_not_rate_limited() {
        let state = test_state();
        let (bucket, limit) = bucket_for("GET", "/index.html");
        assert_eq!(bucket, "static");
        for i in 0..40 {
            assert!(allow(&state, "9.9.9.9", bucket, limit), "request {i} should not be limited");
        }
    }

    /// Without eviction, a table entry is only ever reset in place once its
    /// window passes -- never removed -- so distinct keys accumulate for as
    /// long as the process runs (see `allow`'s doc comment on
    /// `X-Forwarded-For` under `EJ_TRUST_PROXY=1`). This drives `sweep_expired`
    /// directly rather than through `allow`, so it can simulate "long after"
    /// by constructing a later `Instant` instead of waiting on the real clock.
    #[test]
    fn limiter_table_is_swept_once_windows_elapse() {
        let mut m: HashMap<String, (Instant, u32)> = HashMap::new();
        let base = Instant::now();
        for i in 0..500 {
            m.insert(format!("ip-{i}|static"), (base, 1));
        }
        assert_eq!(m.len(), 500);

        // Sweeping before the window has elapsed must not touch anything --
        // otherwise this test would pass even with a sweep that just clears
        // the whole table unconditionally.
        sweep_expired(&mut m, base, LIMITER_WINDOW);
        assert_eq!(m.len(), 500, "entries still inside their window must survive a sweep");

        let later = base + LIMITER_WINDOW + Duration::from_secs(1);
        sweep_expired(&mut m, later, LIMITER_WINDOW);
        assert_eq!(m.len(), 0, "entries whose window fully elapsed must be swept");
    }

    /// Build a limiter state that a sweep *should* act on: `n` keys whose
    /// windows elapsed long ago, and a `last_sweep` far enough back that the
    /// interval gate is open. Returns `false` if this platform can't construct
    /// a past `Instant`, in which case the caller skips rather than asserting
    /// on a state it failed to set up.
    fn backdate_limiter(state: &AppState, n: usize, stamp_last_sweep_in_the_past: bool) -> bool {
        let Some(long_ago) = Instant::now().checked_sub(Duration::from_secs(120)) else {
            return false;
        };
        let mut l = state.limiter.lock().unwrap();
        for i in 0..n {
            l.counters.insert(format!("10.0.{}.{}|static", i / 250, i % 250), (long_ago, 1));
        }
        if stamp_last_sweep_in_the_past {
            l.last_sweep = long_ago;
        }
        true
    }

    /// `limiter_table_is_swept_once_windows_elapse` drives `sweep_expired`
    /// directly, so it proves the sweep *function* works while saying nothing
    /// about whether anything calls it -- deleting the call in `allow`
    /// outright leaves it green. This one goes through `allow`, which is the
    /// only thing that ever triggers eviction in production.
    #[test]
    fn allow_evicts_expired_entries_when_the_table_is_large() {
        let state = test_state();
        if !backdate_limiter(&state, 600, true) {
            eprintln!(
                "SKIP allow_evicts_expired_entries_when_the_table_is_large: \
                 Instant::checked_sub returned None on this platform, so a limiter \
                 state with elapsed windows cannot be constructed without sleeping \
                 for a real minute"
            );
            return;
        }

        assert!(allow(&state, "9.9.9.9", "static", 1200));

        let n = state.limiter.lock().unwrap().counters.len();
        assert_eq!(
            n, 1,
            "allow must evict the 600 elapsed entries and keep only the new one, got {n}"
        );
    }

    /// The other half of the eviction contract: a sweep that just ran must
    /// not run again on the next request merely because the table is still
    /// over the size threshold. Without the interval gate, a caller who mints
    /// enough distinct `X-Forwarded-For` values inside one window makes every
    /// later request re-scan a table where nothing is evictable yet -- an
    /// unauthenticated way to turn `allow` into an O(n) scan under the global
    /// mutex. Here the entries ARE evictable and the sweep still must not
    /// run, which is what pins the gate rather than the size check.
    #[test]
    fn allow_does_not_sweep_twice_within_the_interval() {
        let state = test_state();
        if !backdate_limiter(&state, 600, false) {
            eprintln!(
                "SKIP allow_does_not_sweep_twice_within_the_interval: \
                 Instant::checked_sub returned None on this platform"
            );
            return;
        }
        // `test_state` stamped `last_sweep` at construction, i.e. just now.
        assert!(allow(&state, "9.9.9.9", "static", 1200));

        let n = state.limiter.lock().unwrap().counters.len();
        assert_eq!(
            n, 601,
            "a sweep ran again inside LIMITER_MIN_SWEEP_INTERVAL; the table size \
             threshold alone does not bound how often the O(n) scan happens (got {n})"
        );
    }

    /// `NotConfigured` may only answer with the setup page for requests that
    /// are asking for a page. Everything a Flutter build fetches by filename
    /// -- above all `version.json`, which the installed service worker polls
    /// to discover new deploys -- has to get a 404 instead of 200 HTML.
    #[test]
    fn only_page_requests_get_the_setup_html() {
        for p in ["/", "/settings/sync", "/deep/link"] {
            assert!(expects_a_page(p), "{p} is a page request");
        }
        for p in [
            "/version.json",
            "/flutter_service_worker.js",
            "/canvaskit/canvaskit.wasm",
            "/assets/AssetManifest.bin.json",
            "/favicon.png",
        ] {
            assert!(!expects_a_page(p), "{p} is an asset, not a page");
        }
    }
}
