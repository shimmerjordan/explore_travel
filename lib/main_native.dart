import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'services/location/background_task.dart';

void initPlatform() {
  FlutterForegroundTask.initCommunicationPort();
  BackgroundLocation.init();
}

Widget wrapWithForegroundTask({required Widget child}) {
  // WithForegroundTask's back-button handler queries the (Android/iOS-only)
  // service plugin; on desktop that would throw MissingPluginException, and
  // there's no foreground service to minimise to anyway.
  if (!BackgroundLocation.supported) return child;
  return WithForegroundTask(child: child);
}
