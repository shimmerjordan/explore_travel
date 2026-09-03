import 'package:dio/dio.dart';
import '../music_service.dart';
import 'music_backend.dart';
import '../../security/http_guard.dart';

/// Direct kuwo (酷我音乐) backend.
///
/// Kuwo's www endpoints expect three things:
///   - `Cookie: kw_token=<token>` where `<token>` is any arbitrary 10-char
///     uppercase string the client picks; the server only checks that
///     `Cookie.kw_token == X-Csrf-Token`.
///   - `csrf: <token>` header, same value.
///   - `Referer: http://www.kuwo.cn/` so the server believes we're the web
///     client.
///
/// Endpoints used:
///   search: /api/www/search/searchMusicBykeyWord
///   url:    /api/v1/www/music/playUrl   (newer endpoint that returns mp3
///                                        without needing a downloader)
///
/// VIP tracks need a logged-in Cookie; if the user saved one in
/// [AppSettings.musicCredentials] we forward it alongside our synthetic
/// kw_token.
class KuwoBackend implements MusicBackend {
  static const _csrf = 'EXJOURNAL01'; // 11 chars; any constant works
  static const _base = 'https://www.kuwo.cn';
  static const _ua =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36';

  final Dio _dio;

  KuwoBackend({String? cookie})
      : _dio = guardedDio(BaseOptions(
          headers: {
            'User-Agent': _ua,
            'Referer': '$_base/',
            'Cookie': cookie != null && cookie.isNotEmpty
                ? '$cookie; kw_token=$_csrf'
                : 'kw_token=$_csrf',
            'csrf': _csrf,
          },
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ));

  @override
  String get source => 'kuwo';

  @override
  Future<List<MusicTrack>> search(String keyword, {int count = 20}) async {
    final resp = await _dio.get(
      '$_base/api/www/search/searchMusicBykeyWord',
      queryParameters: {
        'key': keyword,
        'pn': 1,
        'rn': count,
        'httpsStatus': 1,
      },
    );
    final data = resp.data;
    if (data is! Map) return [];
    final inner = (data['data'] as Map?) ?? const {};
    final list = (inner['list'] as List?) ?? const [];
    return list.whereType<Map>().map((j) => MusicTrack(
          id: (j['rid'] ?? j['musicrid'] ?? '').toString(),
          name: j['name']?.toString() ?? '',
          artist: j['artist']?.toString() ?? '',
          album: j['album']?.toString() ?? '',
          source: 'kuwo',
          picId: j['pic']?.toString() ?? j['pic120']?.toString(),
        )).toList();
  }

  @override
  Future<String?> streamUrl(MusicTrack t, {String br = '320'}) async {
    // 128k / 320kmp3 / 2000kflac
    final brTag = switch (br) {
      '128' => '128kmp3',
      '192' => '192kmp3',
      '320' => '320kmp3',
      '740' => '2000kflac',
      '999' => '2000kflac',
      _ => '320kmp3',
    };
    final resp = await _dio.get(
      '$_base/api/v1/www/music/playUrl',
      queryParameters: {
        'mid': t.id,
        'type': 'music',
        'br': brTag,
        'httpsStatus': 1,
      },
    );
    final data = resp.data;
    if (data is! Map) return null;
    final code = data['code'];
    if (code != null && code != 200) return null;
    final url = (data['data'] as Map?)?['url']?.toString();
    return (url != null && url.isNotEmpty) ? url : null;
  }

  @override
  Future<String?> coverUrl(MusicTrack t, {int size = 300}) async {
    return t.picId; // search response already gave us a URL
  }
}
