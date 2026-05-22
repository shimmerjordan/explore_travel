import 'package:flutter/material.dart';

void initPlatform() {
  // No foreground task / background location on web.
}

Widget wrapWithForegroundTask({required Widget child}) => child;
