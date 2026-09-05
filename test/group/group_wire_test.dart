import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/group/group_wire.dart';

void main() {
  group('relayWsUri', () {
    Uri build(String url, {String? token}) => relayWsUri(
          serverUrl: url,
          groupId: 'My Group!',
          selfId: 'peer-a',
          token: token,
        );

    test('https 换成 wss，并拼上 /group/v1/ws', () {
      final u = build('https://ej-backend.example.org');
      expect(u.scheme, 'wss');
      expect(u.host, 'ej-backend.example.org');
      expect(u.path, '/group/v1/ws');
    });

    test('http 换成 ws（局域网直连场景）', () {
      expect(build('http://192.168.1.10:48081').scheme, 'ws');
    });

    test('裸域名默认按 wss 处理', () {
      expect(build('ej-backend.example.org').scheme, 'wss');
    });

    test('尾部斜杠不会产生双斜杠', () {
      expect(build('https://x.example.org///').path, '/group/v1/ws');
    });

    test('group 参数经过 safeId 规范化，peer 原样带上', () {
      final q = build('https://x.example.org').queryParameters;
      expect(q['group'], 'mygroup'); // 小写 + 去掉非字母数字
      expect(q['peer'], 'peer-a');
      expect(q.containsKey('token'), isFalse);
    });

    test('有令牌时作为 token 查询参数带上', () {
      expect(build('https://x.example.org', token: 'abc').queryParameters['token'], 'abc');
    });

    test('空地址抛 StateError', () {
      expect(() => build('   '), throwsA(isA<StateError>()));
    });
  });

  test('线路常量与既有实现一致', () {
    expect(kMcastGroup, '239.42.42.42');
    expect(kDiscoveryPort, 47829);
    expect(kMeshPortBase, 47830);
    expect(kMeshPortProbeCount, 5);
    expect(kRelayWsPath, '/group/v1/ws');
  });
}
