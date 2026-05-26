# explore_journal — Leaderboard Server API

> If you're considering running a community leaderboard server for
> `explore_journal`, this document is the contract. Implement these endpoints
> and the app will sync to your server out-of-the-box. No backend is
> mandatory — the app's primary path is decentralised P2P merge — but a
> server lets users who never meet anyone IRL still see a global ranking.

## Design properties to preserve

The decentralised path the app already does is:

1. Each device generates an Ed25519 keypair once. The `peerId` is the
   stable per-device UUID; the public key travels in every entry the
   device emits.
2. Every leaderboard entry is signed over its canonical JSON body
   (`canonicalBytes()` in `leaderboard_model.dart`). Anyone can verify.
3. Conflict resolution is **Last-Writer-Wins by `statsAt`**, per `peerId`.
4. Trust-On-First-Use on `publicKey`: if a `peerId` has already been seen
   with key K, a later entry under a different key for the same peerId
   MUST be rejected. (Rotation requires picking a new peerId.)
5. Future-timestamp defence: entries whose `statsAt` is more than 24h
   ahead of the server's clock SHOULD be clamped to "now" before storing,
   so a peer cannot fast-forward to overwrite the future.

**A server implementing these endpoints should enforce the same rules.**
The app re-verifies signatures on every pull, so a sloppy server only
hurts itself — but its users will see entries silently disappear.

## Entry schema

Canonical JSON of one entry (fields are alphabetised by the producer):

```jsonc
{
  "avatarBase64": "string",         // base64 JPEG, may be ""
  "displayName": "string",
  "globalKm2": 12345.6789012345,     // float, double precision
  "globalPercent": 0.0024204821,
  "monthKm2": { "2026-04": 12.3, "2026-05": 4.5 },
  "peerId": "uuid string",
  "publicKey": "base64 raw Ed25519 (32 bytes)",
  "signature": "base64 raw Ed25519 (64 bytes)",
  "statsAt": "2026-05-22T10:11:12.345Z"
}
```

The signature covers the canonical bytes of every field EXCEPT
`signature` itself, with keys sorted ASCII and no whitespace. See
`_sortedJson` in `leaderboard_model.dart` for the exact algorithm — it's
intentionally simple so server implementations in any language can
recreate it.

## Endpoints

All routes are JSON in, JSON out. Encoding: UTF-8.

### `GET /entries` — full registry

Returns every entry the server knows about, one per peer.

**Response 200**:
```json
[ { "peerId": "...", ... }, { "peerId": "...", ... } ]
```

**Notes for implementers**: the app polls this on app start and when the
user opens the leaderboard screen. Cache the full body for a few seconds
to absorb herds; a Cache-Control of `max-age=15` is reasonable. Return
entries in any order — the client sorts.

### `GET /entries/{peerId}` — single peer

**Response 200**: the entry object.
**Response 404**: peer unknown.

### `POST /entries` — submit signed entry

Body: a single entry object.

**Response 200**: `{ "accepted": true, "reason": "" }` — server stored it
(or already had an equal/newer copy).

**Response 200**: `{ "accepted": false, "reason": "string" }` — entry
was valid JSON but the server declined (stale, key mismatch, etc.). The
client logs and moves on.

**Response 400**: malformed JSON or missing required fields.

**Response 422**: signature verification failed.

A server SHOULD verify the signature and refuse stale (older `statsAt`)
or TOFU-violating entries. If it returns 200/accepted but the client
later pulls a different entry, the client's local LWW will sort it out
on the next merge.

### `GET /monthly/{yyyy-mm}` — month leaderboard

Convenience endpoint that returns each peer's `monthKm2["yyyy-mm"]`
(defaulting to 0) sorted descending. Recomputable from `GET /entries`,
provided for low-bandwidth clients.

**Response 200**:
```json
[
  { "peerId": "...", "displayName": "...", "avatarBase64": "...",
    "km2": 123.4, "publicKey": "...", "signature": "...",
    "statsAt": "..." }
]
```

### `GET /index` — quick freshness probe

Returns one short hash per peer so a client can decide whether to pull
the full `/entries` body. Inspired by IMAP UIDVALIDITY/UID — cheap to
diff.

**Response 200**:
```json
{ "entries": [ { "peerId": "...", "hash": "16-hex-chars" } ] }
```

`hash` is the 16-char content hash defined by
`LeaderboardEntry.contentHash()`. A client that already has the same
hash for the peer locally skips the pull.

## Rate-limiting & abuse

* Recommend per-IP limits: 60 reads/min, 10 writes/min.
* The Ed25519 verification is the cheap part (≈80 µs); JSON parsing and
  TOFU lookups dominate.
* If you accept anonymous writes, add a tiny proof-of-work (e.g. a
  base64 `nonce` whose sha256 must start with N zero bits) at the
  request level. The app will surface a `X-Pow-Challenge` header back
  to the user if the server returns 429 with one.
* Storage cost: an entry maxes at ~30 KB with avatar; a million peers
  is ~30 GB. Eviction policy is up to you, but keep at least the latest
  entry per peer or the LWW invariant breaks for users syncing to your
  server only.

## Optional auth

`Authorization: Bearer <token>` is sent when the user has configured
`leaderboardServerToken` in app settings. Servers MAY treat unauth'd
GETs as public but require a token for POST.

## Reference implementation

A minimal Cloudflare Workers + KV implementation is in
`docs/leaderboard-server-reference/` (~150 LoC). It enforces signatures
and TOFU but defers rate limiting to Cloudflare's free tier.

## Versioning

This document is v1. Breaking changes ship under `/v2/...`. The app
sends `Accept: application/vnd.explore_journal.leaderboard+json; v=1`
on every request — servers MAY reject unknown versions with 406.
