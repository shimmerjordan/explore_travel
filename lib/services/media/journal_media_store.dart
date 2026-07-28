import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persistent home for journal photos/videos.
///
/// image_picker returns paths inside the app's CACHE directory — the OS (or
/// the user tapping "清除缓存", or an in-place upgrade on some ROMs) can
/// delete those at any time, and journal entries used to store those cache
/// paths verbatim, so photos silently vanished later. Every picked file now
/// gets copied into `documents/journal_media/`, which is inside the
/// auto-backup scope (backup_rules.xml) and survives cache purges and
/// 覆盖安装.
class JournalMediaStore {
  static const _dirName = 'journal_media';

  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, _dirName));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Copy a freshly-picked file into permanent storage; returns the new
  /// path. On any failure returns the ORIGINAL path — a cache path that
  /// works today beats a broken one.
  static Future<String> persist(String srcPath) async {
    if (kIsWeb) return srcPath;
    try {
      final d = await _dir();
      if (p.isWithin(d.path, srcPath)) return srcPath; // already ours
      final name =
          '${DateTime.now().millisecondsSinceEpoch}_${p.basename(srcPath)}';
      final dst = p.join(d.path, name);
      await File(srcPath).copy(dst);
      return dst;
    } catch (e) {
      debugPrint('[JournalMediaStore] persist failed for $srcPath: $e');
      return srcPath;
    }
  }

  /// Resolve a stored path for display. Legacy entries hold absolute paths
  /// that may have died (cache purge) or moved (container path change after
  /// a device restore). Falls back to a same-basename file in the store.
  static Future<String> resolve(String stored) async {
    if (kIsWeb ||
        stored.startsWith('http://') ||
        stored.startsWith('https://') ||
        stored.startsWith('gh-private://')) {
      return stored;
    }
    try {
      if (await File(stored).exists()) return stored;
      final cand = p.join((await _dir()).path, p.basename(stored));
      if (await File(cand).exists()) return cand;
    } catch (_) {}
    return stored;
  }
}
