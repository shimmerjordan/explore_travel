import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import '../../app/providers.dart';
import 'group_types.dart';

/// Listens to incoming group messages and reacts:
///   - music_play / music_stop  → sync local music player
///   - voice                    → stream PCM chunks into a per-peer
///                                playback session
class GroupSyncController {
  final Ref ref;
  StreamSubscription<GroupMessage>? _sub;
  GroupSyncController(this.ref);

  /// Currently auto-playing remote track URL (if any). When the broadcaster
  /// keeps pushing positions every few seconds we re-seek to keep in sync.
  String? _remoteUrl;
  AudioPlayer? _remotePlayer;

  /// Per-peer rolling audio buffers for incoming PTT voice streams.
  /// Each buffer is fed PCM bytes (or compressed Opus frames) as they
  /// arrive and played continuously via just_audio. To keep dependencies
  /// minimal we treat voice chunks as opaque audio bytes (e.g. ogg-opus
  /// or wav) and append them into a SimpleStreamPlayer wrapper.
  final _voicePlayers = <String, _VoiceStreamPlayer>{};

  void attach(Stream<GroupMessage> messages) {
    _sub?.cancel();
    _sub = messages.listen(_onMessage);
  }

  Future<void> _onMessage(GroupMessage m) async {
    switch (m.type) {
      case 'music_play':
        await _onMusicPlay(m);
        break;
      case 'music_stop':
        await _onMusicStop();
        break;
      case 'voice':
        await _onVoice(m);
        break;
      case 'voice_end':
        await _onVoiceEnd(m);
        break;
    }
  }

  Future<void> _onMusicPlay(GroupMessage m) async {
    if (!ref.read(settingsProvider).groupFollowMusic) return;
    final url = m.data['url']?.toString();
    final pos = (m.data['pos'] as num?)?.toInt() ?? 0;
    if (url == null || url.isEmpty) return;
    _remotePlayer ??= AudioPlayer();
    if (url != _remoteUrl) {
      _remoteUrl = url;
      try {
        await _remotePlayer!.setUrl(url);
      } catch (_) {}
    }
    try {
      await _remotePlayer!.seek(Duration(milliseconds: pos));
      await _remotePlayer!.play();
    } catch (_) {}
  }

  Future<void> _onMusicStop() async {
    _remoteUrl = null;
    try {
      await _remotePlayer?.stop();
    } catch (_) {}
  }

  Future<void> _onVoice(GroupMessage m) async {
    final mime = m.data['mime']?.toString() ?? 'audio/wav';
    final b64 = m.data['audio']?.toString();
    if (b64 == null) return;
    final bytes = base64.decode(b64);
    final player =
        _voicePlayers.putIfAbsent(m.fromId, () => _VoiceStreamPlayer(mime));
    player.feed(bytes);
  }

  Future<void> _onVoiceEnd(GroupMessage m) async {
    final p = _voicePlayers.remove(m.fromId);
    await p?.dispose();
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _remotePlayer?.dispose();
    for (final p in _voicePlayers.values) {
      await p.dispose();
    }
    _voicePlayers.clear();
  }
}

/// Plays a sequence of audio chunks (each is a self-contained file in our
/// case — typically a short ~250ms PCM-WAV blob). We just enqueue them on a
/// just_audio player and let it play sequentially.
class _VoiceStreamPlayer {
  final String mime;
  final AudioPlayer _player = AudioPlayer();
  final List<AudioSource> _queue = [];
  ConcatenatingAudioSource? _list;
  int _seq = 0;

  _VoiceStreamPlayer(this.mime) {
    _list = ConcatenatingAudioSource(children: []);
    _player.setAudioSource(_list!).then((_) => _player.play()).catchError((_) {});
  }

  void feed(List<int> bytes) {
    try {
      final dataUri =
          Uri.dataFromBytes(bytes, mimeType: mime).toString();
      final src = AudioSource.uri(Uri.parse(dataUri), tag: 'v$_seq');
      _seq++;
      _list?.add(src);
      _queue.add(src);
      // Trim — keep at most 30 chunks (~7.5 s).
      while (_queue.length > 30) {
        final old = _queue.removeAt(0);
        final idx = _list!.children.indexOf(old);
        if (idx >= 0) _list!.removeAt(idx);
      }
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
  }
}

final groupSyncControllerProvider = Provider<GroupSyncController>((ref) {
  final c = GroupSyncController(ref);
  ref.onDispose(() => c.dispose());
  return c;
});
