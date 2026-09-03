// 组队 transport 的前后台节奏：退后台放慢发现/保活，回前台恢复。纯状态测试，
// 不 start()、不碰 socket / 平台通道——各服务的周期 getter 就是 timer 建立时
// 读的同一份值，所以锁住 getter 就锁住了实际节奏。
import 'package:flutter_test/flutter_test.dart';
import 'package:explore_journal/services/group/frp_engine.dart';
import 'package:explore_journal/services/group/frp_group_service_io.dart';
import 'package:explore_journal/services/group/group_service_io.dart';
import 'package:explore_journal/services/group/relay_group_service_io.dart';
import 'package:explore_journal/services/group/webrtc_group_service_io.dart';

/// 三处 UI（聊天页 / 私聊页 / 地图头像）都按 lastSeen 超过这个值判为离线。
/// 后台 hello 必须短于它，否则退后台的人在别人手机上会闪"离线"。
const kUiStaleWindow = Duration(seconds: 30);

void main() {
  group('LanGroupService 前后台节奏', () {
    LanGroupService make() => LanGroupService(
          selfId: 'aaaa-1111',
          selfName: '阿明',
          groupId: '云南 Trip!',
          selfColor: 0xFF26A69A,
        );

    test('默认前台：beacon 4 s、hello 8 s', () {
      final svc = make();
      expect(svc.beaconPeriod, const Duration(seconds: 4));
      expect(svc.helloPeriod, const Duration(seconds: 8));
    });

    test('退后台：beacon 30 s、hello 20 s', () {
      final svc = make();
      svc.setBackground(true);
      expect(svc.beaconPeriod, const Duration(seconds: 30));
      expect(svc.helloPeriod, const Duration(seconds: 20));
    });

    test('后台 hello 必须留在 UI 的 30 s 离线窗口之内', () {
      final svc = make()..setBackground(true);
      expect(svc.helloPeriod, lessThan(kUiStaleWindow));
      // 至少留几秒给网络抖动，贴着窗口边缘会闪离线。
      expect(kUiStaleWindow - svc.helloPeriod,
          greaterThanOrEqualTo(const Duration(seconds: 5)));
    });

    test('回前台恢复原周期，重复调用幂等', () {
      final svc = make();
      svc.setBackground(true);
      svc.setBackground(true);
      svc.setBackground(false);
      expect(svc.beaconPeriod, const Duration(seconds: 4));
      expect(svc.helloPeriod, const Duration(seconds: 8));
      svc.setBackground(false);
      expect(svc.helloPeriod, const Duration(seconds: 8));
    });

    test('通过 GroupService.create 拿到的 LAN 实例也支持 setBackground', () {
      final svc = GroupService.create(
        transport: 0,
        selfId: 'x',
        selfName: 'x',
        groupId: 'g',
        selfColor: 0,
      );
      expect(svc, isA<LanGroupService>());
      svc.setBackground(true);
      expect((svc as LanGroupService).beaconPeriod,
          const Duration(seconds: 30));
    });
  });

  group('FrpGroupService 重连退避', () {
    test('nextReconnectDelay：5 → 10 → 20 → 40 → 60，之后封顶在 60', () {
      final seq = <Duration>[FrpGroupService.kReconnectMin];
      for (var i = 0; i < 6; i++) {
        seq.add(FrpGroupService.nextReconnectDelay(seq.last));
      }
      expect(
        seq.map((d) => d.inSeconds).toList(),
        [5, 10, 20, 40, 60, 60, 60],
      );
    });

    test('nextReconnectDelay 不会低于下限（防 0 或负值卡死）', () {
      expect(FrpGroupService.nextReconnectDelay(Duration.zero),
          FrpGroupService.kReconnectMin);
      expect(FrpGroupService.nextReconnectDelay(const Duration(seconds: -3)),
          FrpGroupService.kReconnectMin);
      // 下限与上限之间的值正常翻倍。
      expect(FrpGroupService.nextReconnectDelay(const Duration(seconds: 7)),
          const Duration(seconds: 14));
    });

    test('名册刷新：前台 15 s，后台 60 s，回前台恢复', () {
      final svc = FrpGroupService(
        selfId: 'aaaa-1111',
        selfName: '阿明',
        groupId: 'g',
        selfColor: 0,
        engine: FrpEngine.create(),
        serverAddr: 'frp.example.com',
        serverPort: 7000,
        token: null,
        protocol: 'quic',
        secretKey: 'sk',
      );
      expect(svc.rosterPeriod, const Duration(seconds: 15));
      svc.setBackground(true);
      expect(svc.rosterPeriod, const Duration(seconds: 60));
      svc.setBackground(false);
      expect(svc.rosterPeriod, const Duration(seconds: 15));
    });
  });

  group('WebRtcGroupService 信箱轮询', () {
    WebRtcGroupService make(int pollSec) => WebRtcGroupService(
          selfId: 'aaaa-1111',
          selfName: '阿明',
          groupId: 'g',
          selfColor: 0,
          webdavUrl: 'https://dav.example.com',
          webdavUser: 'u',
          webdavPass: 'p',
          signalingPath: '/explore_journal/signaling',
          pollSec: pollSec,
          iceServers: 'stun:stun.l.google.com:19302',
        );

    test('前台按用户配置 pollSec，后台放慢到 60 s，回前台恢复', () {
      final svc = make(5);
      expect(svc.pollPeriod, const Duration(seconds: 5));
      svc.setBackground(true);
      expect(svc.pollPeriod, const Duration(seconds: 60));
      svc.setBackground(false);
      expect(svc.pollPeriod, const Duration(seconds: 5));
    });

    test('用户本来就配得比 60 s 慢：后台尊重用户值，不反向加快', () {
      final svc = make(90)..setBackground(true);
      expect(svc.pollPeriod, const Duration(seconds: 90));
    });
  });

  group('Relay / 默认实现', () {
    test('RelayGroupService.setBackground 是刻意的 no-op，不抛不改状态', () {
      final svc = RelayGroupService(
        selfId: 'a',
        selfName: 'a',
        groupId: 'g',
        selfColor: 0,
        serverUrl: 'https://relay.example.com',
      );
      expect(() => svc.setBackground(true), returnsNormally);
      expect(() => svc.setBackground(false), returnsNormally);
    });
  });
}
