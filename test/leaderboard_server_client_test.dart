// Integration test: the app's leaderboard client stack (LeaderboardService
// signing + HttpLeaderboardClient) against the REAL `backends/` server —
// verifying byte-exact data roundtrips, client-side signature verification
// of everything the server returns, and that the server enforces the same
// LWW / TOFU rules the P2P mesh does.
//
// Requires `node` (>=20) on PATH; skipped automatically when missing.
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/leaderboard/leaderboard_contributors.dart';
import 'package:explore_journal/services/leaderboard/leaderboard_model.dart';
import 'package:explore_journal/services/leaderboard/leaderboard_service.dart';

import 'helpers/spawn_backend.dart';

Future<Map<String, dynamic>> _getJson(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return {'status': resp.statusCode, 'body': body};
  } finally {
    client.close(force: true);
  }
}

void main() {
  late SpawnedBackend backend;
  var nodeAvailable = false;
  final svc = LeaderboardService();

  setUpAll(() async {
    nodeAvailable = await hasNode();
    if (!nodeAvailable) return;
    backend = await spawnBackend();
  });

  tearDownAll(() async {
    if (nodeAvailable) await backend.stop();
  });

  LeaderboardEntry unsigned({
    required String peerId,
    required String publicKey,
    String name = '测试者甲',
    double km2 = 1234.5678901234,
    Map<String, double> months = const {'2026-06': 100.25, '2026-07': 42.0},
    DateTime? at,
  }) =>
      LeaderboardEntry(
        peerId: peerId,
        publicKey: publicKey,
        displayName: name,
        avatarBase64: '',
        globalKm2: km2,
        globalPercent: km2 / 510072000.0,
        monthKm2: months,
        statsAt: at ?? DateTime.utc(2026, 7, 10, 12, 0, 0),
        signature: '',
      );

  test('push → fetchAll roundtrip is byte-exact and verifies client-side',
      () async {
    if (!nodeAvailable) {
      markTestSkipped('node not available');
      return;
    }
    final keys = await svc.generateKeyPair();
    final entry = await svc.sign(
        unsigned(peerId: 'peer-甲', publicKey: keys.publicKey),
        keys.privateKey);

    final client = HttpLeaderboardClient(baseUrl: backend.baseUrl);
    await client.push(entry);

    final all = await client.fetchAll();
    final got = all.singleWhere((e) => e.peerId == 'peer-甲');

    // Data correctness: every field survives the server roundtrip exactly.
    expect(got.toJson(), entry.toJson());
    expect(got.contentHash(), entry.contentHash());
    expect(got.globalKm2, entry.globalKm2); // double precision intact
    expect(got.monthKm2, entry.monthKm2);
    expect(got.statsAt, entry.statsAt);

    // The signature the server stored still verifies with the app's own
    // Ed25519 code — the exact check every client runs on pull.
    expect(await svc.verify(got), isTrue);
  });

  test('server enforces LWW: older push does not overwrite', () async {
    if (!nodeAvailable) {
      markTestSkipped('node not available');
      return;
    }
    final keys = await svc.generateKeyPair();
    final client = HttpLeaderboardClient(baseUrl: backend.baseUrl);

    final newer = await svc.sign(
        unsigned(
            peerId: 'peer-lww',
            publicKey: keys.publicKey,
            km2: 999.0,
            at: DateTime.utc(2026, 7, 10)),
        keys.privateKey);
    await client.push(newer);

    // A validly-signed but OLDER snapshot must be ignored (server returns
    // 200 accepted:false — the client call succeeds, state is unchanged).
    final older = await svc.sign(
        unsigned(
            peerId: 'peer-lww',
            publicKey: keys.publicKey,
            km2: 1.0,
            at: DateTime.utc(2026, 7, 1)),
        keys.privateKey);
    await client.push(older);

    final got = (await client.fetchAll())
        .singleWhere((e) => e.peerId == 'peer-lww');
    expect(got.globalKm2, 999.0);
  });

  test('server enforces TOFU: same peerId under a new key is refused',
      () async {
    if (!nodeAvailable) {
      markTestSkipped('node not available');
      return;
    }
    final keys1 = await svc.generateKeyPair();
    final keys2 = await svc.generateKeyPair();
    final client = HttpLeaderboardClient(baseUrl: backend.baseUrl);

    await client.push(await svc.sign(
        unsigned(
            peerId: 'peer-tofu',
            publicKey: keys1.publicKey,
            at: DateTime.utc(2026, 7, 9)),
        keys1.privateKey));

    // Impostor: valid signature, later timestamp, but a different keypair.
    await client.push(await svc.sign(
        unsigned(
            peerId: 'peer-tofu',
            publicKey: keys2.publicKey,
            km2: 777777.0,
            at: DateTime.utc(2026, 7, 10)),
        keys2.privateKey));

    final got = (await client.fetchAll())
        .singleWhere((e) => e.peerId == 'peer-tofu');
    expect(got.publicKey, keys1.publicKey);
    expect(got.globalKm2, isNot(777777.0));
  });

  test('tampered entry is rejected with 422', () async {
    if (!nodeAvailable) {
      markTestSkipped('node not available');
      return;
    }
    final keys = await svc.generateKeyPair();
    final signed = await svc.sign(
        unsigned(peerId: 'peer-forge', publicKey: keys.publicKey),
        keys.privateKey);
    // Inflate the score AFTER signing.
    final forged = LeaderboardEntry.fromJson(
        {...signed.toJson(), 'globalKm2': 8888888.0});
    final client = HttpLeaderboardClient(baseUrl: backend.baseUrl);
    await expectLater(client.push(forged), throwsA(anything));
    expect((await client.fetchAll()).where((e) => e.peerId == 'peer-forge'),
        isEmpty);
  });

  test('/monthly and /index agree with pushed data', () async {
    if (!nodeAvailable) {
      markTestSkipped('node not available');
      return;
    }
    final k1 = await svc.generateKeyPair();
    final k2 = await svc.generateKeyPair();
    final client = HttpLeaderboardClient(baseUrl: backend.baseUrl);
    final e1 = await svc.sign(
        unsigned(
            peerId: 'peer-m1',
            publicKey: k1.publicKey,
            months: const {'2026-05': 50.5}),
        k1.privateKey);
    final e2 = await svc.sign(
        unsigned(
            peerId: 'peer-m2',
            publicKey: k2.publicKey,
            months: const {'2026-05': 200.75}),
        k2.privateKey);
    await client.push(e1);
    await client.push(e2);

    final monthly = await _getJson('${backend.baseUrl}/monthly/2026-05');
    expect(monthly['status'], 200);
    final list = (jsonDecode(monthly['body'] as String) as List)
        .cast<Map<String, dynamic>>();
    final ranked = list.where((r) => (r['km2'] as num) > 0).toList();
    expect(ranked.first['peerId'], 'peer-m2');
    expect((ranked.first['km2'] as num).toDouble(), 200.75);
    expect(ranked[1]['peerId'], 'peer-m1');

    // /index hashes must equal the app's own contentHash() — this is the
    // cheap freshness probe clients diff against.
    final idx = await _getJson('${backend.baseUrl}/index');
    final hashes = {
      for (final r in (jsonDecode(idx['body'] as String)['entries'] as List))
        r['peerId']: r['hash'],
    };
    expect(hashes['peer-m1'], e1.contentHash());
    expect(hashes['peer-m2'], e2.contentHash());
  });
}
