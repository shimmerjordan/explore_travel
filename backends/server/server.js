'use strict';

// explore_journal backend — single-port, zero-dependency Node server.
//
//   ┌────────────┐   HTTP    ┌───────────────────────────────┐
//   │  frpc / CF │ ────────▶ │ server.js (router + upgrade)  │
//   │   tunnel   │   WS      │  ├─ modules/leaderboard  (HTTP)│
//   └────────────┘           │  └─ modules/group        (WS)  │
//                            └───────────────────────────────┘
//
// Extending: drop a file in `modules/` exporting
//   (cfg) => ({ name, routes?, onUpgrade?, status?, shutdown? })
// and add it to MODULES below. Routes and upgrade paths are namespaced by
// convention (`/<module>/v1/…`); the leaderboard keeps its doc-mandated
// root paths (`/entries`, `/monthly`, `/index`).
//
// Everything is configured via environment variables — see README.md.

const http = require('node:http');
const { parse: parseUrl } = require('node:url');
const { Router, sendJson } = require('./lib/router');
const log = require('./lib/log');

const cfg = {
  port: Number(process.env.PORT || 48081),
  host: process.env.HOST || '0.0.0.0',
  dataDir: process.env.DATA_DIR || '/data',
  trustProxy: process.env.TRUST_PROXY === '1',
  // leaderboard
  lbWriteToken: process.env.LB_WRITE_TOKEN || '',
  lbReadsPerMin: Number(process.env.LB_READS_PER_MIN || 60),
  lbWritesPerMin: Number(process.env.LB_WRITES_PER_MIN || 10),
  lbMaxEntryBytes: Number(process.env.LB_MAX_ENTRY_BYTES || 96 * 1024),
  // group relay
  groupToken: process.env.GROUP_TOKEN || '',
  groupMaxRoomSize: Number(process.env.GROUP_MAX_ROOM_SIZE || 32),
  groupMaxMessage: Number(process.env.GROUP_MAX_MESSAGE || 4 * 1024 * 1024),
  groupMsgsPerSec: Number(process.env.GROUP_MSGS_PER_SEC || 50),
  groupBytesPerSec: Number(process.env.GROUP_BYTES_PER_SEC || 512 * 1024),
  groupConnectsPerMin: Number(process.env.GROUP_CONNECTS_PER_MIN || 30),
};

// Which modules to run. Both default ON, and an unrecognised value keeps the
// module ON rather than quietly disabling it: the two failure directions are
// "a service you wanted is silently missing" and "a service you tried to turn
// off is still running", and only the first is hard to notice. Unrecognised
// values do warn, so a typo is discoverable in the log.
function moduleEnabled(name) {
  const raw = process.env[`EJ_MODULE_${name.toUpperCase()}`];
  if (raw === undefined || raw === '') return true;
  const v = raw.trim().toLowerCase();
  if (['0', 'false', 'no', 'off'].includes(v)) return false;
  if (['1', 'true', 'yes', 'on'].includes(v)) return true;
  log.warn(
    'main',
    `EJ_MODULE_${name.toUpperCase()}="${raw}" is not a boolean; leaving ${name} enabled`,
  );
  return true;
}

cfg.modules = {
  leaderboard: moduleEnabled('leaderboard'),
  group: moduleEnabled('group'),
};

// A module that is off is not merely unrouted -- it is never constructed, so
// it opens no files, starts no timers, and cannot answer anything. That is the
// point of the switch: running only the leaderboard on a box should not leave
// the relay's state machine resident.
const MODULES = [
  cfg.modules.leaderboard && require('./modules/leaderboard')(cfg),
  cfg.modules.group && require('./modules/group')(cfg),
].filter(Boolean);

if (MODULES.length === 0) {
  // Refusing to start beats listening on a port with nothing behind it: the
  // latter passes every health check while serving 404 to everything real,
  // which is the hardest kind of outage to diagnose.
  log.error(
    'main',
    'every module is disabled (EJ_MODULE_LEADERBOARD and EJ_MODULE_GROUP are both off); ' +
      'nothing would be served, so refusing to start -- enable at least one',
  );
  process.exit(2);
}

const router = new Router();
for (const m of MODULES) {
  for (const r of m.routes || []) {
    router.add(r.method, r.pattern, r.handler, { maxBody: r.maxBody });
  }
}

// Built-ins.
router.add('GET', '/healthz', (req, res) => {
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('ok');
});
router.add('GET', '/api/status', (req, res) => {
  const mem = process.memoryUsage();
  sendJson(res, 200, {
    uptimeSec: Math.round(process.uptime()),
    rssMb: Math.round(mem.rss / 1048576),
    modules: Object.fromEntries(
      MODULES.map((m) => [m.name, m.status ? m.status() : {}]),
    ),
  });
});

const server = http.createServer(async (req, res) => {
  try {
    const handled = await router.dispatch(req, res);
    if (!handled) sendJson(res, 404, { error: 'not found' });
  } catch (e) {
    log.error('http', `${req.method} ${req.url} → ${e.stack || e}`);
    if (!res.headersSent) sendJson(res, 500, { error: 'internal error' });
    else res.destroy();
  }
});

// Short timeouts keep half-open connections from pinning sockets on a
// small instance. WebSocket upgrades detach from these automatically.
server.requestTimeout = 30000;
server.headersTimeout = 15000;
server.keepAliveTimeout = 20000;

server.on('upgrade', (req, socket) => {
  try {
    socket.setTimeout(0);
    const u = parseUrl(req.url, true);
    for (const m of MODULES) {
      if (m.onUpgrade && m.onUpgrade(req, socket, u.pathname, u.query)) return;
    }
    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    socket.destroy();
  } catch (e) {
    log.error('ws', `upgrade failed: ${e.stack || e}`);
    socket.destroy();
  }
});

server.listen(cfg.port, cfg.host, () => {
  log.info(
    'main',
    `listening on ${cfg.host}:${cfg.port} data=${cfg.dataDir} ` +
      `modules=${MODULES.map((m) => m.name).join('+')} ` +
      `lbAuth=${cfg.lbWriteToken ? 'on' : 'off'} groupAuth=${cfg.groupToken ? 'on' : 'off'}`,
  );
});

let shuttingDown = false;
function shutdown(sig) {
  if (shuttingDown) return;
  shuttingDown = true;
  log.info('main', `${sig} — shutting down`);
  server.close();
  for (const m of MODULES) {
    try {
      m.shutdown?.();
    } catch (e) {
      log.error('main', `${m.name} shutdown: ${e}`);
    }
  }
  // Give close frames/flushes a moment, then exit hard.
  setTimeout(() => process.exit(0), 500).unref?.();
  process.exitCode = 0;
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = { server, cfg };
