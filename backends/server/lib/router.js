'use strict';

// Minimal path router. Patterns are literal segments or `:param`.
// Matching is exact on segment count; the handler receives
// (req, res, { params, query, body }) where body is only populated for
// requests the router was asked to buffer (see maxBody option per route).

const { parse: parseUrl } = require('node:url');

class Router {
  constructor() {
    /** @type {{method:string,segs:string[],handler:Function,maxBody:number}[]} */
    this.routes = [];
  }

  /**
   * @param {string} method GET/POST/...
   * @param {string} pattern e.g. `/entries/:peerId`
   * @param {Function} handler async (req, res, ctx) => void
   * @param {{maxBody?: number}} [opts] buffer request body up to N bytes
   */
  add(method, pattern, handler, opts = {}) {
    this.routes.push({
      method: method.toUpperCase(),
      segs: pattern.split('/').filter(Boolean),
      handler,
      maxBody: opts.maxBody ?? 0,
    });
  }

  /** Find a route; returns null when nothing matches. */
  match(method, pathname) {
    const segs = pathname.split('/').filter(Boolean).map(decodeURIComponent);
    for (const r of this.routes) {
      if (r.method !== method) continue;
      if (r.segs.length !== segs.length) continue;
      const params = {};
      let ok = true;
      for (let i = 0; i < segs.length; i++) {
        const p = r.segs[i];
        if (p.startsWith(':')) params[p.slice(1)] = segs[i];
        else if (p !== segs[i]) { ok = false; break; }
      }
      if (ok) return { route: r, params };
    }
    return null;
  }

  /** Handle a request. Returns false when no route matched. */
  async dispatch(req, res) {
    const u = parseUrl(req.url, true);
    const m = this.match(req.method, u.pathname);
    if (!m) return false;
    const ctx = { params: m.params, query: u.query, body: null };
    if (m.route.maxBody > 0) {
      try {
        ctx.body = await readBody(req, m.route.maxBody);
      } catch (e) {
        sendJson(res, e.code === 'E_TOO_LARGE' ? 413 : 400, {
          error: e.message,
        });
        return true;
      }
    }
    await m.route.handler(req, res, ctx);
    return true;
  }
}

/** Buffer a request body up to maxBytes; rejects oversize early. */
function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const len = Number(req.headers['content-length'] || 0);
    if (len > maxBytes) {
      const e = new Error('body too large');
      e.code = 'E_TOO_LARGE';
      req.destroy();
      return reject(e);
    }
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > maxBytes) {
        const e = new Error('body too large');
        e.code = 'E_TOO_LARGE';
        req.destroy();
        return reject(e);
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function sendJson(res, status, obj, extraHeaders = {}) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
    ...extraHeaders,
  });
  res.end(body);
}

module.exports = { Router, sendJson, readBody };
