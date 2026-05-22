import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DiagLevel { trace, info, warn, error }

class DiagEvent {
  final DateTime ts;
  final DiagLevel level;
  final String tag;
  final String msg;
  DiagEvent(this.level, this.tag, this.msg) : ts = DateTime.now();

  String format() {
    final h = ts.hour.toString().padLeft(2, '0');
    final m = ts.minute.toString().padLeft(2, '0');
    final s = ts.second.toString().padLeft(2, '0');
    final ms = ts.millisecond.toString().padLeft(3, '0');
    final lvl = switch (level) {
      DiagLevel.trace => 'TRC',
      DiagLevel.info => 'INF',
      DiagLevel.warn => 'WRN',
      DiagLevel.error => 'ERR',
    };
    return '$h:$m:$s.$ms [$lvl] $tag: $msg';
  }
}

/// Ring buffer of group networking events. Read by the diagnostics screen.
///
/// Why this exists: every failure path in the LAN/WebRTC transports used to
/// be `catch (_) {}` — when handshakes silently broke, users had no way to
/// tell whether the bug was group-id mismatch, decrypt failure, the OS
/// dropping multicast packets, or something else. This module makes every
/// such event visible.
class GroupDiagnostics {
  static const int _max = 500;
  final List<DiagEvent> _events = [];
  final _ctrl = StreamController<DiagEvent>.broadcast();

  List<DiagEvent> get events => List.unmodifiable(_events);
  Stream<DiagEvent> get stream => _ctrl.stream;

  void log(DiagLevel level, String tag, String msg) {
    final e = DiagEvent(level, tag, msg);
    _events.add(e);
    if (_events.length > _max) _events.removeAt(0);
    _ctrl.add(e);
  }

  void trace(String tag, String msg) => log(DiagLevel.trace, tag, msg);
  void info(String tag, String msg) => log(DiagLevel.info, tag, msg);
  void warn(String tag, String msg) => log(DiagLevel.warn, tag, msg);
  void error(String tag, String msg) => log(DiagLevel.error, tag, msg);

  void clear() => _events.clear();
}

/// Single global instance. Transports are plain Dart objects with no [Ref]
/// and they fire events from background timers/sockets, so a process-wide
/// static is the path of least resistance. The Riverpod provider just hands
/// out the same instance.
final GroupDiagnostics groupDiagnostics = GroupDiagnostics();

final groupDiagnosticsProvider =
    Provider<GroupDiagnostics>((ref) => groupDiagnostics);
