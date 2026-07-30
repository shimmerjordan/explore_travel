'use strict';

// Module switches: which halves of this server are running.
//
// The interesting failures here are all "silently wrong" ones — a module that
// is off but answers anyway, a module that is on but 404s, or a typo that turns
// something off without saying so. So every case below asserts observable
// behaviour (a status code, an exit code, a log line), never just config.

const { test } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const net = require('node:net');

const SERVER = path.join(__dirname, '..', 'server', 'server.js');

function start(env) {
  const p = spawn(process.execPath, [SERVER], {
    env: {
      ...process.env,
      DATA_DIR: fs.mkdtempSync('/tmp/ejmod-'),
      LOG_LEVEL: 'info',
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  p.out = '';
  p.err = '';
  p.stdout.on('data', (d) => (p.out += d));
  p.stderr.on('data', (d) => (p.err += d));
  return p;
}

/// Poll until the port answers instead of sleeping a guessed interval: a fixed
/// sleep is the reason this kind of test goes flaky on a loaded machine.
async function waitUp(port, proc, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (proc.exitCode !== null) {
      throw new Error(`server exited early (${proc.exitCode}): ${proc.err}`);
    }
    try {
      const res = await fetch(`http://127.0.0.1:${port}/healthz`);
      if (res.ok) return;
    } catch {
      /* not listening yet */
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`server never came up on ${port}: ${proc.err}${proc.out}`);
}

async function stop(p) {
  if (p.exitCode !== null) return;
  p.kill('SIGKILL');
  await new Promise((r) => p.on('exit', r));
}

/// Try a WebSocket upgrade by hand (no ws dependency) and report the status
/// line. `101` means the relay accepted it; anything else means it did not.
function upgradeStatus(port, urlPath) {
  return new Promise((resolve) => {
    const sock = net.connect(port, '127.0.0.1', () => {
      sock.write(
        `GET ${urlPath} HTTP/1.1\r\n` +
          `Host: 127.0.0.1:${port}\r\n` +
          'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n' +
          'Sec-WebSocket-Version: 13\r\n\r\n',
      );
    });
    let buf = '';
    const done = (v) => {
      sock.destroy();
      resolve(v);
    };
    sock.on('data', (d) => {
      buf += d;
      if (buf.includes('\r\n')) done(Number(buf.split(' ')[1]) || 0);
    });
    sock.on('error', () => done(0));
    sock.setTimeout(4000, () => done(0));
  });
}

test('两个模块都关闭时拒绝启动并说明原因', async () => {
  const p = start({ EJ_MODULE_LEADERBOARD: '0', EJ_MODULE_GROUP: '0', PORT: '19100' });
  // Race the exit against a deadline. Without this, a regression that removes
  // the guard makes the server *keep running* and the test hangs forever —
  // which is a far worse signal than a failed assertion, because a hung suite
  // looks like an infrastructure problem rather than a broken invariant.
  const code = await Promise.race([
    new Promise((r) => p.on('exit', r)),
    new Promise((r) => setTimeout(() => r('did-not-exit'), 5000)),
  ]);
  await stop(p);
  assert.notStrictEqual(
    code,
    'did-not-exit',
    '进程没有退出 —— 它带着零个模块把端口占住了，这正是那道守卫要防的事',
  );
  assert.notStrictEqual(code, 0, '应以非零码退出');
  const text = p.err + p.out;
  assert.match(text, /module/i, '日志要说清是模块配置问题');
  assert.match(text, /enable at least one/i, '要告诉运维怎么修，而不只是说它错了');
  // A port with nothing behind it is the outcome this guard exists to prevent:
  // it passes health checks while 404-ing everything real.
  await assert.rejects(fetch('http://127.0.0.1:19100/healthz'));
});

test('只开排行榜：HTTP 可用，WS 升级被拒', async () => {
  const p = start({ EJ_MODULE_GROUP: '0', PORT: '19101' });
  try {
    await waitUp(19101, p);
    assert.strictEqual((await fetch('http://127.0.0.1:19101/entries')).status, 200);

    const status = await (await fetch('http://127.0.0.1:19101/api/status')).json();
    assert.ok(status.modules.leaderboard, '排行榜应出现在 status 中');
    assert.ok(!('group' in status.modules), '关掉的组队模块不该出现在 status 中');

    // The relay is not merely unrouted, it was never constructed — so the
    // upgrade must be refused rather than handled.
    assert.notStrictEqual(
      await upgradeStatus(19101, '/group/v1/ws?room=r'),
      101,
      'WS 升级必须被拒',
    );
    assert.strictEqual((await fetch('http://127.0.0.1:19101/group/v1/info')).status, 404);
    assert.match(p.out, /modules=leaderboard\b/, '启动日志要报告实际启用了哪些模块');
  } finally {
    await stop(p);
  }
});

test('只开组队：排行榜路由 404，组队仍在', async () => {
  const p = start({ EJ_MODULE_LEADERBOARD: '0', PORT: '19102' });
  try {
    await waitUp(19102, p);
    for (const route of ['/entries', '/monthly', '/index']) {
      assert.strictEqual(
        (await fetch(`http://127.0.0.1:19102${route}`)).status,
        404,
        `${route} 应当 404`,
      );
    }
    assert.strictEqual((await fetch('http://127.0.0.1:19102/group/v1/info')).status, 200);
    const status = await (await fetch('http://127.0.0.1:19102/api/status')).json();
    assert.ok(status.modules.group);
    assert.ok(!('leaderboard' in status.modules));
  } finally {
    await stop(p);
  }
});

test('默认（不设变量）两个模块都在', async () => {
  const p = start({ PORT: '19103' });
  try {
    await waitUp(19103, p);
    const status = await (await fetch('http://127.0.0.1:19103/api/status')).json();
    assert.deepStrictEqual(
      Object.keys(status.modules).sort(),
      ['group', 'leaderboard'],
      '两个模块默认都应启用',
    );
  } finally {
    await stop(p);
  }
});

test('拼错的值不会静默关掉模块，而是保持启用并告警', async () => {
  // The dangerous direction is a typo that disables a service without saying
  // so. Staying enabled is recoverable and noisy; silently off is neither.
  const p = start({ EJ_MODULE_GROUP: 'flase', PORT: '19104' });
  try {
    await waitUp(19104, p);
    const status = await (await fetch('http://127.0.0.1:19104/api/status')).json();
    assert.ok(status.modules.group, '非法值时模块必须仍然启用');
    assert.match(p.out + p.err, /not a boolean/i, '必须为拼错的值告警');
  } finally {
    await stop(p);
  }
});

test('off / false / no 都能关闭，空串视为未设置', async () => {
  for (const [i, v] of ['off', 'false', 'no', 'FALSE'].entries()) {
    const port = String(19110 + i);
    const p = start({ EJ_MODULE_GROUP: v, PORT: port });
    try {
      await waitUp(Number(port), p);
      const status = await (await fetch(`http://127.0.0.1:${port}/api/status`)).json();
      assert.ok(!('group' in status.modules), `EJ_MODULE_GROUP=${v} 应关闭组队`);
    } finally {
      await stop(p);
    }
  }
  const p = start({ EJ_MODULE_GROUP: '', PORT: '19120' });
  try {
    await waitUp(19120, p);
    const status = await (await fetch('http://127.0.0.1:19120/api/status')).json();
    assert.ok(status.modules.group, '空串等同于未设置，应保持启用');
  } finally {
    await stop(p);
  }
});
