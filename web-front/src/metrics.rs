//! Request metrics: in-process counters, a 24-hour ring of samples, and a
//! `metrics.json` snapshot on the data volume so the numbers survive a
//! container restart.
//!
//! Two properties this module is built around, both of them consequences of
//! *who* can reach it:
//!
//! 1. **Bounded route cardinality.** `record` is called on every response,
//!    including the ones nobody authenticated for -- the static build sits at
//!    the bottom of `route`'s match, so `GET /whatever-i-invent` reaches it.
//!    Keying the counter map by request path would let a stranger add a map
//!    entry per request, and `persist` would then write that ever-growing map
//!    to disk. `normalise_route` therefore returns a `&'static str` from a
//!    fixed whitelist: the set of possible keys is a compile-time constant, so
//!    there is no input that can make this table (or the file) grow.
//! 2. **The access ring never leaves the process.** It records client IPs, and
//!    `metrics.json` is an operator-shareable file; see `Inner::recent`.
//!
//! Locking: one `Mutex<Inner>` taken on every request, so its critical sections
//! do as little as possible -- no serialization, no time formatting, no IO, no
//! syscalls. Not literally arithmetic only: `bump` allocates a `String` the
//! first time it sees a route, because `BTreeMap<String, _>` needs an owned key
//! to insert. That is at most one allocation per process per whitelisted route
//! (a dozen, ever), so it is not worth a second map to avoid.
//!
//! It is a *leaf* lock: nothing inside this module acquires another lock, so it
//! takes no part in the `admin → config_write → sessions` order in `AppState`.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::atomic_file;

/// The routes allowed to appear under their own name in the counter map.
///
/// MAINTENANCE: adding an endpoint to `route` in main.rs means adding its path
/// here too, otherwise its traffic is billed to `CATCH_ALL` and becomes
/// invisible in the console. That is the deliberate failure mode -- forgetting
/// this costs one merged bucket, never an unbounded table -- but it is still a
/// bug, so keep the two lists in step.
const FIXED_ROUTES: &[&str] = &[
    "/healthz",
    "/api/session",
    "/api/password",
    "/api/config",
    "/api/metrics",
    "/api/export",
    // The console shell. It is the only route served WITHOUT a session, so
    // folding it into the catch-all bucket would make "someone is poking at the
    // login page" indistinguishable from ordinary asset traffic -- and at ~50 KB
    // a hit it would also drown the real static-asset byte count.
    "/admin",
];

/// Proxy routes carry the upstream path (repo, tile, WebDAV object) in their
/// own URL, so they are folded to the prefix: `/proxy/gh/o/r/a.png` and
/// `/proxy/gh/o/r/b.png` are the same route as far as an operator is
/// concerned, and keeping them apart is exactly the cardinality explosion.
const PROXY_PREFIXES: &[&str] = &["/proxy/gh", "/proxy/dav", "/proxy/url"];

/// Everything else: the static web build, its SPA fallback, and any path that
/// matched no route at all (those answer 404). One constant bucket rather than
/// one key per URL -- see the module docs.
const CATCH_ALL: &str = "/static";

/// Samples kept, and how often the sampler adds one. These two are only
/// meaningful as a pair: 1440 × 60 s is exactly 24 hours, the window the
/// console graphs. Changing the interval without changing the cap silently
/// changes how much history the ring covers.
pub const MAX_SAMPLES: usize = 1440;
pub const DEFAULT_SAMPLE_INTERVAL_SECS: u64 = 60;

/// Largest accepted sampling interval, a day. Anything above it is a typo or a
/// misunderstanding, and it fails in the least visible way possible: the thread
/// sleeps, `metrics.json` is never written, the console's sample list stays
/// empty forever, and nothing is logged to say why. A day is already past the
/// point of usefulness (one point per day against a 1440-point ring), so
/// clamping here costs no real configuration.
pub const MAX_SAMPLE_INTERVAL_SECS: u64 = 86_400;

/// How many samples the sampler takes per write of `metrics.json`.
///
/// Sampling and persisting are deliberately on different clocks. A full ring
/// serializes to roughly 160 KB, so writing it on every sample would be ~230 MB
/// a day at the default interval -- and two fsyncs a minute, which on the NAS
/// spindle this runs on means the disk never gets to spin down. At an interval
/// of one second it would be 14 GB a day.
///
/// The 24-hour window is unchanged: the ring still gains a point per interval,
/// which is what the console graphs. Only the *durability* of the newest points
/// is traded away -- an unclean stop can lose up to this many intervals of
/// counters. That is the same bargain the module already makes (see
/// `load_or_new`: a damaged file resets the whole history to zero rather than
/// refusing to boot), just priced explicitly. Ten was chosen because it turns
/// "lose a minute" into "lose ten", which is still nothing an operator would
/// act on, while dropping the write volume by an order of magnitude.
pub const PERSIST_EVERY_SAMPLES: u32 = 10;

/// Entries in the recent-access ring. Small on purpose: it exists to answer
/// "what just happened", not to be a log -- `docker logs` already has every
/// line (see `log_access`).
const MAX_RECENT: usize = 100;

