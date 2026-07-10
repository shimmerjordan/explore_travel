'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const { startServer, makeKeyPair, makeEntry, wsConnect } = require('./helpers');

const vec = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'fixtures', 'lb_vector.json'), 'utf8'),
);

test('leaderboard API end-to-end', async (t) => {
  const srv = await startServer();
  t.after(() => srv.stop());
  const post = (body) =>
    fetch(`${srv.base}/entries`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });

  await t.test('rejects malformed body', async () => {
    const r = await fetch(`${srv.base}/entries`, { method: 'POST', body: 'not json' });
    assert.strictEqual(r.status, 400);
  });

  await t.test('accepts a real Dart-signed entry', async () => {
    const r = await post(vec.entry);
    assert.strictEqual(r.status, 200);
    assert.deepStrictEqual(await r.json(), { accepted: true, reason: '' });
  });

  await t.test('rejects tampered entry with 422', async () => {
    const r = await post(vec.tampered);
    assert.strictEqual(r.status, 422);
  });

  const kp = makeKeyPair();
  await t.test('accepts JS-signed entry; GET /entries serves both + ETag', async () => {
    const r = await post(makeEntry(kp));
    assert.deepStrictEqual(await r.json(), { accepted: true, reason: '' });

    const g1 = await fetch(`${srv.base}/entries`);
    assert.strictEqual(g1.status, 200);
    const list = await g1.json();
    assert.strictEqual(list.length, 2);
    const etag = g1.headers.get('etag');
    assert.ok(etag);
    const g2 = await fetch(`${srv.base}/entries`, {
      headers: { 'if-none-match': etag },
    });
    assert.strictEqual(g2.status, 304);
  });

  await t.test('LWW: stale statsAt refused, newer accepted', async () => {
    const stale = makeEntry(kp, { statsAt: '2026-07-09T00:00:00.000Z', globalKm2: 1.0 });
    const r1 = await post(stale);
    const j1 = await r1.json();
    assert.strictEqual(j1.accepted, false);

    const newer = makeEntry(kp, { statsAt: '2026-07-11T00:00:00.000Z', globalKm2: 99.5 });
    const r2 = await post(newer);
    assert.deepStrictEqual(await r2.json(), { accepted: true, reason: '' });
    const e = await (await fetch(`${srv.base}/entries/peer-a`)).json();
    assert.strictEqual(e.globalKm2, 99.5);
  });

  await t.test('TOFU: same peerId under a new key refused', async () => {
    const kp2 = makeKeyPair();
    const r = await post(
      makeEntry(kp2, { statsAt: '2026-07-12T00:00:00.000Z' }),
    );
    const j = await r.json();
    assert.strictEqual(j.accepted, false);
    assert.match(j.reason, /TOFU/);
  });

  await t.test('future skew >24h refused', async () => {
    const future = new Date(Date.now() + 48 * 3600 * 1000).toISOString();
    const r = await post(makeEntry(kp, { statsAt: future }));
    const j = await r.json();
    assert.strictEqual(j.accepted, false);
    assert.match(j.reason, /future/);
  });

  await t.test('GET /monthly + /index + single peer 404', async () => {
    const m = await (await fetch(`${srv.base}/monthly/2026-07`)).json();
    assert.ok(Array.isArray(m) && m.length === 2);
    assert.ok(m[0].km2 >= m[1].km2);

    const idx = await (await fetch(`${srv.base}/index`)).json();
    assert.strictEqual(idx.entries.length, 2);
    assert.match(idx.entries[0].hash, /^[0-9a-f]{16}$/);

    const nf = await fetch(`${srv.base}/entries/nobody`);
    assert.strictEqual(nf.status, 404);
  });
});

test('leaderboard write token', async (t) => {
  const srv = await startServer({ LB_WRITE_TOKEN: 'sekrit' });
  t.after(() => srv.stop());
  const kp = makeKeyPair();
  const entry = makeEntry(kp);

  const noAuth = await fetch(`${srv.base}/entries`, {
    method: 'POST',
    body: JSON.stringify(entry),
  });
  assert.strictEqual(noAuth.status, 401);

  const ok = await fetch(`${srv.base}/entries`, {
    method: 'POST',
    headers: { authorization: 'Bearer sekrit' },
    body: JSON.stringify(entry),
  });
  assert.strictEqual(ok.status, 200);

  // reads stay public
  const g = await fetch(`${srv.base}/entries`);
  assert.strictEqual(g.status, 200);
});

test('persistence survives restart', async (t) => {
  const srv = await startServer();
  const kp = makeKeyPair();
  await fetch(`${srv.base}/entries`, {
    method: 'POST',
    body: JSON.stringify(makeEntry(kp)),
  });
  await srv.stop(); // SIGTERM → flush

  const srv2 = await startServer({ DATA_DIR: srv.dataDir, PORT: String(srv.port + 1) });
  t.after(() => srv2.stop());
  const list = await (await fetch(`${srv2.base}/entries`)).json();
  assert.strictEqual(list.length, 1);
  assert.strictEqual(list[0].peerId, 'peer-a');
});

test('group relay: broadcast + targeted routing + isolation', async (t) => {
  const srv = await startServer();
  t.after(() => srv.stop());

  const a = await wsConnect(srv.port, '/group/v1/ws?group=trip&peer=aaa');
  const b = await wsConnect(srv.port, '/group/v1/ws?group=trip&peer=bbb');
  const c = await wsConnect(srv.port, '/group/v1/ws?group=trip&peer=ccc');
  const outsider = await wsConnect(srv.port, '/group/v1/ws?group=other&peer=zzz');
  t.after(() => [a, b, c, outsider].forEach((x) => x.close()));

  await t.test('broadcast reaches room members only, not sender', async () => {
    a.send('{"t":"hello","fid":"aaa"}');
    assert.strictEqual(await b.next(), '{"t":"hello","fid":"aaa"}');
    assert.strictEqual(await c.next(), '{"t":"hello","fid":"aaa"}');
    await assert.rejects(outsider.next(500), /timeout/);
  });

  await t.test('targeted @peer| routes to one peer, prefix stripped', async () => {
    a.send('@bbb|{"t":"chat","d":{"text":"hi"}}');
    assert.strictEqual(await b.next(), '{"t":"chat","d":{"text":"hi"}}');
    await assert.rejects(c.next(500), /timeout/);
  });

  await t.test('opaque encrypted lines pass through untouched', async () => {
    const blob = 'v1|' + 'A'.repeat(5000);
    b.send(blob);
    assert.strictEqual(await a.next(), blob);
    assert.strictEqual(await c.next(), blob);
  });

  await t.test('status endpoint counts rooms/clients', async () => {
    const s = await (await fetch(`${srv.base}/api/status`)).json();
    assert.strictEqual(s.modules.group.rooms, 2);
    assert.strictEqual(s.modules.group.clients, 4);
    assert.ok(s.modules.group.relayed >= 4);
  });
});

test('group relay: token auth + bad params', async (t) => {
  const srv = await startServer({ GROUP_TOKEN: 'roomkey' });
  t.after(() => srv.stop());

  await assert.rejects(
    wsConnect(srv.port, '/group/v1/ws?group=trip&peer=aaa'),
    /401/,
  );
  await assert.rejects(
    wsConnect(srv.port, '/group/v1/ws?group=BAD*ID&peer=aaa&token=roomkey'),
    /400/,
  );
  const ok = await wsConnect(srv.port, '/group/v1/ws?group=trip&peer=aaa&token=roomkey');
  ok.close();

  const info = await (await fetch(`${srv.base}/group/v1/info`)).json();
  assert.strictEqual(info.auth, true);
});
