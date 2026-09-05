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

    test('正常跑完 → cleanUp 一定被调用', () async {
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

    // cleanUp 现在是「无条件调用 + 子类自己幂等」，不再由基类做一次性守卫。
    // 守卫会丢掉「取消之后才拿到手的资源」：cancel() 一落地就把守卫置位，之后
    // finally 被短路，那个 await 飞回来之后拿到的 frpc / socket 再也没人释放。
    // 所以这里测的不再是「cleanUp 只跑一次」，而是「被 take 的那份资源只释放一次」
    // ——幂等实现该保证的东西。
    test('跑到一半调用 cancel() → cleanUp 可以被调用多次，但资源只释放一次', () async {
      var cleanUpCalls = 0;
      var releases = 0;
      var resource = true; // 「已持有一份资源」
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
          // take-then-release：子类 cleanUp 的标准写法。
          if (!resource) return;
          resource = false;
          releases++;
        },
      );

      final sub = probe.run().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await probe.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(cleanUpCalls, greaterThanOrEqualTo(1));
      expect(releases, 1, reason: '幂等 cleanUp 必须只释放一次');
      expect(resource, isFalse);
    });
  });

  group('RelayProbe', relayTests);
  group('WebDavProbe', webdavTests);
  group('FrpProbe', frpTests);
  group('LanProbe', lanTests);
  group('探测进行中被销毁（不 await 的 cancel）', cancelMidRunTests);
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

  // dart:io 在升级被拒时只给一句不含状态码的 message，所以 code 永远是 null
  // （见 WebSocketRejected 的注释）。这一步只能报「被拒绝」，并按可能性排序给出
  // 嫌疑：令牌不一致在前（自家中继回的是裸 401，正好是被丢掉的那条信息），反代
  // 没转发 Upgrade 头在后。
  test('WS 被拒 → fail；令牌列为首要嫌疑，且不编造状态码', () async {
    final steps = await _run(RelayProbe(
      cfg,
      _deps(
        http: {
          '/healthz': const ProbeHttpResponse(200, 'ok'),
          '/api/status': const ProbeHttpResponse(200, '{"modules":["group"]}'),
        },
        ws: (u, t) async => throw const WebSocketRejected(null),
      ),
    ));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.title, contains('WebSocket'));
    expect(bad.hint, contains('令牌'));
    expect(bad.hint, contains('GROUP_TOKEN'));
    // 反代那条嫌疑要保留 —— 它是第二常见的原因。
    expect(bad.hint, contains('Upgrade'));
    // 回归：detail 里不能再出现「close code 4821」这类从 URI 里抓出来的数字。
    expect(bad.detail, isNot(matches(RegExp(r'\d{3,4}'))));
    expect(bad.detail, contains('状态码'));
  });

  test('地址没配 → 第一步就 fail，不发任何请求', () async {
    final steps = await _run(
        RelayProbe(const ProbeConfig(groupId: 'g'), const ProbeDeps()));
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
    final steps =
        await _run(WebDavProbe(cfg, ProbeDeps(davClient: (_) => dav)));
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

  /// Makes `start()` take a while, so a test can cancel while the probe is
  /// still inside that await — the window where ownership isn't recorded yet.
  final Duration startDelay;
  bool started = false;
  bool stopped = false;
  _FakeFrpEngine({
    this.lines = const [],
    this.running = false,
    this.startDelay = Duration.zero,
  });

  @override
  Stream<String> get events => Stream.fromIterable(lines);
  @override
  Future<bool> isRunning() async => running || started;
  @override
  Future<void> start(String configToml) async {
    if (startDelay > Duration.zero) await Future<void>.delayed(startDelay);
    started = true;
  }

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
    expect(ProbeReport(transport: GroupTransport.frp, steps: steps).passed,
        isTrue);
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
    expect(steps.any((s) => s.detail.contains('已在运行')), isTrue);
  });

  // 回归：groupRunning 是个 UI 侧标记，只在 GroupLifecycle.start() 全部完成后才置
  // true（绑端口 + frpc 起来 + 首次 roster 查询，数秒）。刚打开组队就点「测试连接」
  // 正落在那个窗口里，此前会走「未组队」分支去 start(探针配置) —— FrpEngine 是进程级
  // frpc 的薄句柄，start 等同 reload，会顶掉真实组队的 proxy/visitor，随后 cleanUp 的
  // stop() 直接把真实组队的 frpc 停掉。引擎自己才是 ground truth。
  test('groupRunning 还没置位、但 frpc 已在跑 → 仍然读现状，绝不 start/stop', () async {
    final engine = _FakeFrpEngine(running: true);
    final steps = await _run(FrpProbe(
      cfg, // groupRunning 默认 false
      ProbeDeps(frpEngine: () => engine, tcpConnect: (h, p, t) async {}),
    ));
    expect(engine.started, isFalse,
        reason: '引擎已在运行，探针绝不能再 start（那等于 reload，会顶掉真实配置）');
    expect(engine.stopped, isFalse, reason: '不是自己启的 frpc，绝不能 stop');
    final login = steps.firstWhere((s) => s.title.contains('登录'));
    expect(login.outcome, ProbeOutcome.pass);
    expect(login.detail, contains('已在运行'));
  });

  test('groupRunning 置位但 frpc 不在线 → fail，并让用户去重开/看日志', () async {
    final engine = _FakeFrpEngine();
    final steps = await _run(FrpProbe(
      const ProbeConfig(
        groupId: 'g',
        frpServerAddr: 'frps.example.org',
        frpServerPort: 17000,
        groupRunning: true,
      ),
      ProbeDeps(frpEngine: () => engine, tcpConnect: (h, p, t) async {}),
    ));
    final login = steps.firstWhere((s) => s.title.contains('登录'));
    expect(login.outcome, ProbeOutcome.fail);
    expect(engine.started, isFalse);
    expect(engine.stopped, isFalse);
  });

  test('没配 dashboard → 该步 skip 而不是 fail', () async {
    final steps = await _run(FrpProbe(
      cfg,
      ProbeDeps(
        frpEngine: () => _FakeFrpEngine(
            lines: const ['login to server success', 'start proxy success']),
        tcpConnect: (h, p, t) async {},
      ),
    ));
    expect(
        steps.any((s) =>
            s.title.contains('dashboard') && s.outcome == ProbeOutcome.skip),
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

  /// Delays the socket handing itself over, so a test can cancel while the
  /// probe is still inside `await openDatagram()`.
  final Duration openDelay;
  bool closed = false;
  _FakeDatagram({
    this.joinOk = true,
    this.sendBytes = 42,
    this.openDelay = Duration.zero,
  });
  @override
  bool joinMulticast() => joinOk;
  @override
  int send(List<int> data) => sendBytes;
  @override
  Future<void> close() async => closed = true;
}

/// Records what the probe did to the (process-wide, non-reference-counted)
/// MulticastLock, and can pretend the group service already holds it.
class _FakeMulticastLock implements ProbeMulticastLock {
  @override
  final bool needed;
  bool held;
  int acquires = 0;
  int releases = 0;
  _FakeMulticastLock({this.needed = true, this.held = false});

  @override
  Future<bool> isHeld() async => held;
  @override
  Future<void> acquire() async {
    acquires++;
    held = true;
  }

  @override
  Future<void> release() async {
    releases++;
    held = false;
  }
}

void lanTests() {
  const cfg = ProbeConfig(groupId: 'g');

  ProbeDeps deps({
    int meshPort = kMeshPortBase,
    bool meshFails = false,
    ProbeDatagram? dg,
    ProbeMulticastLock? lock,
  }) =>
      ProbeDeps(
        listInterfaces: () async =>
            [const ProbeIface(name: 'wlan0', address: '192.168.1.23')],
        bindMesh: (b, c) async =>
            meshFails ? throw const MeshPortUnavailable() : meshPort,
        openDatagram: () async => dg ?? _FakeDatagram(),
        multicastLock: lock ?? _FakeMulticastLock(needed: false),
      );

  test('本机四项就绪 → 整体通过', () async {
    final steps = await _run(LanProbe(cfg, deps()));
    expect(ProbeReport(transport: GroupTransport.lan, steps: steps).passed,
        isTrue);
    expect(steps.map((s) => s.title),
        containsAll(<String>['网络接口', '绑定 mesh 端口', '发出多播']));
  });

  // 「对端应答」曾经是一条 info + 一条让用户去检查对方设备的 hint，而它在生产环境
  // 恒为 0：探针的 socket 绑的是临时端口（不能抢正在运行的组队服务占着的发现端口），
  // 多播投递按目的端口匹配，对端的常规信标发往发现端口，结构上到不了这里；真实服务
  // 也没有任何单播应答机制。成员都在线却报「未发现成员」比没有这一步更糟，所以改成
  // 明说「测不出来」。
  test('对端应答标 skip，说明单机测不出来，且不给误导性 hint', () async {
    final steps = await _run(LanProbe(cfg, deps()));
    final peers = steps.firstWhere((s) => s.title.contains('对端'));
    expect(peers.outcome, ProbeOutcome.skip);
    expect(peers.hint, isNull, reason: '不能再让用户去查「对方设备是不是没开」——这一步根本没测过对方');
    expect(peers.detail, contains('临时端口'));
    expect(peers.detail, contains('$kDiscoveryPort'));
    // skip 不参与判定，报告整体仍然通过。
    expect(ProbeReport(transport: GroupTransport.lan, steps: steps).passed,
        isTrue);
  });

  // 原生锁是进程级 + setReferenceCounted(false)：LanGroupService.start() 拿了它之后
  // 整个会话不再重新获取，探针一 release 就把真实服务的锁放掉了 —— 之后再也收不到
  // 多播信标（现存 TCP 连接不断，所以完全静默）。这正好是「用着的时候查为什么连不上」
  // 那个主场景。
  test('锁已被组队服务持有 → 判 pass，不重复获取、更不释放', () async {
    final lock = _FakeMulticastLock(held: true);
    final steps = await _run(LanProbe(cfg, deps(lock: lock)));
    final s = steps.firstWhere((s) => s.title.contains('MulticastLock'));
    expect(s.outcome, ProbeOutcome.pass);
    expect(s.detail, contains('组队服务'));
    expect(lock.acquires, 0);
    expect(lock.releases, 0, reason: '释放别人的锁会让真实服务静默收不到信标');
    expect(lock.held, isTrue, reason: '探测结束后锁必须还在');
  });

  test('锁没人持有 → 自己获取，并在结束时只释放自己那一次', () async {
    final lock = _FakeMulticastLock();
    final steps = await _run(LanProbe(cfg, deps(lock: lock)));
    final s = steps.firstWhere((s) => s.title.contains('MulticastLock'));
    expect(s.outcome, ProbeOutcome.pass);
    expect(lock.acquires, 1);
    expect(lock.releases, 1);
    expect(lock.held, isFalse);
  });

  test('非 Android → MulticastLock 标 skip，一次都不碰', () async {
    final lock = _FakeMulticastLock(needed: false);
    final steps = await _run(LanProbe(cfg, deps(lock: lock)));
    final s = steps.firstWhere((s) => s.title.contains('MulticastLock'));
    expect(s.outcome, ProbeOutcome.skip);
    expect(lock.acquires, 0);
    expect(lock.releases, 0);
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

  // 加入了多播组但一个字节都没发出去：Android 上少了本地网络权限就是这个样子。
  // 这一步是探针唯一能真正验证的「发」方向，所以 0 字节必须判 fail。
  test('多播发送返回 0 字节 → fail 并提示查本地网络权限', () async {
    final steps =
        await _run(LanProbe(cfg, deps(dg: _FakeDatagram(sendBytes: 0))));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.title, contains('多播'));
    expect(bad.hint, contains('本地网络权限'));
  });

  test('加入多播组失败 → fail 并提示 AP 隔离/多播被丢', () async {
    final steps =
        await _run(LanProbe(cfg, deps(dg: _FakeDatagram(joinOk: false))));
    final bad = steps.firstWhere((s) => s.outcome == ProbeOutcome.fail);
    expect(bad.hint, contains('多播'));
  });

  test('datagram 一定会被关掉', () async {
    final dg = _FakeDatagram();
    await _run(LanProbe(cfg, deps(dg: dg)));
    expect(dg.closed, isTrue);
  });
}

/// 回归：`ProbeController.dispose()` 是同步的，所以它对 `_probe.cancel()` 与
/// `_sub.cancel()` 都**不 await**。取消因此经常正落在某个 acquire 的 await 还在
/// 飞的时候 —— 那一刻探针还什么都没拿到，等 await 飞回来资源才到手。
///
/// 基类此前用一次性守卫防「cleanUp 双跑」，恰好把这种情况漏成了反向竞态：cancel()
/// 一落地就把守卫置位，run() 的 finally 被短路，于是**探测进行中返回上一页会把临时
/// 启动的 frpc 永久留在后台跑**，UDP socket 不关，MulticastLock 不释放。
/// 现在的做法是子类 cleanUp 自身幂等 + 两处无条件调用，第二遍才是真正兜住它的那遍。
void cancelMidRunTests() {
  test('frp：start() 还在飞的时候销毁页面 → 临时 frpc 仍被停掉', () async {
    final engine = _FakeFrpEngine(
      lines: const ['login to server success', 'start proxy success'],
      startDelay: const Duration(milliseconds: 30),
    );
    final probe = FrpProbe(
      const ProbeConfig(
        groupId: 'g',
        passphrase: 'pw',
        frpServerAddr: 'frps.example.org',
        frpServerPort: 17000,
      ),
      ProbeDeps(
        frpEngine: () => engine,
        tcpConnect: (h, p, t) async {},
        timeouts: const ProbeTimeouts(frpLogin: Duration(seconds: 12)),
      ),
    );

    final sub = probe.run().listen((_) {});
    // 等到探针进了 start() 的 await 里（此时 _startedByUs 还是 false）。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    // 与 dispose() 里一模一样：两个 cancel 都不 await。
    probe.cancel();
    sub.cancel();

    // 给 start() 飞回来、以及 finally 兜底的时间。这里必须远小于 frpLogin 的 12s，
    // 否则就证明取消没有提前拆除、只是把超时等满了。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(engine.started, isTrue, reason: 'start() 确实完成了（竞态的前提）');
    expect(engine.stopped, isTrue, reason: '临时 frpc 绝不能被留在后台跑 —— 这是最贵的那种泄漏');
  });

  test('lan：openDatagram() 还在飞的时候销毁页面 → socket 仍被关、锁仍被释放', () async {
    final dg = _FakeDatagram(openDelay: const Duration(milliseconds: 30));
    final lock = _FakeMulticastLock();
    final probe = LanProbe(
      const ProbeConfig(groupId: 'g'),
      ProbeDeps(
        listInterfaces: () async =>
            [const ProbeIface(name: 'wlan0', address: '192.168.1.23')],
        bindMesh: (b, c) async => kMeshPortBase,
        openDatagram: () async {
          await Future<void>.delayed(dg.openDelay);
          return dg;
        },
        multicastLock: lock,
      ),
    );

    final sub = probe.run().listen((_) {});
    // 前三步是同步/瞬时的，等到探针进了 openDatagram() 的 await 里。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    probe.cancel();
    sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(dg.closed, isTrue, reason: 'cancel 之后才到手的 socket 也必须被关掉');
    expect(lock.releases, 1, reason: '自己获取的锁必须释放');
    expect(lock.held, isFalse);
  });

  test('webdav：写入完成前销毁页面 → 探针文件仍被删掉', () async {
    final dav = _SlowDav(const Duration(milliseconds: 30));
    final probe = WebDavProbe(
      const ProbeConfig(
        groupId: 'g',
        webdavUrl: 'https://dav.example.org/dav',
        webdavUser: 'u',
        webdavPass: 'p',
      ),
      ProbeDeps(davClient: (_) => dav),
    );

    final sub = probe.run().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 15));
    probe.cancel();
    sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(dav.calls.where((c) => c.startsWith('write')), hasLength(1));
    expect(dav.calls.where((c) => c.startsWith('remove')), hasLength(1),
        reason: '写进去的探针文件必须被删掉，且只删一次');
  });
}

/// Like [_FakeDav] but with a slow `write`, so a test can cancel while the probe
/// is inside that await (before `_wrote` records ownership).
class _SlowDav implements ProbeDav {
  final Duration writeDelay;
  final List<String> calls = [];
  final Map<String, List<int>> files = {};
  _SlowDav(this.writeDelay);

  @override
  Future<void> ensureDir(String path) async => calls.add('ensureDir $path');
  @override
  Future<void> write(String path, List<int> bytes) async {
    calls.add('write $path');
    await Future<void>.delayed(writeDelay);
    files[path] = bytes;
  }

  @override
  Future<List<int>> read(String path) async {
    calls.add('read $path');
    return files[path] ?? (throw const DavStatus(404));
  }

  @override
  Future<void> remove(String path) async => calls.add('remove $path');
}