/// Longest client IP string kept in the recent ring. With
/// `EJ_TRUST_PROXY=1` the value comes from `X-Forwarded-For`, which the client
/// writes, so without a cap 100 ring entries could hold 100 × whatever header
/// size the client felt like sending. 45 characters is the longest real
/// textual address (an IPv4-mapped IPv6 literal with a zone).
const MAX_IP_LEN: usize = 45;

const FILE_NAME: &str = "metrics.json";
const TMP_NAME: &str = "metrics.json.tmp";

/// Per-route counters. Status classes: 2xx and 304 are `ok`, 4xx is
/// `client_err`, 5xx is `server_err`, any other 3xx is `redirect`. A status
/// outside all of those counts in `total` only, so the four classes may sum to
/// less than `total` -- deliberately, so that a status this server never sends
/// today cannot be silently filed as a success.
///
/// The 3xx split is not pedantry. A 304 is a served request: the client has the
/// body already. But the other 3xx this deployment can emit come from
/// `/proxy/*`, and `proxy::safe_agent` uses `redirects(0)` and passes the
/// upstream status through while forwarding only the status, content type and
/// body -- **not** `Location`. `raw.githubusercontent.com` really does answer
/// 302 for some paths, and what the browser receives is a redirect with nowhere
/// to go: a failed fetch. Counting it as `ok` would make the console read
/// healthy while every tile request came back empty.
#[derive(Clone, Copy, Default, Serialize, Deserialize)]
#[serde(default)]
struct RouteStat {
    total: u64,
    ok: u64,
    client_err: u64,
    server_err: u64,
    /// 3xx other than 304 -- see the note above on why these are neither `ok`
    /// nor lumped in with the 4xx the client caused.
    redirect: u64,
    /// Response body bytes attributed to this route -- this is what makes
    /// "bytes forwarded by the proxy" readable off `/proxy/*` alone.
    bytes: u64,
}

/// One point in the time series. Values are *cumulative*, so the console can
/// difference two neighbouring points to get a per-interval rate and the
/// series stays monotonic across a restart (the totals are restored from
/// disk).
#[derive(Clone, Copy, Default, Serialize, Deserialize)]
#[serde(default)]
struct Sample {
    ts: u64,
    requests: u64,
    bytes_out: u64,
    client_err: u64,
    server_err: u64,
    login_failures: u64,
    rss_mb: u64,
}

/// Exactly the state that goes to disk. Kept as its own type, separate from
/// `Inner`, so that persisting the recent-access ring is not something a later
/// edit can do by accident: `Inner` has no `Serialize` impl at all, and this
/// struct has no field to put the ring in.
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct Persisted {
    routes: BTreeMap<String, RouteStat>,
    requests: u64,
    bytes_out: u64,
    login_failures: u64,
    samples: VecDeque<Sample>,
}

/// One access, for the "recent requests" panel.
///
/// `route` is the normalised `&'static str`, never the request path: this ring
/// is reachable by any unauthenticated `GET`, and storing the raw path would
/// turn it into a 100-slot bucket of remote-controlled strings.
#[derive(Clone)]
struct Access {
    ts: u64,
    route: &'static str,
    status: u16,
    bytes_out: u64,
    ip: String,
}

struct Inner {
    p: Persisted,
    /// Recent accesses, newest at the back. **Deliberately not persisted**:
    /// each entry holds the client IP, while `metrics.json` is a file an
    /// operator hands to someone else when asking for help debugging (and the
    /// console exports it). Counters and samples carry no such data, which is
    /// why they may be written out and this may not. Do not move this into
    /// `Persisted`.
    recent: VecDeque<Access>,
}

pub struct Metrics {
    dir: PathBuf,
    inner: Mutex<Inner>,
}

impl Metrics {
    pub fn new(dir: PathBuf) -> Metrics {
        Metrics {
            dir,
            inner: Mutex::new(Inner {
                p: Persisted::default(),
                recent: VecDeque::new(),
            }),
        }
    }

