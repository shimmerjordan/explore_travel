import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:explore_journal/main.dart';

void main() {
  testWidgets('App boots to home', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ExploreJournalApp()));
    await tester.pump();
    expect(find.text('Explore Journal'), findsWidgets);
  });
}
