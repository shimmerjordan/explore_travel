import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/models/models.dart';
import 'package:explore_journal/services/group/frp_engine.dart';
import 'package:explore_journal/services/group/group_probe.dart';
import 'package:explore_journal/services/group/group_probe_io.dart';
import 'package:explore_journal/services/group/group_wire.dart';

ProbeStep step(ProbeOutcome o, [String title = 's']) => ProbeStep(
      title: title,
      outcome: o,
      detail: '',
      elapsed: Duration.zero,
    );

void main() {
  group('ProbeReport.passed', () {
    test('全 pass 算通过', () {
      final r = ProbeReport(
          transport: GroupTransport.relay,
          steps: [step(ProbeOutcome.pass), step(ProbeOutcome.pass)]);
      expect(r.passed, isTrue);
    });

    test('info 与 skip 不参与判定', () {
      final r = ProbeReport(transport: GroupTransport.lan, steps: [
        step(ProbeOutcome.pass),
        step(ProbeOutcome.info),
        step(ProbeOutcome.skip),
      ]);
      expect(r.passed, isTrue);
    });

    test('任何一个 fail 就算不通过', () {
      final r = ProbeReport(transport: GroupTransport.frp, steps: [
        step(ProbeOutcome.pass),
        step(ProbeOutcome.fail, '连接 frps'),
      ]);
      expect(r.passed, isFalse);
    });

    test('summary 在失败时点名第一个失败的步骤', () {
      final r = ProbeReport(transport: GroupTransport.frp, steps: [
        step(ProbeOutcome.pass),
        step(ProbeOutcome.fail, '连接 frps'),
        step(ProbeOutcome.fail, '注册 proxy'),
      ]);
      expect(r.summary, contains('连接 frps'));
    });

    test('summary 在通过时报步数', () {
      final r = ProbeReport(
          transport: GroupTransport.relay,
          steps: [step(ProbeOutcome.pass), step(ProbeOutcome.pass)]);
      expect(r.summary, contains('2'));
    });
  });

  test('legacy zerotier 分派到 lan 探针', () {
    final p = GroupProbe.forTransport(
        GroupTransport.zerotier, const ProbeConfig(groupId: 'g'));
    expect(p.runtimeType.toString(), contains('Lan'));
  });

  group('_BaseProbe 共用逻辑（经 DebugProbe 驱动）', () {
    test('步骤逐条产出，且执行顺序与 steps() 一致', () async {
      final events = <String>[];
      final probe = DebugProbe(
        const ProbeConfig(groupId: 'g'),
        const ProbeDeps(),
        stepsBuilder: () => [
          () async {
            events.add('start-a');
            await Future<void>.delayed(const Duration(milliseconds: 10));
            events.add('end-a');
            return step(ProbeOutcome.pass, 'a');
          },
          () async {
            events.add('start-b');
            await Future<void>.delayed(const Duration(milliseconds: 10));
            events.add('end-b');
            return step(ProbeOutcome.pass, 'b');
          },
        ],
      );

      final sub = probe.run().listen((s) => events.add('emit-${s.title}'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await sub.cancel();

      // 关键点：a 的 end 在 b 的 start 之前——证明是串行逐条跑，不是并发也不是
      // 攒够全部结果后才一次性吐出来。
      expect(events,
          ['start-a', 'end-a', 'emit-a', 'start-b', 'end-b', 'emit-b']);
    });

    test('总预算耗尽后，其余步骤产出一条 skip 且不再继续', () async {
      final probe = DebugProbe(
        const ProbeConfig(groupId: 'g'),
        const ProbeDeps(
          timeouts: ProbeTimeouts(total: Duration(milliseconds: 10)),
        ),
        stepsBuilder: () => [
          () async {
            // 这一步本身耗时超过总预算，跑完后下一次循环检查才会触发跳过。
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return step(ProbeOutcome.pass, 'a');
          },
          () async => step(ProbeOutcome.pass, 'b'),
          () async => step(ProbeOutcome.pass, 'c'),
        ],
      );

      final results = await probe.run().toList();

      expect(results, hasLength(2));
      expect(results[0].title, 'a');
      expect(results[0].outcome, ProbeOutcome.pass);
      expect(results[1].outcome, ProbeOutcome.skip);
      expect(results[1].detail, contains('总时长超限'));
    });

    test('正常跑完 → cleanUp 恰好执行 1 次', () async {
      var cleanUpCalls = 0;
      final probe = DebugProbe(
        const ProbeConfig(groupId: 'g'),
        const ProbeDeps(),
        stepsBuilder: () => [
          () async => step(ProbeOutcome.pass, 'a'),
        ],
        onCleanUp: () async {
          cleanUpCalls++;
        },
      );

      await probe.run().drain<void>();

      expect(cleanUpCalls, 1);
    });

    test('跑到一半调用 cancel() → cleanUp 仍然恰好执行 1 次（回归：曾经会被执行两次）',
        () async {
      var cleanUpCalls = 0;
      final probe = DebugProbe(
        const ProbeConfig(groupId: 'g'),
        const ProbeDeps(),
        stepsBuilder: () => [
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return step(ProbeOutcome.pass, 'a');
          },
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return step(ProbeOutcome.pass, 'b');
          },
        ],
        onCleanUp: () async {
          cleanUpCalls++;
        },
      );

      final sub = probe.run().listen((_) {});
      // 在第一步完成之前发起 cancel：既触发 cancel() 自己的 cleanUp，也会让
      // run() 的 for 循环在下一次迭代发现 _cancelled 而从 finally 里再跑一次
      // ——这正是 Finding 1 描述的双跑场景。
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await probe.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(cleanUpCalls, 1);
    });
  });

  group('RelayProbe', relayTests);
  group('WebDavProbe', webdavTests);
  group('FrpProbe', frpTests);
  group('LanProbe', lanTests);
}

