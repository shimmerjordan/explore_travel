import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/core/prefs.dart';
import 'package:explore_journal/services/imghost/imghost_service.dart';

/// Image-host (图床) tests.
///
/// Two layers:
///  1. Routing tests — always run, no network. Verify `backendFromSettings`
///     picks the right backend for public vs private journals.
///  2. Live upload+auto-delete tests — gated on env credentials so CI and
///     other machines stay green (mirrors the FOW-fixture pattern in
///     fow_import_test.dart). They upload the committed fixture image to a
///     REAL GitHub repo, assert it's reachable via the Contents API, then
///     DELETE it so nothing is left behind on the host. Cleanup is also
///     registered via addTearDown so a mid-test failure can't leak a file.
///
/// Run the live tests with:
///   # public journal host
///   IMGHOST_TEST_PAT=ghp_xxx IMGHOST_TEST_OWNER=me IMGHOST_TEST_REPO=imgs \
///     flutter test test/imghost_test.dart
///   # private journal host (separate private repo + PAT)
///   IMGHOST_TEST_PRIVATE_PAT=ghp_xxx IMGHOST_TEST_PRIVATE_OWNER=me \
///     IMGHOST_TEST_PRIVATE_REPO=private-imgs flutter test test/imghost_test.dart
void main() {
  // The fixture image lives in the top-level test/ directory.
  final fixture = File('test/fixtures/imghost_sample.png');

  // ─────────────────── routing (no network) ───────────────────
  group('backendFromSettings routing (public vs private)', () {
    test("imgHostKind 'none' → NoopBackend", () {
      expect(backendFromSettings(const AppSettings()), isA<NoopBackend>());
    });

    test('github + public config → public GithubBackend', () {
      const s = AppSettings(
        imgHostKind: 'github',
        githubPat: 'tok',
        githubOwner: 'me',
        githubRepo: 'imgs',
      );
      final b = backendFromSettings(s, level: 'public');
      expect(b, isA<GithubBackend>());
      expect((b as GithubBackend).isPrivate, isFalse);
    });

    test('github + private config → private GithubBackend', () {
      const s = AppSettings(
        imgHostKind: 'github',
        githubPrivatePat: 'tok',
        githubPrivateOwner: 'me',
        githubPrivateRepo: 'private-imgs',
      );
      final b = backendFromSettings(s, level: 'private');
      expect(b, isA<GithubBackend>());
      expect((b as GithubBackend).isPrivate, isTrue);
    });

    test('github with NO private repo → private level falls back to Noop', () {
      // A user who only set up the public repo must not have private photos
      // silently uploaded to the public one.
      const s = AppSettings(
        imgHostKind: 'github',
        githubPat: 'tok',
        githubOwner: 'me',
        githubRepo: 'imgs',
      );
      expect(backendFromSettings(s, level: 'private'), isA<NoopBackend>());
    });

    test('custom host is level-agnostic → CustomBackend for both', () {
      const s = AppSettings(
        imgHostKind: 'custom',
        customUploadUrl: 'https://host.example/upload',
      );
      expect(backendFromSettings(s, level: 'public'), isA<CustomBackend>());
      expect(backendFromSettings(s, level: 'private'), isA<CustomBackend>());
    });

    test('custom without an upload URL → Noop', () {
      expect(backendFromSettings(const AppSettings(imgHostKind: 'custom')),
          isA<NoopBackend>());
    });

    test('NoopBackend.upload throws; delete is a silent no-op', () async {
      final b = NoopBackend();
      expect(
        () => b.upload(File('nope.png'), ctx: const UploadContext(journalId: 1)),
        throwsStateError,
      );
      await b.delete('u', 't'); // must not throw
    });

    test('fixture image exists in the top-level test/ directory', () {
      expect(fixture.existsSync(), isTrue,
          reason: 'expected ${fixture.path} to be committed');
      expect(fixture.lengthSync(), greaterThan(0));
    });
  });

  // ─────────────────── live upload + auto-delete ───────────────────
  group('GitHub image host — live upload then auto-delete', () {
    // Current existence of a file on GitHub via the Contents API (200/404).
    Future<int> contentsStatus(
        String pat, String owner, String repo, String branch, String path) async {
      final r = await Dio().get(
        'https://api.github.com/repos/$owner/$repo/contents/$path',
        queryParameters: {'ref': branch},
        options: Options(
          headers: {
            'Authorization': 'Bearer $pat',
            'Accept': 'application/vnd.github+json',
          },
          validateStatus: (_) => true, // don't throw on 404
        ),
      );
      return r.statusCode ?? 0;
    }

    Future<void> runLive({
      required String level,
      required AppSettings settings,
      required String pat,
      required String owner,
      required String repo,
      required String branch,
    }) async {
      final backend = backendFromSettings(settings, level: level);
      expect(backend, isA<GithubBackend>(),
          reason: '$level config should resolve to a GithubBackend');

      // Cleanup flag for the tearDown safety net (cleared once we delete).
      UploadResult? cleanup;
      addTearDown(() async {
        final c = cleanup;
        if (c != null) await backend.delete(c.displayUrl, c.deleteToken);
      });

      final res = await backend.upload(
        fixture,
        ctx: UploadContext(
          journalId: 999999,
          level: level,
          titleSlug: 'imghost-selftest',
        ),
      );
      cleanup = res;
      expect(res.displayUrl, isNotEmpty);
      expect(res.deleteToken, isNotEmpty);
      if (level == 'private') {
        expect(res.displayUrl, startsWith('gh-private://'),
            reason: 'private images must not get a public CDN URL');
      }

      final path = (jsonDecode(res.deleteToken) as Map<String, dynamic>)['path']
          as String;
      expect(await contentsStatus(pat, owner, repo, branch, path), 200,
          reason: 'uploaded image should exist on GitHub right after upload');

      // The point of the test: clean the host afterwards.
      await backend.delete(res.displayUrl, res.deleteToken);
      cleanup = null; // already deleted — don't double-delete in tearDown
      expect(await contentsStatus(pat, owner, repo, branch, path), 404,
          reason: 'test image must be auto-deleted from the host after the run '
              '(token=${res.deleteToken})');
    }

    test('PUBLIC journal image: upload → reachable → auto-delete', () async {
      final pat = Platform.environment['IMGHOST_TEST_PAT'];
      final owner = Platform.environment['IMGHOST_TEST_OWNER'];
      final repo = Platform.environment['IMGHOST_TEST_REPO'];
      if ((pat ?? '').isEmpty || (owner ?? '').isEmpty || (repo ?? '').isEmpty) {
        markTestSkipped(
            'set IMGHOST_TEST_PAT / IMGHOST_TEST_OWNER / IMGHOST_TEST_REPO to run');
        return;
      }
      final branch = Platform.environment['IMGHOST_TEST_BRANCH'] ?? 'main';
      final settings = AppSettings(
        imgHostKind: 'github',
        githubPat: pat,
        githubOwner: owner,
        githubRepo: repo,
        githubBranch: branch,
      );
      await runLive(
          level: 'public',
          settings: settings,
          pat: pat!,
          owner: owner!,
          repo: repo!,
          branch: branch);
    });

    test('PRIVATE journal image: upload → reachable → auto-delete', () async {
      final pat = Platform.environment['IMGHOST_TEST_PRIVATE_PAT'];
      final owner = Platform.environment['IMGHOST_TEST_PRIVATE_OWNER'];
      final repo = Platform.environment['IMGHOST_TEST_PRIVATE_REPO'];
      if ((pat ?? '').isEmpty || (owner ?? '').isEmpty || (repo ?? '').isEmpty) {
        markTestSkipped(
            'set IMGHOST_TEST_PRIVATE_PAT / _OWNER / _REPO to run');
        return;
      }
      final branch = Platform.environment['IMGHOST_TEST_PRIVATE_BRANCH'] ?? 'main';
      final settings = AppSettings(
        imgHostKind: 'github',
        githubPrivatePat: pat,
        githubPrivateOwner: owner,
        githubPrivateRepo: repo,
        githubPrivateBranch: branch,
      );
      await runLive(
          level: 'private',
          settings: settings,
          pat: pat!,
          owner: owner!,
          repo: repo!,
          branch: branch);
    });
  });
}
