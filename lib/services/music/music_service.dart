import 'package:dio/dio.dart';
import 'package:just_audio/just_audio.dart';
import 'backends/joox_backend.dart';
import 'backends/kuwo_backend.dart';
import 'backends/music_backend.dart';
import 'backends/netease_backend.dart';
import '../security/http_guard.dart';

/// Aggregator. Direct backends (netease, kuwo) are tried first; everything
/// else falls back to the GD音乐台 proxy.
class MusicTrack {
  final String id;
  final String name;
  final String artist;
  final String album;
  final String source; // netease, tencent, kuwo...
  final String? picId;
  MusicTrack({
    required this.id,
    required this.name,
    required this.artist,
    required this.album,
    required this.source,
    this.picId,
  });
  factory MusicTrack.fromJson(Map<String, dynamic> j, String source) =>
      MusicTrack(
        id: j['id'].toString(),
        name: j['name']?.toString() ?? '',
        artist: (j['artist'] is List)
            ? (j['artist'] as List).join('/')
            : j['artist']?.toString() ?? '',
        album: j['album']?.toString() ?? '',
        source: source,
        picId: j['pic_id']?.toString(),
      );
}

class MusicService {
  final String apiBase;
  final Dio _dio = guardedDio();
  final AudioPlayer player = AudioPlayer();

  /// Per-source cookies / tokens looked up from settings. Forwarded to
  /// direct backends. Updated by [setCredentials].
  Map<String, String> _credentials = const {};

  MusicService(this.apiBase);

  void setCredentials(Map<String, String> creds) {
    _credentials = creds;
  }

  /// Sources with a direct backend implementation. Everything else falls
  /// back to the GD音乐台 proxy below. (GD itself is the only source that
  /// intentionally goes through the proxy — when the user picks it
  /// explicitly.)
  static const _directSources = {'netease', 'kuwo', 'joox'};

  MusicBackend _backendFor(String source) => switch (source) {
        'netease' => NeteaseBackend(cookie: _credentials['netease']),
        'kuwo' => KuwoBackend(cookie: _credentials['kuwo']),
        'joox' => JooxBackend(cookie: _credentials['joox']),
        _ => throw StateError('no direct backend for $source'),
      };

  /// 'gd' is a UI-only alias for "GD音乐台 aggregator's default" — gdstudio
  /// defaults to netease when no source is given, so we just drop the param.
  String _gdSource(String source) =>
      source == 'gd' ? 'netease' : source;

  Future<List<MusicTrack>> search(String keyword,
      {String source = 'gd', int count = 20}) async {
    // Direct-only: a source maps to exactly one backend. We deliberately
    // do NOT silently fall back to GD on failure — that hides the real
    // error and surprised users in the previous version. Pick another
    // source manually if direct doesn't work.
    if (_directSources.contains(source)) {
      return _backendFor(source).search(keyword, count: count);
    }
    // source == 'gd' → proxy.
    return _gdSearch(keyword, source: _gdSource(source), count: count);
  }

  Future<String?> resolveStreamUrl(MusicTrack t,
      {String br = '320'}) async {
    if (_directSources.contains(t.source)) {
      return _backendFor(t.source).streamUrl(t, br: br);
    }
    return _gdResolveStreamUrl(t, br: br);
  }

  Future<String?> resolveCoverUrl(MusicTrack t, {int size = 300}) async {
    if (_directSources.contains(t.source)) {
      return _backendFor(t.source).coverUrl(t, size: size);
    }
    return _gdResolveCoverUrl(t, size: size);
  }

  // ─── GD studio proxy fallbacks ───────────────────────────────────

  Future<List<MusicTrack>> _gdSearch(String keyword,
      {required String source, int count = 20}) async {
    final resp = await _dio.get(apiBase, queryParameters: {
      'types': 'search',
      'source': source,
      'name': keyword,
      'count': count,
    });
    final data = resp.data;
    if (data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map((j) => MusicTrack.fromJson(j, source))
          .toList();
    }
    return [];
  }

  Future<String?> _gdResolveStreamUrl(MusicTrack t, {String br = '320'}) async {
    final resp = await _dio.get(apiBase, queryParameters: {
      'types': 'url',
      'source': t.source,
      'id': t.id,
      'br': br,
    });
    final data = resp.data;
    if (data is Map && data['url'] != null) return data['url'].toString();
    return null;
  }

  Future<String?> _gdResolveCoverUrl(MusicTrack t, {int size = 300}) async {
    if (t.picId == null) return null;
    final resp = await _dio.get(apiBase, queryParameters: {
      'types': 'pic',
      'source': t.source,
      'id': t.picId,
      'size': size,
    });
    final data = resp.data;
    if (data is Map && data['url'] != null) return data['url'].toString();
    return null;
  }

  Future<void> play(MusicTrack t) async {
    final url = await resolveStreamUrl(t);
    if (url == null) return;
    await player.setUrl(url);
    await player.play();
  }

  /// Resolve every track's stream URL and play them sequentially via
  /// just_audio's [ConcatenatingAudioSource]. Skips tracks whose URL the
  /// gdstudio backend refuses (some tracks are region-locked or have a dead
  /// link upstream). Returns how many actually got queued.
  Future<int> playAll(List<MusicTrack> tracks) async {
    if (tracks.isEmpty) return 0;
    final sources = <AudioSource>[];
    for (final t in tracks) {
      try {
        final url = await resolveStreamUrl(t);
        if (url == null) continue;
        sources.add(AudioSource.uri(
          Uri.parse(url),
          tag: {'name': t.name, 'artist': t.artist, 'id': t.id},
        ));
      } catch (_) {}
    }
    if (sources.isEmpty) return 0;
    await player
        .setAudioSource(ConcatenatingAudioSource(children: sources));
    await player.play();
    return sources.length;
  }

  Future<void> stop() => player.stop();
  Future<void> pause() => player.pause();
  Future<void> resume() => player.play();
}
