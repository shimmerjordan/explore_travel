use std::io::Read;
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::time::Duration;

const MAX_PROXY_BYTES: u64 = 32 << 20; // 32 MiB cap on a proxied object

/// Reject any address an SSRF would target: loopback / private / link-local /
/// ULA / IPv4-mapped equivalents / cloud metadata. Covers IPv4 and IPv6.
pub fn is_safe_ip(ip: &IpAddr) -> bool {
    if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() {
        return false;
    }
    match ip {
        IpAddr::V4(v4) => {
            !(v4.is_private() || v4.is_link_local() || v4.is_broadcast() || v4.is_documentation())
        }
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                return is_safe_ip(&IpAddr::V4(mapped));
            }
            let seg0 = v6.segments()[0];
            let is_ula = (seg0 & 0xfe00) == 0xfc00; // fc00::/7
            let is_link_local = (seg0 & 0xffc0) == 0xfe80; // fe80::/10
            !(is_ula || is_link_local)
        }
    }
}

/// ureq resolver that returns ONLY validated public IPs. Because ureq dials the
/// addresses we return, this both rejects bad hosts AND pins the connection to
/// a checked IP — defeating DNS rebinding (TLS SNI/cert still use the original
/// hostname, so https validation is intact).
struct SafeResolver;

impl ureq::Resolver for SafeResolver {
    fn resolve(&self, netloc: &str) -> std::io::Result<Vec<SocketAddr>> {
        let safe: Vec<SocketAddr> = netloc
            .to_socket_addrs()?
            .filter(|a| is_safe_ip(&a.ip()))
            .collect();
        if safe.is_empty() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "blocked or unresolved target",
            ));
        }
        Ok(safe)
    }
}

pub fn safe_agent() -> ureq::Agent {
    ureq::builder()
        .resolver(SafeResolver)
        .redirects(0) // each redirect would bypass the pre-dial IP check
        .timeout(Duration::from_secs(30))
        .build()
}

pub struct Fetched {
    pub status: u16,
    pub content_type: Option<String>,
    pub body: Vec<u8>,
}

fn read_resp(resp: ureq::Response) -> Option<Fetched> {
    let status = resp.status();
    let content_type = resp.header("Content-Type").map(|s| s.to_string());
    let mut body = Vec::new();
    resp.into_reader()
        .take(MAX_PROXY_BYTES)
        .read_to_end(&mut body)
        .ok()?;
    Some(Fetched {
        status,
        content_type,
        body,
    })
}

/// Guarded GET. `upstream_auth` is the client-supplied upstream credential
/// (X-Upstream-Authorization) — forwarded transiently, never stored.
pub fn fetch(
    agent: &ureq::Agent,
    url: &str,
    upstream_auth: Option<&str>,
    accept: Option<&str>,
) -> Option<Fetched> {
    let mut req = agent.get(url);
    if let Some(a) = upstream_auth {
        if !a.is_empty() {
            req = req.set("Authorization", a);
        }
    }
    if let Some(a) = accept {
        if !a.is_empty() {
            req = req.set("Accept", a);
        }
    }
    match req.call() {
        Ok(resp) => read_resp(resp),
        // redirects(0) + non-2xx surface as Status; pass the upstream code through.
        Err(ureq::Error::Status(_code, resp)) => read_resp(resp),
        Err(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::IpAddr;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn rejects_internal_targets() {
        // Unsafe — must all be rejected.
        for s in [
            "127.0.0.1",          // loopback
            "10.1.2.3",           // RFC1918
            "192.168.0.5",        // RFC1918
            "172.16.9.9",         // RFC1918
            "169.254.169.254",    // link-local / cloud metadata
            "0.0.0.0",            // unspecified
            "::1",                // v6 loopback
            "fe80::1",            // v6 link-local
            "fc00::1",            // v6 ULA
            "fd00:ec2::254",      // v6 ULA (metadata-ish)
            "::ffff:10.0.0.1",    // IPv4-mapped private
        ] {
            assert!(!is_safe_ip(&ip(s)), "{s} should be blocked");
        }
    }

    #[test]
    fn allows_public_targets() {
        for s in ["1.1.1.1", "8.8.8.8", "93.184.216.34", "2606:4700:4700::1111"] {
            assert!(is_safe_ip(&ip(s)), "{s} should be allowed");
        }
    }
}

/// Like [`is_safe_ip`], but permits RFC1918 / ULA addresses.
///
/// The two proxies have genuinely different threat models and so cannot share
/// one predicate:
///
///   * `/proxy/url` takes its target from the *request*, so an attacker with a
///     session picks the address and private ranges must be refused — that is
///     a classic SSRF pivot.
///   * the WebDAV proxy takes its target from the admin's own stored config,
///     and the overwhelmingly common deployment is a NAS talking to a WebDAV
///     server on the same LAN. Refusing private addresses there does not close
///     an attack path (whoever can rewrite that config already holds every
///     cloud credential this server stores); it just makes the feature
///     unusable for the setup it exists to serve.
///
/// Still refused: loopback (a request loop back into this process),
/// unspecified, multicast, broadcast, and **link-local — which is what keeps
/// cloud metadata at 169.254.169.254 out of reach**.
pub fn is_lan_or_public_ip(ip: &IpAddr) -> bool {
    if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() {
        return false;
    }
    match ip {
        IpAddr::V4(v4) => !(v4.is_link_local() || v4.is_broadcast() || v4.is_documentation()),
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                return is_lan_or_public_ip(&IpAddr::V4(mapped));
            }
            (v6.segments()[0] & 0xffc0) != 0xfe80 // fe80::/10
        }
    }
}

