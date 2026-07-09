import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/prefs.dart';
import '../../data/db/database.dart';
import '../geo/country_lookup.dart';
import '../geo/geocoding_service.dart';
import 'imghost_service.dart';

/// One image's upload lifecycle. Persisted as JSON in SharedPreferences so a
/// crash mid-upload doesn't lose pending work, and the journal viewer can
/// show a retry button next time the user opens it.
class UploadRecord {
  final String localPath;
  final int journalId;
  /// 'pending' | 'done' | 'failed'
  final String status;
  /// Public CDN/host URL once done. Substituted into the entry's mediaPaths
  /// and richContent in place of the local file path.
  final String? remoteUrl;
  /// Backend-specific delete token (json'd `{path,sha}` for GitHub, or the
  /// origin URL for custom). null until upload succeeds.
  final String? deleteToken;
  final String? error;
  final DateTime updatedAt;

  const UploadRecord({
    required this.localPath,
    required this.journalId,
    required this.status,
    this.remoteUrl,
    this.deleteToken,
    this.error,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'localPath': localPath,
        'journalId': journalId,
        'status': status,
        'remoteUrl': remoteUrl,
        'deleteToken': deleteToken,
        'error': error,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static UploadRecord fromJson(Map<String, dynamic> j) => UploadRecord(
        localPath: j['localPath'].toString(),
        journalId: (j['journalId'] as num).toInt(),
        status: j['status']?.toString() ?? 'pending',
        remoteUrl: j['remoteUrl']?.toString(),
        deleteToken: j['deleteToken']?.toString(),
        error: j['error']?.toString(),
        updatedAt:
            DateTime.tryParse(j['updatedAt']?.toString() ?? '') ?? DateTime.now(),
      );

  UploadRecord copyWith({
    String? status,
    String? remoteUrl,
    String? deleteToken,
    String? error,
  }) =>
      UploadRecord(
        localPath: localPath,
        journalId: journalId,
        status: status ?? this.status,
        remoteUrl: remoteUrl ?? this.remoteUrl,
        deleteToken: deleteToken ?? this.deleteToken,
        error: error ?? this.error,
        updatedAt: DateTime.now(),
      );
}

/// Single queue + persistent registry shared by the journal save flow and
/// the retry buttons in the viewer.
///
/// Design notes:
/// * Records are keyed by [localPath] — uploading the same file twice
///   short-circuits to the existing remote URL.
/// * Once an upload finishes, we rewrite the owning journal entry's
///   `mediaPaths` and `richContent` in-place so future views (and backups)
///   reference the remote URL. The local file is left on disk for now —
///   we don't delete user-imported originals.
/// * Deletes are best-effort: failing remotes do NOT block the DB delete.
class UploadQueue {
  static const _prefsKey = 'img_host_uploads_v1';
  final AppDb db;
  final GeocodingService? geocoding;
  AppSettings _settings;

  UploadQueue(this.db, AppSettings settings, {this.geocoding})
      : _settings = settings;

  void updateSettings(AppSettings s) {
    _settings = s;
  }

  /// Bumped on every registry write so reactive UIs (the journal list badge,
  /// the upload-list screen) can refresh without polling. The registry lives
  /// in SharedPreferences, which isn't reactive on its own.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// All upload records, newest first — for the upload-list screen.
  Future<List<UploadRecord>> allRecords() async {
    final all = await _loadAll();
    final list = all.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// Manually kick the queue — used by the upload list's 上传 button when
  /// auto-upload is off (so pending items only go when the user says so).
  Future<void> drainNow() => _drain();

  // Persistence -------------------------------------------------------------

  Future<Map<String, UploadRecord>> _loadAll() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw == null) return {};
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map(
        (k, v) => MapEntry(k, UploadRecord.fromJson(v as Map<String, dynamic>)));
  }

  Future<void> _saveAll(Map<String, UploadRecord> all) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey,
        jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))));
    revision.value++;
  }

  Future<UploadRecord?> recordFor(String localPath) async {
    final all = await _loadAll();
    return all[localPath];
  }

  Future<List<UploadRecord>> recordsForJournal(int journalId) async {
    final all = await _loadAll();
    return all.values.where((r) => r.journalId == journalId).toList();
  }

  Future<void> _upsert(UploadRecord r) async {
    final all = await _loadAll();
    all[r.localPath] = r;
    await _saveAll(all);
  }

  // Public API --------------------------------------------------------------

  bool get isEnabled => _settings.imgHostKind != 'none';

  /// Enqueue every local file referenced by an entry. Skips files that are
  /// already URLs (remote) or already have a `done` record. The actual
  /// upload starts in the background — call sites don't need to await it.
  Future<void> enqueueForJournal({
    required int journalId,
    required List<String> localPaths,
    required String richContent,
  }) async {
    if (!isEnabled) return;
    final paths = <String>{};
    for (final raw in localPaths) {
      if (raw.isEmpty) continue;
      if (_isRemote(raw)) continue;
      paths.add(raw);
    }
    // Also pull image paths out of the Quill Delta JSON.
    paths.addAll(_extractQuillImagePaths(richContent));

    for (final localPath in paths) {
      final existing = await recordFor(localPath);
      if (existing != null && existing.status == 'done') continue;
      await _upsert(UploadRecord(
        localPath: localPath,
        journalId: journalId,
        status: 'pending',
        updatedAt: DateTime.now(),
      ));
    }
    // Auto-upload is opt-out: when the user has turned it off, the work stays
    // `pending` in the registry until they tap 上传 in the upload list.
    if (_settings.autoUploadImages) {
      unawaited(_drain());
    }
  }

  Future<void> retry(String localPath) async {
    final r = await recordFor(localPath);
    if (r == null) return;
    await _upsert(r.copyWith(status: 'pending', error: ''));
    unawaited(_drain());
  }

  Future<void> retryAllForJournal(int journalId) async {
    final all = await _loadAll();
    for (final r in all.values) {
      if (r.journalId == journalId && r.status != 'done') {
        all[r.localPath] = r.copyWith(status: 'pending', error: '');
      }
    }
    await _saveAll(all);
    unawaited(_drain());
  }

  /// Delete every remote we know about for [journalId] (best-effort) and
  /// scrub the registry rows. Call this BEFORE the journal row is removed
  /// from drift.
  Future<void> deleteAllForJournal(int journalId) async {
    final all = await _loadAll();
    // Look up the entry's level so we delete against the right repo. If
    // the row is already gone (deleteAllForJournal is normally called
    // BEFORE the DB delete), default to public.
    final entry = await (db.select(db.journalEntries)
          ..where((t) => t.id.equals(journalId)))
        .getSingleOrNull();
    final backend =
        backendFromSettings(_settings, level: entry?.level ?? 'public');
    final mine = all.values.where((r) => r.journalId == journalId).toList();
    for (final r in mine) {
      if (r.status == 'done' &&
          r.remoteUrl != null &&
          r.deleteToken != null) {
        try {
          await backend.delete(r.remoteUrl!, r.deleteToken!);
        } catch (e) {
          debugPrint('[UploadQueue] remote delete failed for ${r.remoteUrl}: $e');
        }
      }
      all.remove(r.localPath);
    }
    await _saveAll(all);
  }

  // Internals ---------------------------------------------------------------

  bool _draining = false;
  Future<void> _drain() async {
    if (_draining) return;
    if (!isEnabled) return;
    _draining = true;
    try {
      while (true) {
        final all = await _loadAll();
        final next = all.values
            .where((r) => r.status == 'pending')
            .toList()
          ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
        if (next.isEmpty) break;
        final r = next.first;
        await _processOne(r);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _processOne(UploadRecord r) async {
    final f = File(r.localPath);
    if (!f.existsSync()) {
      await _upsert(r.copyWith(status: 'failed', error: '本地文件不存在'));
      return;
    }
    // Resolve entry-driven context (level / traveler / continent / country).
    final entry = await (db.select(db.journalEntries)
          ..where((t) => t.id.equals(r.journalId)))
        .getSingleOrNull();
    final level = entry?.level ?? 'public';
    final backend = backendFromSettings(_settings, level: level);
    if (backend is NoopBackend) {
      await _upsert(r.copyWith(
          status: 'failed',
          error: level == 'private' ? '私有图床未配置' : '图床未配置'));
      return;
    }
    String? continent, country, province, city;
    if (entry != null) {
      try {
        // Use the layered geocoder first (cache → Amap → system → bbox).
        // It also seeds the learned-regions table as a side effect.
        if (geocoding != null) {
          final r = await geocoding!.resolve(entry.lat, entry.lng);
          country = r.country.isEmpty ? null : r.country;
          province = r.province.isEmpty ? null : r.province;
          city = r.city.isEmpty ? null : r.city;
        }
        // Pull continent from the bundled bbox table regardless — that's
        // the only place we know which countries belong to which continent.
        if (country != null) {
          final lk = await CountryLookupExt.continentFor(country);
          continent = lk;
        }
      } catch (e) {
        debugPrint('[UploadQueue] geocode failed: $e');
      }
    }
    // Compose the title slug suffix with city when known, so two entries
    // in different cities don't collide even before journalId is appended.
    final titleSlug = entry?.title;
    final ctx = UploadContext(
      journalId: r.journalId,
      level: level,
      travelerSlug: entry?.ownerPeerId ?? 'self',
      continent: continent,
      country: country,
      province: province,
      city: city,
      titleSlug: titleSlug,
    );
    try {
      final res = await backend.upload(f, ctx: ctx);
      await _upsert(r.copyWith(
        status: 'done',
        remoteUrl: res.displayUrl,
        deleteToken: res.deleteToken,
        error: '',
      ));
      await _applyToEntry(r.journalId, r.localPath, res.displayUrl);
    } catch (e, st) {
      debugPrint('[UploadQueue] upload failed for ${r.localPath}: $e\n$st');
      await _upsert(r.copyWith(status: 'failed', error: e.toString()));
    }
  }

  /// Replace every occurrence of [localPath] in the journal entry's
  /// mediaPaths and richContent with [remoteUrl], and write the new row
  /// back. Idempotent — running twice is harmless.
  Future<void> _applyToEntry(
      int journalId, String localPath, String remoteUrl) async {
    final entry =
        await (db.select(db.journalEntries)..where((t) => t.id.equals(journalId)))
            .getSingleOrNull();
    if (entry == null) return;

    final newMedia = entry.mediaPaths
        .split('\n')
        .map((p) => p == localPath ? remoteUrl : p)
        .join('\n');

    // Quill Delta: replace `{"insert":{"image":"<localPath>"}}` payloads.
    String newRich = entry.richContent;
    if (newRich.contains(localPath)) {
      try {
        final delta = jsonDecode(newRich) as List;
        for (final op in delta) {
          if (op is Map &&
              op['insert'] is Map &&
              (op['insert'] as Map)['image'] == localPath) {
            (op['insert'] as Map)['image'] = remoteUrl;
          }
        }
        newRich = jsonEncode(delta);
      } catch (_) {
        // Non-Quill body — fall back to a literal replace.
        newRich = newRich.replaceAll(localPath, remoteUrl);
      }
    }

    if (newMedia == entry.mediaPaths && newRich == entry.richContent) return;
    await (db.update(db.journalEntries)..where((t) => t.id.equals(journalId)))
        .write(JournalEntriesCompanion(
      mediaPaths: Value(newMedia),
      richContent: Value(newRich),
      // The URL rewrite is a content edit — stamp it so the hosted-image
      // version wins sync merges against the local-path copy elsewhere.
      updatedAt: Value(DateTime.now()),
    ));
    // Keep FTS consistent — the rich body is part of the search index.
    if (newRich != entry.richContent) {
      try {
        await db.customStatement(
            'UPDATE journal_fts SET content=? WHERE rowid=?',
            [newRich, journalId]);
      } catch (_) {}
    }
  }

  static bool _isRemote(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

  /// Pull every `{"insert":{"image":"..."}}` payload out of a Delta JSON.
  /// Returns only local paths (skips URLs).
  static Iterable<String> _extractQuillImagePaths(String richContent) sync* {
    if (richContent.isEmpty) return;
    try {
      final delta = jsonDecode(richContent);
      if (delta is! List) return;
      for (final op in delta) {
        if (op is Map &&
            op['insert'] is Map &&
            (op['insert'] as Map)['image'] is String) {
          final s = (op['insert'] as Map)['image'] as String;
          if (!_isRemote(s)) yield s;
        }
      }
    } catch (_) {
      // ignore
    }
  }
}
