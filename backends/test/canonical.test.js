'use strict';

// Cross-language contract test: the fixture was produced by the app's own
// Dart model + signing code (tool/gen_lb_vector.dart). If these pass, the
// server's canonical bytes / hashing / verification are byte-compatible
// with real clients.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const { sortedJson, canonicalOf, contentHash, verifyEntry } =
  require('../server/lib/canonical');

const vec = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'fixtures', 'lb_vector.json'), 'utf8'),
);

test('canonical JSON matches Dart byte-for-byte', () => {
  assert.strictEqual(sortedJson(canonicalOf(vec.entry)), vec.canonical);
});

test('contentHash matches Dart', () => {
  assert.strictEqual(contentHash(vec.entry), vec.contentHash);
});

test('Dart-signed entry verifies', () => {
  assert.strictEqual(verifyEntry(vec.entry), true);
});

test('tampered entry (score inflated after signing) is rejected', () => {
  assert.strictEqual(verifyEntry(vec.tampered), false);
});

test('sortedJson number normalisation mirrors Dart', () => {
  // whole double → int form; fractional → shortest repr
  assert.strictEqual(sortedJson({ a: 3.0, b: 3.5, c: 0 }), '{"a":3,"b":3.5,"c":0}');
  assert.strictEqual(sortedJson([true, false, null, 'x']), '[true,false,null,"x"]');
});
