import 'dart:collection';
import 'package:flutter/foundation.dart';

/// In-memory ring buffer that captures every `debugPrint` call after
/// [LogBuffer.install] runs. Used by the debug log viewer screen.
///
/// We don't suppress the original print output — Flutter's `debugPrint`
/// still hits the platform console as before, we just additionally append
/// to this buffer so the user (or a bug-report email) can read it inside
/// the app.
class LogBuffer {
  static final ListQueue<LogEntry> _entries = ListQueue();
  static const _maxEntries = 1000;
  static int _seq = 0;
  static DebugPrintCallback? _original;
  static final List<VoidCallback> _listeners = [];

  static void install() {
    if (_original != null) return;
    _original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      _push(message ?? '');
      _original!(message, wrapWidth: wrapWidth);
    };
  }

  static bool get installed => _original != null;

  /// Put the plain `debugPrint` back. Release builds only capture while the
  /// hidden debug mode is on — every log line otherwise costs an allocation
  /// and a listener sweep for a viewer nobody has opened.
  static void uninstall() {
    final orig = _original;
    if (orig == null) return;
    debugPrint = orig;
    _original = null;
  }

  static void _push(String line) {
    _entries.add(LogEntry(
      seq: _seq++,
      time: DateTime.now(),
      message: line,
    ));
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    for (final l in _listeners) {
      l();
    }
  }

  static List<LogEntry> snapshot() => _entries.toList(growable: false);

  static void clear() {
    _entries.clear();
    for (final l in _listeners) {
      l();
    }
  }

  static void addListener(VoidCallback l) => _listeners.add(l);
  static void removeListener(VoidCallback l) => _listeners.remove(l);

  static String exportText() {
    final buf = StringBuffer();
    for (final e in _entries) {
      buf.writeln('[${e.time.toIso8601String()}] ${e.message}');
    }
    return buf.toString();
  }
}

class LogEntry {
  final int seq;
  final DateTime time;
  final String message;
  const LogEntry(
      {required this.seq, required this.time, required this.message});
}
