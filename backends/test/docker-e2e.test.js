'use strict';

// Container-level E2E suite — runs against an ALREADY-RUNNING backend
// (normally the Docker image, started by scripts/docker-e2e.sh):
//
//   E2E_BASE_URL=http://127.0.0.1:18990 node --test test/docker-e2e.test.js
//
// Env knobs:
//   E2E_BASE_URL    required — where the container listens
//   E2E_CONTAINER   optional — docker container name; enables the
//                   restart-persistence test (`docker restart`)
//   E2E_LB_TOKEN /  optional — when set the suite runs in AUTH MODE and
//   E2E_GROUP_TOKEN verifies token enforcement instead of the main suite
//
// Unlike test/api.test.js (unit-level, spawns its own node per case) this
// exercises the real image: Alpine node, non-root user, volume-mounted
// /data, healthcheck wiring — i.e. what actually ships to ECS.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const { makeKeyPair, makeEntry, wsConnect } = require('./helpers');
const { contentHash } = require('../server/lib/canonical');

const BASE = process.env.E2E_BASE_URL;
const CONTAINER = process.env.E2E_CONTAINER || '';
const LB_TOKEN = process.env.E2E_LB_TOKEN || '';
const GROUP_TOKEN = process.env.E2E_GROUP_TOKEN || '';
const AUTH_MODE = Boolean(LB_TOKEN || GROUP_TOKEN);

if (!BASE) {
  // Part of the same glob as the unit suite — without a running container
  // there is nothing to test here. scripts/docker-e2e.sh sets the env.
  test('docker E2E (skipped: E2E_BASE_URL not set — run scripts/docker-e2e.sh)', {
    skip: true,
  }, () => {});
  return;
}
const PORT = Number(new URL(BASE).port || 80);

const vec = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'fixtures', 'lb_vector.json'), 'utf8'),
);

const post = (body, headers = {}) =>
  fetch(`${BASE}/entries`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });

