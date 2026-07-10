'use strict';

// Minimal server-side RFC 6455 WebSocket — enough for the group relay:
// text frames, fragmentation, ping/pong, clean close. No permessage-deflate
// (voice payloads are already compressed; JSON lines are small), no
// extensions, no client mode. ~200 lines instead of a dependency.

const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

const OP_CONT = 0x0;
const OP_TEXT = 0x1;
const OP_BIN = 0x2;
const OP_CLOSE = 0x8;
const OP_PING = 0x9;
const OP_PONG = 0xa;

/**
 * Complete the HTTP upgrade handshake and wrap the socket.
 * Returns null (and closes the socket) when the request is not a valid
 * WebSocket upgrade.
 */
function acceptUpgrade(req, socket, opts = {}) {
  const key = req.headers['sec-websocket-key'];
  const version = req.headers['sec-websocket-version'];
  if (
    !key ||
    version !== '13' ||
    !/upgrade/i.test(String(req.headers.connection || '')) ||
    String(req.headers.upgrade || '').toLowerCase() !== 'websocket'
  ) {
    socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return null;
  }
  const accept = crypto
    .createHash('sha1')
    .update(key + GUID)
    .digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  return new WsConn(socket, opts);
}

class WsConn extends EventEmitter {
  /**
   * @param {import('node:net').Socket} socket
   * @param {{maxMessage?: number, maxBuffered?: number}} opts
   */
  constructor(socket, opts = {}) {
    super();
    this.socket = socket;
    this.maxMessage = opts.maxMessage ?? 4 * 1024 * 1024;
    // A consumer that can't drain its send buffer gets dropped instead of
    // ballooning server memory; mobile clients reconnect automatically.
    this.maxBuffered = opts.maxBuffered ?? 4 * 1024 * 1024;
    this.alive = true;
    this.closed = false;
    this._buf = Buffer.alloc(0);
    this._frags = [];
    this._fragLen = 0;
    this._fragOp = 0;

    socket.setNoDelay(true);
    socket.on('data', (d) => this._onData(d));
    socket.on('error', () => this.destroy());
    socket.on('close', () => {
      if (!this.closed) {
        this.closed = true;
        this.emit('close');
      }
    });
  }

  _onData(d) {
    this._buf = this._buf.length ? Buffer.concat([this._buf, d]) : d;
    while (true) {
      const frame = this._parseFrame();
      if (frame === undefined) return; // need more bytes
      if (frame === null) return; // protocol error → destroyed
      this._onFrame(frame);
      if (this.closed) return;
    }
  }

  /** Returns {fin, op, payload} | undefined (incomplete) | null (fatal). */
  _parseFrame() {
    const b = this._buf;
    if (b.length < 2) return undefined;
    const fin = (b[0] & 0x80) !== 0;
    const rsv = b[0] & 0x70;
    const op = b[0] & 0x0f;
    const masked = (b[1] & 0x80) !== 0;
    let len = b[1] & 0x7f;
    let off = 2;
    if (rsv !== 0 || !masked) {
      // No extensions negotiated; client frames MUST be masked.
      this.destroy();
      return null;
    }
    if (len === 126) {
      if (b.length < off + 2) return undefined;
      len = b.readUInt16BE(off);
      off += 2;
    } else if (len === 127) {
      if (b.length < off + 8) return undefined;
      const big = b.readBigUInt64BE(off);
      if (big > BigInt(this.maxMessage)) {
        this.destroy();
        return null;
      }
      len = Number(big);
      off += 8;
    }
    if (len > this.maxMessage || this._fragLen + len > this.maxMessage) {
      this.destroy();
      return null;
    }
    if (b.length < off + 4 + len) return undefined;
    const mask = b.subarray(off, off + 4);
    off += 4;
    const payload = Buffer.allocUnsafe(len);
    for (let i = 0; i < len; i++) payload[i] = b[off + i] ^ mask[i & 3];
    this._buf = b.subarray(off + len);
    return { fin, op, payload };
  }

  _onFrame({ fin, op, payload }) {
    switch (op) {
      case OP_TEXT:
      case OP_BIN:
        if (!fin) {
          this._fragOp = op;
          this._frags = [payload];
          this._fragLen = payload.length;
        } else {
          this._emitMessage(op, payload);
        }
        break;
      case OP_CONT: {
        if (!this._frags.length && this._fragLen === 0 && this._fragOp === 0) {
          this.destroy();
          return;
        }
        this._frags.push(payload);
        this._fragLen += payload.length;
        if (fin) {
          const whole = Buffer.concat(this._frags, this._fragLen);
          const fop = this._fragOp;
          this._frags = [];
          this._fragLen = 0;
          this._fragOp = 0;
          this._emitMessage(fop, whole);
        }
        break;
      }
      case OP_PING:
        this._writeFrame(OP_PONG, payload);
        break;
      case OP_PONG:
        this.alive = true;
        break;
      case OP_CLOSE:
        this.close(1000);
        break;
      default:
        this.destroy();
    }
  }

  _emitMessage(op, payload) {
    this.alive = true;
    // The relay treats everything as opaque text lines.
    this.emit('message', payload.toString('utf8'), op === OP_BIN);
  }

  _writeFrame(op, payload) {
    if (this.closed || this.socket.destroyed) return false;
    if (this.socket.writableLength > this.maxBuffered) {
      // Slow consumer — cut it loose rather than queue unboundedly.
      this.destroy();
      return false;
    }
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.from([0x80 | op, len]);
    } else if (len < 65536) {
      header = Buffer.allocUnsafe(4);
      header[0] = 0x80 | op;
      header[1] = 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.allocUnsafe(10);
      header[0] = 0x80 | op;
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(len), 2);
    }
    this.socket.write(Buffer.concat([header, payload]));
    return true;
  }

  send(text) {
    return this._writeFrame(OP_TEXT, Buffer.from(text, 'utf8'));
  }

  ping() {
    this._writeFrame(OP_PING, Buffer.alloc(0));
  }

  close(code = 1000, reason = '') {
    if (this.closed) return;
    const r = Buffer.from(reason, 'utf8');
    const p = Buffer.allocUnsafe(2 + r.length);
    p.writeUInt16BE(code, 0);
    r.copy(p, 2);
    this._writeFrame(OP_CLOSE, p);
    this.closed = true;
    this.emit('close');
    // Give the close frame a moment to flush, then hard-close.
    setTimeout(() => this.socket.destroy(), 250).unref?.();
  }

  destroy() {
    if (this.closed) {
      this.socket.destroy();
      return;
    }
    this.closed = true;
    this.socket.destroy();
    this.emit('close');
  }
}

module.exports = { acceptUpgrade, WsConn };