struct LanResolver;

impl ureq::Resolver for LanResolver {
    fn resolve(&self, netloc: &str) -> std::io::Result<Vec<SocketAddr>> {
        let ok: Vec<SocketAddr> = netloc
            .to_socket_addrs()?
            .filter(|a| is_lan_or_public_ip(&a.ip()))
            .collect();
        if ok.is_empty() {
            return Err(std::io::Error::other("blocked or unresolved target"));
        }
        Ok(ok)
    }
}

/// Agent for the WebDAV proxy. Same pinning and no-redirect posture as
/// [`safe_agent`] — only the address predicate differs (see
/// [`is_lan_or_public_ip`]).
pub fn lan_agent() -> ureq::Agent {
    ureq::builder()
        .resolver(LanResolver)
        .redirects(0)
        .timeout(Duration::from_secs(30))
        .build()
}

/// The cap this module reads a proxied body up to, exposed so the WebDAV proxy
/// bounds its own reads by the same number rather than inventing a second one.
pub const BODY_CAP: u64 = MAX_PROXY_BYTES;

#[cfg(test)]
mod lan_tests {
    use super::*;

    #[test]
    fn lan_predicate_allows_private_but_still_blocks_the_dangerous_ones() {
        // Not a TEST-NET address here on purpose: 192.0.2.0/24, 198.51.100.0/24
        // and 203.0.113.0/24 are the documentation ranges and `is_documentation`
        // refuses them, which is correct -- nobody's WebDAV lives there.
        for ok in ["192.168.1.5", "10.0.0.9", "172.16.4.4", "93.184.216.34"] {
            assert!(
                is_lan_or_public_ip(&ok.parse().unwrap()),
                "{ok} is a plausible WebDAV host"
            );
        }
        for bad in [
            "127.0.0.1",
            "0.0.0.0",
            "169.254.169.254",
            "255.255.255.255",
            "203.0.113.9", // documentation range
        ] {
            assert!(!is_lan_or_public_ip(&bad.parse().unwrap()), "{bad} must stay blocked");
        }
        // The metadata address is the one that would actually hurt, so pin it
        // from the other direction too: the stricter predicate agrees.
        assert!(!is_safe_ip(&"169.254.169.254".parse().unwrap()));
        // ...and the LAN address the strict one refuses is exactly why this
        // second predicate exists.
        assert!(!is_safe_ip(&"192.168.1.5".parse().unwrap()));
    }

    #[test]
    fn ipv6_mapped_and_link_local_follow_the_same_rules() {
        assert!(!is_lan_or_public_ip(&"::ffff:127.0.0.1".parse().unwrap()));
        assert!(is_lan_or_public_ip(&"::ffff:192.168.1.5".parse().unwrap()));
        assert!(!is_lan_or_public_ip(&"fe80::1".parse().unwrap()));
        assert!(is_lan_or_public_ip(&"fd00::1".parse().unwrap()), "ULA is a real LAN in v6");
    }
}
