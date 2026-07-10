'use strict';

// Community leaderboard module — implements the app contract in
// `explore_journal/docs/leaderboard-server-api.md` (v1):
//
//   GET  /entries            full registry (ETag + max-age=15)
//   GET  /entries/:peerId    single entry
//   POST /entries            submit a signed entry
//   GET  /monthly/:ym        month ranking, precomputed server-side
//   GET  /index              {peerId, hash} freshness probe
//
// Trust rules enforced server-side (the clients re-verify anyway):
//   * Ed25519 signature over canonical bytes — 422 when invalid
//   * TOFU on publicKey per peerId — refuse key changes
//   * LWW by statsAt per peerId — refuse stale entries
//   * future-skew defence — refuse statsAt >24h ahead (clamping would
//     break the signature, so we reject instead and let the client retry
//     with a sane clock)

const path = require('node:path');
const crypto = require('node:crypto');
const { sendJson } = require('../lib/router');
const { JsonStore } = require('../lib/store');
const { RateLimiter, clientIp } = require('../lib/ratelimit');
const { contentHash, verifyEntry } = require('../lib/canonical');
const log = require('../lib/log');

const YM_RE = /^\d{4}-\d{2}$/;

module.exports = function leaderboardModule(cfg) {
  const store = new JsonStore(
    path.join(cfg.dataDir, 'leaderboard.json'),
    { entries: {}, pins: {} },
  );
  const entries = store.data.entries; // peerId → entry (verbatim JSON)
  const pins = store.data.pins; // peerId → first-seen publicKey

  const readLimit = new RateLimiter(cfg.lbReadsPerMin ?? 60);
  const writeLimit = new RateLimiter(cfg.lbWritesPerMin ?? 10);

  let stats = { accepted: 0, rejected: 0, reads: 0 };

  // ── caching ─────────────────────────────────────────────────────────
  // The full /entries body is the expensive object (avatars). Serialize
  // once per change, serve the cached buffer with an ETag so repeat
  // pollers cost a 304 and ~200 bytes.
  let cachedBody = null;
  let cachedEtag = '';
  function invalidate() {
    cachedBody = null;
    store.save();
  }
  function fullBody() {
    if (!cachedBody) {
      cachedBody = Buffer.from(JSON.stringify(Object.values(entries)));
      cachedEtag = `"${crypto.createHash('sha1').update(cachedBody).digest('hex').slice(0, 20)}"`;
    }
    return { body: cachedBody, etag: cachedEtag };
  }

  function guardRead(req, res) {
    if (!readLimit.allow(clientIp(req, cfg.trustProxy))) {
      sendJson(res, 429, { error: 'rate limited' });
      return false;
    }
    stats.reads++;
    return true;
  }

  function validate(e) {
    if (!e || typeof e !== 'object') return 'not an object';
    if (typeof e.peerId !== 'string' || !e.peerId || e.peerId.length > 128) {
      return 'peerId missing/invalid';
    }
    if (typeof e.publicKey !== 'string' || !e.publicKey) return 'publicKey missing';
    if (typeof e.signature !== 'string' || !e.signature) return 'signature missing';
    if (typeof e.statsAt !== 'string' || Number.isNaN(Date.parse(e.statsAt))) {
      return 'statsAt missing/unparseable';
    }
    if (typeof e.globalKm2 !== 'number' || !Number.isFinite(e.globalKm2) || e.globalKm2 < 0) {
      return 'globalKm2 invalid';
    }
    if (
      typeof e.globalPercent !== 'number' ||
      !Number.isFinite(e.globalPercent) ||
      e.globalPercent < 0 ||
      e.globalPercent > 1
    ) {
      return 'globalPercent invalid';
    }
    if (typeof e.displayName !== 'string' || e.displayName.length > 200) {
      return 'displayName invalid';
    }
    if (typeof (e.avatarBase64 ?? '') !== 'string' || (e.avatarBase64 || '').length > 48 * 1024) {
      return 'avatarBase64 too large';
    }
    const m = e.monthKm2;
    if (m !== undefined) {
      if (typeof m !== 'object' || Array.isArray(m) || m === null) return 'monthKm2 invalid';
      const keys = Object.keys(m);
      if (keys.length > 40) return 'monthKm2 too many months';
      for (const k of keys) {
        if (!YM_RE.test(k)) return `monthKm2 key ${k} invalid`;
        if (typeof m[k] !== 'number' || !Number.isFinite(m[k]) || m[k] < 0) {
          return `monthKm2[${k}] invalid`;
        }
      }
    }
    return null;
  }

  const routes = [
    {
      method: 'GET',
      pattern: '/entries',
      handler: (req, res) => {
        if (!guardRead(req, res)) return;
        const { body, etag } = fullBody();
        if (req.headers['if-none-match'] === etag) {
          res.writeHead(304, { etag, 'cache-control': 'max-age=15' });
          return res.end();
        }
        res.writeHead(200, {
          'content-type': 'application/json; charset=utf-8',
          'content-length': body.length,
          'cache-control': 'max-age=15',
          etag,
        });
        res.end(body);
      },
    },
    {
      method: 'GET',
      pattern: '/entries/:peerId',
      handler: (req, res, { params }) => {
        if (!guardRead(req, res)) return;
        const e = entries[params.peerId];
        if (!e) return sendJson(res, 404, { error: 'unknown peer' });
        sendJson(res, 200, e);
      },
    },
    {
      method: 'POST',
      pattern: '/entries',
      maxBody: cfg.lbMaxEntryBytes ?? 96 * 1024,
      handler: (req, res, { body }) => {
        if (cfg.lbWriteToken) {
          const auth = String(req.headers.authorization || '');
          if (auth !== `Bearer ${cfg.lbWriteToken}`) {
            return sendJson(res, 401, { error: 'token required for POST' });
          }
        }
        if (!writeLimit.allow(clientIp(req, cfg.trustProxy))) {
          return sendJson(res, 429, { error: 'rate limited' });
        }
        let e;
        try {
          e = JSON.parse(body.toString('utf8'));
        } catch {
          return sendJson(res, 400, { error: 'malformed JSON' });
        }
        const bad = validate(e);
        if (bad) return sendJson(res, 400, { error: bad });

        if (!verifyEntry(e)) {
          stats.rejected++;
          return sendJson(res, 422, { error: 'signature verification failed' });
        }

        // TOFU pin.
        const pinned = pins[e.peerId];
        if (pinned && pinned !== e.publicKey) {
          stats.rejected++;
          return sendJson(res, 200, {
            accepted: false,
            reason: 'publicKey differs from first-seen key (TOFU); use a new peerId to rotate',
          });
        }

        // Future-skew defence.
        const at = Date.parse(e.statsAt);
        if (at > Date.now() + 24 * 3600 * 1000) {
          stats.rejected++;
          return sendJson(res, 200, {
            accepted: false,
            reason: 'statsAt more than 24h in the future',
          });
        }

        // LWW by statsAt.
        const prev = entries[e.peerId];
        if (prev) {
          const prevAt = Date.parse(prev.statsAt);
          if (at < prevAt) {
            return sendJson(res, 200, { accepted: false, reason: 'stale (older statsAt)' });
          }
          if (at === prevAt) {
            // Identical copy → idempotent success; different body at the
            // same instant → keep what we have.
            const same = contentHash(prev) === contentHash(e);
            return sendJson(res, 200, {
              accepted: same,
              reason: same ? '' : 'conflicting entry at same statsAt',
            });
          }
        }

        entries[e.peerId] = e;
        if (!pinned) pins[e.peerId] = e.publicKey;
        invalidate();
        stats.accepted++;
        log.info('lb', `accepted ${e.peerId.slice(0, 8)}… (${e.displayName || 'anon'})`);
        sendJson(res, 200, { accepted: true, reason: '' });
      },
    },
    {
      method: 'GET',
      pattern: '/monthly/:ym',
      handler: (req, res, { params }) => {
        if (!guardRead(req, res)) return;
        if (!YM_RE.test(params.ym)) return sendJson(res, 400, { error: 'bad month key' });
        const list = Object.values(entries)
          .map((e) => ({
            peerId: e.peerId,
            displayName: e.displayName,
            avatarBase64: e.avatarBase64 || '',
            km2: (e.monthKm2 || {})[params.ym] ?? 0,
            publicKey: e.publicKey,
            signature: e.signature,
            statsAt: e.statsAt,
          }))
          .sort((a, b) => b.km2 - a.km2);
        sendJson(res, 200, list, { 'cache-control': 'max-age=15' });
      },
    },
    {
      method: 'GET',
      pattern: '/index',
      handler: (req, res) => {
        if (!guardRead(req, res)) return;
        const idx = Object.values(entries).map((e) => ({
          peerId: e.peerId,
          hash: contentHash(e),
        }));
        sendJson(res, 200, { entries: idx }, { 'cache-control': 'max-age=15' });
      },
    },
  ];

  return {
    name: 'leaderboard',
    routes,
    status: () => ({
      peers: Object.keys(entries).length,
      ...stats,
    }),
    shutdown: () => store.flush(),
  };
};
