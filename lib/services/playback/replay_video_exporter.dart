import 'dart:typed_data';

/// Turns a replay into an mp4, frame by frame: the exporter owns the frame
/// SCHEDULE (how many frames, which moment of the timeline each one shows)
/// and the pixel plumbing (even dimensions, consistent size); rendering a
/// frame ([FrameCapture]) and encoding it ([VideoSink]) are injected, so the
/// orchestration is unit-tested with fakes and the screen only supplies a
/// RepaintBoundary capture + the platform encoder.

/// One captured frame, straight RGBA8888, row-major, no padding.
class RawFrame {
  final int width, height;
  final Uint8List rgba;
  const RawFrame(this.width, this.height, this.rgba)
      : assert(rgba.length == width * height * 4);
}

/// Render the frame showing the replay at [virtualTime]. Null aborts the
/// export (e.g. the screen went away).
typedef FrameCapture = Future<RawFrame?> Function(Duration virtualTime);

abstract class VideoSink {
  Future<void> start(
      {required int width,
      required int height,
      required int fps,
      required String path});
  Future<void> addFrame(Uint8List rgba);
  Future<void> finish();
}

class ExportPlan {
  final int fps;

  /// Length of the OUTPUT video — the whole replay timeline is fitted into
  /// it (a 3-hour hike becomes a 30-second clip).
  final Duration videoDuration;
  const ExportPlan({this.fps = 30, this.videoDuration = const Duration(seconds: 30)});

  int get frameCount => (videoDuration.inMilliseconds * fps / 1000).round();

  /// Timeline position shown by frame [i]: linear, first frame at 0, last
  /// frame exactly at [total].
  Duration virtualTimeOfFrame(int i, Duration total) {
    final n = frameCount;
    if (n <= 1) return total;
    return Duration(
        microseconds: (total.inMicroseconds * i / (n - 1)).round());
  }
}

class ExportResult {
  final String path;
  final int framesWritten;
  final int width, height;
  final bool cancelled;
  const ExportResult(
      {required this.path,
      required this.framesWritten,
      required this.width,
      required this.height,
      required this.cancelled});
}

/// Hardware encoders want even (some, 16-aligned) dimensions; a captured
/// boundary is whatever the layout gave it. Crop from the top-left to the
/// largest even size — at most one row/column of pixels is lost.
int evenDown(int v) => v.isOdd ? v - 1 : v;

/// Top-left crop of a straight-RGBA buffer. Returns [src] itself when the
/// size already matches.
Uint8List cropRgba(
    Uint8List src, int srcW, int srcH, int dstW, int dstH) {
  if (dstW > srcW || dstH > srcH) {
    throw ArgumentError('crop target $dstW×$dstH exceeds source $srcW×$srcH');
  }
  if (dstW == srcW && dstH == srcH) return src;
  final out = Uint8List(dstW * dstH * 4);
  final rowBytes = dstW * 4, srcRowBytes = srcW * 4;
  for (var y = 0; y < dstH; y++) {
    out.setRange(y * rowBytes, (y + 1) * rowBytes, src, y * srcRowBytes);
  }
  return out;
}

class ReplayVideoExporter {
  /// Drive [capture] over [plan.frameCount] frames and push each into
  /// [sink]. Frame 0 fixes the output size (even-cropped); later frames are
  /// cropped to it. [onProgress] gets 0..1; [isCancelled] is polled between
  /// frames — a cancelled run still closes the sink so the partial file is
  /// valid, and reports `cancelled: true` so the caller can delete it.
  Future<ExportResult> run({
    required Duration timelineTotal,
    required ExportPlan plan,
    required FrameCapture capture,
    required VideoSink sink,
    required String outputPath,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final n = plan.frameCount;
    if (n <= 0) throw ArgumentError('plan yields no frames');
    var started = false;
    var width = 0, height = 0, written = 0, cancelled = false;
    try {
      for (var i = 0; i < n; i++) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        final frame = await capture(plan.virtualTimeOfFrame(i, timelineTotal));
        if (frame == null) {
          cancelled = true;
          break;
        }
        if (!started) {
          width = evenDown(frame.width);
          height = evenDown(frame.height);
          if (width < 2 || height < 2) {
            throw StateError('frame too small: ${frame.width}×${frame.height}');
          }
          await sink.start(
              width: width, height: height, fps: plan.fps, path: outputPath);
          started = true;
        }
        await sink.addFrame(
            cropRgba(frame.rgba, frame.width, frame.height, width, height));
        written++;
        onProgress?.call(written / n);
      }
    } finally {
      if (started) await sink.finish();
    }
    return ExportResult(
        path: outputPath,
        framesWritten: written,
        width: width,
        height: height,
        cancelled: cancelled || written < n);
  }
}
