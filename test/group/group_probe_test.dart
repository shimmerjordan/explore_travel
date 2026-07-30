import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/models/models.dart';
import 'package:explore_journal/services/group/group_probe.dart';
import 'package:explore_journal/services/group/group_probe_io.dart';

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
