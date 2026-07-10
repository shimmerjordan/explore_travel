'use strict';

// Tiny leveled logger. One line per event, ISO timestamp, no deps.
// LOG_LEVEL=trace|info|warn|error (default info).

const LEVELS = { trace: 0, info: 1, warn: 2, error: 3 };
const threshold = LEVELS[(process.env.LOG_LEVEL || 'info').toLowerCase()] ?? 1;

function emit(level, tag, msg) {
  if (LEVELS[level] < threshold) return;
  const line = `${new Date().toISOString()} [${level}] [${tag}] ${msg}`;
  if (level === 'error') process.stderr.write(line + '\n');
  else process.stdout.write(line + '\n');
}

module.exports = {
  trace: (tag, msg) => emit('trace', tag, msg),
  info: (tag, msg) => emit('info', tag, msg),
  warn: (tag, msg) => emit('warn', tag, msg),
  error: (tag, msg) => emit('error', tag, msg),
};
