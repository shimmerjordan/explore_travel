import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:explore_journal/main.dart';

void main() {
  // Smoke test: the app must construct its provider graph + GoRouter and mount
  // the root MaterialApp without throwing on the first frame. The boot route is
  // the map (`/`), not a screen with literal "Explore Journal" text, so we
  // assert the router mounted rather than scraping a label off the home menu.
  testWidgets('App boots and mounts the router without throwing',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ExploreJournalApp()));
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
