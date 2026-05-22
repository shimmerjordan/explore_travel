import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../core/prefs.dart';

class UploadResult {
  /// Public URL — what gets stored in the journal entry.
  final String displayUrl;
  /// Backend-specific opaque token used to delete later (e.g. GitHub
  /// content SHA, or the original URL for a custom host).
  final String deleteToken;
  const UploadResult({required this.displayUrl, required this.deleteToken});
}

/// Extra context for path templating + private routing. All fields are
/// optional — backends use what they can and fall back to a date-based
/// path for the rest.
class UploadContext {
  final int journalId;
  final String level; // 'public' | 'private'
  final String? travelerSlug;
  final String? continent;
  final String? country;
  final String? province;
  final String? city;
  final String? titleSlug;
  const UploadContext({
    required this.journalId,
    this.level = 'public',
    this.travelerSlug,
    this.continent,
    this.country,
    this.province,
    this.city,
    this.titleSlug,
  });
}

abstract class ImgHostBackend {
  Future<UploadResult> upload(File file, {required UploadContext ctx});

  /// Best-effort: silently swallows 404 / not-implemented.
  Future<void> delete(String displayUrl, String deleteToken);
}

class NoopBackend implements ImgHostBackend {
  @override
  Future<UploadResult> upload(File file, {required UploadContext ctx}) async {
    throw StateError('图床未配置 (imgHostKind=none)');
  }

  @override
  Future<void> delete(String displayUrl, String deleteToken) async {}
}

String _sanitize(String s, {String fallback = 'x'}) {
  if (s.isEmpty) return fallback;
  // Keep ASCII alphanumerics, CJK, dash, underscore. Replace everything else.
  final out = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (RegExp(r'[A-Za-z0-9\-_]').hasMatch(ch) ||
        (r >= 0x4E00 && r <= 0x9FFF)) {
      out.write(ch);
    } else if (ch == ' ' || ch == '/' || ch == '\\') {
      out.write('-');
    }
  }
  final s2 = out.toString();
  return s2.isEmpty ? fallback : s2;
}

/// Uploads via GitHub Contents API (no CI involved). The file lands in a
/// public repo at `{prefix}/{yyyy}/{mm}/{journalId}/{uuid}.{ext}` and we
/// hand back a jsDelivr/Statically URL by substituting into the user's
/// configured template.
class GithubBackend implements ImgHostBackend {
  final String pat;
  final String owner;
  final String repo;
  final String branch;
  final String pathPrefix;
  final String cdnTemplate;
  final Dio _dio = Dio();

  GithubBackend({
    required this.pat,
    required this.owner,
    required this.repo,
    required this.branch,
    required this.pathPrefix,
    required this.cdnTemplate,
    this.isPrivate = false,
  });

  String _buildPath(File file, UploadContext ctx) {
    final now = DateTime.now();
    final yyyy = now.year.toString();
    final mm = now.month.toString().padLeft(2, '0');
    final ext = p.extension(file.path).toLowerCase();
    final id = const Uuid().v4().substring(0, 8);
    final prefix =
        pathPrefix.isEmpty ? '' : '${pathPrefix.replaceAll(RegExp(r'/+$'), '')}/';
    // Hierarchy: prefix / traveler / yyyy / mm / continent / country /
    // <title-journalId> / <uuid>.ext. Title gets the journal id appended so
    // two entries with the same name don't collide.
    final traveler = _sanitize(ctx.travelerSlug ?? 'self', fallback: 'self');
    final continent =
        _sanitize(ctx.continent ?? 'unknown', fallback: 'unknown');
    final country = _sanitize(ctx.country ?? 'unknown', fallback: 'unknown');
    final province = _sanitize(ctx.province ?? '', fallback: '');
    final city = _sanitize(ctx.city ?? '', fallback: '');
    final titleBase = _sanitize(ctx.titleSlug ?? 'untitled',
        fallback: 'untitled');
    final titleDir = '$titleBase-${ctx.journalId}';
    // Insert province/city only when known — keeps URLs cleaner for points
    // that only resolved to country level.
    final regionParts = [
      continent,
      country,
      if (province.isNotEmpty) province,
      if (city.isNotEmpty) city,
    ].join('/');
    return '$prefix$traveler/$yyyy/$mm/$regionParts/$titleDir/$id$ext';
  }

  String _cdnUrlFor(String path) => cdnTemplate
      .replaceAll('{user}', owner)
      .replaceAll('{repo}', repo)
      .replaceAll('{branch}', branch)
      .replaceAll('{path}', path);

  /// When true, the backend skips the CDN template and returns a custom
  /// `gh-private://` URL that the in-app loader will fetch with the PAT.
  final bool isPrivate;

  @override
  Future<UploadResult> upload(File file, {required UploadContext ctx}) async {
    final path = _buildPath(file, ctx);
    final bytes = await file.readAsBytes();
    final url = 'https://api.github.com/repos/$owner/$repo/contents/$path';
    final resp = await _dio.put(
      url,
      options: Options(
        headers: {
          'Authorization': 'Bearer $pat',
          'Accept': 'application/vnd.github+json',
        },
      ),
      data: {
        'message': 'upload $path',
        'branch': branch,
        'content': base64Encode(bytes),
      },
    );
    final data = resp.data as Map<String, dynamic>;
    final sha = (data['content']?['sha'] as String?) ?? '';
    final displayUrl = isPrivate
        ? 'gh-private://$owner/$repo@$branch/$path'
        : _cdnUrlFor(path);
    return UploadResult(
      displayUrl: displayUrl,
      // Encode both path and sha — we need both for DELETE.
      deleteToken: jsonEncode({'path': path, 'sha': sha}),
    );
  }