class _FakeSocket implements ProbeSocket {
  final String? frame;
  @override
  int? closeCode;
  bool closed = false;
  // closeCode isn't set by any current test but is part of the real
  // ProbeSocket surface; keep it constructible for future cases.
  // ignore: unused_element_parameter
  _FakeSocket({this.frame, this.closeCode});
  @override
  Future<String?> firstFrame(Duration timeout) async => frame;
  @override
  Future<void> close() async => closed = true;
}

ProbeDeps _deps({
  Map<String, ProbeHttpResponse>? http,
  Future<ProbeSocket> Function(Uri, Duration)? ws,
}) =>
    ProbeDeps(
      httpGet: (url, {headers, timeout = const Duration(seconds: 5)}) async {
        final r = http?[url.path];
        if (r == null) throw StateError('no fake for ${url.path}');
        return r;
      },
      wsConnect: ws,
    );

Future<List<ProbeStep>> _run(GroupProbe p) => p.run().toList();

void relayTests() {
  const cfg = ProbeConfig(
      groupId: 'g', relayServerUrl: 'https://ej-backend.example.org');

  test('健康 + 模块开 + WS 升级成功 → 通过，口令一致性标 skip', () async {
    final steps = await _run(RelayProbe(
      cfg,
      _deps(
        http: {
          '/healthz': const ProbeHttpResponse(200, 'ok'),
          '/api/status': const ProbeHttpResponse(
              200, '{"modules":["leaderboard","group"]}'),
        },
        ws: (u, t) async => _FakeSocket(frame: '{"type":"hello"}'),
      ),
    ));
    final report = ProbeReport(transport: GroupTransport.relay, steps: steps);
    expect(report.passed, isTrue);
    expect(steps.any((s) => s.outcome == ProbeOutcome.skip), isTrue,
        reason: '共享口令一致性单机测不出来，必须标 skip');
  });

  test('服务端关掉 group 模块 → 该步 fail 并给出 EJ_MODULE_GROUP 提示', () async {
    final steps = await _run(RelayProbe(
      cfg,
      _deps(
        http: {
          '/healthz': const ProbeHttpResponse(200, 'ok'),
          '/api/status': const ProbeHttpResponse(200, '{"modules":["leaderboard"]}'),
        },
        ws: (u, t) async => _FakeSocket(frame: null),
      ),
    ));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.hint, contains('EJ_MODULE_GROUP'));
  });

  test('令牌错导致 WS 被关 → 升级步 fail 并提示查中继令牌', () async {
    final steps = await _run(RelayProbe(
      cfg,
      _deps(
        http: {
          '/healthz': const ProbeHttpResponse(200, 'ok'),
          '/api/status': const ProbeHttpResponse(200, '{"modules":["group"]}'),
        },
        ws: (u, t) async => throw const WebSocketRejected(4401),
      ),
    ));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.title, contains('WebSocket'));
    expect(bad.hint, contains('令牌'));
  });

  test('地址没配 → 第一步就 fail，不发任何请求', () async {
    final steps = await _run(RelayProbe(
        const ProbeConfig(groupId: 'g'), const ProbeDeps()));
    expect(steps.first.outcome, ProbeOutcome.fail);
    expect(steps.length, 1);
  });
}

class _FakeDav implements ProbeDav {
  final int? failEnsureWith;
  final int? failWriteWith;
  final bool corruptReadBack;
  final List<String> calls = [];
  final Map<String, List<int>> files = {};
  _FakeDav({this.failEnsureWith, this.failWriteWith, this.corruptReadBack = false});

