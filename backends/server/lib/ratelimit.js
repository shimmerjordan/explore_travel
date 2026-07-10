'use strict';

// Token-bucket rate limiter keyed by an arbitrary string (usually IP).
// Buckets are pruned lazily so a scan of the whole map never happens on
// the hot path.

class RateLimiter {
  /**
   * @param {number} ratePerMin sustained tokens per minute
   * @param {number} [burst] bucket capacity (default = ratePerMin)
   */
  constructor(ratePerMin, burst) {
    this.rate = ratePerMin / 60000; // tokens per ms
    this.burst = burst ?? ratePerMin;
    /** @type {Map<string, {tokens:number, at:number}>} */
    this.buckets = new Map();
    this._lastPrune = Date.now();
  }

  /** Take one token for `key`; returns true when allowed. */
  allow(key) {
    const now = Date.now();
    let b = this.buckets.get(key);
    if (!b) {
      b = { tokens: this.burst, at: now };
      this.buckets.set(key, b);
    }
    b.tokens = Math.min(this.burst, b.tokens + (now - b.at) * this.rate);
    b.at = now;
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    this._maybePrune(now);
    return true;
  }

  _maybePrune(now) {
    if (now - this._lastPrune < 60000) return;
    this._lastPrune = now;
    for (const [k, b] of this.buckets) {
      // Full bucket and untouched for 10 min → forget it.
      if (b.tokens >= this.burst && now - b.at > 600000) this.buckets.delete(k);
    }
  }
}

/**
 * Client IP for rate-limiting. Behind frp the remote address is the frps
 * host; behind Cloudflare Tunnel it's localhost — both would collapse all
 * users into one bucket. When TRUST_PROXY=1 we prefer the standard
 * forwarding headers (CF sets cf-connecting-ip, most proxies set
 * x-forwarded-for).
 */
function clientIp(req, trustProxy) {
  if (trustProxy) {
    const cf = req.headers['cf-connecting-ip'];
    if (cf) return String(cf);
    const xff = req.headers['x-forwarded-for'];
    if (xff) return String(xff).split(',')[0].trim();
  }
  return req.socket.remoteAddress || 'unknown';
}

module.exports = { RateLimiter, clientIp };
