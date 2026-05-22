import 'dart:convert';
import 'package:dio/dio.dart';
import '../music_service.dart';
import 'music_backend.dart';

/// Direct JOOX backend.
///
/// JOOX doesn't publish an official client API; the endpoints below are
/// reverse-engineered from the web/mobile clients and are what the
/// community Music API aggregators (gdstudio, listen1, etc.) hit
/// internally. The format is JSONP-style — the responses come wrapped in
/// `MusicJsonCallback(...)`.
///
/// Known limitations:
///  - JOOX's catalog is geo-fenced to HK / TW / SG / MY / TH; from
///    elsewhere most tracks return a 403 on the stream URL. Search still
///    works.
///  - VIP tracks require a `wmid` Cookie from a logged-in JOOX session.
class JooxBackend implements MusicBackend {
  static const _base = 'http://api-jooxtt.sanook.com';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  final Dio _dio;

  JooxBackend({String? cookie})
      : _dio = Dio(BaseOptions(
          headers: {
            'User-Agent': _ua,
            'Referer': 'https://www.joox.com/',
            if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
          },
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ));

  @override
  String get source => 'joox';

  /// Strip the `MusicJsonCallbackjx(...)` wrapper that the upstream uses.
  Map<String, dynamic>? _unwrap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      final s = data.trim();
      final open = s.indexOf('(');
      final close = s.lastIndexOf(')');
      if (open < 0 || close <= open) {
        try {
          return jsonDecode(s) as Map<String, dynamic>;
        } catch (_) {
          return null;
        }
      }
      try {
        return jsonDecode(s.substring(open + 1, close))
            as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @override
  Future<List<MusicTrack>> search(String keyword, {int count = 20}) async {
    final resp = await _dio.get(
      '$_base/openjoox/v1/search',
      queryParameters: {
        'country': 'hk',
        'lang': 'zh',
        'search_input': keyword,
        'pn': 1,
        'sin': 0,
        'ein': count - 1,
      },
      options: Options(responseType: ResponseType.plain),
    );
    final doc = _unwrap(resp.data);
    if (doc == null) return [];
    final items = (doc['itemlist'] as List?) ?? const [];
    return items.whereType<Map>().map((j) {
      final artists = (j['singer_list'] as List?)
              ?.map((a) => (a as Map)['name']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList() ??
          const <String>[];
      return MusicTrack(
        id: (j['songid'] ?? j['msid'] ?? '').toString(),
        name: j['name']?.toString() ?? '',
        artist: artists.join('/'),
        album: (j['album'] is Map)
            ? (j['album']['name']?.toString() ?? '')
            : (j['album']?.toString() ?? ''),
        source: 'joox',
        picId: (j['album'] is Map)
            ? j['album']['cover_url_large']?.toString() ??
                j['album']['cover_url']?.toString()
            : null,
      );
    }).toList();
  }

  @override
  Future<String?> streamUrl(MusicTrack t, {String br = '320'}) async {
    final resp = await _dio.get(
      '$_base/openjoox/v1/url',
      queryParameters: {
        'country': 'hk',
        'lang': 'zh',
        'songid': t.id,
      },
      options: Options(responseType: ResponseType.plain),
    );
    final doc = _unwrap(resp.data);
    if (doc == null) return null;
    final url = doc['mp3_url']?.toString() ??
        doc['url']?.toString() ??
        (doc['hires_url']?.toString());
    if (url == null || url.isEmpty) return null;
    return url;
  }

  @override
  Future<String?> coverUrl(MusicTrack t, {int size = 300}) async {
    return t.picId;
  }
}