  @override
  Future<void> ensureDir(String path) async {
    calls.add('ensureDir $path');
    if (failEnsureWith != null) throw DavStatus(failEnsureWith!);
  }
  @override
  Future<void> write(String path, List<int> bytes) async {
    calls.add('write $path');
    if (failWriteWith != null) throw DavStatus(failWriteWith!);
    files[path] = bytes;
  }
  @override
  Future<List<int>> read(String path) async {
    calls.add('read $path');
    final b = files[path] ?? (throw DavStatus(404));
    return corruptReadBack ? [...b, 33] : b;
  }
  @override
  Future<void> remove(String path) async => calls.add('remove $path');
}

void webdavTests() {
  const cfg = ProbeConfig(
    groupId: 'g',
    webdavUrl: 'https://dav.example.org/dav',
    webdavUser: 'u',
    webdavPass: 'p',
  );

  test('目录可用 + 写入 + 读回一致 → 通过，并删掉探针文件', () async {
    final dav = _FakeDav();
    final steps = await _run(
        WebDavProbe(cfg, ProbeDeps(davClient: (_) => dav)));
    expect(ProbeReport(transport: GroupTransport.webrtc, steps: steps).passed,
        isTrue);
    expect(dav.calls.any((c) => c.startsWith('remove')), isTrue,
        reason: '探针文件必须清理掉');
  });

  test('401 → 凭据错，提示查用户名口令', () async {
    final steps = await _run(WebDavProbe(
        cfg, ProbeDeps(davClient: (_) => _FakeDav(failEnsureWith: 401))));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.detail, contains('401'));
    expect(bad.hint, contains('口令'));
  });

  test('403 → 权限不足，与 401 给不同提示', () async {
    final steps = await _run(WebDavProbe(
        cfg, ProbeDeps(davClient: (_) => _FakeDav(failWriteWith: 403))));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.hint, contains('只读'));
  });

  test('读回内容不一致 → fail（这是能当信令用的最后一道判定）', () async {
    final steps = await _run(WebDavProbe(
        cfg, ProbeDeps(davClient: (_) => _FakeDav(corruptReadBack: true))));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.title, contains('读回'));
  });

  test('地址或账号缺失 → 第一步 fail', () async {
    final steps = await _run(
        WebDavProbe(const ProbeConfig(groupId: 'g'), const ProbeDeps()));
    expect(steps.first.outcome, ProbeOutcome.fail);
    expect(steps.length, 1);
  });
}

class _FakeFrpEngine implements FrpEngine {
  final List<String> lines;
  final bool running;
  bool started = false;
  bool stopped = false;
  _FakeFrpEngine({this.lines = const [], this.running = false});

  @override
  Stream<String> get events => Stream.fromIterable(lines);
  @override
  Future<bool> isRunning() async => running || started;
  @override
  Future<void> start(String configToml) async => started = true;
  @override
  Future<void> reload(String configToml) async {}
  @override
  Future<void> stop() async => stopped = true;
}

void frpTests() {
  const cfg = ProbeConfig(
    groupId: 'g',
    passphrase: 'pw',
    frpServerAddr: 'frps.example.org',
    frpServerPort: 17000,
    frpToken: 't',
  );

  test('未组队时：临时启 frpc，login 成功 + proxy 上线 → 通过，且一定 stop', () async {
    final engine = _FakeFrpEngine(lines: const [
      'login to server success',
      'proxy added: [ej-g.probe]',
      'start proxy success',
    ]);
    final steps = await _run(FrpProbe(
      cfg,
      ProbeDeps(
        frpEngine: () => engine,
        tcpConnect: (h, p, t) async {},
      ),
    ));
    expect(ProbeReport(transport: GroupTransport.frp, steps: steps).passed, isTrue);
    expect(engine.started, isTrue);
    expect(engine.stopped, isTrue, reason: '临时 frpc 必须在 finally 里停掉');
  });

  test('login 失败（token 错）→ fail 并提示 auth.token 要一致', () async {
    final engine = _FakeFrpEngine(
        lines: const ['login to server failed: authorization failed']);
    final steps = await _run(FrpProbe(
      cfg,
      ProbeDeps(
        frpEngine: () => engine,
        tcpConnect: (h, p, t) async {},
        timeouts: const ProbeTimeouts(frpLogin: Duration(milliseconds: 200)),
      ),
    ));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.hint, contains('auth.token'));
  });

  test('TCP 连不上 frps → 在启 frpc 之前就 fail', () async {
    final engine = _FakeFrpEngine();
    final steps = await _run(FrpProbe(
      cfg,
      ProbeDeps(
        frpEngine: () => engine,
        tcpConnect: (h, p, t) async => throw const SocketException('refused'),
      ),
    ));
    expect(steps.any((s) => s.outcome == ProbeOutcome.fail), isTrue);
    expect(engine.started, isFalse, reason: '连不上就不该再启 frpc');
  });

  test('正在组队时：读现有 engine 状态，绝不 start/stop', () async {
    final engine = _FakeFrpEngine(running: true);
    final steps = await _run(FrpProbe(
      const ProbeConfig(
        groupId: 'g',
        passphrase: 'pw',
        frpServerAddr: 'frps.example.org',
        frpServerPort: 17000,
        groupRunning: true,
      ),
      ProbeDeps(frpEngine: () => engine, tcpConnect: (h, p, t) async {}),
    ));
    expect(engine.started, isFalse);
    expect(engine.stopped, isFalse);
    expect(steps.any((s) => s.detail.contains('正在运行')), isTrue);
  });

  test('没配 dashboard → 该步 skip 而不是 fail', () async {
    final steps = await _run(FrpProbe(
      cfg,
      ProbeDeps(
        frpEngine: () => _FakeFrpEngine(lines: const ['login to server success', 'start proxy success']),
        tcpConnect: (h, p, t) async {},
      ),
    ));
    expect(steps.any((s) => s.title.contains('dashboard') && s.outcome == ProbeOutcome.skip),
        isTrue);
  });

  test('地址没配 → 第一步 fail', () async {
    final steps = await _run(
        FrpProbe(const ProbeConfig(groupId: 'g'), const ProbeDeps()));
    expect(steps.first.outcome, ProbeOutcome.fail);
    expect(steps.length, 1);
  });
}

