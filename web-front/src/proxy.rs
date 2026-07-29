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
