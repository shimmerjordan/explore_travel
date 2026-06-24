import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../app/providers.dart';
import '../../core/prefs.dart';
import 'onedrive_config.dart';

/// OneDrive sync via Microsoft Graph + OAuth2 (authorization-code + PKCE).
///
/// This is the "redirect to the Microsoft login page" flow the user wanted —
/// [connect] opens the Microsoft sign-in page in an in-app browser tab
/// (Android Custom Tab / iOS ASWebAuthenticationSession), gets an auth code
/// back through a custom-scheme redirect, then we exchange it for tokens and
/// store the long-lived refresh token. All file I/O targets the app folder
/// (`special/approot` → "Apps/Explore Journal/" in the user's OneDrive), so we
/// only ever need the least-privilege `Files.ReadWrite.AppFolder` scope.
///
/// PREREQUISITE: the user registers an Azure app (any personal MS account
/// works) and pastes its Application (client) ID into settings, and adds the
/// redirect URI [redirectUri] under "Mobile and desktop applications".
class OneDriveService {
  final Ref ref;
  OneDriveService(this.ref) {
    // Fail fast on a dead network instead of hanging the UI forever, and log
    // every request so a stuck sync is visible in the console / debug log.
    _dio.interceptors.add(LogInterceptor(
      request: true,
      requestHeader: false,
      requestBody: false,
      responseHeader: false,
      responseBody: false,
      error: true,
      logPrint: (o) => debugPrint('[OneDrive] $o'),
    ));
  }

  // OAuth endpoints — `common` authority accepts personal + work accounts.
  static const _authorize =
      'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
  static const _token =
      'https://login.microsoftonline.com/common/oauth2/v2.0/token';
  static const _graph = 'https://graph.microsoft.com/v1.0';

  /// Custom-scheme redirect. NOTE: the scheme must satisfy flutter_web_auth_2's
  /// `^[a-z][a-z\d+.-]*$` (no underscores!) — hence `...explorejournal.oauth`,
  /// not the underscore-bearing bundle id. Register this exact URI in Azure.
  static const redirectUri = 'com.explorejournal.oauth://auth';
  static const callbackScheme = 'com.explorejournal.oauth';

  // App-folder gives a sandboxed folder + least privilege. User.Read is only
  // for showing which account is connected.
  static const _scopes = 'Files.ReadWrite.AppFolder offline_access User.Read';