class _FakeDatagram implements ProbeDatagram {
  final bool joinOk;
  final int sendBytes;
  final int answers;
  bool closed = false;
  // sendBytes isn't overridden by any current test but is part of the real
  // ProbeDatagram surface; keep it constructible for future cases (same
  // pattern as _FakeSocket.closeCode above).
  // ignore: unused_element_parameter
  _FakeDatagram({this.joinOk = true, this.sendBytes = 42, this.answers = 0});
  @override
  bool joinMulticast() => joinOk;
  @override
  int send(List<int> data) => sendBytes;
  @override
  Future<int> countAnswers(Duration window) async => answers;
  @override
  Future<void> close() async => closed = true;
}

void lanTests() {
  const cfg = ProbeConfig(groupId: 'g');

  ProbeDeps deps({
    int meshPort = kMeshPortBase,
    bool meshFails = false,
    ProbeDatagram? dg,
  }) =>
      ProbeDeps(
        listInterfaces: () async =>
            [const ProbeIface(name: 'wlan0', address: '192.168.1.23')],
        bindMesh: (b, c) async =>
            meshFails ? throw const MeshPortUnavailable() : meshPort,
        openDatagram: () async => dg ?? _FakeDatagram(),
        timeouts: const ProbeTimeouts(multicast: Duration(milliseconds: 10)),
      );

  test('本机就绪且发现 2 个对端 → 通过，对端数是 info', () async {
    final steps = await _run(
        LanProbe(cfg, deps(dg: _FakeDatagram(answers: 2))));
    final report = ProbeReport(transport: GroupTransport.lan, steps: steps);
    expect(report.passed, isTrue);
    final peers = steps.firstWhere((s) => s.title.contains('对端'));
    expect(peers.outcome, ProbeOutcome.info);
    expect(peers.detail, contains('2'));
  });

  test('0 个对端仍算通过，但提示让对方也开启', () async {
    final steps = await _run(LanProbe(cfg, deps()));
    expect(ProbeReport(transport: GroupTransport.lan, steps: steps).passed, isTrue);
    final peers = steps.firstWhere((s) => s.title.contains('对端'));
    expect(peers.detail, contains('未发现'));
  });

  test('mesh 端口全被占 → fail', () async {
    final steps = await _run(LanProbe(cfg, deps(meshFails: true)));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.title, contains('mesh'));
  });

  test('组队正在运行时端口被自己占 → 判 pass 而不是 fail', () async {
    final steps = await _run(LanProbe(
      const ProbeConfig(groupId: 'g', groupRunning: true),
      deps(meshFails: true),
    ));
    final mesh = steps.firstWhere((s) => s.title.contains('mesh'));
    expect(mesh.outcome, ProbeOutcome.pass);
    expect(mesh.detail, contains('组队'));
  });

  test('加入多播组失败 → fail 并提示 AP 隔离/多播被丢', () async {
    final steps = await _run(
        LanProbe(cfg, deps(dg: _FakeDatagram(joinOk: false))));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.hint, contains('多播'));
  });

  test('datagram 一定会被关掉', () async {
    final dg = _FakeDatagram();
    await _run(LanProbe(cfg, deps(dg: dg)));
    expect(dg.closed, isTrue);
  });
}
