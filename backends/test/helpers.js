'use strict';

// Test helpers: spawn the server on a free port with a temp data dir, a
// minimal RFC 6455 *client* (for relay tests), and an Ed25519 signer that
// mirrors the app's producer so tests can mint fresh valid entries.

const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');

const { sortedJson, canonicalOf } = require('../server/lib/canonical');

async function startServer(env = {}) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ejbe-test-'));
  const port = env.PORT ? Number(env.PORT) : 20000 + Math.floor(Math.random() * 20000);
  const child = spawn(
    process.execPath,
    [path.join(__dirname, '..', 'server', 'server.js')],
    {
      env: {
        ...process.env,
        PORT: String(port),
        HOST: '127.0.0.1',
        DATA_DIR: dataDir,
        LOG_LEVEL: 'error',
        ...env,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  child.stderr.on('data', (d) => process.stderr.write(d));
  const base = `http://127.0.0.1:${port}`;
  // Wait for readiness.
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`${base}/healthz`);
      if (r.ok) break;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
    if (i === 99) throw new Error('server did not start');
  }
  return {
    base,
    port,
    dataDir,
    stop: () =>
      new Promise((resolve) => {
        child.on('exit', resolve);
        child.kill('SIGTERM');
        setTimeout(() => child.kill('SIGKILL'), 2000).unref();
      }),
  };
}

// ── entry factory ─────────────────────────────────────────────────────

function makeKeyPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  return { privateKey, publicKeyB64: raw.toString('base64') };
}

function makeEntry(kp, overrides = {}) {
  const entry = {
    peerId: 'peer-a',
    publicKey: kp.publicKeyB64,
    displayName: 'Tester A',
    avatarBase64: '',
    globalKm2: 42.5,
    globalPercent: 0.0000000833,
    monthKm2: { '2026-07': 42.5 },
    statsAt: '2026-07-10T00:00:00.000Z',
    ...overrides,
  };
  const bytes = Buffer.from(sortedJson(canonicalOf(entry)), 'utf8');
  entry.signature = crypto.sign(null, bytes, kp.privateKey).toString('base64');
  return entry;
}

// ── minimal WebSocket client ──────────────────────────────────────────

class WsTestClient {
  constructor(socket) {
    this.socket = socket;
    this.messages = [];
    this.waiters = [];
    this.closedPromise = new Promise((r) => socket.on('close', r));
    let buf = Buffer.alloc(0);
    socket.on('data', (d) => {
      buf = Buffer.concat([buf, d]);
      while (true) {
        if (buf.length < 2) return;
        const op = buf[0] & 0x0f;
        let len = buf[1] & 0x7f;
        let off = 2;
        if (len === 126) {
          if (buf.length < 4) return;
          len = buf.readUInt16BE(2);
          off = 4;
        } else if (len === 127) {
          if (buf.length < 10) return;
          len = Number(buf.readBigUInt64BE(2));
          off = 10;
        }
        if (buf.length < off + len) return;
        const payload = buf.subarray(off, off + len);
        buf = buf.subarray(off + len);
        if (op === 0x1) {
          const text = payload.toString('utf8');
          const w = this.waiters.shift();
          if (w) w(text);
          else this.messages.push(text);
        } else if (op === 0x9) {
          this._frame(0xa, payload); // pong
        }
      }
    });
  }

  _frame(op, payload) {
    const mask = crypto.randomBytes(4);
    const masked = Buffer.from(payload);
    for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i & 3];
    let header;
    if (payload.length < 126) {
      header = Buffer.from([0x80 | op, 0x80 | payload.length]);
    } else if (payload.length < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | op;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(payload.length, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | op;
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(payload.length), 2);
    }
    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  send(text) {
    this._frame(0x1, Buffer.from(text, 'utf8'));
  }

  /** Next text message (already-buffered or future), with timeout. */
  next(timeoutMs = 3000) {
    if (this.messages.length) return Promise.resolve(this.messages.shift());
    return new Promise((resolve, reject) => {
      const waiter = (m) => {
        clearTimeout(t);
        resolve(m);
      };
      const t = setTimeout(() => {
        // Remove the dead waiter so it can't swallow a later message.
        const i = this.waiters.indexOf(waiter);
        if (i >= 0) this.waiters.splice(i, 1);
        reject(new Error('ws message timeout'));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  close() {
    this.socket.destroy();
  }
}

function wsConnect(port, path_) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString('base64');
    const req = http.request({
      host: '127.0.0.1',
      port,
      path: path_,
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Key': key,
        'Sec-WebSocket-Version': '13',
      },
    });
    req.on('upgrade', (res, socket) => resolve(new WsTestClient(socket)));
    req.on('response', (res) => reject(new Error(`upgrade refused: HTTP ${res.statusCode}`)));
    req.on('error', reject);
    req.end();
  });
}

module.exports = { startServer, makeKeyPair, makeEntry, wsConnect };
