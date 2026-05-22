import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../../app/providers.dart';

/// Push-to-talk: hold to record short chunks (~300 ms each), each chunk is
/// streamed immediately to all group peers over the existing GroupService
/// `voice` channel. Receivers queue and play seamlessly via
/// `_VoiceStreamPlayer` in `GroupSyncController`.
///
/// Zero server: the audio bytes flow directly device → ZeroTier LAN → device.
/// Not recorded anywhere; release the button and the stream stops.
class PttController {
  final Ref ref;
  PttController(this.ref);

  AudioRecorder? _recorder;
  bool _active = false;
  bool get active => _active;

  static const _chunkMs = 350;

  Timer? _chunkTimer;
  String? _currentPath;
  int _seq = 0;
  String? _targetPeerId;

  /// [targetPeerId] non-null = private (walkie-talkie) call to that peer
  /// only. Null = broadcast to the whole group.
  Future<bool> start({String? targetPeerId}) async {
    if (_active) return true;
    _recorder ??= AudioRecorder();
    final hasPerm = await _recorder!.hasPermission();
    if (!hasPerm) return false;
    _active = true;
    _seq = 0;
    _targetPeerId = targetPeerId;
    await _startNextChunk();
    _chunkTimer = Timer.periodic(
        const Duration(milliseconds: _chunkMs), (_) => _rotateChunk());
    return true;
  }

  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _chunkTimer?.cancel();
    _chunkTimer = null;
    try {
      await _finishCurrent();
    } catch (_) {}
    final target = _targetPeerId;
    _targetPeerId = null;
    try {
      final svc = ref.read(groupServiceProvider);
      if (target != null) {
        await svc.sendVoiceEndTo(target);
      } else {
        await svc.sendVoiceEnd();
      }
    } catch (_) {}
  }

  Future<void> _startNextChunk() async {
    final dir = await getTemporaryDirectory();
    _currentPath =
        p.join(dir.path, 'ptt_${DateTime.now().microsecondsSinceEpoch}.m4a');
    try {
      await _recorder!.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          numChannels: 1,
          sampleRate: 24000,
          bitRate: 32000,
        ),
        path: _currentPath!,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('PTT chunk start failed: $e');
    }
  }

  Future<void> _rotateChunk() async {
    if (!_active) return;
    try {
      await _finishCurrent();
      await _startNextChunk();
    } catch (_) {}
  }

  Future<void> _finishCurrent() async {
    if (_currentPath == null) return;
    try {
      await _recorder!.stop();
    } catch (_) {}
    final f = File(_currentPath!);
    if (!f.existsSync()) return;
    try {
      final bytes = await f.readAsBytes();
      if (bytes.isNotEmpty) {
        final svc = ref.read(groupServiceProvider);
        if (_targetPeerId != null) {
          await svc.sendVoiceTo(_targetPeerId!, bytes, 'audio/mp4');
        } else {
          await svc.sendVoice(bytes, 'audio/mp4');
        }
        _seq++;
      }
      try {
        await f.delete();
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _recorder?.dispose();
    } catch (_) {}
  }
}

final pttControllerProvider = Provider<PttController>((ref) {
  final c = PttController(ref);
  ref.onDispose(() => c.dispose());
  return c;
});

final pttActiveProvider = StateProvider<bool>((ref) => false);