  /// Baked-in Azure app client ID so users just tap "连接 OneDrive" and get
  /// redirected to Microsoft login with NO manual entry. Source order:
  ///   1. `--dart-define=ONEDRIVE_CLIENT_ID=...` (lets CI inject without
  ///      committing the id), else
  ///   2. [OneDriveConfig.clientId] from onedrive_config.dart.
  /// Empty in both → fall back to the optional in-app override field.
  static const _envClientId =
      String.fromEnvironment('ONEDRIVE_CLIENT_ID', defaultValue: '');
  static String get defaultClientId =>
      _envClientId.isNotEmpty ? _envClientId : OneDriveConfig.clientId;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 60),
    sendTimeout: const Duration(minutes: 2),
  ));

  // In-memory access-token cache (the provider is a singleton, so it persists).
  String? _accessToken;
  DateTime _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  AppSettings get _s => ref.read(settingsProvider);

  bool get connected => (_s.oneDriveRefreshToken ?? '').isNotEmpty;

  /// Build-time baked-in client ID wins over the in-app field, so a shipped
  /// build lets users connect with one tap (no manual entry).
  String? get effectiveClientId {
    if (defaultClientId.isNotEmpty) return defaultClientId;
    final f = _s.oneDriveClientId;
    return (f != null && f.isNotEmpty) ? f : null;
  }

  bool get hasClientId => effectiveClientId != null;
  String? get account => _s.oneDriveAccount;

  // ── OAuth ────────────────────────────────────────────────────────────────

  static String _randomString(int len) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Opens the Microsoft login page and, on success, persists the refresh
  /// token + the connected account label. Returns the account label.
  Future<String> connect() async {
    final clientId = effectiveClientId;
    if (clientId == null) {
      throw StateError('未配置 OneDrive 客户端 ID（在 onedrive_service.dart 的 '
          'defaultClientId 填入，或用 --dart-define，或在设置里粘贴；见 docs/onedrive_setup.md）');
    }

    final verifier = _randomString(64);
    final challenge =
        base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', '');
    final state = _randomString(24);

    final authUrl = Uri.parse(_authorize).replace(queryParameters: {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'response_mode': 'query',
      'scope': _scopes,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'prompt': 'select_account',
    }).toString();

    final result = await FlutterWebAuth2.authenticate(
      url: authUrl,
      callbackUrlScheme: callbackScheme,
    );
    final cb = Uri.parse(result);
    if (cb.queryParameters['error'] != null) {
      throw StateError(
          '登录失败：${cb.queryParameters['error_description'] ?? cb.queryParameters['error']}');
    }
    if (cb.queryParameters['state'] != state) {
      throw StateError('登录失败：state 不匹配（可能被劫持）');
    }
    final code = cb.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw StateError('登录失败：未拿到授权码');
    }

    final resp = await _dio.post(
      _token,
      data: {
        'client_id': clientId,
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'code_verifier': verifier,
        'scope': _scopes,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final data = resp.data as Map<String, dynamic>;
    final refresh = data['refresh_token'] as String?;
    if (refresh == null || refresh.isEmpty) {
      throw StateError('登录成功但未返回 refresh_token（确认勾选了 offline_access 权限）');
    }
    _cacheAccess(data);

    // Best-effort account label.
    var label = 'OneDrive';
    try {
      final me = await _dio.get('$_graph/me',
          options: Options(headers: {'Authorization': 'Bearer $_accessToken'}));
      final m = me.data as Map<String, dynamic>;
      label = (m['userPrincipalName'] ?? m['displayName'] ?? 'OneDrive')
          .toString();
    } catch (_) {}

    await ref.read(settingsProvider.notifier).update((p) => p.copyWith(
          oneDriveRefreshToken: refresh,
          oneDriveAccount: label,
        ));
    return label;
  }

  /// Forget the connection. Empty strings (not null) because copyWith merges
  /// with `?? this.x` and can't write null.
  Future<void> disconnect() async {
    _accessToken = null;
    _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);
    await ref.read(settingsProvider.notifier).update((p) =>
        p.copyWith(oneDriveRefreshToken: '', oneDriveAccount: ''));
  }

  void _cacheAccess(Map<String, dynamic> tokenResponse) {
    _accessToken = tokenResponse['access_token'] as String?;
    final secs = (tokenResponse['expires_in'] as num?)?.toInt() ?? 3600;
    // Refresh a minute early to dodge clock skew / in-flight expiry.
    _accessExpiry = DateTime.now().add(Duration(seconds: secs - 60));
  }

  /// Returns a valid access token, refreshing via the stored refresh token
  /// when the cached one is missing/expired. Rotates the refresh token if the
  /// server issues a new one.
  Future<String> _validAccessToken([CancelToken? cancelToken]) async {
    if (_accessToken != null && DateTime.now().isBefore(_accessExpiry)) {
      return _accessToken!;
    }
    final clientId = effectiveClientId;
    final refresh = _s.oneDriveRefreshToken;
    if (clientId == null) {
      throw StateError('缺少客户端 ID');
    }
    if (refresh == null || refresh.isEmpty) {
      throw StateError('未连接 OneDrive');
    }
    debugPrint('[OneDrive] refreshing access token');
    final resp = await _dio.post(
      _token,
      data: {
        'client_id': clientId,
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
        'scope': _scopes,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
      cancelToken: cancelToken,
    );
    final data = resp.data as Map<String, dynamic>;
    _cacheAccess(data);
    final rotated = data['refresh_token'] as String?;
    if (rotated != null && rotated.isNotEmpty && rotated != refresh) {
      await ref
          .read(settingsProvider.notifier)
          .update((p) => p.copyWith(oneDriveRefreshToken: rotated));
    }
    if (_accessToken == null) throw StateError('刷新令牌失败');
    return _accessToken!;
  }

  // ── Graph file ops (app folder) ────────────────────────────────────────────

  Map<String, dynamic> _auth(String token) =>
      {'Authorization': 'Bearer $token'};

  /// Upload [bytes] to the app folder as [name] via a resumable upload
  /// session (handles archives of any size; chunk = 5 MiB, a 320 KiB multiple
  /// as Graph requires). Overwrites an existing file of the same name.
  Future<void> uploadArchive(String name, Uint8List bytes) async {
    final token = await _validAccessToken();
    final create = await _dio.post(
      '$_graph/me/drive/special/approot:/${Uri.encodeComponent(name)}:/createUploadSession',
      data: {
        'item': {'@microsoft.graph.conflictBehavior': 'replace'},
      },
      options: Options(headers: _auth(token)),
    );
    final uploadUrl = (create.data as Map<String, dynamic>)['uploadUrl'] as String;

    const chunk = 5 * 327680 * 16; // 5 MiB, multiple of 320 KiB
    final total = bytes.length;
    for (var start = 0; start < total; start += chunk) {
      final end = (start + chunk < total) ? start + chunk : total;
      final slice = bytes.sublist(start, end);
      await _dio.put(
        uploadUrl,
        data: Stream.fromIterable([slice]),
        options: Options(
          // No Authorization here — the uploadUrl is already pre-authorized.
          headers: {
            'Content-Length': slice.length,
            'Content-Range': 'bytes $start-${end - 1}/$total',
          },
          contentType: 'application/octet-stream',
          // 202 = more chunks expected; 200/201 = finished.
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
    }
  }

  /// Download [name] from the app folder, or null if it doesn't exist.
  Future<Uint8List?> readArchive(String name) async {
    final token = await _validAccessToken();
    try {
      final resp = await _dio.get<List<int>>(
        '$_graph/me/drive/special/approot:/${Uri.encodeComponent(name)}:/content',
        options: Options(
          headers: _auth(token),
          responseType: ResponseType.bytes,
          validateStatus: (s) => s != null && (s == 200 || s == 404),
        ),
      );
      if (resp.statusCode == 404 || resp.data == null) return null;
      return Uint8List.fromList(resp.data!);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  static const latestName = 'explore_journal_latest.zip';

  Future<Uint8List?> downloadLatest() => readArchive(latestName);

  /// `.zip` archive names currently in the app folder.
  Future<List<String>> listArchives() async {
    final token = await _validAccessToken();
    try {
      final resp = await _dio.get(
        '$_graph/me/drive/special/approot/children',
        queryParameters: {r'$select': 'name', r'$top': 200},
        options: Options(
          headers: _auth(token),
          validateStatus: (s) => s != null && (s == 200 || s == 404),
        ),
      );
      if (resp.statusCode == 404) return const [];
      final value = (resp.data as Map<String, dynamic>)['value'] as List? ?? [];
      return value
          .map((e) => (e as Map<String, dynamic>)['name']?.toString() ?? '')
          .where((n) => n.toLowerCase().endsWith('.zip'))
          .toList()
        ..sort();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      rethrow;
    }
  }

  // ── Incremental Sync folder: Apps/Explore Journal/Sync/<relPath> ──────────
  // Per-file ops used by OneDriveSyncEngine for FOW-style incremental sync.
  // Files here are individual backup entries (small), so a simple PUT/GET is
  // enough — no upload session needed.

  String _syncContentUrl(String rel) {
    final enc = rel.split('/').map(Uri.encodeComponent).join('/');
    return '$_graph/me/drive/special/approot:/Sync/$enc:/content';
  }

  Future<void> putSyncFile(String rel, List<int> bytes,
      {CancelToken? cancelToken}) async {
    final token = await _validAccessToken(cancelToken);
    await _dio.put(
      _syncContentUrl(rel),
      data: Stream.fromIterable([bytes]),
      cancelToken: cancelToken,
      options: Options(
        headers: {..._auth(token), 'Content-Length': bytes.length},
        contentType: 'application/octet-stream',
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
  }

  Future<Uint8List?> getSyncFile(String rel, {CancelToken? cancelToken}) async {
    final token = await _validAccessToken(cancelToken);
    try {
      final r = await _dio.get<List<int>>(
        _syncContentUrl(rel),
        cancelToken: cancelToken,
        options: Options(
          headers: _auth(token),
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

  Future<void> deleteSyncFile(String rel, {CancelToken? cancelToken}) async {
    final token = await _validAccessToken(cancelToken);
    final enc = rel.split('/').map(Uri.encodeComponent).join('/');
    try {
      await _dio.delete(
        '$_graph/me/drive/special/approot:/Sync/$enc',
        cancelToken: cancelToken,
        options: Options(
          headers: _auth(token),
          validateStatus: (s) =>
              s != null && (s == 204 || s == 200 || s == 404),
        ),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return;
      rethrow;
    }
  }
}

final oneDriveServiceProvider =
    Provider<OneDriveService>((ref) => OneDriveService(ref));
