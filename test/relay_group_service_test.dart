// Integration test: RelayGroupService (the app's cloud-relay transport)
// against the REAL backend in `backends/` — a node process is spawned on a
// random port, clients join a room, and we assert presence, every message
// type the app uses, targeted delivery, end-to-end encryption, room
// isolation, and reconnect-after-server-restart.
//
// Requires `node` (>=20) on PATH; skipped automatically when missing.
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/group/relay_group_service_io.dart';
import 'package:explore_journal/services/group/group_types.dart';
import 'package:explore_journal/services/group/p2p_crypto.dart';

import 'helpers/spawn_backend.dart';

void main() {
  late SpawnedBackend backend;
  var nodeAvailable = false;

  setUpAll(() async {
    nodeAvailable = await hasNode();
    if (!nodeAvailable) return;
    backend = await spawnBackend();
  });

  tearDownAll(() async {
    if (nodeAvailable) await backend.stop();
  });

  RelayGroupService svc(String id, String name,
          {String group = '云南 Trip!', P2PCrypto? c}) =>
      RelayGroupService(
        selfId: id,
        selfName: name,
        groupId: group,
        selfColor: 0xFF26A69A,
        serverUrl: backend.baseUrl,
        crypto: c,
      );

  test('relay end-to-end: presence + all message types + E2E + isolation',
      () async {
    if (!nodeAvailable) {
      markTestSkipped('node not available');
      return;
    }
    final crypto = P2PCrypto.fromPassphrase('口令123');

    final a = svc('aaaa-1111', '阿明', c: crypto);
    final b = svc('bbbb-2222', '小红', c: crypto);
    final c = svc('cccc-3333', '老王', c: crypto);
    // Same room name, but NO passphrase — must not be able to read anything.
    final eavesdropper = svc('eeee-9999', '偷听者');
    // Different room entirely.
    final outsider = svc('zzzz-0000', '路人', group: '别的团', c: crypto);

    final aMsgs = <GroupMessage>[];
    final bMsgs = <GroupMessage>[];
    final cMsgs = <GroupMessage>[];
    final eveMsgs = <GroupMessage>[];
    final outMsgs = <GroupMessage>[];
    a.messages.listen(aMsgs.add);
    b.messages.listen(bMsgs.add);
    c.messages.listen(cMsgs.add);
    eavesdropper.messages.listen(eveMsgs.add);
    outsider.messages.listen(outMsgs.add);

    await a.start();
    await b.start();
    await c.start();
    await eavesdropper.start();
    await outsider.start();
    await Future.delayed(const Duration(milliseconds: 800));

    // ── presence ─────────────────────────────────────────────────────
    final aPeers = <String>{for (final m in aMsgs) m.fromId};
    expect(aPeers, containsAll(['bbbb-2222', 'cccc-3333']));
    expect(aPeers, isNot(contains('aaaa-1111')));

    // ── broadcast chat + location ────────────────────────────────────
    await a.sendChat('大家好！');
    await a.broadcastLocation(lat: 25.0389, lng: 102.7183, heading: 90);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(bMsgs.where((m) => m.type == 'chat').map((m) => m.data['text']),
        contains('大家好！'));
    final cLoc = cMsgs.where((m) => m.type == 'location').toList();
    expect(cLoc, isNotEmpty);
    expect(cLoc.last.data['lat'], closeTo(25.0389, 1e-9));
    expect(cLoc.last.data['heading'], closeTo(90, 1e-9));

    // ── PTT voice: broadcast bytes survive base64 roundtrip ──────────
    final pcm = List<int>.generate(4096, (i) => (i * 31) & 0xff);
    await a.sendVoice(pcm, 'audio/wav');
    await a.sendVoiceEnd();
    await Future.delayed(const Duration(milliseconds: 500));
    final bVoice = bMsgs.where((m) => m.type == 'voice').toList();
    expect(bVoice, hasLength(1));
    expect(base64.decode(bVoice.single.data['audio'] as String), pcm);
    expect(bVoice.single.data['mime'], 'audio/wav');
    expect(bMsgs.where((m) => m.type == 'voice_end'), hasLength(1));

    // ── targeted voice: only the addressee hears it ──────────────────
    await a.sendVoiceTo('cccc-3333', pcm, 'audio/ogg');
    await Future.delayed(const Duration(milliseconds: 500));
    expect(cMsgs.where((m) => m.data['mime'] == 'audio/ogg'), hasLength(1));
    expect(bMsgs.where((m) => m.data['mime'] == 'audio/ogg'), isEmpty);

    // ── music sync ───────────────────────────────────────────────────
    await b.sendMusicPlay(
        url: 'https://cdn.example.com/song.mp3',
        title: '夜空中最亮的星',
        artist: '逃跑计划',
        positionMs: 42500);
    await b.sendMusicStop();
    await Future.delayed(const Duration(milliseconds: 500));
    final aPlay = aMsgs.where((m) => m.type == 'music_play').toList();
    expect(aPlay, hasLength(1));
    expect(aPlay.single.data['title'], '夜空中最亮的星');
    expect(aPlay.single.data['pos'], 42500);
    expect(cMsgs.where((m) => m.type == 'music_stop'), hasLength(1));

    // ── custom messages (leaderboard gossip rides this path) ─────────
    await c.broadcastCustom('lb_hello', {'h': 'deadbeef', 'n': 3});
    await c.sendCustomTo('aaaa-1111', 'lb_pull', const {});
    await Future.delayed(const Duration(milliseconds: 500));
    expect(
        aMsgs
            .where((m) => m.type == 'lb_hello')
            .map((m) => m.data['h']),
        contains('deadbeef'));
    expect(aMsgs.where((m) => m.type == 'lb_pull'), hasLength(1));
    expect(bMsgs.where((m) => m.type == 'lb_pull'), isEmpty,
        reason: 'targeted custom must not reach third parties');

    // ── targeted chat ────────────────────────────────────────────────
    await a.sendChatTo('bbbb-2222', '悄悄话');
    await Future.delayed(const Duration(milliseconds: 500));
    expect(bMsgs.where((m) => m.data['text'] == '悄悄话'), hasLength(1));
    expect(cMsgs.where((m) => m.data['text'] == '悄悄话'), isEmpty);

    // ── E2E crypto + room isolation ──────────────────────────────────
    expect(eveMsgs, isEmpty,
        reason: 'no-passphrase eavesdropper must decode nothing');
    expect(outMsgs, isEmpty, reason: 'other room must see nothing');

    // ── peer state carries live position for trail rendering ─────────
    final bPeerA = await b.peers
        .firstWhere((l) => l.any((p) => p.id == 'aaaa-1111' && p.lat != null))
        .timeout(const Duration(seconds: 3), onTimeout: () {
      // Stream may have settled before we subscribed — poke it.
      a.broadcastLocation(lat: 25.0389, lng: 102.7183);
      return b.peers.firstWhere(
          (l) => l.any((p) => p.id == 'aaaa-1111' && p.lat != null));
    });
    final pa = bPeerA.firstWhere((p) => p.id == 'aaaa-1111');
    expect(pa.lat, closeTo(25.0389, 1e-9));
    expect(pa.name, '阿明');

    await a.stop();
    await b.stop();
    await c.stop();
    await eavesdropper.stop();
    await outsider.stop();
  });

  test('client auto-reconnects after server restart (same port)', () async {
    if (!nodeAvailable) {
      markTestSkipped('node not available');
      return;
    }
    final crypto = P2PCrypto.fromPassphrase('口令123');
    final a = svc('rrrr-0001', '重连甲', group: '重连团', c: crypto);
    final b = svc('rrrr-0002', '重连乙', group: '重连团', c: crypto);
    final bMsgs = <GroupMessage>[];
    b.messages.listen(bMsgs.add);
    await a.start();
    await b.start();
    await Future.delayed(const Duration(milliseconds: 500));

    // Kill the backend, then bring it back on the SAME port + data dir.
    final port = backend.port;
    final dataDir = backend.dataDir;
    await backend.stop(deleteData: false);
    await Future.delayed(const Duration(milliseconds: 300));
    backend = await spawnBackend(port: port, dataDir: dataDir);

    // Both clients reconnect with 2s-backoff; give them a comfortable
    // window, then verify traffic flows again.
    var delivered = false;
    for (var i = 0; i < 20 && !delivered; i++) {
      await a.sendChat('回来了吗 $i');
      await Future.delayed(const Duration(seconds: 1));
      delivered = bMsgs.any((m) => m.type == 'chat');
    }
    expect(delivered, isTrue,
        reason: 'chat must flow again after server restart');

    await a.stop();
    await b.stop();
  });

  test('bad server URL surfaces an error on start', () async {
    if (!nodeAvailable) {
      markTestSkipped('node not available');
      return;
    }
    final bad = RelayGroupService(
      selfId: 'xxxx',
      selfName: 'x',
      groupId: 'g',
      selfColor: 0,
      serverUrl: 'http://127.0.0.1:1', // nothing listens on port 1
    );
    await expectLater(bad.start(), throwsA(anything));
    await bad.stop();
  });
}
