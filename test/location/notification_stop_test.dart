
import 'package:explore_journal/app/recording_controller.dart';
import 'package:explore_journal/services/location/background_task.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通知栏「停止记录」这条路的主 isolate 一侧。
///
/// 后台那一半（`onNotificationButtonPressed` → 清标志位 → 发命令 → 停服）跑在
/// 前台服务的 isolate 里，widget test 起不来那套平台通道，所以这里测的是**能
/// 测的那半**：命令到达主 isolate 之后，收尾是否与手动停止一致、是否幂等、
/// 是否会在没在录制时误触发。后台那半靠真机验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // stop() 会经过前台服务、定位插件与 path_provider 三条平台通道；单测里没有
  // 平台实现，不 mock 就会在 `isRunningService` 上抛，收尾停在半路。
  final channels = <String, Object? Function(MethodCall)>{
    'flutter_foreground_task/methods': (c) =>
        c.method == 'isRunningService' ? false : null,
    'flutter.baseflow.com/geolocator': (_) => null,
    'plugins.flutter.io/path_provider': (_) => '/tmp/ej-test',
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    channels.forEach((name, handler) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (call) async => handler(call));
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in channels.keys) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('命令名与按钮 id 是稳定常量（后台与主侧靠它们对齐）', () {
    // 两边分别在 background_task.dart 与 recording_controller.dart 里用，
    // 改了名字必须一起改——写死在测试里当锁。
    expect(kStopRecordingButtonId, 'stop_recording');
    expect(kStoppedFromNotification, 'stopped_from_notification');
  });

  test('没在录制时收到命令：什么都不做', () async {
    final c = makeContainer();
    final ctrl = c.read(recordingControllerProvider);
    expect(c.read(recordingActiveProvider), isFalse);

    ctrl.handleBackgroundCommand(kStoppedFromNotification);
    await Future<void>.delayed(Duration.zero);

    expect(c.read(recordingActiveProvider), isFalse);
  });

  test('认不出的命令被忽略，不会误停录制', () async {
    final c = makeContainer();
    final ctrl = c.read(recordingControllerProvider);
    c.read(recordingActiveProvider.notifier).state = true;

    ctrl.handleBackgroundCommand('some_future_command');
    await Future<void>.delayed(Duration.zero);

    expect(c.read(recordingActiveProvider), isTrue,
        reason: '未知命令不该把录制停掉');
  });

  test('录制中收到命令：翻掉 recordingActive，与手动停止同一条路', () async {
    final c = makeContainer();
    final ctrl = c.read(recordingControllerProvider);
    c.read(recordingActiveProvider.notifier).state = true;

    ctrl.handleBackgroundCommand(kStoppedFromNotification);
    // stop() 是异步的（要拆订阅、清缓冲），给它跑完。
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(c.read(recordingActiveProvider), isFalse);
  });

  test('通知按钮与界面按钮几乎同时到达：只收尾一次', () async {
    final c = makeContainer();
    final ctrl = c.read(recordingControllerProvider);
    c.read(recordingActiveProvider.notifier).state = true;

    // 两条路同时进来。stop() 里的 _stopping 闸门应该让第二次直接返回，
    // 否则 detectRecent 会被算两遍。
    final manual = ctrl.stop();
    ctrl.handleBackgroundCommand(kStoppedFromNotification);
    await manual;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(c.read(recordingActiveProvider), isFalse);
  });

  test('重复收到同一条命令是安全的', () async {
    final c = makeContainer();
    final ctrl = c.read(recordingControllerProvider);
    c.read(recordingActiveProvider.notifier).state = true;

    ctrl.handleBackgroundCommand(kStoppedFromNotification);
    ctrl.handleBackgroundCommand(kStoppedFromNotification);
    ctrl.handleBackgroundCommand(kStoppedFromNotification);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(c.read(recordingActiveProvider), isFalse);
  });

  test('收尾中途平台通道抛异常：状态仍翻掉、闸门仍放开', () async {
    // 停服/清缓冲/关定位三步都走平台通道，任一步抛都不能让用户卡在
    // 「界面显示正在录制、再按没反应」——那正是 _stopping 永久 true 的样子。
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_foreground_task/methods'),
        (call) async => throw PlatformException(code: 'boom'));

    final c = makeContainer();
    final ctrl = c.read(recordingControllerProvider);
    c.read(recordingActiveProvider.notifier).state = true;

    await ctrl.stop().catchError((_) {});
    expect(c.read(recordingActiveProvider), isFalse,
        reason: 'finally 必须把录制状态翻掉');

    // 闸门放开了：再停一次仍然能进去（不是直接 return）。
    c.read(recordingActiveProvider.notifier).state = true;
    await ctrl.stop().catchError((_) {});
    expect(c.read(recordingActiveProvider), isFalse,
        reason: '_stopping 若卡在 true，这次会直接 return，状态就还是 true');
  });

  group('对抗审查抓出的四个洞（回归测试）', () {
    test('接线窗口里到达的停止命令不会被丢：记下意图，接线尾部转去收尾', () async {
      final c = makeContainer();
      final ctrl = c.read(recordingControllerProvider);
      // 模拟「接线还没走完」：recordingActive 仍是 false。以前这里会 return，
      // 请求被静默丢弃，接线随后把状态置成"正在记录" → 用户卡在假录制态。
      expect(c.read(recordingActiveProvider), isFalse);
      ctrl.handleBackgroundCommand(kStoppedFromNotification);
      // 意图必须被记住。用一次真实的 start() 来观察：它跑完时应当发现意图、
      // 走收尾，而不是把 recordingActive 置 true。
      await ctrl.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.read(recordingActiveProvider), isFalse,
          reason: '接线尾部看到停止意图就该收尾，而不是宣称正在记录');
    });

    test('start() 有重入闸门：并发两次只接线一次', () async {
      // 可观测判据：接线第一步就是 ensurePermission() → geolocator 的
      // checkPermission。没有闸门时两次 start() 会各查一遍权限；有闸门则
      // 只查一次。这同时也就证明了第二次没有走到覆盖 _bgSub 那一步——
      // 覆盖会让插件里的 task-data 回调永不解绑。
      var permissionChecks = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('flutter.baseflow.com/geolocator'),
              (call) async {
        if (call.method == 'checkPermission') permissionChecks++;
        return 1; // LocationPermission.denied → start() 会带着错误早退
      });

      final c = makeContainer();
      final ctrl = c.read(recordingControllerProvider);
      final a = ctrl.start();
      final b = ctrl.start();
      await Future.wait([a, b]);
      expect(permissionChecks, 1,
          reason: '第二次 start() 应当被闸门挡住，不该再查一遍权限');
      // 让 SettingsNotifier 的异步加载在容器销毁前落地，避免测试尾部噪声。
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  });

  group('listen 的命令分流', () {
    test('带 cmd 的 Map 走 onCommand，不当成位置样本', () async {
      // BackgroundLocation.listen 直接挂平台回调，测不了；这里把分流规则本身
      // 复刻一遍当契约测试——`_enqueueSample` 会静默丢掉没有 lat/lng 的 Map，
      // 所以命令**必须**在到达样本回调之前就被分出去。
      final samples = <Map<String, dynamic>>[];
      final commands = <String>[];
      void route(Map<String, dynamic> m) {
        final cmd = m['cmd'];
        if (cmd is String) {
          commands.add(cmd);
          return;
        }
        samples.add(m);
      }

      route({'cmd': kStoppedFromNotification});
      route({'lat': 31.1, 'lng': 121.4, 'timeMs': 1});
      route({'cmd': 42}); // 非字符串 cmd 不算命令
      expect(commands, [kStoppedFromNotification]);
      expect(samples.length, 2);
    });
  });
}