async function waitHealthy(timeoutMs = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try {
      const r = await fetch(`${BASE}/healthz`);
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error('backend not healthy in time');
}

// ══════════════════════════ AUTH MODE ═══════════════════════════════
if (AUTH_MODE) {
  test('auth mode: tokens are enforced end-to-end', async (t) => {
    await waitHealthy();

    if (LB_TOKEN) {
      await t.test('POST /entries without token → 401', async () => {
        const r = await post(makeEntry(makeKeyPair()));
        assert.strictEqual(r.status, 401);
      });
      await t.test('POST /entries with token → accepted', async () => {
        const r = await post(makeEntry(makeKeyPair(), { peerId: 'auth-ok' }), {
          authorization: `Bearer ${LB_TOKEN}`,
        });
        assert.deepStrictEqual(await r.json(), { accepted: true, reason: '' });
      });
      await t.test('reads stay public', async () => {
        const r = await fetch(`${BASE}/entries`);
        assert.strictEqual(r.status, 200);
      });
    }

    if (GROUP_TOKEN) {
      await t.test('WS without token refused, with token accepted', async () => {
        await assert.rejects(
          wsConnect(PORT, '/group/v1/ws?group=trip&peer=x1'),
          /401/,
        );
        const ok = await wsConnect(
          PORT,
          `/group/v1/ws?group=trip&peer=x1&token=${encodeURIComponent(GROUP_TOKEN)}`,
        );
        ok.close();
        const info = await (await fetch(`${BASE}/group/v1/info`)).json();
        assert.strictEqual(info.auth, true);
      });
    }
  });
} else {
  // ═══════════════════════ MAIN CORRECTNESS SUITE ════════════════════

  test('container health + status shape', async (t) => {
    await waitHealthy();
    await t.test('/healthz says ok', async () => {
      const r = await fetch(`${BASE}/healthz`);
      assert.strictEqual(r.status, 200);
      assert.strictEqual(await r.text(), 'ok');
    });
    await t.test('/api/status exposes both modules', async () => {
      const s = await (await fetch(`${BASE}/api/status`)).json();
      assert.ok(s.uptimeSec >= 0);
      assert.ok(s.rssMb > 0);
      assert.ok('leaderboard' in s.modules);
      assert.ok('group' in s.modules);
    });
    await t.test('unknown route → 404 JSON', async () => {
      const r = await fetch(`${BASE}/no/such/route`);
      assert.strictEqual(r.status, 404);
    });
  });

  test('leaderboard: full API + data correctness', async (t) => {
    const kp = makeKeyPair();

    await t.test('Dart-signed vector accepted; JS-signed accepted', async () => {
      assert.deepStrictEqual(await (await post(vec.entry)).json(), {
        accepted: true,
        reason: '',
      });
      const mine = makeEntry(kp, {
        peerId: 'e2e-peer',
        displayName: 'E2E 测试员 ✓',
        globalKm2: 12345.6789012345,
        monthKm2: { '2026-06': 100.25, '2026-07': 0.0186378065 },
      });
      assert.deepStrictEqual(await (await post(mine)).json(), {
        accepted: true,
        reason: '',
      });
    });

    await t.test('GET /entries/{id} roundtrip is byte-exact', async () => {
      const got = await (await fetch(`${BASE}/entries/e2e-peer`)).json();
      // Doubles, unicode, month maps — everything survives verbatim.
      assert.strictEqual(got.globalKm2, 12345.6789012345);
      assert.strictEqual(got.displayName, 'E2E 测试员 ✓');
      assert.deepStrictEqual(got.monthKm2, {
        '2026-06': 100.25,
        '2026-07': 0.0186378065,
      });
      // And the canonical hash matches what a client would compute.
      const idx = await (await fetch(`${BASE}/index`)).json();
      const row = idx.entries.find((e) => e.peerId === 'e2e-peer');
      assert.strictEqual(row.hash, contentHash(got));
      const dartRow = idx.entries.find((e) => e.peerId === vec.entry.peerId);
      assert.strictEqual(dartRow.hash, vec.contentHash);
    });

    await t.test('validation: malformed → 400, forged → 422, unknown → 404', async () => {
      assert.strictEqual((await post('not json')).status, 400);
      assert.strictEqual((await post({ peerId: 'x' })).status, 400);
      assert.strictEqual((await post(vec.tampered)).status, 422);
      assert.strictEqual(
        (await fetch(`${BASE}/entries/nobody-here`)).status,
        404,
      );
    });

    await t.test('LWW + TOFU + future-skew enforced', async () => {
      const stale = makeEntry(kp, {
        peerId: 'e2e-peer',
        statsAt: '2026-07-01T00:00:00.000Z',
      });
      assert.strictEqual((await (await post(stale)).json()).accepted, false);

      const impostor = makeEntry(makeKeyPair(), {
        peerId: 'e2e-peer',
        statsAt: '2026-07-20T00:00:00.000Z',
      });
      const tofu = await (await post(impostor)).json();
      assert.strictEqual(tofu.accepted, false);
      assert.match(tofu.reason, /TOFU/);

      const future = makeEntry(kp, {
        peerId: 'e2e-peer',
        statsAt: new Date(Date.now() + 48 * 3600 * 1000).toISOString(),
      });
      const fut = await (await post(future)).json();
      assert.strictEqual(fut.accepted, false);
      assert.match(fut.reason, /future/);
    });

    await t.test('/monthly ordering + values', async () => {
      const m = await (await fetch(`${BASE}/monthly/2026-07`)).json();
      assert.ok(Array.isArray(m));
      for (let i = 1; i < m.length; i++) assert.ok(m[i - 1].km2 >= m[i].km2);
      const mine = m.find((r) => r.peerId === 'e2e-peer');
      assert.strictEqual(mine.km2, 0.0186378065);
      assert.strictEqual(
        (await fetch(`${BASE}/monthly/not-a-month`)).status,
        400,
      );
    });

    await t.test('ETag: second poll costs a 304', async () => {
      const g1 = await fetch(`${BASE}/entries`);
      const etag = g1.headers.get('etag');
      assert.ok(etag);
      assert.strictEqual(g1.headers.get('cache-control'), 'max-age=15');
      const g2 = await fetch(`${BASE}/entries`, {
        headers: { 'if-none-match': etag },
      });
      assert.strictEqual(g2.status, 304);
    });
  });

  test('group relay through the container', async (t) => {
    const a = await wsConnect(PORT, '/group/v1/ws?group=e2etrip&peer=aa');
    const b = await wsConnect(PORT, '/group/v1/ws?group=e2etrip&peer=bb');
    const c = await wsConnect(PORT, '/group/v1/ws?group=e2etrip&peer=cc');
    const outsider = await wsConnect(PORT, '/group/v1/ws?group=elsewhere&peer=zz');
    t.after(() => [a, b, c, outsider].forEach((x) => x.close()));

    await t.test('broadcast + targeted + isolation', async () => {
      a.send('{"t":"hello","fid":"aa"}');
      assert.strictEqual(await b.next(), '{"t":"hello","fid":"aa"}');
      assert.strictEqual(await c.next(), '{"t":"hello","fid":"aa"}');
      await assert.rejects(outsider.next(500), /timeout/);

      a.send('@bb|{"t":"chat","d":{"text":"私聊"}}');
      assert.strictEqual(await b.next(), '{"t":"chat","d":{"text":"私聊"}}');
      await assert.rejects(c.next(500), /timeout/);
    });

    await t.test('opaque 100 KB voice-sized frame relays intact', async () => {
      const blob = 'v1|' + 'V'.repeat(100 * 1024);
      b.send(blob);
      const gotA = await a.next(5000);
      const gotC = await c.next(5000);
      assert.strictEqual(gotA.length, blob.length);
      assert.strictEqual(gotA, blob);
      assert.strictEqual(gotC, blob);
    });

    await t.test('unicode payload passes byte-clean', async () => {
      const line = '{"t":"chat","d":{"text":"你好🌍 émoji ✓"}}';
      c.send(line);
      assert.strictEqual(await a.next(), line);
      assert.strictEqual(await b.next(), line);
    });

    await t.test('/api/status reflects live relay counters', async () => {
      const s = await (await fetch(`${BASE}/api/status`)).json();
      assert.ok(s.modules.group.rooms >= 2);
      assert.ok(s.modules.group.clients >= 4);
      assert.ok(s.modules.group.relayed >= 6);
      assert.ok(s.modules.group.bytes >= 200 * 1024);
    });
  });

  test('data survives `docker restart` (volume persistence)', {
    skip: CONTAINER ? false : 'E2E_CONTAINER not set',
  }, async () => {
    // The store debounces writes for 2 s; `docker restart` sends SIGTERM
    // which flushes synchronously — that is exactly the path we verify.
    const before = await (await fetch(`${BASE}/entries`)).json();
    assert.ok(before.length >= 2);

    execFileSync('docker', ['restart', '-t', '5', CONTAINER], {
      stdio: 'ignore',
    });
    await waitHealthy(30000);

    const after = await (await fetch(`${BASE}/entries`)).json();
    assert.strictEqual(after.length, before.length);
    const sortById = (l) => [...l].sort((x, y) => x.peerId.localeCompare(y.peerId));
    assert.deepStrictEqual(sortById(after), sortById(before));
  });
}
