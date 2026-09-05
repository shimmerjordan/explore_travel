import 'dart:async';
import '../../models/models.dart';

const String kStopRecordingButtonId = 'stop_recording';
const String kStoppedFromNotification = 'stopped_from_notification';

/// Stub for web — background location is not available on web.
class BackgroundLocation {
  static void init() {}
  static Future<void> start(RecordingMode mode) async {}
  static Future<void> stop() async {}
  static Future<bool> wasRecording() async => false;
  static Future<bool> isServiceRunning() async => false;
  static StreamSubscription<Map<String, dynamic>> listen(
      void Function(Map<String, dynamic>) onSample,
      {void Function(String cmd)? onCommand}) {
    return const Stream<Map<String, dynamic>>.empty().listen(onSample);
  }
}
