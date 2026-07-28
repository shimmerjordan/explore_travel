import 'dart:convert';
import 'package:dio/dio.dart';
import 'leaderboard_model.dart';
import 'leaderboard_service.dart';
import '../security/http_guard.dart';

/// Outbound paths for sharing the local leaderboard:
///   1. [GithubLeaderboardPR] — push `entries/<peerId>.json` to a fork +
///      open a PR against a community-maintained registry repo.
///   2. [HttpLeaderboardClient] — sync to/from an opt-in REST server. See
///      `docs/leaderboard-server-api.md` for the full contract.
///
/// Both are best-effort. The decentralised P2P merge in
/// [LeaderboardService.mergeBatch] is the authoritative path; these two
/// just plug the islands together for users who never meet anyone IRL.

class GithubLeaderboardPR {
  final String owner;
  final String repo;
  final String branch;
  final String pat;
  final Dio _dio;

  GithubLeaderboardPR({
    required this.owner,
    required this.repo,
    required this.branch,
    required this.pat,
    Dio? dio,
  }) : _dio = dio ?? guardedDio() {
    _dio.options.headers['Authorization'] = 'Bearer $pat';
    _dio.options.headers['Accept'] = 'application/vnd.github+json';
    _dio.options.headers['X-GitHub-Api-Version'] = '2022-11-28';
  }

  /// Fetch the existing `entries/` directory listing and merge it with
  /// [local] using [LeaderboardService.mergeBatch] semantics so the PR
  /// only includes net-new info. Returns the merged set.
  Future<List<LeaderboardEntry>> fetchAndMerge(
      List<LeaderboardEntry> local, LeaderboardService svc) async {
    try {
      final resp = await _dio.get<List<dynamic>>(
        'https://api.github.com/repos/$owner/$repo/contents/entries?ref=$branch',
      );
      final files = (resp.data ?? []).cast<Map<String, dynamic>>();
      final remote = <LeaderboardEntry>[];
      for (final f in files) {
        final dl = f['download_url']?.toString();
        if (dl == null || !dl.endsWith('.json')) continue;
        try {
          final body = await _dio.get<String>(dl,
              options: Options(responseType: ResponseType.plain));
          final j =
              jsonDecode(body.data ?? '{}') as Map<String, dynamic>;
          remote.add(LeaderboardEntry.fromJson(j));
        } catch (_) {}
      }
      await svc.mergeBatch(remote);
    } catch (_) {
      // Repo may be empty or unreachable — fall through with whatever
      // local already had.
    }
    await svc.mergeBatch(local);
    return svc.current;
  }

  /// Push the caller's own entry to a personal fork branch and open a PR.
  /// `selfEntry` should already be signed.
  ///
  /// Returns the PR URL on success. Throws on failure with the GitHub
  /// error body in the message — surface it to the user.
  Future<String> contribute(LeaderboardEntry selfEntry) async {
    final branchName =
        'leaderboard/${selfEntry.peerId.substring(0, selfEntry.peerId.length.clamp(0, 8))}-'
        '${DateTime.now().millisecondsSinceEpoch}';
    final path = 'entries/${selfEntry.peerId}.json';
    final content =
        base64.encode(utf8.encode(const JsonEncoder.withIndent('  ')
            .convert(selfEntry.toJson())));

    // 1. Get base branch SHA.
    final refResp = await _dio.get<Map<String, dynamic>>(
      'https://api.github.com/repos/$owner/$repo/git/ref/heads/$branch',
    );
    final baseSha = refResp.data!['object']['sha'] as String;

    // 2. Create the new branch.
    await _dio.post(
      'https://api.github.com/repos/$owner/$repo/git/refs',
      data: {'ref': 'refs/heads/$branchName', 'sha': baseSha},
    );

    // 3. Look up existing file SHA (if any) so we PUT-update rather than
    //    create-fail.
    String? existingSha;
    try {
      final exist = await _dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$owner/$repo/contents/$path?ref=$branchName',
      );
      existingSha = exist.data?['sha']?.toString();
    } catch (_) {}

    // 4. Commit the file on the new branch.
    await _dio.put(
      'https://api.github.com/repos/$owner/$repo/contents/$path',
      data: {
        'message':
            'leaderboard: update ${selfEntry.displayName} (${selfEntry.peerId.substring(0, selfEntry.peerId.length.clamp(0, 8))})',
        'branch': branchName,
        'content': content,
        if (existingSha != null) 'sha': existingSha,
      },
    );

    // 5. Open the PR.
    final pr = await _dio.post<Map<String, dynamic>>(
      'https://api.github.com/repos/$owner/$repo/pulls',
      data: {
        'title':
            'leaderboard: ${selfEntry.displayName} → ${selfEntry.globalPercent.toStringAsFixed(6)}%',
        'head': branchName,
        'base': branch,
        'body':
            'Submitting signed leaderboard entry for `${selfEntry.peerId}`.\n\n'
            '* globalKm2: `${selfEntry.globalKm2}`\n'
            '* globalPercent: `${selfEntry.globalPercent}`\n'
            '* statsAt: `${selfEntry.statsAt.toIso8601String()}`\n\n'
            'Signature can be verified with the embedded `publicKey`.',
      },
    );
    return pr.data!['html_url']?.toString() ?? '';
  }
}

class HttpLeaderboardClient {
  final String baseUrl;
  final String? token;
  final Dio _dio;

  HttpLeaderboardClient({required this.baseUrl, this.token, Dio? dio})
      : _dio = dio ?? guardedDio() {
    if (token != null && token!.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  /// GET /entries → full registry; the server is expected to honour the
  /// same LWW + signature rules a peer would.
  Future<List<LeaderboardEntry>> fetchAll() async {
    final resp = await _dio.get<List<dynamic>>('$baseUrl/entries');
    return (resp.data ?? [])
        .cast<Map<String, dynamic>>()
        .map(LeaderboardEntry.fromJson)
        .toList();
  }

  /// POST /entries with the signed self entry. The server SHOULD verify
  /// the signature and reject if it doesn't pass; we don't trust the
  /// server's ack though — clients still verify on pull.
  Future<void> push(LeaderboardEntry selfEntry) async {
    await _dio.post('$baseUrl/entries', data: selfEntry.toJson());
  }
}
