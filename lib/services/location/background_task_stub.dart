import 'dart:async';
import '../../models/models.dart';

/// Stub for web — background location is not available on web.
class BackgroundLocation {
  static void init() {}
  static Future<void> start(RecordingMode mode) async {}
  static Future<void> stop() async {}
  static StreamSubscription<Map<String, dynamic>> listen(
      void Function(Map<String, dynamic>) onSample) {
    return const Stream<Map<String, dynamic>>.empty().listen(onSample);
  }
}
