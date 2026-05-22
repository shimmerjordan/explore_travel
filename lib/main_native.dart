import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'services/location/background_task.dart';

void initPlatform() {
  FlutterForegroundTask.initCommunicationPort();
  BackgroundLocation.init();
}

Widget wrapWithForegroundTask({required Widget child}) {
  return WithForegroundTask(child: child);
}
