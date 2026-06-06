import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Durable on-disk GPS sample buffer (one JSON object per line).
///
/// Why it exists: the foreground-service background isolate keeps streaming
/// GPS even when the UI/main isolate isn't running — the screen has been off
/// long enough that the OS suspended the main isolate, or the service was
/// auto-restarted after a reboot with no Activity at all. In those windows
/// `sendDataToMain` reaches nobody, so the background isolate also appends
/// every fix here. The main isolate drains the file into the database on
/// launch / resume / record-start, so nothing recorded in the background is
/// lost.
///
/// Single-writer (background isolate) / single-reader (main isolate). A fix
/// appended in the instant between the reader's read and truncate can be
/// dropped — acceptable for a trail where samples are plentiful and a single
/// missed point is invisible.
class SampleBuffer {
  static File? _cached;

  static Future<File> _file() async {
    if (_cached != null) return _cached!;
    final dir = await getApplicationSupportDirectory();
    return _cached = File(p.join(dir.path, 'pending_track.jsonl'));
  }

  /// Append one sample. Called from the background isolate on every fix.
  static Future<void> append(Map<String, dynamic> sample) async {
    try {
      final f = await _file();
      await f.writeAsString('${jsonEncode(sample)}\n',
          mode: FileMode.append, flush: true);
    } catch (_) {
      // Best-effort durability; a failed append just means this one fix
      // isn't buffered. Never throw into the GPS callback.
    }
  }

  /// Read everything buffered and clear the file. Called from the main
  /// isolate to drain the background-captured gap into the DB.
  static Future<List<Map<String, dynamic>>> drain() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const [];
      final lines = await f.readAsLines();
      await f.writeAsString(''); // truncate — we've taken ownership of these
      final out = <Map<String, dynamic>>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final m = jsonDecode(line);
          if (m is Map) {
            out.add(<String, dynamic>{
              for (final e in m.entries) e.key.toString(): e.value,
            });
          }
        } catch (_) {
          // Skip a torn/partial line (possible if a write interleaved a
          // truncate). The rest of the buffer is still good.
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Discard any buffered samples without ingesting them (called on stop so
  /// a fresh recording doesn't inherit stale points).
  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.writeAsString('');
    } catch (_) {}
  }
}
