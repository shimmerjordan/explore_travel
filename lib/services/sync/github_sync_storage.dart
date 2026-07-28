import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/prefs.dart';
import 'sync_storage.dart';
import '../security/http_guard.dart';

/// [SyncStorage] backed by a GitHub repo via the Contents API. Shards are
/// stored as files under [_base]`/<rel>` on the configured branch.
///
/// Native only — the provider refuses to build this on web because the PAT
/// must never enter browser JS. Reuses the GitHub credentials already in
/// [AppSettings] (the same repo the image host can use).
///
/// Two GitHub quirks handled here:
///  * **>1 MB reads**: the JSON Contents response truncates `content` past
///    1 MB, so reads use the `application/vnd.github.raw` media type which
///    streams the raw bytes up to 100 MB. Fog/track shards can exceed 1 MB.
///  * **update needs a `sha`**: PUT/DELETE on an existing path must pass its
///    blob `sha`. We cache shas from writes, and on a cold cache (or a 409/422
///    conflict) re-fetch the sha and retry, so a process restart can't wedge
///    an overwrite.
class GithubSyncStorage implements SyncStorage {
  final String token;
  final String owner;
  final String repo;
  final String branch;

  GithubSyncStorage({
    required this.token,
    required this.owner,
    required this.repo,
    required this.branch,
  });

  factory GithubSyncStorage.fromSettings(AppSettings s) {
    final pat = s.githubPat;
    final owner = s.githubOwner;
    final repo = s.githubRepo;
    if (pat == null || pat.isEmpty || owner == null || owner.isEmpty ||
        repo == null || repo.isEmpty) {
      throw StateError('GitHub 同步未配置（缺少 PAT / owner / repo）');
    }
    return GithubSyncStorage(
      token: pat,
      owner: owner,
      repo: repo,
      branch: s.githubBranch,
    );
  }

  static const _base = 'explore_journal/sync';

  final Dio _dio = guardedDio(BaseOptions(
    baseUrl: 'https://api.github.com',
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(minutes: 2),
  ));

  /// path → last-known blob sha, so an overwrite/delete can supply it without
  /// an extra round trip on the hot path.
  final Map<String, String> _shaCache = {};

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  String _contentPath(String rel) {
    final full = '$_base/$rel';
    final enc = full.split('/').map(Uri.encodeComponent).join('/');
    return '/repos/$owner/$repo/contents/$enc';
  }

  /// Current blob sha for [rel], or null if the file doesn't exist (404).
  Future<String?> _fetchSha(String rel, {CancelToken? cancelToken}) async {
    try {
      final r = await _dio.get(
        _contentPath(rel),
        queryParameters: {'ref': branch},
        cancelToken: cancelToken,
        options: Options(
          headers: _headers,
          validateStatus: (s) => s != null && (s == 200 || s == 404),
        ),
      );
      if (r.statusCode == 404) return null;
      final sha = (r.data as Map)['sha']?.toString();
      if (sha != null) _shaCache[rel] = sha;
      return sha;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<void> putSyncFile(String rel, List<int> bytes,
      {CancelToken? cancelToken}) async {
    final body = {
      'message': 'ej sync: $rel',
      'content': base64.encode(bytes),
      'branch': branch,
    };

    Future<Response> put(String? sha) => _dio.put(
          _contentPath(rel),
          data: sha == null ? body : {...body, 'sha': sha},
          cancelToken: cancelToken,
          options: Options(
            headers: _headers,
            validateStatus: (s) =>
                s != null && (s >= 200 && s < 300 || s == 409 || s == 422),
          ),
        );

    var resp = await put(_shaCache[rel]);
    // 409/422 ⇒ our sha was missing or stale; refetch the real one and retry.
    if (resp.statusCode == 409 || resp.statusCode == 422) {
      final sha = await _fetchSha(rel, cancelToken: cancelToken);
      resp = await put(sha);
      if (resp.statusCode == 409 || resp.statusCode == 422) {
        throw DioException(
          requestOptions: resp.requestOptions,
          response: resp,
          message: 'GitHub 拒绝写入 $rel（sha 冲突）',
        );
      }
    }
    final newSha = (resp.data as Map?)?['content']?['sha']?.toString();
    if (newSha != null) _shaCache[rel] = newSha;
  }

  @override
  Future<Uint8List?> getSyncFile(String rel, {CancelToken? cancelToken}) async {
    try {
      final r = await _dio.get<List<int>>(
        _contentPath(rel),
        queryParameters: {'ref': branch},
        cancelToken: cancelToken,
        options: Options(
          headers: {..._headers, 'Accept': 'application/vnd.github.raw'},
          responseType: ResponseType.bytes,
          validateStatus: (s) => s != null && (s == 200 || s == 404),
        ),
      );
      if (r.statusCode == 404 || r.data == null) return null;
      return Uint8List.fromList(r.data!);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<void> deleteSyncFile(String rel, {CancelToken? cancelToken}) async {
    final sha = _shaCache[rel] ?? await _fetchSha(rel, cancelToken: cancelToken);
    if (sha == null) return; // already absent — idempotent
    await _dio.delete(
      _contentPath(rel),
      data: {'message': 'ej sync rm: $rel', 'sha': sha, 'branch': branch},
      cancelToken: cancelToken,
      options: Options(
        headers: _headers,
        validateStatus: (s) => s != null && (s >= 200 && s < 300 || s == 404),
      ),
    );
    _shaCache.remove(rel);
  }
}