    /// Read the counters back from `metrics.json`, or start from zero.
    ///
    /// Unlike `admin.json`, a damaged file here is *not* a reason to refuse to
    /// start or to quarantine anything: losing counters costs nothing but
    /// history, and a service that won't boot because its statistics file is
    /// truncated would be a far worse failure than a graph that restarts at
    /// zero. The loss is still logged, because it means the last write was
    /// interrupted.
    pub fn load_or_new(dir: PathBuf) -> Metrics {
        let path = dir.join(FILE_NAME);
        let p = match fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<Persisted>(&bytes) {
                Ok(p) => sanitise(p),
                Err(e) => {
                    eprintln!("WARN: {} is unreadable ({e}); metrics restart at zero", path.display());
                    Persisted::default()
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Persisted::default(),
            Err(e) => {
                eprintln!("WARN: read {} failed ({e}); metrics restart at zero", path.display());
                Persisted::default()
            }
        };
        // Built on `new` rather than repeating the struct literal, so "what an
        // empty instance looks like" -- in particular that `recent` starts
        // empty whatever was on disk -- is defined in exactly one place.
        let m = Metrics::new(dir);
        m.inner.lock().unwrap().p = p;
        m
    }

    /// Count one response. `route` may be the raw request path -- normalising
    /// is this module's job, not the caller's, so a new call site can't be the
    /// thing that unbounds the table.
    ///
    /// The counters-only entry point. Requests served by this process always
    /// have a peer address and go through `record_access`, so nothing in
    /// `main` reaches this one; a binary crate lints that as dead code even
    /// though the tests below drive it.
    #[allow(dead_code)]
    pub fn record(&self, route: &str, status: u16, bytes_out: u64) {
        let key = normalise_route(route);
        let mut g = self.inner.lock().unwrap();
        bump(&mut g.p, key, status, bytes_out);
    }

    /// Count one response and remember it in the recent-access ring. Same
    /// critical section as `record` -- one lock acquisition, not two, so a
    /// request can never appear in the counters but not the ring.
    pub fn record_access(&self, route: &str, status: u16, bytes_out: u64, ip: &str) {
        let key = normalise_route(route);
        // Both of these touch the outside world (clock, allocator), so they
        // happen before the lock is taken.
        let ts = now_secs();
        let ip = short_ip(ip);

        let mut g = self.inner.lock().unwrap();
        bump(&mut g.p, key, status, bytes_out);

        // The console's own poll does NOT go in the ring. It reads
        // `/api/metrics` every 10 seconds while the ring holds 100 entries, so
        // anyone who simply LEAVES THE PANEL OPEN flushes every other event out
        // of it within ~17 minutes -- and the 20 rows actually rendered turn
        // pure self-poll in about three. The counters still cover this route
        // (that is what counters are for); the ring exists to answer "what else
        // just happened", so its own read is precisely the event worth
        // excluding. Verified rather than assumed -- see
        // `the_consoles_own_poll_does_not_flush_the_ring` below.
        // Only the console's OWN successful polls. A 4xx on this route is
        // someone probing an endpoint they cannot read -- which is precisely
        // what a "what just happened" panel exists to surface, so it must not
        // be swallowed along with the self-noise.
        if key == "/api/metrics" && status < 400 {
            return;
        }
        if g.recent.len() >= MAX_RECENT {
            g.recent.pop_front();
        }
        g.recent.push_back(Access {
            ts,
            route: key,
            status,
            bytes_out,
            ip,
        });
    }

    /// A rejected credential check. Counted on its own rather than inferred
    /// from `/api/session`'s 4xx count, which also includes malformed bodies.
    pub fn record_login_failure(&self) {
        let mut g = self.inner.lock().unwrap();
        g.p.login_failures += 1;
    }

    /// Append one point to the ring, dropping the oldest once it is full.
    pub fn take_sample(&self) {
        // Clock and `/proc` read stay outside the critical section.
        let ts = now_secs();
        let rss = rss_mb();

        let mut g = self.inner.lock().unwrap();
        let (client_err, server_err) = error_totals(&g.p);
        let s = Sample {
            ts,
            requests: g.p.requests,
            bytes_out: g.p.bytes_out,
            client_err,
            server_err,
            login_failures: g.p.login_failures,
            rss_mb: rss,
        };
        if g.p.samples.len() >= MAX_SAMPLES {
            g.p.samples.pop_front();
        }
        g.p.samples.push_back(s);
    }

    /// Everything the console shows, as JSON: the shareable document plus the
    /// `recent` array.
    ///
    /// `uptime_secs` and `rss_mb` come from the caller because they are
    /// properties of the process, not of the counters.
    ///
    /// `recent` is the only part of this document that carries client IPs, so
    /// this is the *console-only* accessor: it answers the operator's own
    /// browser over an authenticated session. Anything that writes metrics into
    /// a file or a support bundle must call `snapshot_shareable_json` instead --
    /// and does not have to remember to delete anything, because that function
    /// never has the ring in hand to begin with.
    // The console's metrics endpoint is the only caller, and a binary crate
    // reports a `pub fn` that `main` cannot reach as dead code even when the
    // tests exercise it.
    pub fn snapshot_json(&self, uptime_secs: u64, rss_mb: u64) -> Value {
        // One acquisition for both halves; the JSON is built after it is
        // released.
        let (p, recent) = self.copy_out();
        let mut doc = shareable_doc(&p, uptime_secs, rss_mb);
        // Newest first: this is a "what just happened" panel, and the answer
        // should be the first row rather than the last.
        let recent: Vec<Value> = recent
            .iter()
            .rev()
            .map(|a| {
                json!({
                    "ts": a.ts,
                    "route": a.route,
                    "status": a.status,
                    "bytes_out": a.bytes_out,
                    "ip": a.ip,
                })
            })
            .collect();
        doc["recent"] = Value::Array(recent);
        doc
    }

    /// The same numbers with no `recent` array -- the version safe to put in a
    /// file, an export archive, or anything else that leaves the machine.
    ///
    /// Structural, not a convention: it reads the counters through
    /// `copy_persisted`, whose return type is `Persisted`, and `Persisted` has
    /// no field for the access ring (the same reason `metrics.json` cannot
    /// contain one). So this cannot leak an IP even if someone edits
    /// `shareable_doc` carelessly -- there is no IP reachable from here. The
    /// alternative, one function with an `include_recent` flag, would put the
    /// decision at every call site and make "wrote the wrong argument" a way to
    /// ship 100 visitor addresses inside a file the operator forwards to a
    /// stranger.
    // No caller in `main` yet -- the export endpoint is what will use it -- and
    // a binary crate lints an unreachable `pub fn` as dead code.
    pub fn snapshot_shareable_json(&self, uptime_secs: u64, rss_mb: u64) -> Value {
        shareable_doc(&self.copy_persisted(), uptime_secs, rss_mb)
    }

    /// Write the counters and samples to `metrics.json`.
    ///
    /// Two statements on purpose: the first takes the lock and gives it back,
    /// the second does the serializing and the IO with nothing held. Keep it
    /// that shape -- `record` runs on every request from every worker, and a
    /// disk write inside that critical section would stall all of them.
    pub fn persist(&self) -> Result<(), String> {
        let p = self.copy_persisted();
        write_json(&self.dir, &p)
    }

    /// The two locked accessors the readers above are built from.
    ///
    /// MAINTENANCE: both return owned copies, and the guard's scope ends inside
    /// them, so as long as every accessor looks like this, no caller of
    /// `snapshot_json`/`persist` can be holding the mutex while it serializes.
    /// This is a convention, not a proof -- an accessor that returned a
    /// `MutexGuard`, or took `&Persisted` from a caller that holds one, would
    /// compile fine. If you add an accessor here, keep it returning owned data.
    fn copy_persisted(&self) -> Persisted {
        self.inner.lock().unwrap().p.clone()
    }

    /// One acquisition for both halves, so the counters and the access ring in
    /// a single snapshot always describe the same moment.
    fn copy_out(&self) -> (Persisted, VecDeque<Access>) {
        let g = self.inner.lock().unwrap();
        (g.p.clone(), g.recent.clone())
    }
}

/// Render the counters and the sample ring as JSON.
///
/// Takes `&Persisted` rather than `&self`, which is what keeps it honest: the
/// access ring is not part of that type, so no edit to this function can add
/// client IPs to the document. It also cannot reach the mutex, so it cannot be
/// the thing that serializes under the lock.
fn shareable_doc(p: &Persisted, uptime_secs: u64, rss_mb: u64) -> Value {
    let mut routes = serde_json::Map::new();
    for (name, st) in p.routes.iter() {
        routes.insert(
            name.clone(),
            json!({
                "total": st.total,
                "ok": st.ok,
                "client_err": st.client_err,
                "server_err": st.server_err,
                "redirect": st.redirect,
                "bytes": st.bytes,
            }),
        );
    }
    let (client_err, server_err) = error_totals(p);
    let samples: Vec<Value> = p
        .samples
        .iter()
        .map(|s| {
            json!({
                "ts": s.ts,
                "requests": s.requests,
                "bytes_out": s.bytes_out,
                "client_err": s.client_err,
                "server_err": s.server_err,
                "login_failures": s.login_failures,
                "rss_mb": s.rss_mb,
            })
        })
        .collect();

    json!({
        "uptime_secs": uptime_secs,
        "rss_mb": rss_mb,
        "requests": p.requests,
        "bytes_out": p.bytes_out,
        "client_err": client_err,
        "server_err": server_err,
        "login_failures": p.login_failures,
        "routes": Value::Object(routes),
        "samples": samples,
    })
}

/// The one place counters are advanced. `route` is already normalised, which
/// its `&'static str` type enforces.
fn bump(p: &mut Persisted, route: &'static str, status: u16, bytes_out: u64) {
    let st = p.routes.entry(route.to_string()).or_default();
    st.total += 1;
    st.bytes += bytes_out;
    match status {
        // A 304 is the cache-validation half of a successful GET.
        304 => st.ok += 1,
        200..=299 => st.ok += 1,
        300..=399 => st.redirect += 1,
        400..=499 => st.client_err += 1,
        500..=599 => st.server_err += 1,
        _ => {}
    }
    p.requests += 1;
    p.bytes_out += bytes_out;
}

/// Sum the error classes over the (at most a dozen) route buckets rather than
/// keeping a second set of aggregate counters that could drift out of step
/// with the per-route ones.
fn error_totals(p: &Persisted) -> (u64, u64) {
    p.routes
        .values()
        .fold((0, 0), |(c, s), st| (c + st.client_err, s + st.server_err))
}

/// Map a request path onto one of a fixed, compile-time set of route names.
///
/// The return type is the guarantee: a `&'static str` can only be one of the
/// literals above, so no input -- however long, however many distinct values
/// -- can add a key to the counter map.
///
/// The query string is cut off first. `serve` happens to split it before
/// calling, so today every argument arrives clean -- but `record`'s contract is
/// "the raw request path is fine", and `GET /api/config?x=1` would otherwise
/// match no fixed route and land in `CATCH_ALL`. That failure is invisible and
/// total: one call site passing `req.url()` would silently move *all* API
/// traffic into the static bucket, which is worse than the "one extra bucket"
/// cost the whitelist is designed to fail with. `#` is cut for the same reason
/// even though a fragment never reaches a server.
fn normalise_route(path: &str) -> &'static str {
    let path = match path.find(['?', '#']) {
        Some(i) => &path[..i],
        None => path,
    };
    for r in FIXED_ROUTES {
        if path == *r {
            return r;
        }
    }
    for prefix in PROXY_PREFIXES {
        // `strip_prefix` + a separator check rather than a bare
        // `starts_with`, so a hypothetical `/proxy/ghost` is not folded into
        // `/proxy/gh`.
        if let Some(rest) = path.strip_prefix(*prefix) {
            if rest.is_empty() || rest.starts_with('/') {
                return prefix;
            }
        }
    }
    CATCH_ALL
}

