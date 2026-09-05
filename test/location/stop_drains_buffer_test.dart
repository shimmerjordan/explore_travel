import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/app/recording_controller.dart';
import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/location/background_task.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 对抗审查抓到的那个数据丢失缺陷的回归测试。
///
/// 缺陷：`stop()` 直接 `SampleBuffer.clear()` 截断缓冲文件。以前唯一的停止入口
/// 是界面按钮，用户按到它必然先把应用切回前台，`resumed` 已经排空过一轮；通知
/// 按钮把这个隐含前置条件拿掉了，于是**只存在于缓冲里**的样本（队列闸门丢弃的、
/// 写库失败的）被连文件一起删掉，永久丢失。
///
/// 真机上很难构造「只在缓冲里、不在库里」的样本——主 isolate 活着时样本是实时
/// 入库的，缓冲里那几条都是重复项。所以这条用真实的缓冲文件 + 内存库来钉：
/// 往缓冲里放一条库里没有的点，跑 `stop()`，它必须落进库，而不是随文件蒸发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late File buffer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('ej_buf_');
    buffer = File('${tmp.path}/pending_track.jsonl');

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 走方法通道而不是替换 PathProviderPlatform.instance：后者要 import 两个
    // 只在传递依赖里的包，为一条测试往 pubspec 里加依赖不划算。
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => tmp.path);
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_foreground_task/methods'),
        (call) async => call.method == 'isRunningService' ? false : null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/geolocator'),
        (_) async => null);
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final n in [
      'flutter_foreground_task/methods',
      'flutter.baseflow.com/geolocator',
      'plugins.flutter.io/path_provider',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(n), null);
    }
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('stop() 先把缓冲排进库再清文件——通知按钮那条路不会吞掉轨迹', () async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    // 库里先有一个「上一次录制」的点，用来产生 _ingestBuffer 的时间 cutoff。
    final layerId = container.read(effectiveActiveLayerIdProvider);
    final base = DateTime(2026, 9, 5, 13, 0);
    await db.insertPoints([
      TrackPointsCompanion.insert(
          layerId: layerId, lat: 31.10, lng: 121.39, time: base),
    ]);
    final before = await db.select(db.trackPoints).get();

    // 缓冲里放两条**比 cutoff 更新**的点：它们只存在于文件里，库里没有。
    // 这正是队列闸门丢弃 / 写库失败后留下的形态。
    await buffer.writeAsString([
      jsonEncode({
        'lat': 31.11,
        'lng': 121.40,
        'timeMs': base.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
        'accuracy': 8.0,
      }),
      jsonEncode({
        'lat': 31.12,
        'lng': 121.41,
        'timeMs': base.add(const Duration(minutes: 2)).millisecondsSinceEpoch,
        'accuracy': 9.0,
      }),
    ].join('\n'));

    // 模拟「正在录制」，然后走通知按钮那条路。
    container.read(recordingActiveProvider.notifier).state = true;
    container
        .read(recordingControllerProvider)
        .handleBackgroundCommand(kStoppedFromNotification);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final after = await db.select(db.trackPoints).get();
    expect(after.length, greaterThan(before.length),
        reason: '缓冲里的点必须在清文件之前写进库；修复前这里会相等（点被删光）');
    expect(after.map((p) => p.lat.toStringAsFixed(2)).toSet(),
        containsAll(<String>{'31.11', '31.12'}));

    // 排空之后文件才该被清空。
    expect(await buffer.readAsString(), isEmpty);
    expect(container.read(recordingActiveProvider), isFalse);
  });
}
