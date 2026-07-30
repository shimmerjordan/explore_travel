import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/models/models.dart';
import 'package:explore_journal/services/group/group_probe.dart';

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
}