/// Fold whatever was on disk back into today's invariants: route keys through
/// `normalise_route` (a file written by an older build, or edited by hand on
/// the NAS, could otherwise reintroduce unbounded keys) and the sample list
/// back down to the cap.
fn sanitise(p: Persisted) -> Persisted {
    let mut routes: BTreeMap<String, RouteStat> = BTreeMap::new();
    for (name, st) in p.routes.into_iter() {
        let e = routes.entry(normalise_route(&name).to_string()).or_default();
        e.total += st.total;
        e.ok += st.ok;
        e.client_err += st.client_err;
        e.server_err += st.server_err;
        e.redirect += st.redirect;
        e.bytes += st.bytes;
    }
    let mut samples = p.samples;
    while samples.len() > MAX_SAMPLES {
        samples.pop_front();
    }
    Persisted {
        routes,
        samples,
        ..p
    }
}

/// Serialize and replace `metrics.json`. A free function taking no `&self`, so
/// it cannot go and take the mutex itself -- it still cannot stop a caller from
/// holding the lock across the call, which is why `persist` is written as two
/// statements (lock, release; then serialize and write) and why the accessors
/// above hand back owned copies.
///
/// Uses `atomic_file` like the other two state files rather than a private
/// write+rename. The fsyncs it brings along are not the point here -- losing
/// the last minute of counters is fine -- but atomicity is: a torn or
/// truncated `metrics.json` is unparseable, and `load_or_new` answers that by
/// resetting to zero, so a crash mid-write would cost the whole 24-hour
/// history rather than one sample. Twice-a-minute fsync is a price worth
/// paying for that, and `write_tmp`/`commit` are a unit -- opting out of the
/// durability half would mean adding a flag that blurs what that module
/// promises everyone else.
///
/// The sampler thread is the only caller, so the fixed tmp path needs no lock
/// of its own (unlike `config.json.tmp`, which has concurrent writers).
fn write_json(dir: &Path, p: &Persisted) -> Result<(), String> {
    let bytes = serde_json::to_vec(p).map_err(|e| format!("serialize metrics: {e}"))?;
    let tmp = dir.join(TMP_NAME);
    atomic_file::write_tmp(&tmp, &bytes)?;
    atomic_file::commit(&tmp, &dir.join(FILE_NAME))
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Truncate an address to `MAX_IP_LEN`, on a char boundary so the result is
/// still a valid `String` even if the header held multi-byte junk.
fn short_ip(ip: &str) -> String {
    if ip.len() <= MAX_IP_LEN {
        return ip.to_string();
    }
    let mut end = MAX_IP_LEN;
    while end > 0 && !ip.is_char_boundary(end) {
        end -= 1;
    }
    ip[..end].to_string()
}

/// Resident set size in MiB, or 0 if it cannot be determined.
pub fn rss_mb() -> u64 {
    rss_mb_from(Path::new("/proc/self/status"))
}

/// `VmRSS` from a procfs-shaped file, in MiB.
///
/// Reads `/proc/self/status` (kB, already scaled) rather than
/// `/proc/self/statm` (pages) to avoid needing the page size, which std does
/// not expose. Split out over an explicit path so the "cannot read it" branch
/// is testable, and every failure -- missing file, no such line, unparseable
/// number -- returns 0 instead of panicking: this is a display value, not
/// worth risking the sampler thread over.
fn rss_mb_from(path: &Path) -> u64 {
    let text = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return 0,
    };
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            let kb: u64 = match rest
                .split_whitespace()
                .next()
                .and_then(|n| n.parse().ok())
            {
                Some(n) => n,
                None => return 0,
            };
            return kb / 1024;
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("wf-metrics-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn counts_group_by_route_and_status_class() {
        let m = Metrics::new(tmpdir("count"));
        m.record("/api/config", 200, 100);
        m.record("/api/config", 200, 100);
        m.record("/api/config", 401, 0);
        m.record("/healthz", 200, 2);
        let s = m.snapshot_json(10, 50);
        let routes = &s["routes"];
        assert_eq!(routes["/api/config"]["total"], 3);
        assert_eq!(routes["/api/config"]["ok"], 2);
        assert_eq!(routes["/api/config"]["client_err"], 1);
        assert_eq!(routes["/healthz"]["total"], 1);
        assert_eq!(s["bytes_out"], 202);
        // Per-route bytes, not just the total: "how much did the proxy move"
        // is the question this field exists for, and it is only answerable if
        // the bytes land in the right bucket. Asserting only `bytes_out` above
        // passes even with the per-route accumulation deleted.
        assert_eq!(routes["/api/config"]["bytes"], 200);
        assert_eq!(routes["/healthz"]["bytes"], 2, "bytes must be attributed per route");
    }

    /// `record`'s contract says the raw request path is acceptable. A path with
    /// a query must therefore still find its own bucket -- otherwise one call
    /// site passing `req.url()` would quietly relabel every API request as
    /// static traffic.
    #[test]
    fn a_query_string_does_not_change_the_route() {
        let m = Metrics::new(tmpdir("query"));
        m.record("/api/config?x=1", 200, 5);
        m.record("/api/config?x=2&y=3", 200, 5);
        m.record("/proxy/gh/o/r/main/a.png?token=abc", 200, 5);
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["routes"]["/api/config"]["total"], 2, "a query must not push a known route into the catch-all");
        assert_eq!(s["routes"]["/proxy/gh"]["total"], 1);
        assert!(s["routes"].get(CATCH_ALL).is_none(), "nothing here belongs in the catch-all: {s}");
    }

    #[test]
    fn proxy_routes_are_normalised() {
        let m = Metrics::new(tmpdir("norm"));
        m.record("/proxy/gh/o/r/main/a.png", 200, 10);
        m.record("/proxy/gh/o/r/main/b.png", 200, 10);
        m.record("/proxy/dav/Sync/x.zip", 200, 10);
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["routes"]["/proxy/gh"]["total"], 2, "proxy paths of one kind must fold together");
        assert_eq!(s["routes"]["/proxy/dav"]["total"], 1);
        assert!(s["routes"].get("/proxy/gh/o/r/main/a.png").is_none());
    }

    #[test]
    fn login_failures_are_counted_separately() {
        let m = Metrics::new(tmpdir("login"));
        m.record_login_failure();
        m.record_login_failure();
        assert_eq!(m.snapshot_json(1, 1)["login_failures"], 2);
    }

    #[test]
    fn ring_buffer_is_capped() {
        let m = Metrics::new(tmpdir("ring"));
        for _ in 0..1500 {
            m.take_sample();
        }
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["samples"].as_array().unwrap().len(), 1440, "the sample cap must be 1440");
    }

    #[test]
    fn persist_then_load_keeps_totals() {
        let d = tmpdir("persist");
        let m = Metrics::new(d.clone());
        m.record("/healthz", 200, 5);
        m.take_sample();
        m.persist().unwrap();
        let m2 = Metrics::load_or_new(d);
        let s = m2.snapshot_json(1, 1);
        assert_eq!(s["routes"]["/healthz"]["total"], 1, "totals must come back from disk after a restart");
        assert_eq!(s["samples"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn corrupt_metrics_file_does_not_crash() {
        let d = tmpdir("corrupt");
        std::fs::write(d.join("metrics.json"), "{not json").unwrap();
        let m = Metrics::load_or_new(d);
        assert_eq!(m.snapshot_json(1, 1)["bytes_out"], 0, "a damaged metrics file resets quietly instead of panicking");
    }

    /// The one remotely reachable way to hurt this module: the static build is
    /// the bottom of `route`'s match, so every unmatched `GET` -- any URL a
    /// stranger cares to invent, no session needed -- reaches `record`. If the
    /// route key were the request path, each of those would mint a map entry
    /// that then gets written into `metrics.json` and grows it forever.
    #[test]
    fn unknown_paths_cannot_grow_the_route_table() {
        let bound = FIXED_ROUTES.len() + PROXY_PREFIXES.len() + 1;
        let m = Metrics::new(tmpdir("cardinality"));
        for i in 0..500 {
            m.record(&format!("/{i}-{}", "z".repeat(i % 11)), 200, 1);
        }
        let first = m.snapshot_json(1, 1)["routes"].as_object().unwrap().len();
        for i in 500..1000 {
            m.record(&format!("/other/{i}"), 404, 1);
        }
        let second = m.snapshot_json(1, 1)["routes"].as_object().unwrap().len();
        assert!(first <= bound, "route keys must stay within the fixed set, got {first}");
        assert_eq!(first, second, "route key count must not grow with the number of distinct paths");
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["routes"][CATCH_ALL]["total"], 1000, "unknown paths all belong to one bucket");
    }

    /// A `metrics.json` written by an older build (or hand-edited on the NAS)
    /// must not be able to smuggle unbounded keys back in through `load`.
    #[test]
    fn loading_cannot_reintroduce_arbitrary_route_keys() {
        let d = tmpdir("loadnorm");
        let mut routes = serde_json::Map::new();
        for i in 0..200 {
            routes.insert(
                format!("/junk/{i}"),
                serde_json::json!({"total": 2, "ok": 1, "client_err": 1, "server_err": 0, "bytes": 3}),
            );
        }
        let samples: Vec<Value> = (0..2000).map(|i| serde_json::json!({"ts": i})).collect();
        std::fs::write(
            d.join("metrics.json"),
            serde_json::to_vec(&serde_json::json!({
                "routes": routes, "requests": 400, "bytes_out": 600,
                "login_failures": 0, "samples": samples,
            }))
            .unwrap(),
        )
        .unwrap();

        let m = Metrics::load_or_new(d);
        let s = m.snapshot_json(1, 1);
        let loaded = s["routes"].as_object().unwrap();
        assert!(
            loaded.len() <= FIXED_ROUTES.len() + PROXY_PREFIXES.len() + 1,
            "loaded keys must be folded into the fixed set, got {}",
            loaded.len()
        );
        assert_eq!(s["routes"][CATCH_ALL]["total"], 400, "folded totals must be preserved, not dropped");
        assert_eq!(
            s["samples"].as_array().unwrap().len(),
            MAX_SAMPLES,
            "an over-long sample list on disk must be trimmed to the cap"
        );
    }

    /// Recent accesses carry the client IP, so they live in memory only. This
    /// pins the boundary: a restart (i.e. `persist` then `load_or_new`) must
    /// come back with an empty ring even though the counters survive.
    #[test]
    fn recent_accesses_are_not_persisted() {
        let d = tmpdir("recent-persist");
        let m = Metrics::new(d.clone());
        m.record_access("/api/config", 200, 12, "203.0.113.9");
        m.persist().unwrap();

        let raw = std::fs::read_to_string(d.join("metrics.json")).unwrap();
        assert!(!raw.contains("203.0.113.9"), "metrics.json must not contain a client IP: {raw}");

        let m2 = Metrics::load_or_new(d);
        let s = m2.snapshot_json(1, 1);
        assert_eq!(s["routes"]["/api/config"]["total"], 1, "counters still survive a restart");
        assert_eq!(
            s["recent"].as_array().unwrap().len(),
            0,
            "the recent-access ring must start empty after a restart"
        );
    }

    #[test]
    fn recent_accesses_are_capped_and_hold_no_raw_paths() {
        let m = Metrics::new(tmpdir("recent-cap"));
        for i in 0..(MAX_RECENT + 40) {
            m.record_access(&format!("/deep/{i}/page"), 200, 1, "10.0.0.5");
        }
        let s = m.snapshot_json(1, 1);
        let recent = s["recent"].as_array().unwrap();
        assert_eq!(recent.len(), MAX_RECENT, "the recent ring must stay at its cap");
        for e in recent {
            assert_eq!(e["route"], CATCH_ALL, "the ring stores the normalised route, never the raw path");
        }
        assert_eq!(recent[0]["ip"], "10.0.0.5");
    }

    /// A forwarded-for header is client-controlled and unbounded; 100 of them
    /// held in memory must not become 100 × header size.
    #[test]
    fn a_long_client_ip_is_truncated() {
        let m = Metrics::new(tmpdir("longip"));
        m.record_access("/healthz", 200, 2, &"9".repeat(4000));
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["recent"][0]["ip"].as_str().unwrap().len(), MAX_IP_LEN);
    }

    /// A 304 is a served request; a bare 30x is not. The proxy runs with
    /// `redirects(0)` and forwards neither `Location` nor any other header, so a
    /// 302 from `raw.githubusercontent.com` reaches the browser as a redirect to
    /// nowhere -- a failed fetch that must not inflate `ok`.
    #[test]
    fn only_2xx_and_304_count_as_ok() {
        let m = Metrics::new(tmpdir("classes"));
        m.record("/healthz", 304, 0);
        m.record("/healthz", 500, 30);
        m.record("/healthz", 429, 30);
        m.record("/proxy/gh", 302, 0);
        m.record("/proxy/gh", 301, 0);
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["routes"]["/healthz"]["ok"], 1, "a 304 is a served request, not an error");
        assert_eq!(s["routes"]["/healthz"]["server_err"], 1);
        assert_eq!(s["routes"]["/healthz"]["client_err"], 1);
        assert_eq!(s["routes"]["/proxy/gh"]["ok"], 0, "a passed-through 30x has no Location and fetched nothing");
        assert_eq!(s["routes"]["/proxy/gh"]["redirect"], 2);
    }

    /// The console panel is "what just happened", so the newest access has to
    /// be the first row. The two entries differ in IP and status because a ring
    /// of identical records cannot tell the two orderings apart.
    /// `/admin` is the only route served without a session, so it must be
    /// visible on its own line rather than folded into the catch-all: "someone
    /// is probing the login page" and "the browser fetched some assets" are not
    /// the same event, and at ~50 KB a hit it would also swamp the static byte
    /// count.
    #[test]
    fn the_unauthenticated_console_route_is_not_folded_into_the_catch_all() {
        assert_eq!(normalise_route("/admin"), "/admin");
        let m = Metrics::new(tmpdir("adminroute"));
        m.record("/admin", 200, 52_776);
        m.record("/some/spa/deep/link", 200, 300);
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["routes"]["/admin"]["total"], 1);
        assert_eq!(s["routes"]["/admin"]["bytes"], 52_776);
        assert_eq!(
            s["routes"]["/static"]["bytes"], 300,
            "the console must not pollute the static-asset byte count"
        );
    }

    /// Leaving the console open must not erase the answer it is there to give.
    #[test]
    fn the_consoles_own_poll_does_not_flush_the_ring() {
        let m = Metrics::new(tmpdir("pollring"));
        m.record_access("/api/session", 200, 10, "203.0.113.9");
        // More polls than the ring can hold -- the old behaviour left nothing
        // but polls behind.
        for _ in 0..(MAX_RECENT * 2) {
            m.record_access("/api/metrics", 200, 4000, "203.0.113.9");
        }
        let s = m.snapshot_json(1, 1);
        let recent = s["recent"].as_array().unwrap();
        assert_eq!(recent.len(), 1, "only the real event should be in the ring");
        assert_eq!(recent[0]["route"], "/api/session");
        // ...while the counters still see every poll.
        assert_eq!(s["routes"]["/api/metrics"]["total"], (MAX_RECENT * 2) as u64);
    }

    /// The exclusion is for self-noise, not for the route. Somebody hammering
    /// `/api/metrics` without a session is exactly the event the panel is for.
    #[test]
    fn a_rejected_metrics_read_still_lands_in_the_ring() {
        let m = Metrics::new(tmpdir("probering"));
        m.record_access("/api/metrics", 200, 4000, "203.0.113.9"); // console poll
        m.record_access("/api/metrics", 401, 24, "198.51.100.4"); // a prober
        let s = m.snapshot_json(1, 1);
        let recent = s["recent"].as_array().unwrap();
        assert_eq!(recent.len(), 1, "the successful poll must not be kept");
        assert_eq!(recent[0]["status"], 401);
        assert_eq!(recent[0]["ip"], "198.51.100.4");
    }

    #[test]
    fn recent_accesses_are_newest_first() {
        let m = Metrics::new(tmpdir("recent-order"));
        m.record_access("/api/session", 401, 0, "198.51.100.1");
        m.record_access("/healthz", 200, 2, "203.0.113.7");
        let s = m.snapshot_json(1, 1);
        let recent = s["recent"].as_array().unwrap();
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0]["ip"], "203.0.113.7", "the most recent access must be first");
        assert_eq!(recent[0]["status"], 200);
        assert_eq!(recent[1]["ip"], "198.51.100.1");
        assert_eq!(recent[1]["status"], 401);
    }

    /// The counterpart to `recent_accesses_are_not_persisted`: the file cannot
    /// hold an IP because `Persisted` has no field for one, and this pins the
    /// same property for the *export* document, which is built from the same
    /// type. A future export endpoint that reaches for `snapshot_json` instead
    /// would ship 100 visitor addresses inside a file an operator forwards to
    /// someone else.
    #[test]
    fn the_shareable_snapshot_carries_no_client_ips() {
        let m = Metrics::new(tmpdir("shareable"));
        m.record_access("/api/config", 200, 12, "203.0.113.9");
        m.record_access("/healthz", 200, 2, "198.51.100.4");
        m.take_sample();

        let share = m.snapshot_shareable_json(5, 7);
        let text = share.to_string();
        assert!(share.get("recent").is_none(), "the shareable document must have no recent array: {text}");
        assert!(!text.contains("203.0.113.9"), "no client IP may appear: {text}");
        assert!(!text.contains("198.51.100.4"), "no client IP may appear: {text}");

        // It is the same numbers, though -- dropping the ring must not cost the
        // counters the export exists to carry.
        let full = m.snapshot_json(5, 7);
        assert_eq!(share["requests"], 2);
        assert_eq!(share["bytes_out"], 14);
        assert_eq!(share["routes"], full["routes"]);
        assert_eq!(share["samples"], full["samples"]);
        assert_eq!(full["recent"].as_array().unwrap().len(), 2, "the console version still has the ring");
    }

    #[test]
    fn samples_record_cumulative_totals() {
        let m = Metrics::new(tmpdir("samplevals"));
        m.record("/healthz", 200, 7);
        m.take_sample();
        m.record("/healthz", 500, 3);
        m.take_sample();
        let s = m.snapshot_json(1, 1);
        let samples = s["samples"].as_array().unwrap();
        assert_eq!(samples[0]["requests"], 1);
        assert_eq!(samples[0]["bytes_out"], 7);
        assert_eq!(samples[1]["requests"], 2);
        assert_eq!(samples[1]["bytes_out"], 10);
        assert_eq!(samples[1]["server_err"], 1);
    }

    /// `/proc` is normally mounted even in a distroless container, but a
    /// missing or unreadable file must read as "unknown", not as a panic that
    /// takes the sampler thread down.
    #[test]
    fn rss_is_zero_when_it_cannot_be_read() {
        let d = tmpdir("rss");
        assert_eq!(rss_mb_from(&d.join("no-such-status")), 0);
        std::fs::write(d.join("garbage"), "VmRSS:\tnot-a-number kB\n").unwrap();
        assert_eq!(rss_mb_from(&d.join("garbage")), 0);
        std::fs::write(d.join("good"), "Name:\tweb-front\nVmRSS:\t   40960 kB\nThreads:\t9\n").unwrap();
        assert_eq!(rss_mb_from(&d.join("good")), 40);
    }

    /// Every worker thread calls `record` on every request, so a lost update
    /// here would silently under-report load.
    #[test]
    fn concurrent_records_are_not_lost() {
        let d = tmpdir("concurrent");
        let m = std::sync::Arc::new(Metrics::new(d));
        let mut hs = Vec::new();
        for _ in 0..8 {
            let m = m.clone();
            hs.push(std::thread::spawn(move || {
                for _ in 0..500 {
                    m.record_access("/api/config", 200, 1, "127.0.0.1");
                }
            }));
        }
        let writer = {
            let m = m.clone();
            std::thread::spawn(move || {
                for _ in 0..20 {
                    m.take_sample();
                    m.persist().unwrap();
                }
            })
        };
        for h in hs {
            h.join().unwrap();
        }
        writer.join().unwrap();
        let s = m.snapshot_json(1, 1);
        assert_eq!(s["routes"]["/api/config"]["total"], 4000);
        assert_eq!(s["bytes_out"], 4000);
    }
}
