import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/services/playback/replay_video_exporter.dart';

class _FakeSink implements VideoSink {
  int? width, height, fps;
  String? path;
  final frames = <Uint8List>[];
  var finished = false;

  @override
  Future<void> start(
      {required int width,
      required int height,
      required int fps,
      required String path}) async {
    this.width = width;
    this.height = height;
    this.fps = fps;
    this.path = path;
  }

  @override
  Future<void> addFrame(Uint8List rgba) async => frames.add(rgba);

  @override
  Future<void> finish() async => finished = true;
}

RawFrame solid(int w, int h, int v) =>
    RawFrame(w, h, Uint8List(w * h * 4)..fillRange(0, w * h * 4, v));

void main() {
  group('ExportPlan', () {
    test('frame count and linear timeline mapping', () {
      const plan = ExportPlan(fps: 30, videoDuration: Duration(seconds: 10));
      expect(plan.frameCount, 300);
      const total = Duration(hours: 3);
      expect(plan.virtualTimeOfFrame(0, total), Duration.zero);
      expect(plan.virtualTimeOfFrame(299, total), total);
      expect(plan.virtualTimeOfFrame(150, total).inSeconds,
          closeTo(total.inSeconds / 2, 40));
    });
  });

  group('cropRgba', () {
    test('top-left crop keeps rows intact', () {
      // 3×2 source, pixel value = x + 10*y
      final src = Uint8List(3 * 2 * 4);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 3; x++) {
          final o = (y * 3 + x) * 4;
          src.fillRange(o, o + 4, x + 10 * y);
        }
      }
      final out = cropRgba(src, 3, 2, 2, 2);
      expect(out.length, 2 * 2 * 4);
      expect(out[0], 0);
      expect(out[4], 1);
      expect(out[8], 10);
      expect(out[12], 11);
    });

    test('same size returns the source buffer', () {
      final src = Uint8List(16);
      expect(identical(cropRgba(src, 2, 2, 2, 2), src), isTrue);
    });

    test('refuses to grow', () {
      expect(() => cropRgba(Uint8List(16), 2, 2, 4, 2), throwsArgumentError);
    });
  });

  group('ReplayVideoExporter.run', () {
    test('odd capture → even output, every frame written, progress to 1',
        () async {
      final sink = _FakeSink();
      final asked = <Duration>[];
      final progress = <double>[];
      final res = await ReplayVideoExporter().run(
        timelineTotal: const Duration(minutes: 10),
        plan: const ExportPlan(fps: 10, videoDuration: Duration(seconds: 1)),
        capture: (t) async {
          asked.add(t);
          return solid(7, 5, asked.length);
        },
        sink: sink,
        outputPath: '/tmp/x.mp4',
        onProgress: progress.add,
      );
      expect(sink.width, 6);
      expect(sink.height, 4);
      expect(sink.fps, 10);
      expect(sink.frames, hasLength(10));
      expect(sink.frames.first.length, 6 * 4 * 4);
      expect(sink.finished, isTrue);
      expect(res.cancelled, isFalse);
      expect(res.framesWritten, 10);
      expect(asked.first, Duration.zero);
      expect(asked.last, const Duration(minutes: 10));
      expect(progress.last, 1.0);
      expect(progress, orderedEquals([...progress]..sort()));
    });

    test('cancellation stops early but still closes the file', () async {
      final sink = _FakeSink();
      var captured = 0;
      final res = await ReplayVideoExporter().run(
        timelineTotal: const Duration(minutes: 1),
        plan: const ExportPlan(fps: 10, videoDuration: Duration(seconds: 2)),
        capture: (_) async => solid(4, 4, ++captured),
        sink: sink,
        outputPath: '/tmp/x.mp4',
        isCancelled: () => captured >= 5,
      );
      expect(res.cancelled, isTrue);
      expect(sink.frames, hasLength(5));
      expect(sink.finished, isTrue);
    });

    test('a null capture aborts as cancelled', () async {
      final sink = _FakeSink();
      var n = 0;
      final res = await ReplayVideoExporter().run(
        timelineTotal: const Duration(minutes: 1),
        plan: const ExportPlan(fps: 10, videoDuration: Duration(seconds: 1)),
        capture: (_) async => ++n > 3 ? null : solid(4, 4, n),
        sink: sink,
        outputPath: '/tmp/x.mp4',
      );
      expect(res.cancelled, isTrue);
      expect(res.framesWritten, 3);
      expect(sink.finished, isTrue);
    });

    test('sink is never opened when the very first frame is missing',
        () async {
      final sink = _FakeSink();
      final res = await ReplayVideoExporter().run(
        timelineTotal: const Duration(minutes: 1),
        plan: const ExportPlan(fps: 10, videoDuration: Duration(seconds: 1)),
        capture: (_) async => null,
        sink: sink,
        outputPath: '/tmp/x.mp4',
      );
      expect(sink.path, isNull);
      expect(sink.finished, isFalse);
      expect(res.cancelled, isTrue);
    });
  });
}
