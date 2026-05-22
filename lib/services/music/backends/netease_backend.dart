import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart' as enc;
import '../music_service.dart';
import 'music_backend.dart';

/// Direct netease cloud music backend using the "linuxapi" flavor.
///
/// Encrypts a small JSON payload with AES-128-ECB (PKCS7, hex-encoded
/// uppercase) using the public linuxapi key, then POSTs it to
/// `https://music.163.com/api/linux/forward` as `eparams=<hex>`. The
/// response is plain JSON.
///
/// We deliberately use linuxapi (ECB only) rather than the more common
/// weapi flavor (CBC + RSA-OAEP) — it covers search / song URL / cover
/// without needing RSA.
///
/// Known limitations:
///  - VIP / high-bitrate tracks need a logged-in MUSIC_U Cookie. If the
///    user saved one in [AppSettings.musicCredentials], we forward it.
///  - Netease occasionally changes the endpoint; if this stops working,
///    the source dropdown still has "GD音乐台" as a fallback.
class NeteaseBackend implements MusicBackend {
  static const _aesKey = 'rFgB&h#%2?^eDg:Q';
  static const _forwardUrl =
      'https://music.163.com/api/linux/forward';
  static const _ua =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36';

  final Dio _dio;
  late final enc.Encrypter _encrypter;

  NeteaseBackend({String? cookie})
      : _dio = Dio(BaseOptions(
          headers: {
            'User-Agent': _ua,
            'Referer': 'https://music.163.com',
            if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
          },
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          contentType: 'application/x-www-form-urlencoded',
          responseType: ResponseType.json,
        )) {
    _encrypter = enc.Encrypter(
      enc.AES(enc.Key.fromUtf8(_aesKey), mode: enc.AESMode.ecb),
    );
  }

  @override
  String get source => 'netease';

  @override
  Future<List<MusicTrack>> search(String keyword, {int count = 20}) async {
    final resp = await _post('https://music.163.com/api/cloudsearch/pc', {
      's': keyword,
      'type': 1,
      'limit': count,
      'offset': 0,
    });
    final result = resp['result'];
    final songs = (result is Map ? result['songs'] : null) as List? ?? const [];
    return songs.whereType<Map>().map((j) {
      final artists = (j['ar'] as List?)
              ?.map((a) => (a as Map)['name']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList() ??
          const <String>[];
      final album = (j['al'] as Map?)?['name']?.toString() ?? '';
      final picUrl = (j['al'] as Map?)?['picUrl']?.toString();
      return MusicTrack(
        id: j['id'].toString(),
        name: j['name']?.toString() ?? '',
        artist: artists.join('/'),
        album: album,
        source: 'netease',
        picId: picUrl,
      );
    }).toList();
  }

  @override
  Future<String?> streamUrl(MusicTrack t, {String br = '320'}) async {
    final bitrate = switch (br) {
      '128' => 128000,
      '192' => 192000,
      '320' => 320000,
      '740' => 740000,
      '999' => 999000,
      _ => 320000,
    };
    final resp =
        await _post('https://music.163.com/api/song/enhance/player/url', {
      'ids': '[${t.id}]',
      'br': bitrate,
    });
    final data = (resp['data'] as List?) ?? const [];
    if (data.isEmpty) return null;
    final first = data.first as Map?;
    final url = first?['url']?.toString();
    if (url == null || url.isEmpty) return null;
    return url.replaceFirst(RegExp(r'^http://'), 'https://');
  }

  @override
  Future<String?> coverUrl(MusicTrack t, {int size = 300}) async {
    final base = t.picId;
    if (base == null || base.isEmpty) return null;
    return '$base?param=${size}y$size';
  }

  Future<Map<String, dynamic>> _post(
      String upstream, Map<String, dynamic> params) async {
    final inner = jsonEncode({
      'method': 'POST',
      'url': upstream,
      'params': params,
    });
    // AES-128-ECB encrypt → uppercase hex. IV is unused in ECB mode but
    // `encrypt` requires we pass one; use a zero block.
    final iv = enc.IV.fromLength(16);
    final encrypted = _encrypter.encrypt(inner, iv: iv);
    final hex = encrypted.base16.toUpperCase();
    final resp = await _dio.post(_forwardUrl, data: 'eparams=$hex');
    final body = resp.data;
    if (body is Map<String, dynamic>) return body;
    if (body is String) return jsonDecode(body) as Map<String, dynamic>;
    if (body is Map) return Map<String, dynamic>.from(body);
    throw StateError(
        'netease: unexpected response type ${body.runtimeType}');
  }
}

