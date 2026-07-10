'use strict';

// Byte-exact mirror of `_sortedJson` / `canonicalBytes` in the app's
// `lib/services/leaderboard/leaderboard_model.dart`. Signatures are
// computed over these bytes, so any divergence breaks verification —
// change ONLY in lockstep with the Dart side (both are v1).

const crypto = require('node:crypto');

function sortedJson(value) {
  if (value === null || value === undefined) return 'null';
  const t = typeof value;
  if (t === 'number') {
    // Dart: whole doubles serialise via toInt().toString().
    if (Number.isInteger(value)) return String(value);
    // Shortest round-trip repr — same algorithm family as Dart's
    // double.toString() (both emit e.g. "0.0024204821", "1e-7").
    return String(value);
  }
  if (t === 'boolean') return value ? 'true' : 'false';
  if (t === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(sortedJson).join(',')}]`;
  if (t === 'object') {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${sortedJson(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

/**
 * Canonical form of one leaderboard entry (everything except `signature`).
 * `statsAt` is passed through as the string the client produced —
 * re-formatting a parsed date could change milliseconds/microseconds and
 * invalidate the signature.
 */
function canonicalOf(entry) {
  const months = {};
  for (const k of Object.keys(entry.monthKm2 || {}).sort()) {
    months[k] = entry.monthKm2[k];
  }
  return {
    avatarBase64: entry.avatarBase64 ?? '',
    displayName: entry.displayName ?? '',
    globalKm2: entry.globalKm2 ?? 0,
    globalPercent: entry.globalPercent ?? 0,
    monthKm2: months,
    peerId: entry.peerId ?? '',
    publicKey: entry.publicKey ?? '',
    statsAt: entry.statsAt ?? '',
  };
}

function canonicalBytes(entry) {
  return Buffer.from(sortedJson(canonicalOf(entry)), 'utf8');
}

/** 16-hex-char content hash — must match `LeaderboardEntry.contentHash()`. */
function contentHash(entry) {
  return crypto
    .createHash('sha256')
    .update(canonicalBytes(entry))
    .digest('hex')
    .slice(0, 16);
}

// Raw 32-byte Ed25519 public key → SPKI DER wrapper node:crypto accepts.
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

/** Verify an entry's Ed25519 signature. Never throws. */
function verifyEntry(entry) {
  try {
    const pub = Buffer.from(entry.publicKey, 'base64');
    const sig = Buffer.from(entry.signature, 'base64');
    if (pub.length !== 32 || sig.length !== 64) return false;
    const key = crypto.createPublicKey({
      key: Buffer.concat([SPKI_PREFIX, pub]),
      format: 'der',
      type: 'spki',
    });
    return crypto.verify(null, canonicalBytes(entry), key, sig);
  } catch {
    return false;
  }
}

module.exports = { sortedJson, canonicalOf, canonicalBytes, contentHash, verifyEntry };
