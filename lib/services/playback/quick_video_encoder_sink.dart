import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';

import 'replay_video_exporter.dart';

/// [VideoSink] over the platform hardware encoder (MediaCodec on Android,
/// AVFoundation on iOS/macOS) via flutter_quick_video_encoder. H.264 mp4,
/// no audio track.
class QuickVideoEncoderSink implements VideoSink {
  /// The plugin ships Android/iOS/macOS implementations only.
  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  @override
  Future<void> start(
      {required int width,
      required int height,
      required int fps,
      required String path}) async {
    // ~0.12 bit/px/frame: crisp map linework at 1080p ≈ 7 Mbps, clamped so
    // tiny or huge captures stay in a sane range.
    final bitrate =
        (width * height * fps * 0.12).round().clamp(2000000, 12000000);
    await FlutterQuickVideoEncoder.setLogLevel(LogLevel.error);
    await FlutterQuickVideoEncoder.setup(
      width: width,
      height: height,
      fps: fps,
      videoBitrate: bitrate,
      profileLevel: ProfileLevel.any,
      audioChannels: 0,
      audioBitrate: 0,
      sampleRate: 0,
      filepath: path,
    );
  }

  @override
  Future<void> addFrame(Uint8List rgba) =>
      FlutterQuickVideoEncoder.appendVideoFrame(rgba);

  @override
  Future<void> finish() => FlutterQuickVideoEncoder.finish();
}
