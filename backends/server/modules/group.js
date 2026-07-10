'use strict';

// Group relay module — a dumb, room-scoped fan-out for the app's group
// mesh (live location trails, chat, PTT voice, music sync, leaderboard
// gossip).
//
// Design goals, in order:
//   1. Zero knowledge: payloads are relayed verbatim. With a group
//      passphrase set on the clients every line is `v1|<AES-GCM>…` —
//      the server can't read locations or chat, it only sees room names
//      and peer ids. Bandwidth cost of that privacy: none.
//   2. Bandwidth thrift: targeted messages use a tiny routing prefix
//      (`@<peerId>|payload`) so 1:1 chat/voice is NOT broadcast to the
//      whole room. No JSON re-encoding on the hot path — buffers pass
//      straight through.
//   3. Small footprint: no per-message allocation beyond the routing
//      check; rooms are plain Maps; dead peers are reaped by ping.
//
// Endpoint:
//   GET /group/v1/ws?group=<id>&peer=<peerId>[&token=…]   (WebSocket)
//
// Frames (client → server), all text:
//   `@<peerId>|<payload>`  → deliver payload to that peer only
//   `<payload>`            → deliver to every other peer in the room
// Frames (server → client): the payload only — routing prefix stripped.
//
// The server never generates application messages; presence is built by
// the clients from their own periodic `hello` broadcasts, exactly like
// the LAN transport. That keeps the protocol identical across transports.

const { sendJson } = require('../lib/router');
const { acceptUpgrade } = require('../lib/ws');
const { RateLimiter, clientIp } = require('../lib/ratelimit');
const log = require('../lib/log');

module.exports = function groupModule(cfg) {
  /** @type {Map<string, Map<string, import('../lib/ws').WsConn>>} */
  const rooms = new Map();
  const connectLimit = new RateLimiter(cfg.groupConnectsPerMin ?? 30);

  let stats = { relayed: 0, bytes: 0, kicked: 0 };

  const maxMsg = cfg.groupMaxMessage ?? 4 * 1024 * 1024;
  const msgsPerSec = cfg.groupMsgsPerSec ?? 50;
  const bytesPerSec = cfg.groupBytesPerSec ?? 512 * 1024;

  // Reap dead connections. Ping every 30 s; anything silent for 90 s is
  // gone (mobile clients reconnect with backoff).
  const reaper = setInterval(() => {
    for (const [gid, members] of rooms) {
      for (const [pid, conn] of members) {
        if (!conn.alive) {
          log.info('group', `reap ${pid.slice(0, 8)}… from ${gid}`);
          conn.destroy();
          continue; // 'close' handler removes it from the room
        }
        conn.alive = false;
        conn.ping();
      }
      if (members.size === 0) rooms.delete(gid);
    }
  }, 30000);
  reaper.unref?.();

  function join(group, peer, conn) {
    let members = rooms.get(group);
    if (!members) {
      members = new Map();
      rooms.set(group, members);
    }
    // Same peer reconnecting (e.g. network flap) — drop the stale socket.
    const old = members.get(peer);
    if (old && old !== conn) old.destroy();
    members.set(peer, conn);
    log.info('group', `join ${peer.slice(0, 8)}… → room "${group}" (${members.size} online)`);

    // Per-connection throttles. Voice PTT is the heaviest legit flow
    // (~4 chunks/s, tens of KB each); the caps leave ample headroom while
    // stopping a runaway client from saturating the uplink.
    const msgBucket = new RateLimiter(msgsPerSec * 60, msgsPerSec * 2);
    const byteWindow = { at: Date.now(), n: 0 };

    conn.on('message', (line) => {
      if (!msgBucket.allow('m')) return; // silently drop excess
      const now = Date.now();
      if (now - byteWindow.at >= 1000) {
        byteWindow.at = now;
        byteWindow.n = 0;
      }
      byteWindow.n += line.length;
      if (byteWindow.n > bytesPerSec) return;

      let payload = line;
      let target = null;
      if (line.charCodeAt(0) === 64 /* '@' */) {
        const sep = line.indexOf('|');
        if (sep > 1 && sep < 130) {
          target = line.slice(1, sep);
          payload = line.slice(sep + 1);
        }
      }
      if (target) {
        const t = members.get(target);
        if (t && t !== conn) {
          t.send(payload);
          stats.relayed++;
          stats.bytes += payload.length;
        }
        return;
      }
      for (const [pid, c] of members) {
        if (c === conn) continue;
        c.send(payload);
        stats.relayed++;
        stats.bytes += payload.length;
      }
    });

    conn.on('close', () => {
      // Only remove if we're still the registered socket for this peer —
      // a reconnect may already have replaced us.
      if (members.get(peer) === conn) {
        members.delete(peer);
        log.info('group', `leave ${peer.slice(0, 8)}… ← room "${group}" (${members.size} online)`);
      }
      if (members.size === 0) rooms.delete(group);
    });
  }

  return {
    name: 'group',
    routes: [
      {
        // Lightweight probe used by the in-app connection test.
        method: 'GET',
        pattern: '/group/v1/info',
        handler: (req, res) => {
          sendJson(res, 200, {
            service: 'explore_journal-group-relay',
            v: 1,
            auth: Boolean(cfg.groupToken),
          });
        },
      },
    ],
    /**
     * @returns true when this module owned the upgrade request.
     */
    onUpgrade(req, socket, pathname, query) {
      if (pathname !== '/group/v1/ws') return false;
      if (!connectLimit.allow(clientIp(req, cfg.trustProxy))) {
        socket.write('HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return true;
      }
      const group = String(query.group || '');
      const peer = String(query.peer || '');
      if (!/^[a-z0-9]{1,64}$/.test(group) || !peer || peer.length > 128) {
        socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return true;
      }
      if (cfg.groupToken && String(query.token || '') !== cfg.groupToken) {
        socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return true;
      }
      const maxRoom = cfg.groupMaxRoomSize ?? 32;
      const members = rooms.get(group);
      if (members && members.size >= maxRoom && !members.has(peer)) {
        socket.write('HTTP/1.1 409 Conflict\r\nConnection: close\r\n\r\n');
        socket.destroy();
        stats.kicked++;
        return true;
      }
      const conn = acceptUpgrade(req, socket, { maxMessage: maxMsg });
      if (conn) join(group, peer, conn);
      return true;
    },
    status: () => ({
      rooms: rooms.size,
      clients: [...rooms.values()].reduce((n, m) => n + m.size, 0),
      ...stats,
    }),
    shutdown: () => {
      clearInterval(reaper);
      for (const members of rooms.values()) {
        for (const conn of members.values()) conn.close(1001, 'server shutdown');
      }
      rooms.clear();
    },
  };
};
