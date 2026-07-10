'use strict';

// JSON-file persistence with debounced atomic writes.
//
// Why not SQLite/Redis: the whole dataset (leaderboard entries) is a few
// MB at most and lives happily in memory. A JSON file + rename gives us
// crash-safe durability with zero dependencies and zero idle CPU — the
// cheapest possible footprint on a small ECS instance.

const fs = require('node:fs');
const path = require('node:path');
const log = require('./log');

class JsonStore {
  /**
   * @param {string} file absolute path of the JSON file
   * @param {*} initial value used when the file doesn't exist / is corrupt
   * @param {number} debounceMs collapse write bursts (default 2000)
   */
  constructor(file, initial, debounceMs = 2000) {
    this.file = file;
    this.debounceMs = debounceMs;
    this._timer = null;
    this._dirty = false;
    this.data = initial;
    try {
      this.data = JSON.parse(fs.readFileSync(file, 'utf8'));
      log.info('store', `loaded ${path.basename(file)}`);
    } catch (e) {
      if (e.code !== 'ENOENT') {
        log.warn('store', `${path.basename(file)} unreadable (${e.message}); starting fresh`);
        // Keep the corrupt file around for post-mortem instead of clobbering.
        try { fs.renameSync(file, `${file}.corrupt-${Date.now()}`); } catch {}
      }
    }
  }

  /** Mark dirty; actual disk write happens at most once per debounce window. */
  save() {
    this._dirty = true;
    if (this._timer) return;
    this._timer = setTimeout(() => {
      this._timer = null;
      this.flush();
    }, this.debounceMs);
    // Don't hold the process open just for a pending flush; shutdown calls
    // flush() explicitly.
    this._timer.unref?.();
  }

  /** Synchronous atomic write (tmp + rename). Safe to call at shutdown. */
  flush() {
    if (!this._dirty) return;
    this._dirty = false;
    const tmp = `${this.file}.tmp`;
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      fs.writeFileSync(tmp, JSON.stringify(this.data));
      fs.renameSync(tmp, this.file);
    } catch (e) {
      log.error('store', `flush ${path.basename(this.file)} failed: ${e.message}`);
    }
  }
}

module.exports = { JsonStore };
