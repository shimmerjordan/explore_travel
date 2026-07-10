// Generates a signed leaderboard entry test vector for the backend's
// cross-language signature tests. Run from the repo root:
//
//   dart run tool/gen_lb_vector.dart > backends/test/fixtures/lb_vector.json
//
// Uses the SAME model + signing code as the app, so the fixture is by
// construction byte-compatible with what real clients send.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:explore_journal/services/leaderboard/leaderboard_model.dart';

Future<void> main() async {
  final alg = Ed25519();
  // Deterministic seed so the fixture is stable across regenerations.
  final seed = List<int>.generate(32, (i) => (i * 7 + 3) & 0xff);
  final kp = await alg.newKeyPairFromSeed(seed);
  final pub = await kp.extractPublicKey();
  final pubB64 = base64.encode(pub.bytes);

  final entry = LeaderboardEntry(
    peerId: 'test-peer-0001',
    publicKey: pubB64,
    displayName: '测试者 Tester ✓',
    avatarBase64: '',
    globalKm2: 12345.6789012345,
    globalPercent: 0.0024204821,
    monthKm2: {'2026-05': 4.5, '2026-04': 12.3, '2026-07': 0.0186378065},
    statsAt: DateTime.utc(2026, 7, 10, 8, 30, 12, 345),
    signature: '',
  );
  final sig = await alg.sign(entry.canonicalBytes(), keyPair: kp);
  final signed = entry.copyWith(signature: base64.encode(sig.bytes));

  // A tampered copy (score inflated after signing) for the negative test.
  final tampered = {...signed.toJson(), 'globalKm2': 999999.0};

  stdout.write(const JsonEncoder.withIndent('  ').convert({
    'entry': signed.toJson(),
    'canonical': utf8.decode(signed.canonicalBytes()),
    'contentHash': signed.contentHash(),
    'tampered': tampered,
  }));
}
