import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/app/providers.dart';
import 'package:explore_journal/app/recording_controller.dart';

void main() {
  group('viewOnly source-gates the recording pipeline', () {
    test('start() refuses and does not flip recordingActive when viewOnly', () async {
      final container = ProviderContainer(overrides: [
        viewOnlyProvider.overrideWith((ref) => true),
      ]);
      addTearDown(container.dispose);

      final ctrl = container.read(recordingControllerProvider);
      final err = await ctrl.start();

      expect(err, isNotNull,
          reason: 'a read-only build must refuse to start recording');
      expect(container.read(recordingActiveProvider), isFalse,
          reason: 'recording must not become active in view-only mode');
    });

    test('resumeIfRecording() is a no-op when viewOnly', () async {
      final container = ProviderContainer(overrides: [
        viewOnlyProvider.overrideWith((ref) => true),
      ]);
      addTearDown(container.dispose);

      // Must complete without touching platform plugins (it returns at the gate).
      await container.read(recordingControllerProvider).resumeIfRecording();
      expect(container.read(recordingActiveProvider), isFalse);
    });

    test('viewOnly defaults to false on native (recording allowed)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(viewOnlyProvider), isFalse);
    });
  });
}
