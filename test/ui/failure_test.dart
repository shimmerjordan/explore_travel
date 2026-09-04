import 'dart:async';
import 'dart:io';

import 'package:explore_journal/ui/common/failure.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('describeFailure', () {
    test('网络类异常各归各位', () {
      expect(describeFailure(const SocketException('nope')), '网络连不上');
      expect(describeFailure(const HttpException('500')), '服务器没有正常响应');
      expect(describeFailure(TimeoutException('slow')), '等太久了，超时');
    });

    test('文件系统按 errno 分开说', () {
      FileSystemException fs(int code) => FileSystemException(
          'x', '/p', OSError('boom', code));
      expect(describeFailure(fs(28)), '设备存储空间不足');
      expect(describeFailure(fs(13)), '没有访问这个文件的权限');
      expect(describeFailure(fs(2)), '文件已经不在了');
      expect(describeFailure(fs(999)), '读写文件出错');
      expect(describeFailure(const FileSystemException('x', '/p')), '读写文件出错');
    });

    test('格式错误', () {
      expect(describeFailure(const FormatException('bad json')), '内容格式不对，解析不了');
    });

    test('认不出来的异常返回 null，让调用方只说「失败」', () {
      expect(describeFailure(Exception('mystery')), isNull);
      expect(describeFailure(null), isNull);
    });

    test('service 层用中文 StateError 携带的用户指引要原样透出', () {
      // 这些是仓库里真实存在的文案（onedrive_service / frp / github 同步等）。
      expect(describeFailure(StateError('未配置 frp 服务器地址')), '未配置 frp 服务器地址');
      expect(describeFailure(StateError('GitHub 同步未配置（缺少 PAT / owner / repo）')),
          'GitHub 同步未配置（缺少 PAT / owner / repo）');
      expect(describeFailure(ArgumentError('后端地址需为 http(s):// 开头的完整 URL')),
          '后端地址需为 http(s):// 开头的完整 URL');
    });

    test('开发者向的英文断言不上屏', () {
      // 同样两个类型也承载大量内部断言，这些必须被挡住。
      expect(describeFailure(StateError('No element')), isNull);
      expect(describeFailure(StateError('WebDAV not configured')), isNull);
      expect(describeFailure(StateError('zoom past native')), isNull);
      expect(describeFailure(StateError('')), isNull);
      expect(describeFailure(ArgumentError('plan yields no frames')), isNull);
    });
  });

  group('failureMessage', () {
    test('认得出原因就带上，认不出就只说动作', () {
      expect(failureMessage('播放', const SocketException('')), '播放失败 · 网络连不上');
      expect(failureMessage('导出视频', StateError('x')), '导出视频失败');
    });

    test('不会把异常原文塞进用户看到的字串', () {
      final msg = failureMessage(
          '同步',
          const SocketException(
              "Failed host lookup: 'nas.local' (OS Error: nodata, errno = 7)"));
      expect(msg, isNot(contains('errno')));
      expect(msg, isNot(contains('SocketException')));
      expect(msg, '同步失败 · 网络连不上');
    });
  });

  group('showFailure', () {
    Widget host(void Function(BuildContext) onTap) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                  onPressed: () => onTap(ctx), child: const Text('go')),
            ),
          ),
        );

    testWidgets('弹出人话提示，不带重试时没有按钮', (tester) async {
      await tester.pumpWidget(host((ctx) => showFailure(ctx,
          action: '播放', error: const SocketException('x'))));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(find.text('播放失败 · 网络连不上'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('给了 onRetry 就有「重试」，点了会回调', (tester) async {
      var retried = 0;
      await tester.pumpWidget(host((ctx) => showFailure(ctx,
          action: '上传',
          error: TimeoutException('t'),
          onRetry: () => retried++)));
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(find.text('上传失败 · 等太久了，超时'), findsOneWidget);
      // SnackBar 有入场动画，动画跑完才可点。
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retried, 1);
    });
  });
}