  @override
  Future<void> delete(String displayUrl, String deleteToken) async {
    try {
      final j = jsonDecode(deleteToken) as Map<String, dynamic>;
      var path = j['path'] as String;
      var sha = (j['sha'] as String?) ?? '';
      if (sha.isEmpty) {
        // Fall back: GET to look up current sha.
        final resp = await _dio.get(
          'https://api.github.com/repos/$owner/$repo/contents/$path',
          options: Options(
            headers: {
              'Authorization': 'Bearer $pat',
              'Accept': 'application/vnd.github+json',
            },
          ),
          queryParameters: {'ref': branch},
        );
        sha = (resp.data['sha'] as String?) ?? '';
      }
      if (sha.isEmpty) return;
      await _dio.delete(
        'https://api.github.com/repos/$owner/$repo/contents/$path',
        options: Options(
          headers: {
            'Authorization': 'Bearer $pat',
            'Accept': 'application/vnd.github+json',
          },
        ),
        data: {
          'message': 'delete $path',
          'branch': branch,
          'sha': sha,
        },
      );
    } catch (e) {
      debugPrint('[GithubBackend] delete failed: $e');
    }
  }
}

/// Generic custom-host backend driven by URL templates. Multipart POST,
/// then JSON path extraction, then template substitution. Mirrors what
/// Chevereto, EasyImage, Lsky, SM.MS etc. accept.
class CustomBackend implements ImgHostBackend {
  final String uploadUrl;
  final String fileField;
  final String responseUrlPath; // e.g. "data.url"
  final String displayUrlTemplate; // e.g. "{url}"
  final String deleteUrlTemplate; // empty = unsupported
  final String authHeader; // raw "Bearer xxx" or "Basic yyy" — empty for none
  final Dio _dio = Dio();

  CustomBackend({
    required this.uploadUrl,
    required this.fileField,
    required this.responseUrlPath,
    required this.displayUrlTemplate,
    required this.deleteUrlTemplate,
    required this.authHeader,
  });

  dynamic _extract(dynamic data, String jsonpath) {
    if (jsonpath.isEmpty) return data;
    dynamic cur = data;
    for (final part in jsonpath.split('.')) {
      if (cur is Map && cur.containsKey(part)) {
        cur = cur[part];
      } else {
        return null;
      }
    }
    return cur;
  }

  @override
  Future<UploadResult> upload(File file, {required UploadContext ctx}) async {
    final headers = <String, dynamic>{};
    if (authHeader.isNotEmpty) headers['Authorization'] = authHeader;
    final form = FormData.fromMap({
      fileField: await MultipartFile.fromFile(file.path,
          filename: p.basename(file.path)),
    });
    final resp = await _dio.post(
      uploadUrl,
      data: form,
      options: Options(headers: headers),
    );
    final extracted = _extract(resp.data, responseUrlPath);
    if (extracted == null) {
      throw StateError(
          '上传成功但响应里取不到 URL（path "$responseUrlPath" 不存在）。响应：${resp.data}');
    }
    final url = extracted.toString();
    final display = displayUrlTemplate.replaceAll('{url}', url);
    return UploadResult(displayUrl: display, deleteToken: url);
  }

  @override
  Future<void> delete(String displayUrl, String deleteToken) async {
    if (deleteUrlTemplate.isEmpty) return;
    final endpoint = deleteUrlTemplate.replaceAll('{url}', deleteToken);
    final headers = <String, dynamic>{};
    if (authHeader.isNotEmpty) headers['Authorization'] = authHeader;
    try {
      await _dio.delete(endpoint, options: Options(headers: headers));
    } catch (e) {
      debugPrint('[CustomBackend] delete failed: $e');
    }
  }
}

/// Resolves the configured backend, or [NoopBackend] when the user hasn't
/// finished setting things up. Centralised so the upload queue and the
/// "test connection" button speak through one entry point.
///
/// [level] picks between the public and private GitHub configs when the
/// active host is `github`. Custom hosts are level-agnostic.
ImgHostBackend backendFromSettings(AppSettings s, {String level = 'public'}) {
  switch (s.imgHostKind) {
    case 'github':
      if (level == 'private') {
        if ((s.githubPrivatePat ?? '').isEmpty ||
            (s.githubPrivateOwner ?? '').isEmpty ||
            (s.githubPrivateRepo ?? '').isEmpty) {
          return NoopBackend();
        }
        return GithubBackend(
          pat: s.githubPrivatePat!,
          owner: s.githubPrivateOwner!,
          repo: s.githubPrivateRepo!,
          branch: s.githubPrivateBranch,
          pathPrefix: s.githubPrivatePathPrefix,
          cdnTemplate: '', // unused — isPrivate flips the display URL
          isPrivate: true,
        );
      }
      if ((s.githubPat ?? '').isEmpty ||
          (s.githubOwner ?? '').isEmpty ||
          (s.githubRepo ?? '').isEmpty) {
        return NoopBackend();
      }
      return GithubBackend(
        pat: s.githubPat!,
        owner: s.githubOwner!,
        repo: s.githubRepo!,
        branch: s.githubBranch,
        pathPrefix: s.githubPathPrefix,
        cdnTemplate: s.githubCdnTemplate,
      );
    case 'custom':
      if ((s.customUploadUrl ?? '').isEmpty) return NoopBackend();
      return CustomBackend(
        uploadUrl: s.customUploadUrl!,
        fileField: s.customFileField,
        responseUrlPath: s.customResponseUrlPath,
        displayUrlTemplate: s.customDisplayUrlTemplate,
        deleteUrlTemplate: s.customDeleteUrlTemplate,
        authHeader: s.customAuthHeader,
      );
    default:
      return NoopBackend();
  }
}
